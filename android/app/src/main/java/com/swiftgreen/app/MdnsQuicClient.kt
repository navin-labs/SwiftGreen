package com.swiftgreen.app

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Base64
import android.net.wifi.WifiManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import androidx.core.net.toUri
import androidx.core.graphics.scale
import androidx.core.graphics.createBitmap
import androidx.core.content.edit

/** The Mac proved (PROTOCOL.md §3.4) that it deleted our key: unpaired there while we were away. */
private class PeerUnpairedException : Exception("Unpaired on your Mac")

/** The Mac refused our key without proving an unpair. Retrying can't help; the user has to act. */
private class AuthRejectedException(message: String) : Exception(message)

class MdnsQuicClient(context: android.content.Context) {

    private val appContext = context.applicationContext
    private val TAG = "MdnsSslClient"
    private val wifiManager = appContext.getSystemService(android.content.Context.WIFI_SERVICE) as WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null

    // PairingManager reference — set from outside for challenge-response
    var pairingManager: PairingManager? = null

    // Step 15.3 — incoming call control. Registered on tunnel-complete, torn down on disconnect.
    private val callControl = CallControlManager(appContext) { json ->
        try { sendJsonPayload(json) } catch (e: Exception) {
            Log.e(TAG, "call control send failed: ${e.localizedMessage}")
        }
    }

    companion object {
        @Volatile
        private var activeClient: MdnsQuicClient? = null

        fun getActiveClient(): MdnsQuicClient? = activeClient

        // Retry configuration
        private const val MAX_RETRIES = 3
        private const val BASE_RETRY_DELAY_MS = 1_000L   // 1s → 2s → 4s (exponential)
        private const val CONNECT_TIMEOUT_MS = 5_000      // 5 seconds to establish TCP+TLS
        private const val READ_TIMEOUT_MS    = 120_000    // 2 minutes — tolerates Doze throttling
        private const val RESOLVE_TIMEOUT_MS = 3_000L    // fresh mDNS resolve before dialling cached port
        // TLS handshake + challenge. Was unbounded (soTimeout 0 before the handshake): a
        // Mac that accepted TCP but never answered held isConnecting, and "Connecting…",
        // forever.
        private const val HANDSHAKE_TIMEOUT_MS = 15_000
        // No line from the Mac for this long = dead link. The Mac pings every 30 s and
        // declares the phone dead after 100 s of silence (mDNSQuicServer
        // keepaliveDeadThreshold); the same 100 s here makes both sides agree. Before
        // this the phone had no timeout at all and kept a dead socket until something
        // happened to write to it. The read timer runs on the monotonic clock, so a
        // phone in deep sleep doesn't trip it.
        private const val IDLE_TIMEOUT_MS = 100_000
    }

    init {
        activeClient = this
        // ponytail: the multicast lock stays off the Wi-Fi radio except during the ~3s
        // mDNS resolve in resolveAndConnect. Held forever, it kept the radio from
        // filtering multicast and drained battery all day.
        multicastLock = wifiManager.createMulticastLock("SwiftGreenQuicClient").apply { setReferenceCounted(false) }
    }

    // Background coroutine scope and job for connection operations
    // A reply racing a disconnect (sendJsonPayload → "No active TLS socket") used to be
    // uncaught in its launch{} and crash the whole app. Log it instead: the Mac
    // re-requests whatever it didn't get once it reconnects.
    private val clientScope = CoroutineScope(Dispatchers.IO + SupervisorJob() +
        kotlinx.coroutines.CoroutineExceptionHandler { _, e -> Log.w(TAG, "Background job failed: ${e.message}", e) })
    private var connectionJob: Job? = null
    private val isConnecting = java.util.concurrent.atomic.AtomicBoolean(false)

    @Volatile
    private var activeSocket: SSLSocket? = null

    @Volatile
    private var lastConnectedDevice: NsdServiceInfo? = null

    @Volatile
    private var lastConnectedDeviceTimestamp: Long = 0L

    // Reactive states for Compose UI
    private val _connectionStatus = MutableStateFlow("Disconnected")
    val connectionStatus: StateFlow<String> = _connectionStatus.asStateFlow()

    private val _receivedMessage = MutableStateFlow("")
    val receivedMessage: StateFlow<String> = _receivedMessage.asStateFlow()

    private val _latencyMs = MutableStateFlow<Int?>(null)
    val latencyMs: StateFlow<Int?> = _latencyMs.asStateFlow()

    /** True while the auto-reconnect loop has attempts left: the only time the UI says "Connecting". */
    private val _reconnecting = MutableStateFlow(false)
    val reconnecting: StateFlow<Boolean> = _reconnecting.asStateFlow()

    /**
     * Set when the Mac refused our key without proving an unpair. Every automatic
     * reconnect stops until the user taps Connect ([retryAfterIssue]) or re-pairs:
     * a loop can't fix a key mismatch, it only showed "Connecting" forever.
     */
    private val _linkIssue = MutableStateFlow<String?>(null)
    val linkIssue: StateFlow<String?> = _linkIssue.asStateFlow()

    /** The user asked to connect again after [linkIssue]. */
    fun retryAfterIssue() { _linkIssue.value = null }

    private fun blockedByIssue(): Boolean =
        (_linkIssue.value != null).also { if (it) Log.d(TAG, "Not reconnecting: ${_linkIssue.value}") }

    @Volatile
    private var keepaliveSendTime: Long = 0L
    /** Round trips of the current probe burst; see handleIncomingLine's heartbeat_ack. */
    private val latencyBurst = mutableListOf<Int>()

    fun isConnected(): Boolean {
        val socket = activeSocket
        return socket != null && socket.isConnected && !socket.isClosed
    }

    fun connectToService(serviceInfo: NsdServiceInfo) {
        if (blockedByIssue()) return
        if (isConnecting.getAndSet(true)) return
        if (isConnected() || _connectionStatus.value == "Connecting over TLS...") {
            Log.d(TAG, "Already connected or actively connecting. Ignoring duplicate trigger.")
            isConnecting.set(false)
            return
        }
        val host = serviceInfo.firstHost?.hostAddress ?: run {
            isConnecting.set(false)
            return
        }
        val port = serviceInfo.port

        Log.d(TAG, "Connecting to TCP TLS server at $host:$port")
        _connectionStatus.value = "Connecting over TLS..."
        _receivedMessage.value = ""

        connectionJob?.cancel()
        connectionJob = clientScope.launch {
            try {
                connectWithRetry(serviceInfo)
            } finally {
                isConnecting.set(false)
            }
        }
    }
    
    fun connectForStandardSync(serviceInfo: NsdServiceInfo) {
        connectToService(serviceInfo)
    }

    /**
     * Attempts to connect to [host]:[port] up to [MAX_RETRIES] times.
     * Uses exponential back-off between attempts: 1s, 2s, 4s.
     * Gives up and marks status as failed after all retries are exhausted.
     */
    private suspend fun connectWithRetry(serviceInfo: NsdServiceInfo) {
        val host = serviceInfo.firstHost?.hostAddress ?: return
        val port = serviceInfo.port
        var attempt = 0
        while (attempt <= MAX_RETRIES && currentCoroutineContext().isActive) {
            if (attempt > 0) {
                val delayMs = BASE_RETRY_DELAY_MS * (1L shl (attempt - 1))  // 1s, 2s, 4s
                Log.d(TAG, "Retry $attempt/$MAX_RETRIES — waiting ${delayMs}ms before next attempt...")
                _connectionStatus.value = "Retrying ($attempt/$MAX_RETRIES)..."
                delay(delayMs)
            }

            try {
                delay(2000)
                attemptConnection(serviceInfo)
                return   // Clean exit — no retry needed after successful run
            } catch (e: Exception) {
                if (handleAuthVerdict(e)) return
                Log.e(TAG, "Connection attempt ${attempt + 1} failed: ${e.localizedMessage}")
                // Refused = nothing listens on that port: the Mac restarted on a new one.
                // Redialling it only delays the fresh mDNS resolve the next attempt does.
                val refused = e is java.net.ConnectException
                if (attempt == MAX_RETRIES || refused) {
                    Log.e(TAG, if (refused) "Port refused — giving up to re-resolve." else "All $MAX_RETRIES retries exhausted. Giving up.")
                    // A failed dial isn't the user leaving: the auto-reconnect loop keeps going.
                    disconnect(keepAutoReconnect = true)
                    // Reset to Disconnected so LaunchedEffect auto-connect daemon can restart
                    _connectionStatus.value = "Disconnected"
                    return
                }
            }
            attempt++
        }
    }

    /**
     * TLS context for the Mac's self-signed, per-install certificate. No CA can vouch for it,
     * so trust is decided after the handshake by its SHA-256 pin (QR or key-proven `tls_id`,
     * [MacCertPin], SG-09): pairing refuses a mismatch before the PIN proof; a reconnect
     * reads only a key-proven `unpaired` from it and sends nothing. The handshake itself
     * must therefore complete for any server certificate, as long as there is one.
     */
    private fun macSSLContext(): SSLContext {
        // Custom by design: the pin replaces CA validation (see above). Regression tests: MacCertPinTest.
        @android.annotation.SuppressLint("CustomX509TrustManager")
        val pinChecksAfterHandshake = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
                throw CertificateException("The phone never accepts TLS clients")
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                if (chain.isNullOrEmpty()) throw CertificateException("The Mac sent no certificate to check against the pin")
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }

        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf<TrustManager>(pinChecksAfterHandshake), java.security.SecureRandom())
        return sslContext
    }

    /**
     * Performs a single connection attempt: creates an [SSLSocket], sets explicit
     * [CONNECT_TIMEOUT_MS] and [READ_TIMEOUT_MS], performs TLS handshake,
     * runs challenge-response authentication, sends the hello payload,
     * registers the socket with [TunnelManager], then loops reading until EOF.
     *
     * Throws on any network, TLS, or challenge error so [connectWithRetry] can handle back-off.
     */
    private fun attemptConnection(serviceInfo: NsdServiceInfo) {
        val host = serviceInfo.firstHost?.hostAddress ?: throw IllegalArgumentException("Host address is null")
        val port = serviceInfo.port
        // Close any previous socket before opening a new one
        try {
            activeSocket?.close()
        } catch (e: Exception) {
            // ignore
        }

        // Configure a trust-all SSLContext to bypass self-signed certificate validation
        val sslContext = macSSLContext()

        // Create an unconnected SSLSocket so we can set the connect timeout separately
        val socketFactory = sslContext.socketFactory
        val socket = socketFactory.createSocket() as SSLSocket
        activeSocket = socket

        // --- Timeouts ---
        socket.soTimeout = READ_TIMEOUT_MS

        Log.d(TAG, "Connecting socket to $host:$port (timeout=${CONNECT_TIMEOUT_MS}ms)...")
        val reader: LineReader
        val outputStream: OutputStream
        try {
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)

            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.setPerformancePreferences(0, 1, 0)

            reader = LineReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            outputStream = socket.outputStream
            handshakeAndAuthenticate(socket, reader, outputStream, "")
        } catch (e: Throwable) {
            abandonHandshake(socket)
            throw e
        }

        lastConnectedDevice = serviceInfo
        lastConnectedDeviceTimestamp = System.currentTimeMillis()
        saveLastKnownHost(host, port, serviceInfo.serviceName)
        _connectionStatus.value = "Connected over TLS!"

        // Send hello payload after successful challenge
        writeLine(outputStream, "SwiftGreen-Hello-Android")
        Log.d(TAG, "Sent SwiftGreen-Hello-Android to Mac")
        socket.soTimeout = IDLE_TIMEOUT_MS

        // Register socket so notification listener can send through this socket
        TunnelManager.registerSocket(socket)
        // Call-state receiver lives with the connection, not with the Mac's hello line.
        // Idempotent via CallControlManager.registered.
        callControl.start()
        // Same lifetime, same reason: without it the log was a connect-time snapshot and
        // a call that ended while connected never reached the Mac at all.
        CallLogHistoryManager.start(SwiftGreenApplication.instance)

        // Send battery telemetry after socket is registered
        TunnelManager.sendBatteryTelemetry(SwiftGreenApplication.instance)
        // Static device facts — same unprompted push, once per connection.
        TunnelManager.sendDeviceInfo(SwiftGreenApplication.instance)
        // Now-playing with artwork, so the Mac never shows a track without its art.
        MediaSessionManager.instance?.resendOnConnect()
        // Sync call log once per connection (background — READ_CALL_LOG query blocks briefly)
        clientScope.launch(Dispatchers.IO) {
            CallLogHistoryManager.fetchAndSerialize(SwiftGreenApplication.instance)?.let {
                TunnelManager.sendRawMessage(it)
            }
        }
        ClipboardSyncManager.sendMessage = { payload ->
            try {
                sendJsonPayload(payload)
            } catch (e: Exception) {
                Log.w(TAG, "Clipboard send failed: ${e.localizedMessage}")
            }
        }
        // Flush after a short delay to ensure read loop is established
        clientScope.launch(Dispatchers.IO) {
            delay(500)
            ClipboardSyncManager.flushPendingClipboard()
        }

        // One latency reading 3s in, so the Mac isn't showing "Measuring…". After that
        // the Mac drives keepalive with its own ping (see "ping" below): this side keeps
        // no timer, so the phone can sleep between pings like any idle socket.
        val keepaliveJob = clientScope.launch {
            delay(3_000L)
            runCatching {
                if (isConnected()) {
                    synchronized(latencyBurst) { latencyBurst.clear() }
                    sendKeepalive()
                }
            }
        }

        val openedAt = System.currentTimeMillis()
        var lastType = ""
        try {
            // Persistent read loop — blocks until EOF or socket is closed
            while (activeSocket == socket && !socket.isClosed) {
                val responseText = reader.readLine()
                if (responseText == null) {
                    Log.d(TAG, "Socket stream closed (EOF received)")
                    break
                }
                lastType = messageType(responseText)
                handleIncomingLine(responseText)
            }
        } catch (e: java.net.SocketTimeoutException) {
            Log.w(TAG, "Nothing from the Mac for ${IDLE_TIMEOUT_MS / 1000}s — link is dead, reconnecting")
        } catch (e: IOException) {
            Log.w(TAG, "Socket read failed or was closed: ${e.localizedMessage}")
        } catch (e: Throwable) {
            // Not a network error: a handler threw and takes the tunnel down with it.
            // Logged with the message type so a tunnel drop can be pinned on one.
            Log.e(TAG, "Read loop ended by ${e.javaClass.simpleName} while handling '$lastType'", e)
            throw e
        } finally {
            keepaliveJob.cancel()
            // Still the active socket = the Mac (or network) dropped us. A deliberate
            // disconnect() clears activeSocket first, so that path won't retry.
            val droppedByPeer = activeSocket === socket
            Log.d(TAG, "Connection ended after ${(System.currentTimeMillis() - openedAt) / 1000}s " +
                "(last message '$lastType', ${if (droppedByPeer) "dropped — will reconnect" else "closed here"})")
            disconnect(socket)
            if (droppedByPeer) scheduleReconnect()
        }
    }

    /** For the log only. A scan, not a parse: file chunks run to megabytes and are parsed once already. */
    private fun messageType(line: String): String {
        val at = line.indexOf("\"type\":\"")
        if (at < 0) return line.take(40)
        val end = line.indexOf('"', at + 8)
        return if (end > at + 8) line.substring(at + 8, end) else "?"
    }

    /**
     * A handshake or auth that failed after TCP connected used to leave its socket as
     * [activeSocket]. That socket still reads as connected, so [isConnected] stayed true
     * and every reconnect trigger bailed out ("already connected") while the UI showed
     * Connecting and the Mac showed Disconnected — indefinitely.
     */
    private fun abandonHandshake(socket: SSLSocket) {
        if (activeSocket === socket) activeSocket = null
        runCatching { socket.close() }
    }

    /** TLS handshake plus challenge-response, timed so a slow reconnect shows where the time went. */
    private fun handshakeAndAuthenticate(socket: SSLSocket, reader: LineReader, out: OutputStream, logPrefix: String) {
        val tcpAt = android.os.SystemClock.elapsedRealtime()
        Log.d(TAG, "${logPrefix}TCP connected. Starting TLS handshake...")
        socket.startHandshake()
        val tlsAt = android.os.SystemClock.elapsedRealtime()
        Log.d(TAG, "${logPrefix}TLS handshake complete in ${tlsAt - tcpAt} ms " +
            "(${socket.session?.protocol}, ${socket.session?.cipherSuite})")
        performChallengeResponse(reader, out, socket, peerFingerprint(socket))
        reader.limit = LineReader.AFTER_AUTH  // the Mac has proved the key; its own ceiling applies
        Log.d(TAG, "${logPrefix}Authenticated in ${android.os.SystemClock.elapsedRealtime() - tlsAt} ms after TLS")
        _linkIssue.value = null
    }

    /** SHA-256 of the certificate this TLS session presented, or null if it presented none. */
    private fun peerFingerprint(socket: SSLSocket): ByteArray? =
        runCatching { socket.session.peerCertificates.firstOrNull()?.encoded }.getOrNull()
            ?.let { MacCertPin.fingerprint(it) }

    /**
     * Auth outcomes a retry can't change. Returns true when [e] was one of them, after
     * acting on it; the caller stops retrying.
     */
    private fun handleAuthVerdict(e: Exception): Boolean = when (e) {
        is PeerUnpairedException -> {
            Log.w(TAG, "Mac proved it unpaired this phone — deleting the key here too")
            onPeerUnpaired()
            true
        }
        is AuthRejectedException -> {
            Log.w(TAG, "Mac rejected this phone's key: ${e.message} — auto-reconnect stopped")
            _linkIssue.value = e.message
            disconnect()
            true
        }
        else -> false
    }

    /** The Mac unpaired (live, or proved it on reconnect): forget it and stop syncing, like a local unpair. */
    private fun onPeerUnpaired() {
        (pairingManager ?: PairingManager(appContext))
            .resetPairing(notifyPeer = false, notice = "Unpaired on your Mac. Pair again to reconnect.")
        disconnect()
        SyncSwitch.turnOff(appContext)
    }

    /**
     * Tells a Mac this phone unpaired while it was unreachable. One short connection,
     * never the tunnel's socket: challenge in, proof out, and the Mac echoes the proof
     * once it has deleted its key. A Mac that answers with `unpaired` of its own
     * already has no key either. Blocking; call off the main thread.
     */
    fun deliverUnpairNotice(host: String, port: Int, proof: ByteArray, macCert: ByteArray? = null): Boolean {
        val socket = macSSLContext().socketFactory.createSocket() as SSLSocket
        return try {
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            socket.startHandshake()
            // With a pinned Mac, only that Mac can take the notice (or say it already has no
            // key); any other host answering at the old address is not "delivered".
            if (macCert != null && !MacCertPin.matches(peerFingerprint(socket), macCert)) {
                Log.d(TAG, "Unpair notice: a different certificate answers — kept for later")
                return false
            }
            val reader = LineReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            val first = JSONObject(reader.readLine() ?: return false)
            if (first.optString("type") == "unpaired") return true
            if (first.optString("type") != "challenge") return false
            writeLine(socket.outputStream, JSONObject()
                .put("type", "unpaired")
                .put("proof", Base64.encodeToString(proof, Base64.NO_WRAP)).toString())
            val reply = JSONObject(reader.readLine() ?: return false)
            val echoed = runCatching { Base64.decode(reply.optString("proof"), Base64.NO_WRAP) }.getOrDefault(ByteArray(0))
            reply.optString("type") == "unpaired" && java.security.MessageDigest.isEqual(echoed, proof)
        } catch (e: Exception) {
            Log.d(TAG, "Unpair notice not delivered: ${e.javaClass.simpleName}")
            false
        } finally {
            runCatching { socket.close() }
        }
    }

    private var reconnectJob: Job? = null

    /**
     * Reconnect after the Mac drops the link (app restart, sleep, quit). Without this
     * the phone stayed offline until the 15-minute keepalive job or the user opened
     * the app. connectToLastKnownHost re-resolves mDNS, so a new Mac port is fine.
     *
     * ponytail: ~10 minutes of backoff (2s → 30s), then the keepalive job takes over —
     * a Mac that is off shouldn't cost battery forever.
     */
    private fun scheduleReconnect() {
        if (pairingManager?.isPaired?.value != true || blockedByIssue()) return
        // A new drop restarts the backoff. Reusing a still-sleeping job from the last
        // drop inherited its stretched delays: the second Mac restart took 17s, not 3s.
        reconnectJob?.cancel()
        _reconnecting.value = true
        reconnectJob = clientScope.launch {
            try {
                var delayMs = 2_000L
                repeat(25) { attempt ->
                    delay(delayMs)
                    if (isConnected() || pairingManager?.isPaired?.value != true || _linkIssue.value != null) return@launch
                    Log.d(TAG, "Auto-reconnect attempt ${attempt + 1} after peer drop")
                    connectToLastKnownHost()
                    // 10 s apart for the first couple of minutes, so a Mac that relaunches
                    // or wakes is picked up within seconds; then 30 s, to spare the battery.
                    delayMs = (delayMs * 2).coerceAtMost(if (attempt < 12) 10_000L else 30_000L)
                }
                Log.d(TAG, "Auto-reconnect gave up — Bluetooth, Wi-Fi and the 15-minute job take over")
            } finally {
                if (reconnectJob === coroutineContext[Job]) _reconnecting.value = false
            }
        }
    }

    /**
     * Performs HMAC challenge-response authentication after TLS handshake.
     *
     * Protocol:
     * 1. Server sends: {"type":"challenge","nonce":"<base64-32-bytes>"}
     * 2. Client sends {"type":"challenge-response","v":2,"hmac":HMAC(key, nonce‖binding),
     *    "client_nonce":<base64-32-bytes>}
     * 3. Server responds {"type":"challenge-ok","proof":HMAC(key, "SwiftGreen-server|"‖client_nonce‖binding)}
     *
     * TLS here is trust-all and the Mac's TLS identity ships inside the app (the same for
     * every install), so the certificate proves nothing. The Mac proves itself with the
     * pairing key instead, and `binding` (an RFC 5705 exporter secret of this TLS session)
     * ties both proofs to this connection: a relay in the middle runs two sessions with
     * different secrets, so neither proof survives it. Android < 12 has no exporter API
     * (v1, empty binding): that still stops impersonation, not a relay.
     */
    /**
     * RFC 5705 exporter secret of this TLS session — identical on both ends of one
     * session, different across the two sessions a relay would need. Empty where the
     * platform can't export (Android < 12); the handshake then runs as v1.
     */
    private fun tlsBinding(socket: SSLSocket): ByteArray {
        // exportKeyingMaterial is API 31. The Q check here let 10–11 reach it and fall
        // through runCatching to v1, silently; now the gate says what actually happens.
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return ByteArray(0)
        return runCatching {
            android.net.ssl.SSLSockets.exportKeyingMaterial(socket, "EXPORTER-SwiftGreen-auth", null, 32)
        }.onFailure { Log.w(TAG, "TLS exporter unavailable: ${it.message}") }.getOrNull() ?: ByteArray(0)
    }

    private fun performChallengeResponse(reader: LineReader, outputStream: OutputStream, socket: SSLSocket,
                                         seenCert: ByteArray?) {
        val pm = pairingManager
        val pairedKey = pm?.loadPairedKey()

        if (pairedKey == null) {
            Log.e(TAG, "No paired key available — cannot complete challenge-response")
            throw Exception("Not paired — scan QR code to pair first")
        }
        // Not the pinned certificate: not our Mac, whatever it claims (SG-09). Only an
        // unpair proof made with our own key (which it can't have unless it is the Mac) is
        // acted on; a bare "unpaired" from it must not stop reconnecting, and nothing is sent.
        val pinnedCert = pm.loadMacCertPin()
        val certMismatch = pinnedCert != null && !MacCertPin.matches(seenCert, pinnedCert)

        // Step 1: Read challenge from server
        Log.d(TAG, "Waiting for challenge from server...")
        val challengeLine = reader.readLine()
            ?: throw Exception("Server closed connection before sending challenge")

        Log.d(TAG, "Received challenge line (${challengeLine.length} chars)")

        val challengeJson = try {
            JSONObject(challengeLine)
        } catch (e: Exception) {
            null
        }

        val type = challengeJson?.optString("type", "") ?: ""
        if (type == "unpaired") {
            val verdict = unpairedVerdict(challengeJson!!, pairedKey)
            if (certMismatch && verdict !is PeerUnpairedException) throw Exception("Host's certificate isn't the paired Mac's")
            throw verdict
        }
        if (certMismatch) throw Exception("Host's certificate isn't the paired Mac's — not sending anything")

        if (challengeJson == null) {
            throw Exception("Invalid challenge JSON: not a JSON object")
        }

        if (type != "challenge") {
            throw Exception("Expected challenge message, got type='$type'")
        }

        val nonceBase64 = challengeJson.optString("nonce", "")
        if (nonceBase64.isEmpty()) {
            throw Exception("Challenge message missing nonce")
        }

        val nonceBytes = Base64.decode(nonceBase64, Base64.NO_WRAP)
        Log.d(TAG, "Challenge nonce received (${nonceBytes.size} bytes)")

        // Step 2: Compute HMAC and send response
        val binding = tlsBinding(socket)
        val clientNonce = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val hmacBytes = pm.computeHmac(pairedKey, nonceBytes + binding)
        val hmacBase64 = Base64.encodeToString(hmacBytes, Base64.NO_WRAP)

        val responseJson = JSONObject().apply {
            put("type", "challenge-response")
            put("v", if (binding.isEmpty()) 1 else 2)
            put("hmac", hmacBase64)
            put("client_nonce", Base64.encodeToString(clientNonce, Base64.NO_WRAP))
        }

        writeLine(outputStream, responseJson.toString())
        Log.d(TAG, "Sent challenge-response HMAC")

        // Step 3: Read challenge-ok
        val okLine = reader.readLine()
            ?: throw Exception("Server closed connection after challenge-response")

        Log.d(TAG, "Received challenge result (${okLine.length} chars)")

        val okJson = try {
            JSONObject(okLine)
        } catch (e: Exception) {
            null
        }

        val okType = okJson?.optString("type", "") ?: ""
        if (okType == "unpaired") throw unpairedVerdict(okJson!!, pairedKey)

        if (okJson == null) {
            throw Exception("Invalid challenge-ok JSON: not a JSON object")
        }

        if (okType != "challenge-ok") {
            throw Exception("Challenge failed — server responded with type='$okType'")
        }

        val proof = try { Base64.decode(okJson.optString("proof", ""), Base64.NO_WRAP) } catch (e: Exception) { ByteArray(0) }
        val expected = pm.computeHmac(pairedKey, "SwiftGreen-server|".toByteArray(Charsets.UTF_8) + clientNonce + binding)
        if (!java.security.MessageDigest.isEqual(proof, expected)) {
            throw Exception("Server failed to prove the pairing key — not your Mac")
        }

        // The Mac's certificate claim, proven with the key (MacCertPin). The first proof pins
        // it, which is how a phone paired before the QR carried a fingerprint pins without
        // re-pairing. A pinned phone already checked the certificate above.
        when (val claim = MacCertPin.evaluate(pairedKey, clientNonce, seenCert,
            okJson.optString("tls_id", ""), okJson.optString("tls_id_proof", ""))) {
            is MacCertPin.Verdict.Confirmed -> if (pinnedCert == null) pm.saveMacCertPin(claim.fingerprint)
            MacCertPin.Verdict.Rejected -> throw Exception("Mac's certificate claim doesn't match this connection")
            MacCertPin.Verdict.Unclaimed -> Unit
        }

        Log.d(TAG, "Challenge-response authentication successful ✅")
    }

    /**
     * The Mac said it has no pairing with us. Only a proof made with our own key
     * (PairingManager.unpairProof) lets that delete the key here: anyone on the network
     * can send the bare message, so without the proof the key stays and the user decides.
     */
    private fun unpairedVerdict(json: JSONObject, pairedKey: ByteArray): Exception {
        val proof = runCatching { Base64.decode(json.optString("proof", ""), Base64.NO_WRAP) }.getOrDefault(ByteArray(0))
        return if (proof.isNotEmpty() && java.security.MessageDigest.isEqual(proof, PairingManager.unpairProof(pairedKey)))
            PeerUnpairedException()
        else AuthRejectedException("Your Mac isn't paired with this phone. Unpair here, then pair again.")
    }

    // =========================================================================
    // Pairing-Specific Connection Flow
    // =========================================================================

    /**
     * Connects to the Mac server specifically for the pairing handshake.
     * This is a one-shot connection that:
     * 1. Establishes TLS
     * 2. Sends Android's public key as {"type":"pairing","publicKey":"..."}
     * 3. Waits for {"type":"pairing-complete"}
     * 4. Completes ECDH + HKDF key derivation
     * 5. Disconnects
     */
    fun connectForPairing(serviceInfo: NsdServiceInfo, pairingMgr: PairingManager) {
        val host = serviceInfo.firstHost?.hostAddress
            ?: throw Exception("Service has no host address")
        connectForPairing(host, serviceInfo.port, serviceInfo.serviceName ?: "", pairingMgr)
    }

    /**
     * Same as above, dialling an address directly (from the QR) instead of an mDNS result.
     * Throws [java.net.ConnectException] only when nothing answered at [host]:[port], so the
     * caller can try another address — never after the Mac has seen the PIN proof.
     */
    fun connectForPairing(host: String, port: Int, serviceName: String, pairingMgr: PairingManager) {
        Log.d(TAG, "Connecting for pairing")

        // Create TLS socket
        val sslContext = macSSLContext()
        val socketFactory = sslContext.socketFactory
        val socket = socketFactory.createSocket() as SSLSocket

        try {
            socket.soTimeout = READ_TIMEOUT_MS
            try {
                socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            } catch (e: IOException) {
                throw java.net.ConnectException("Couldn't reach the Mac at that address (${e.javaClass.simpleName})")
            }
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = 10_000  // 10s timeout for pairing responses
            socket.setPerformancePreferences(0, 1, 0)

            Log.d(TAG, "TCP connected for pairing. Starting TLS handshake...")
            socket.startHandshake()
            Log.d(TAG, "TLS handshake complete for pairing.")
            // The QR names the Mac's certificate (SG-09). Anything else here is a man in
            // the middle; checked before the PIN proof leaves the phone.
            if (!MacCertPin.matches(peerFingerprint(socket), pairingMgr.qrMacCertPin ?: ByteArray(0))) {
                throw Exception("This isn't the Mac whose code you scanned. Check both are on the same Wi-Fi and scan again.")
            }

            val reader = LineReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            val outputStream: OutputStream = socket.outputStream

            // Get Android's public key
            val androidPubKeyBase64 = pairingMgr.getAndroidPublicKeyBase64()

            // Send pairing message
            val pairingJson = JSONObject().apply {
                put("type", "pairing")
                put("publicKey", androidPubKeyBase64)
                put("pin_proof", pairingMgr.pinProof())
            }

            writeLine(outputStream, pairingJson.toString())
            Log.d(TAG, "Sent pairing public key to Mac")

            // Wait for pairing-complete response. An unpaired Mac opens every connection
            // with an `unpaired` line (meant for phones that still hold an old key); a
            // phone that is pairing skips it.
            var responseLine = reader.readLine()
                ?: throw Exception("Server closed connection before pairing-complete")
            while (responseLine.contains("\"unpaired\"")) {
                responseLine = reader.readLine()
                    ?: throw Exception("Server closed connection before pairing-complete")
            }

            Log.d(TAG, "Received pairing response (${responseLine.length} chars)")

            val responseJson = try {
                JSONObject(responseLine)
            } catch (e: Exception) {
                throw Exception("Invalid pairing response JSON: ${e.localizedMessage}")
            }

            val responseType = responseJson.optString("type", "")
            if (responseType == "pairing-failed") {
                throw Exception(if (responseJson.optString("reason") == "pin")
                    "That PIN doesn't match the one on your Mac."
                else "That pairing code has expired. Scan the new code on your Mac.")
            }
            if (responseType != "pairing-complete") {
                throw Exception("Expected pairing-complete, got type='$responseType'")
            }

            Log.d(TAG, "Pairing-complete received — completing ECDH key derivation")

            // Complete the pairing (ECDH + HKDF + store key)
            pairingMgr.completePairing()
            // Unpairing wipes the saved Mac; without this every reconnect after a fresh
            // pairing found "No last known host" and the phone sat on "Not connected".
            saveLastKnownHost(host, port, serviceName)

            Log.d(TAG, "Pairing flow completed successfully ✅")

        } finally {
            try {
                socket.close()
            } catch (e: Exception) {
                Log.e(TAG, "Error closing pairing socket", e)
            }
        }
    }

    private fun sendKeepalive() {
        keepaliveSendTime = System.currentTimeMillis()
        sendJsonPayload("{\"type\":\"keepalive\",\"timestamp\":$keepaliveSendTime}")
    }

    @Throws(IOException::class)
    fun sendJsonPayload(json: String) {
        val socket = activeSocket
            ?: throw IOException("No active TLS socket")
        if (socket.isClosed) {
            throw IOException("Active TLS socket is already closed")
        }

        synchronized(socket) {
            writeLine(socket.outputStream, json)
        }
    }

    private fun writeLine(outputStream: OutputStream, text: String) {
        val payload = if (text.endsWith("\n")) text else "$text\n"
        outputStream.write(payload.toByteArray(Charsets.UTF_8))
        outputStream.flush()
    }

    // ── SharedPreferences host persistence ────────────────────────────────────────

    private fun saveLastKnownHost(host: String, port: Int, serviceName: String = "") {
        val prefs = appContext.getSharedPreferences("swiftgreen_tunnel", android.content.Context.MODE_PRIVATE)
        prefs.edit {
            putString("last_host", host)
            putInt("last_port", port)
            putLong("last_host_ts", System.currentTimeMillis())
            if (serviceName.isNotEmpty()) putString("last_service_name", serviceName)
        }
        Log.d(TAG, "Saved last known host: $host:$port service=$serviceName")
    }

    private fun loadLastKnownHost(): Triple<String, Int, String?>? {
        val prefs = appContext.getSharedPreferences("swiftgreen_tunnel", android.content.Context.MODE_PRIVATE)
        val host = prefs.getString("last_host", null) ?: return null
        val port = prefs.getInt("last_port", -1)
        val ts = prefs.getLong("last_host_ts", 0)
        val ageMs = System.currentTimeMillis() - ts
        // No age limit: resolveAndConnect looks the Mac up by name first, and a stale
        // address just fails the handshake. Expiring it after 30 min stranded a phone that
        // came home later with no way to reconnect in the background.
        if (port == -1) {
            Log.d(TAG, "Last known host invalid (age=${ageMs}ms)")
            return null
        }
        val serviceName = prefs.getString("last_service_name", null)
        return Triple(host, port, serviceName)
    }

    fun connectToLastKnownHost(): Boolean {
        if (blockedByIssue()) return false
        val (host, port, serviceName) = loadLastKnownHost() ?: run {
            Log.d(TAG, "No last known host available")
            return false
        }
        if (isConnected() || isConnecting.get()) return false
        if (isConnecting.getAndSet(true)) return false
        Log.d(TAG, "Fast reconnect attempting: $host:$port service=$serviceName")
        connectionJob?.cancel()
        connectionJob = clientScope.launch(Dispatchers.IO) {
            try {
                if (serviceName != null) {
                    resolveAndConnect(host, port, serviceName)
                } else {
                    // Pre-fix cache entry — no service name stored; direct connect only
                    attemptConnectionDirect(host, port, timeoutMs = 3_000)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Fast reconnect failed: ${e.localizedMessage}")
            } finally {
                isConnecting.set(false)
            }
        }
        return true
    }

    /**
     * String host/port overload used by connectToLastKnownHost() for direct IP reconnect
     * without an NsdServiceInfo. Bypasses mDNS entirely. Returns false only when the Mac
     * never answered at [host] (gave up), so the caller can look for it elsewhere.
     */
    private suspend fun connectWithRetry(host: String, port: Int): Boolean {
        var attempt = 0
        while (attempt <= MAX_RETRIES && currentCoroutineContext().isActive) {
            if (attempt > 0) {
                val delayMs = BASE_RETRY_DELAY_MS * (1L shl (attempt - 1))
                Log.d(TAG, "Fast reconnect retry $attempt/$MAX_RETRIES — waiting ${delayMs}ms...")
                _connectionStatus.value = "Retrying ($attempt/$MAX_RETRIES)..."
                delay(delayMs)
            }
            try {
                delay(500)  // shorter delay for cached-IP path
                attemptConnectionDirect(host, port)
                return true
            } catch (e: Exception) {
                if (handleAuthVerdict(e)) return true
                Log.e(TAG, "Fast reconnect attempt ${attempt + 1} failed: ${e.localizedMessage}")
                // Same as the mDNS path: a refused port is gone, not busy — stop so the
                // next attempt re-resolves instead of redialling it for ~10s.
                if (attempt == MAX_RETRIES || e is java.net.ConnectException) {
                    Log.e(TAG, "Fast reconnect exhausted — status reset for mDNS fallback")
                    _connectionStatus.value = "Disconnected"
                    return false
                }
            }
            attempt++
        }
        return true
    }

    /**
     * Last resort when mDNS is blocked (many ISP/office routers) and the saved address no
     * longer answers because the Mac's IP changed: try the Mac's port on every address of
     * the phone's Wi-Fi/Ethernet /24s, first answer wins. Runs only after the saved address
     * failed, i.e. with no live tunnel — a probe would otherwise displace it, since the Mac
     * swaps in every new connection. The real connection after it still has to pass the
     * TLS + paired-key challenge, so a stranger answering on the port gets nowhere.
     * ponytail: /24 only (254 probes, ~3s worst case); a larger home subnet needs re-pairing.
     */
    private suspend fun findMacOnLocalNetwork(port: Int, skip: String): String? = coroutineScope {
        val candidates = java.net.NetworkInterface.getNetworkInterfaces().toList()
            .filter { nic -> nic.isUp && !nic.isLoopback &&
                listOf("wlan", "swlan", "ap", "eth").any { nic.name.startsWith(it) } }
            .flatMap { it.interfaceAddresses }
            .mapNotNull { (it.address as? java.net.Inet4Address)?.takeIf { a -> a.isSiteLocalAddress }?.address }
            .flatMap { b -> (1..254).map { "${b[0].toInt() and 255}.${b[1].toInt() and 255}.${b[2].toInt() and 255}.$it" } }
            .distinct() - skip
        Log.d(TAG, "findMacOnLocalNetwork: probing ${candidates.size} addresses for port $port")
        val io = Dispatchers.IO.limitedParallelism(64)
        val hit = CompletableDeferred<String?>()
        val probes = candidates.map { ip ->
            launch(io) {
                runCatching { java.net.Socket().use { it.connect(InetSocketAddress(ip, port), 800) } }
                    .onSuccess { hit.complete(ip) }
            }
        }
        launch { probes.joinAll(); hit.complete(null) }
        hit.await().also { coroutineContext.cancelChildren() }
    }

    /**
     * Direct connection to a host:port string (no NsdServiceInfo).
     * Used by the fast-reconnect path via SharedPreferences cached IP.
     */
    private fun attemptConnectionDirect(
        host: String, 
        port: Int, 
        timeoutMs: Int = CONNECT_TIMEOUT_MS
    ) {
        try { activeSocket?.close() } catch (e: Exception) { /* ignore */ }

        val sslContext = macSSLContext()
        val socket = sslContext.socketFactory.createSocket() as SSLSocket
        activeSocket = socket

        socket.soTimeout = READ_TIMEOUT_MS
        Log.d(TAG, "Fast reconnect: connecting to $host:$port (timeout=${timeoutMs}ms)")
        val reader: LineReader
        val outputStream: OutputStream
        try {
            socket.connect(InetSocketAddress(host, port), timeoutMs)
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.soTimeout = HANDSHAKE_TIMEOUT_MS
            socket.setPerformancePreferences(0, 1, 0)

            reader = LineReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            outputStream = socket.outputStream
            handshakeAndAuthenticate(socket, reader, outputStream, "Fast reconnect: ")
        } catch (e: Throwable) {
            abandonHandshake(socket)
            throw e
        }

        lastConnectedDeviceTimestamp = System.currentTimeMillis()
        saveLastKnownHost(host, port)
        _connectionStatus.value = "Connected over TLS!"

        writeLine(outputStream, "SwiftGreen-Hello-Android")
        Log.d(TAG, "Fast reconnect: Sent SwiftGreen-Hello-Android to Mac")
        socket.soTimeout = IDLE_TIMEOUT_MS

        TunnelManager.registerSocket(socket)
        callControl.start()
        CallLogHistoryManager.start(SwiftGreenApplication.instance)
        ClipboardSyncManager.sendMessage = { payload ->
            try {
                sendJsonPayload(payload)
            } catch (e: Exception) {
                Log.w(TAG, "Clipboard send failed: ${e.localizedMessage}")
            }
        }
        // Same per-connection pushes as the full path; without them the Mac showed a
        // nameless "Android phone" and no battery after every fast reconnect.
        TunnelManager.sendBatteryTelemetry(SwiftGreenApplication.instance)
        TunnelManager.sendDeviceInfo(SwiftGreenApplication.instance)
        MediaSessionManager.instance?.resendOnConnect()
        // Fast reconnect never sent this, so a call that started and ended while the
        // tunnel was down stayed invisible until a full re-pair. The observer cannot
        // cover that window — it is unregistered for exactly as long as the gap lasts.
        clientScope.launch(Dispatchers.IO) {
            CallLogHistoryManager.fetchAndSerialize(SwiftGreenApplication.instance)?.let {
                TunnelManager.sendRawMessage(it)
            }
        }
        clientScope.launch(Dispatchers.IO) {
            delay(500)
            ClipboardSyncManager.flushPendingClipboard()
        }

        // Read loop — identical to standard path
        val openedAt = System.currentTimeMillis()
        var lastType = ""
        try {
            while (!socket.isClosed) {
                val line = reader.readLine() ?: break
                val trimmed = line.trim()
                if (trimmed.isEmpty()) continue
                lastType = messageType(trimmed)
                handleIncomingLine(trimmed)
            }
        } catch (e: java.net.SocketTimeoutException) {
            Log.w(TAG, "Fast reconnect: nothing from the Mac for ${IDLE_TIMEOUT_MS / 1000}s — link is dead, reconnecting")
        } catch (e: IOException) {
            Log.w(TAG, "Fast reconnect: socket read failed or was closed: ${e.localizedMessage}")
        } catch (e: Throwable) {
            Log.e(TAG, "Fast reconnect: read loop ended by ${e.javaClass.simpleName} while handling '$lastType'", e)
            throw e
        } finally {
            // Same socket-scoped teardown as the standard path, which is also what stops
            // the PHONE_STATE receiver — this path used to leave it registered against a
            // dead socket, so every call_state push after a fast reconnect threw.
            val droppedByPeer = activeSocket === socket
            Log.d(TAG, "Fast reconnect: connection ended after ${(System.currentTimeMillis() - openedAt) / 1000}s " +
                "(last message '$lastType', ${if (droppedByPeer) "dropped — will reconnect" else "closed here"})")
            disconnect(socket)
            if (droppedByPeer) scheduleReconnect()
        }
    }

    private fun handleIncomingLine(responseText: String) {
        // Type and size only: the line itself can be clipboard text, an SMS, or a 350 KB file chunk.
        Log.d(TAG, "Received from Mac: ${messageType(responseText)} (${responseText.length} chars)")
        _receivedMessage.value = responseText

        val responseType = try {
            JSONObject(responseText).optString("type", "")
        } catch (e: Exception) {
            ""
        }

        // The Mac's periodic ping; the reply doubles as a latency reading.
        if (responseType == "ping") {
            synchronized(latencyBurst) { latencyBurst.clear() }
            runCatching { sendKeepalive() }
            return
        }

        if (responseType == "heartbeat_ack") {
            val sendTime = keepaliveSendTime
            if (sendTime > 0) {
                val rtt = (System.currentTimeMillis() - sendTime).toInt()
                // The first ping after a minute idle mostly measures Wi-Fi power-save
                // wake-up on both ends (500-700 ms), not the link. Two quick follow-ups
                // ride the now-awake radio; the median of three is the real round trip.
                val burst = synchronized(latencyBurst) { latencyBurst.add(rtt); latencyBurst.toList() }
                if (burst.size < 3) {
                    clientScope.launch {
                        delay(150)
                        runCatching { if (isConnected()) sendKeepalive() }
                    }
                } else {
                    val latency = burst.sorted()[1]
                    _latencyMs.value = latency
                    TunnelManager.sendTelemetry(SwiftGreenApplication.instance, latency)
                }
            }
            return
        }

        if (responseType == "unpair_request") {
            Log.w(TAG, "Received 'unpair_request' (divorce protocol) from Mac in read loop. Resetting...")
            onPeerUnpaired()
            return
        }

        // The Mac is quitting or going to sleep (PROTOCOL.md §2). Closing here,
        // with activeSocket left in place, unwinds the read loop as a peer drop, so the
        // reconnect loop starts now instead of whenever the TCP close shows up — which,
        // on 2026-09-26, it didn't for 80 s.
        if (responseType == "disconnect") {
            val reason = runCatching { JSONObject(responseText).optString("reason") }.getOrDefault("")
            Log.d(TAG, "Mac said goodbye ($reason) — reconnecting when it's back")
            runCatching { activeSocket?.close() }
            return
        }

        if (responseType == "clipboard_push") {
            try {
                val json = JSONObject(responseText)
                val body = mutableMapOf<String, Any?>()
                for (key in json.keys()) {
                    body[key] = json.opt(key)
                }
                ClipboardSyncManager.handleIncomingClipboard(
                    context = appContext,
                    body = body
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse clipboard_push: ${e.localizedMessage}")
            }
        }

        if (responseType == "file_transfer_begin") {
            try {
                val json = JSONObject(responseText)
                FileTransferReceiver.handleBegin(json, appContext)
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to handle file_transfer_begin: ${e.localizedMessage}")
            }
            return
        }

        if (responseType == "file_transfer_chunk") {
            try {
                val json = JSONObject(responseText)
                FileTransferReceiver.handleChunk(json, appContext)
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to handle file_transfer_chunk: ${e.localizedMessage}")
            }
            return
        }

        // The Mac cancelled its send. Unhandled, the .part and the ongoing "Receiving
        // file" notification stayed until the next transfer.
        if (responseType == "file_transfer_cancel") {
            FileTransferReceiver.peerCancelled(appContext)
            return
        }

        if (responseType == "media_action") {
            try {
                val json = JSONObject(responseText)
                MediaSessionManager.instance?.handleMediaAction(json)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse media_action: ${e.localizedMessage}")
            }
            return
        }

        if (responseType == "notification_action") {
            handleNotificationAction(responseText)
            return
        }

        if (responseType == "get_app_filter_list") {
            handleGetAppFilterList()
            return
        }

        if (responseType == "app_filter_update") {
            try {
                val json = JSONObject(responseText)
                val pkg = json.getString("package_name")
                val blocked = json.getBoolean("blocked")
                AppFilterManager.setPackageBlocked(appContext, pkg, blocked)
                Log.d(TAG, "app_filter_update: $pkg → blocked=$blocked")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse app_filter_update: ${e.localizedMessage}")
            }
            return
        }

        if (responseType == "call_action") {
            handleCallAction(responseText)
            return
        }

        if (responseType == "call_state_request") {
            callControl.pushCurrentState()
            return
        }

        if (responseType == "app_call_action") {
            val json = runCatching { JSONObject(responseText) }.getOrNull() ?: return
            val ok = SwiftGreenNotificationListener.performAppCallAction(
                json.optString("key"), json.optString("action"))
            Log.d(TAG, "WhatsApp call ${json.optString("action")} from Mac: ${if (ok) "done" else "no live call"}")
            return
        }

        if (responseType == "call_control") {
            try { callControl.handleCommand(JSONObject(responseText)) } catch (e: Exception) {
                Log.e(TAG, "Failed to handle call_control: ${e.localizedMessage}")
            }
            return
        }

        if (responseType == "find_phone") {
            val start = try { JSONObject(responseText).optString("action") == "start" } catch (e: Exception) { false }
            if (start) PhoneRinger.start(appContext) else PhoneRinger.stop(appContext)
            return
        }

        if (responseType == "get_sms_threads") {
            val page = try { JSONObject(responseText).optInt("page", 0) } catch (e: Exception) { 0 }
            clientScope.launch(Dispatchers.IO) {
                SmsThreadStore.fetchThreadPage(appContext, page)?.let { sendJsonPayload(it) }
            }
            return
        }

        if (responseType == "get_sms_messages") {
            val obj = try { JSONObject(responseText) } catch (e: Exception) { null }
            val threadId = obj?.optLong("thread_id", -1L) ?: -1L
            // Absent on the Mac's routine refresh (latest page); set by "Load earlier".
            val beforeMs = obj?.optLong("before_ms", -1L)?.takeIf { it > 0 }
            if (threadId > 0) {
                clientScope.launch(Dispatchers.IO) {
                    SmsThreadStore.fetchMessages(appContext, threadId, beforeMs)?.let { sendJsonPayload(it) }
                }
            }
            return
        }

        if (responseType == "sms_send") {
            val obj = try { JSONObject(responseText) } catch (e: Exception) { null }
            val toNumber = obj?.optString("to_number") ?: ""
            val body = obj?.optString("body") ?: ""
            val threadId = obj?.optLong("thread_id", -1L) ?: -1L
            val subId = obj?.optInt("subscription_id", -1) ?: -1
            if (toNumber.isNotEmpty() && body.isNotEmpty()) {
                clientScope.launch(Dispatchers.IO) {
                    SmsThreadStore.sendSms(appContext, toNumber, body, threadId, clientScope, subId) { result ->
                        // A result that lands while the link is down would otherwise vanish in
                        // the scope's handler; the Mac's next thread refresh shows the real row.
                        try { sendJsonPayload(result) } catch (e: Exception) { Log.w(TAG, "sms_send_result not delivered: ${e.message}") }
                    }
                }
            }
            return
        }

        if (responseType == "sms_search") {
            val obj = try { JSONObject(responseText) } catch (e: Exception) { null }
            val query = obj?.optString("query") ?: ""
            val page = obj?.optInt("page", 0) ?: 0
            if (query.isNotEmpty()) {
                clientScope.launch(Dispatchers.IO) {
                    SmsThreadStore.fetchSearchResults(appContext, query, page)?.let { sendJsonPayload(it) }
                }
            }
            return
        }

        if (responseType == "mac_directory_list_push") {
            try {
                MacFileBrowserStore.replace(JSONObject(responseText))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse mac_directory_list_push: ${e.localizedMessage}")
            }
            return
        }

        // Remote file browser (Mac→Android). Every request carries a path relative to
        // shared storage; MediaBrowserStore refuses anything that escapes it.
        if (responseType == "media_list_request") {
            val path = try { JSONObject(responseText).optString("directory") } catch (e: Exception) { "" }
            clientScope.launch(Dispatchers.IO) {
                try {
                    sendJsonPayload(MediaBrowserStore.fetchList(appContext, path))
                } catch (e: Exception) {
                    Log.e(TAG, "media_list_response send failed: ${e.localizedMessage}")
                }
            }
            return
        }

        if (responseType == "media_search_request") {
            val query = try { JSONObject(responseText).optString("query") } catch (e: Exception) { "" }
            clientScope.launch(Dispatchers.IO) {
                try {
                    sendJsonPayload(MediaBrowserStore.search(appContext, query))
                } catch (e: Exception) {
                    Log.e(TAG, "media_search_response send failed: ${e.localizedMessage}")
                }
            }
            return
        }

        if (responseType == "media_file_request") {
            val path = try { JSONObject(responseText).optString("path") } catch (e: Exception) { "" }
            val file = MediaBrowserStore.resolveFile(path)
            if (file != null) {
                FileTransferManager.sendFile(
                    uri = android.net.Uri.fromFile(file),
                    context = appContext,
                    onProgress = {},
                    onComplete = {},
                    onError = { Log.e(TAG, "media_file_request send failed: $it") }
                )
            }
            return
        }

        if (responseType == "media_thumbnail_request") {
            val path = try { JSONObject(responseText).optString("path") } catch (e: Exception) { "" }
            clientScope.launch(Dispatchers.IO) {
                // sendJsonPayload, not TunnelManager.sendRawMessage — stays clear of the
                // FileTransferManager.isCancelled early-return that silently drops raw
                // messages (TunnelManager.kt:143).
                try {
                    sendJsonPayload(MediaThumbnailStore.fetchThumbnail(appContext, path))
                } catch (e: Exception) {
                    Log.e(TAG, "media_thumbnail_response send failed: ${e.localizedMessage}")
                }
            }
            return
        }

        if (responseType == "contacts_list_request") {
            clientScope.launch(Dispatchers.IO) {
                sendJsonPayload(ContactsStore.fetchContactsListResponse(appContext))
            }
            return
        }

        if (responseText == "SwiftGreen-Hello-Mac") {
            _connectionStatus.value = "Tunnel Completed"
        }
    }

    // A dial places a real call, so a replayed call_action must not dial twice. Claimed
    // here on the read loop, before the IO hop, so two copies can't both get through.
    private val dialRequests = RequestDedup()

    private fun handleCallAction(jsonText: String) {
        val claimedId = runCatching { JSONObject(jsonText).optString("request_id") }.getOrDefault("")
        when (val claim = dialRequests.claim(claimedId)) {
            is RequestDedup.Claim.InFlight -> {
                Log.d(TAG, "Duplicate call_action $claimedId still in flight — ignoring")
                return
            }
            is RequestDedup.Claim.Replay -> {
                Log.d(TAG, "Duplicate call_action $claimedId — re-sending prior result")
                try { sendJsonPayload(claim.result) } catch (e: Exception) {
                    Log.e(TAG, "Failed to re-send call_action_result: ${e.localizedMessage}")
                }
                return
            }
            RequestDedup.Claim.Run -> Unit
        }
        clientScope.launch(Dispatchers.IO) {
            val json = try { JSONObject(jsonText) } catch (e: Exception) {
                // The request_id was in the bytes that failed to parse, so this result
                // carries none and the Mac cannot match it. Nothing better is available.
                sendCallActionResult("", false, "call_failed")
                return@launch
            }
            val requestId = json.optString("request_id")
            val number = json.optString("phone_number", "")
            if (json.optString("action") != "dial" || number.isBlank()) {
                sendCallActionResult(requestId, false, "invalid_number")
                return@launch
            }
            if (appContext.checkSelfPermission(android.Manifest.permission.CALL_PHONE)
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                sendCallActionResult(requestId, false, "permission_denied")
                return@launch
            }
            val subId = json.optInt("subscription_id", -1)
            val telecom = appContext.getSystemService(android.telecom.TelecomManager::class.java)
            if (telecom == null) {
                sendCallActionResult(requestId, false, "call_failed")
                return@launch
            }
            try {
                val extras = android.os.Bundle()
                // TelephonyManager.getSubscriptionId(PhoneAccountHandle) is API 30, but
                // minSdk is 26. On 26-29 the unguarded call throws NoSuchMethodError —
                // an Error, not an Exception, so the catch below would not stop it.
                // Skip the lookup there and let the OS pick the SIM.
                if (subId >= 0 && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    val tm = appContext.getSystemService(android.telephony.TelephonyManager::class.java)
                    val match = telecom.callCapablePhoneAccounts?.firstOrNull { handle ->
                        tm?.getSubscriptionId(handle) == subId
                    }
                    if (match != null) {
                        Log.d(TAG, "dial: matched PhoneAccountHandle id=${match.id} for subId=$subId")
                        extras.putParcelable(
                            android.telecom.TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, match)
                    } else {
                        Log.w(TAG, "dial: no PhoneAccountHandle for subId=$subId, using OS default")
                    }
                } else if (subId >= 0) {
                    Log.w(TAG, "dial: SIM selection needs API 30 " +
                        "(have ${android.os.Build.VERSION.SDK_INT}), using OS default")
                }
                // Tell the state machine the number before the call goes offhook, so the
                // outgoing call_state it pushes carries one.
                callControl.noteOutgoingDial(number)
                // placeCall, not startActivity(ACTION_CALL): this runs inside the tunnel
                // foreground service with no visible activity, and Android 10+ blocks
                // that as a background activity launch ("Background activity launch
                // blocked!"), so the call was never actually placed. placeCall is the
                // API meant for programmatic dialling and needs no activity.
                telecom.placeCall("tel:$number".toUri(), extras)
                sendCallActionResult(requestId, true, null)
            } catch (e: SecurityException) {
                Log.e(TAG, "placeCall denied: ${e.localizedMessage}")
                sendCallActionResult(requestId, false, "permission_denied")
            } catch (e: Exception) {
                Log.e(TAG, "placeCall failed: ${e.localizedMessage}")
                sendCallActionResult(requestId, false, "call_failed")
            }
        }
    }

    /** [requestId] is echoed verbatim so the Mac can match this to the dial that caused it. */
    private fun sendCallActionResult(requestId: String, success: Boolean, error: String?) {
        val result = JSONObject().apply {
            put("type", "call_action_result")
            put("request_id", requestId)
            put("success", success)
            if (error != null) put("error", error) else put("error", JSONObject.NULL)
        }
        dialRequests.complete(requestId, result.toString())
        try { sendJsonPayload(result.toString()) } catch (e: Exception) {
            Log.e(TAG, "Failed to send call_action_result: ${e.localizedMessage}")
        }
    }

    private fun handleGetAppFilterList() {
        clientScope.launch(Dispatchers.IO) {
            try {
                val seen = AppFilterManager.getSeenPackages(appContext)
                val blocked = AppFilterManager.getBlockedPackages(appContext)
                val pm = appContext.packageManager
                val apps = JSONArray()

                for (pkg in seen) {
                    val appName = AppFilterManager.getAppName(appContext, pkg)
                    var iconBase64: String? = null
                    try {
                        val drawable = pm.getApplicationIcon(pkg)
                        val bmp = if (drawable is android.graphics.drawable.BitmapDrawable && drawable.bitmap != null) {
                            drawable.bitmap.scale(48, 48, true)
                        } else {
                            val bitmap = createBitmap(48, 48)
                            val canvas = android.graphics.Canvas(bitmap)
                            drawable.setBounds(0, 0, 48, 48)
                            drawable.draw(canvas)
                            bitmap
                        }
                        val stream = java.io.ByteArrayOutputStream()
                        bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
                        iconBase64 = android.util.Base64.encodeToString(stream.toByteArray(), android.util.Base64.NO_WRAP)
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to extract icon for $pkg")
                    }

                    apps.put(JSONObject().apply {
                        put("package_name", pkg)
                        put("app_name", appName)
                        put("icon_base64", iconBase64 ?: JSONObject.NULL)
                        put("blocked", blocked.contains(pkg))
                    })
                }

                val response = JSONObject().apply {
                    put("type", "app_filter_list")
                    put("apps", apps)
                }
                sendJsonPayload(response.toString())
                Log.d(TAG, "Sent app_filter_list with ${apps.length()} apps")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send app_filter_list: ${e.localizedMessage}")
            }
        }
    }

    private fun handleNotificationAction(jsonText: String) {
        clientScope.launch(Dispatchers.IO) {
            val json = try { JSONObject(jsonText) } catch (e: Exception) {
                Log.e(TAG, "Invalid notification_action JSON: ${e.localizedMessage}")
                return@launch
            }
            val notificationKey = json.optString("notification_key", "")
            val sbnKey = json.optString("sbn_key", "")
            val actionType = json.optString("action_type", "")
            val replyText = json.optString("reply_text", "")
            val actionId = json.optString("action_id", "")

            if (notificationKey.isEmpty()) {
                sendNotificationActionResult(notificationKey, false, "missing notification_key")
                return@launch
            }

            // Cache first, then the live notification: the cache expires after 5
            // minutes, but the PendingIntent stays good while the notification is still
            // posted. Only give up if both miss.
            val entry = SwiftGreenNotificationListener.lookupReplyAction(notificationKey)
                ?: SwiftGreenNotificationListener.resolveReplyActionLive(notificationKey, sbnKey)
            if (entry == null) {
                Log.w(TAG, "No reply action in cache or live notifications for key: $notificationKey")
                sendNotificationActionResult(notificationKey, false, "notification no longer available")
                return@launch
            }

            try {
                when (actionType) {
                    "reply" -> {
                        val packageName = notificationKey.substringBefore("|")
                        val gmail = packageName == "com.google.android.gm"
                        // Gmail validates its own RemoteInput contract — a freshly built
                        // single-key RemoteInput is rejected — so it needs the originals.
                        if (gmail && entry.remoteInputs.isNullOrEmpty()) {
                            sendNotificationActionResult(notificationKey, false,
                                "Gmail inline reply is not supported. Open Gmail on your phone to reply.",
                                userFacing = true)
                            return@launch
                        }
                        // One fill-in for every app: the action's own RemoteInputs with every
                        // result key filled, marked as typed text, as the system reply does.
                        fun sendReply(e: SwiftGreenNotificationListener.Companion.ReplyActionEntry) {
                            val inputs = e.remoteInputs?.takeIf { it.isNotEmpty() }
                                ?: arrayOf(android.app.RemoteInput.Builder(e.remoteInputKey).build())
                            val fillIn = android.content.Intent()
                            val bundle = android.os.Bundle()
                            for (ri in inputs) bundle.putCharSequence(ri.resultKey, replyText)
                            android.app.RemoteInput.addResultsToIntent(inputs, fillIn, bundle)
                            if (android.os.Build.VERSION.SDK_INT >= 28) {
                                android.app.RemoteInput.setResultsSource(fillIn, android.app.RemoteInput.SOURCE_FREE_FORM_INPUT)
                            }
                            if (android.os.Build.VERSION.SDK_INT >= 31) {
                                Log.d(TAG, "Reply → $packageName (broadcast=${e.pendingIntent.isBroadcast} activity=${e.pendingIntent.isActivity})")
                            }
                            e.pendingIntent.send(appContext, 0, fillIn)
                        }
                        try {
                            try {
                                sendReply(entry)
                            } catch (ce: android.app.PendingIntent.CanceledException) {
                                // The cached intent was replaced (the app reposted the chat):
                                // retry once with whatever the live notification carries now.
                                SwiftGreenNotificationListener.evictReplyAction(notificationKey)
                                val live = SwiftGreenNotificationListener.resolveReplyActionLive(notificationKey, sbnKey)
                                if (live == null || live.pendingIntent == entry.pendingIntent) throw ce
                                Log.d(TAG, "Reply: cached intent cancelled — retrying with the live notification")
                                sendReply(live)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Reply failed: ${e.javaClass.simpleName} ${e.localizedMessage}")
                            if (gmail) {
                                sendNotificationActionResult(notificationKey, false,
                                    "Gmail inline reply is not supported. Open Gmail on your phone to reply.",
                                    userFacing = true)
                            } else {
                                sendNotificationActionResult(notificationKey, false, e.localizedMessage ?: "error")
                            }
                            return@launch
                        }
                        SwiftGreenNotificationListener.evictReplyAction(notificationKey)
                        sendNotificationActionResult(notificationKey, true, null)
                        sendNotificationDismiss(notificationKey)
                    }
                    "button" -> {
                        val btnIntent = entry.buttonActions[actionId]
                        if (btnIntent == null) {
                            sendNotificationActionResult(notificationKey, false, "unknown action_id: $actionId")
                            return@launch
                        }
                        btnIntent.send(appContext, 0, null)
                        SwiftGreenNotificationListener.evictReplyAction(notificationKey)
                        sendNotificationActionResult(notificationKey, true, null)
                        sendNotificationDismiss(notificationKey)
                    }
                    else -> sendNotificationActionResult(notificationKey, false, "unknown action_type: $actionType")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Notification action failed: ${e.localizedMessage}")
                sendNotificationActionResult(notificationKey, false, e.localizedMessage ?: "error")
            }
        }
    }

    private fun sendNotificationActionResult(key: String, success: Boolean, error: String?, userFacing: Boolean = false) {
        val result = JSONObject().apply {
            put("type", "notification_action_result")
            put("notification_key", key)
            put("success", success)
            if (error != null) put("error", error) else put("error", JSONObject.NULL)
            put("user_facing", userFacing)
        }
        try { sendJsonPayload(result.toString()) } catch (e: Exception) {
            Log.e(TAG, "Failed to send notification_action_result: ${e.localizedMessage}")
        }
    }

    private fun sendNotificationDismiss(key: String) {
        val dismiss = JSONObject().apply {
            put("type", "notification_dismiss")
            put("notification_key", key)
            put("origin", "android")
        }
        try { sendJsonPayload(dismiss.toString()) } catch (e: Exception) {
            Log.e(TAG, "Failed to send notification_dismiss: ${e.localizedMessage}")
        }
    }

    /**
     * Performs a fresh mDNS resolve for [serviceName] (3 s timeout), then connects
     * using the live port. Falls back to [cachedHost]:[cachedPort] on timeout/failure.
     * Write-through: on a successful resolve, both SharedPrefs and lastConnectedDevice
     * are updated before dialling, so the next reconnect sees the correct port.
     * Caller must set isConnecting = true before calling and clear it in a finally block.
     */
    private suspend fun resolveAndConnect(cachedHost: String, cachedPort: Int, serviceName: String) {
        val nsdManager = appContext.getSystemService(android.content.Context.NSD_SERVICE) as NsdManager
        runCatching { multicastLock?.acquire() }
        val fresh: NsdServiceInfo? = try {
            withTimeout(RESOLVE_TIMEOUT_MS) {
                suspendCancellableCoroutine { cont ->
                    val query = NsdServiceInfo().also {
                        it.serviceName = serviceName
                        it.serviceType = "_swiftgreen._tcp."
                    }
                    val cancel = nsdManager.resolveOnce(query,
                        onResolved = { si ->
                            Log.d(TAG, "resolveAndConnect: fresh port=${si.port} (cached was $cachedPort)")
                            if (cont.isActive) cont.resumeWith(Result.success(si))
                        },
                        onFailed = { errorCode ->
                            Log.w(TAG, "resolveAndConnect: mDNS resolve failed (code=$errorCode) — will use cached $cachedHost:$cachedPort")
                            if (cont.isActive) cont.resumeWith(Result.success(null))
                        })
                    // Timeout or job cancel: stop the in-flight resolve, else it stays registered
                    // and the next resolve can fail with FAILURE_ALREADY_ACTIVE.
                    cont.invokeOnCancellation { cancel() }
                }
            }
        } catch (e: TimeoutCancellationException) {
            Log.w(TAG, "resolveAndConnect: resolve timed out — falling back to cached $cachedHost:$cachedPort")
            null
        } catch (e: Exception) {
            Log.w(TAG, "resolveAndConnect: resolve error (${e.localizedMessage}) — falling back to cached $cachedHost:$cachedPort")
            null
        } finally {
            runCatching { multicastLock?.release() }
        }

        if (fresh != null) {
            val freshHost = fresh.firstHost?.hostAddress ?: cachedHost
            // Write-through both caches before connecting
            lastConnectedDevice = fresh
            lastConnectedDeviceTimestamp = System.currentTimeMillis()
            saveLastKnownHost(freshHost, fresh.port, serviceName)
            connectWithRetry(fresh)
        } else if (!connectWithRetry(cachedHost, cachedPort)) {
            val found = findMacOnLocalNetwork(cachedPort, skip = cachedHost) ?: run {
                Log.w(TAG, "resolveAndConnect: Mac not found on the local network")
                return
            }
            Log.d(TAG, "resolveAndConnect: Mac found at $found:$cachedPort by local-network scan")
            connectWithRetry(found, cachedPort)
        }
    }

    /**
     * mDNS fallback reconnect — called by NetworkCallback.onAvailable and TunnelKeepaliveJob.
     * Performs a fresh mDNS resolve before dialling to avoid stale ephemeral port.
     */
    fun reconnectIfNeeded() {
        if (isConnected() || isConnecting.get() || blockedByIssue()) return
        // No fresh in-memory device (new process, or the Mac was away 5+ minutes): use
        // the saved host, which re-resolves the Mac by name first. This used to give up
        // and wait for the app screen's discovery, so a closed app never reconnected.
        val lastDevice = lastConnectedDevice
        if (lastDevice == null || System.currentTimeMillis() - lastConnectedDeviceTimestamp > 5 * 60 * 1000L) {
            Log.d(TAG, "reconnectIfNeeded: no fresh device — reconnecting via saved host")
            connectToLastKnownHost()
            return
        }
        if (isConnecting.getAndSet(true)) return
        val cachedHost = lastDevice.firstHost?.hostAddress ?: run { isConnecting.set(false); return }
        connectionJob?.cancel()
        connectionJob = clientScope.launch {
            try {
                resolveAndConnect(cachedHost, lastDevice.port, lastDevice.serviceName)
            } finally {
                isConnecting.set(false)
            }
        }
    }

    /**
     * [expectedSocket] scopes the teardown to one connection: a read loop that unwinds
     * late must not close the socket a fresh reconnect has already installed, nor
     * unregister the PHONE_STATE receiver that now belongs to it — that left the Mac
     * with a call banner frozen on the last state it happened to see. Callers tearing
     * the tunnel down deliberately (user action, pairing) pass nothing.
     */
    fun disconnect(expectedSocket: SSLSocket? = null, keepAutoReconnect: Boolean = false) {
        // 1. Capture the active socket
        val socket = activeSocket
        if (expectedSocket != null && socket !== expectedSocket) {
            Log.d(TAG, "disconnect() for a superseded socket — live connection left alone")
            return
        }

        // Deliberate teardown: say who asked, since the log otherwise can't tell a user's
        // Disconnect from an unpair or a sync switch-off.
        if (expectedSocket == null && socket != null) Log.d(TAG, "disconnect() requested", Throwable("caller"))

        // 2. Nullify the reference immediately to stop incoming reads
        activeSocket = null
        
        // 3. Close the socket safely inside a try/catch
        try {
            socket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error closing socket", e)
        }
        
        // 4. Unregister the socket from the tunnel manager
        TunnelManager.unregisterSocket()
        ClipboardSyncManager.sendMessage = null
        callControl.stop()
        // Both read loops unwind through here, so this one call covers the standard and
        // fast-reconnect teardowns as well as a deliberate disconnect — and it is inside
        // the expectedSocket guard above, so a late-unwinding old loop cannot unregister
        // the observer belonging to a connection that has already replaced it.
        CallLogHistoryManager.stop()
        
        // A connection that just ended makes the saved address fresh, not old. The
        // 30-minute limit in loadLastKnownHost counted from when the connection
        // *started*, so a Mac that dropped a tunnel older than half an hour was never
        // redialled: every auto-reconnect attempt found "no last known host".
        if (socket != null) {
            lastConnectedDeviceTimestamp = System.currentTimeMillis()
            appContext.getSharedPreferences("swiftgreen_tunnel", android.content.Context.MODE_PRIVATE).edit {
                putLong("last_host_ts", lastConnectedDeviceTimestamp)
            }
        }

        // 5. Update the connection state on the calling thread instantly
        _connectionStatus.value = "Disconnected"
        _receivedMessage.value = ""
        
        // 6. Cancel all pending reconnect/retry coroutine jobs. Skipped for a scoped
        // teardown: that call comes from inside the very job that owns this socket, which
        // is already unwinding, so the cancel is a no-op — and skipping it means we never
        // have to reason about whether connectionJob still points at us rather than at a
        // newer connection that took the slot.
        if (expectedSocket == null) {
            connectionJob?.cancel()
            connectionJob = null
            // A deliberate disconnect (user, unpair) must not be undone by auto-reconnect.
            if (!keepAutoReconnect) {
                reconnectJob?.cancel()
                reconnectJob = null
                _reconnecting.value = false
            }
        }

        isConnecting.set(false)
        _latencyMs.value = null
        keepaliveSendTime = 0L
    }
}
