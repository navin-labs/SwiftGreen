package com.swiftgreen.app

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Security
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import androidx.core.content.edit

/**
 * PairingManager handles the cryptographic QR pairing flow between Android and macOS.
 *
 * Protocol summary:
 * 1. Mac displays a QR code containing its X25519 public key (raw 32 bytes, base64), a 6-digit PIN, and hostname.
 * 2. Android scans the QR, generates its own X25519 key pair, sends its public key to the Mac over TLS.
 * 3. Both sides compute ECDH → HKDF-SHA256 to derive a shared 32-byte key.
 * 4. The derived key is stored locally and used for HMAC challenge-response on every subsequent connection.
 */
class PairingManager(context: Context) {

    private val TAG = "PairingManager"
    private val appContext = context.applicationContext
    private val bouncyCastleProvider = BouncyCastleProvider()
    private val managerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // --- Pairing State Machine ---
    enum class PairingState {
        IDLE,
        SCANNING,
        PIN_DISPLAYED,
        PAIRING,
        PAIRED,
        ERROR
    }

    private val _state = MutableStateFlow(PairingState.IDLE)
    val state: StateFlow<PairingState> = _state.asStateFlow()

    // Process-wide, not per instance: the activity and the tunnel service each build a
    // PairingManager, and the client holds whichever was set last (usually the
    // service's). An unpair arriving from the Mac cleared that instance's flag only,
    // so the screen, collecting the activity's copy, kept showing the dashboard.
    private val _isPaired = pairedFlow
    val isPaired: StateFlow<Boolean> = _isPaired.asStateFlow()

    /** Why the phone is unpaired, when that happened on the other side; shown above the QR scanner. */
    val unpairNotice: StateFlow<String> = noticeFlow.asStateFlow()

    private val _pairingPin = MutableStateFlow("")
    val pairingPin: StateFlow<String> = _pairingPin.asStateFlow()

    private val _scannedHostname = MutableStateFlow("")
    val scannedHostname: StateFlow<String> = _scannedHostname.asStateFlow()

    // Mac's direct address from the QR (newer Macs only): dialled before mDNS, which
    // many routers drop between devices.
    var scannedAddresses: List<String> = emptyList()
        private set
    var scannedPort: Int = -1
        private set

    private val _errorMessage = MutableStateFlow("")
    val errorMessage: StateFlow<String> = _errorMessage.asStateFlow()

    // --- Ephemeral Crypto State (cleared after pairing completes) ---
    private var androidKeyPair: KeyPair? = null
    private var macPublicKeyRawBytes: ByteArray? = null
    private var pairedPeerPublicKeyRawBytes: ByteArray? = null
    /** The Mac certificate fingerprint from the scanned QR. */
    var qrMacCertPin: ByteArray? = null
        private set

    // --- SharedPreferences for key storage ---
    private val prefs = appContext.getSharedPreferences("swiftgreen_pairing", Context.MODE_PRIVATE)

    companion object {
        private const val PREFS_KEY = "SwiftGreen-PairedKey"
        private const val PREFS_PEER_PUBLIC_KEY = "SwiftGreen-PeerPublicKey"
        // Display only — never part of the crypto material, so a missing value is harmless.
        private const val PREFS_MAC_HOSTNAME = "SwiftGreen-MacHostname"
        private const val HKDF_INFO = "SwiftGreen-v1"
        private const val HKDF_OUTPUT_LENGTH = 32
        private const val BOUNCY_CASTLE_PROVIDER_NAME = "BC"
        // An unpair made while the Mac was unreachable, still to be delivered (see
        // deliverPendingUnpair). Holds the proof, never the key.
        private const val PREFS_PENDING_PROOF = "SwiftGreen-PendingUnpairProof"
        private const val PREFS_PENDING_HOST = "SwiftGreen-PendingUnpairHost"
        private const val PREFS_PENDING_PORT = "SwiftGreen-PendingUnpairPort"
        private const val PREFS_PENDING_CERT = "SwiftGreen-PendingUnpairMacCert"
        // SHA-256 of the paired Mac's TLS certificate (MacCertPin, SG-09). Public, but it
        // decides which host is trusted, so it lives with the key and is wiped with it.
        private const val PREFS_MAC_CERT = "SwiftGreen-MacCertSha256"
        const val UNREADABLE_KEY_NOTICE = "This phone couldn't read its pairing key (restored or moved to a new phone?). Pair again."

        private val pairedFlow = MutableStateFlow(false)
        private val noticeFlow = MutableStateFlow("")

        /**
         * HKDF (RFC 5869) using HMAC-SHA256.
         *
         * @param ikm   Input Key Material (ECDH shared secret)
         * @param salt  Optional salt (empty → all-zeros key of hash length)
         * @param info  Context/application-specific info string
         * @param length  Desired output key material length in bytes
         */
        fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            // ---- Extract phase: PRK = HMAC-SHA256(salt, IKM) ----
            val mac = Mac.getInstance("HmacSHA256")
            val extractKey = if (salt.isEmpty()) {
                SecretKeySpec(ByteArray(32), "HmacSHA256")
            } else {
                SecretKeySpec(salt, "HmacSHA256")
            }
            mac.init(extractKey)
            val prk = mac.doFinal(ikm)

            // ---- Expand phase: T(i) = HMAC-SHA256(PRK, T(i-1) || info || i) ----
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            val result = ByteArray(length)
            var t = ByteArray(0)
            var offset = 0
            var i: Byte = 1
            while (offset < length) {
                mac.update(t)
                mac.update(info)
                mac.update(i)
                t = mac.doFinal()
                val toCopy = minOf(t.size, length - offset)
                System.arraycopy(t, 0, result, offset, toCopy)
                offset += toCopy
                i++
                mac.init(SecretKeySpec(prk, "HmacSHA256"))
            }

            return result
        }

        /**
         * HMAC(K, "SwiftGreen-unpaired"): proves an unpair came from the paired peer.
         * One-way, so it gives nothing toward K, and no other check accepts it; the
         * Mac keeps its copy after deleting K so it can prove the unpair later
         * (PROTOCOL.md §3.4).
         */
        fun unpairProof(key: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            return mac.doFinal("SwiftGreen-unpaired".toByteArray(Charsets.UTF_8))
        }

        // ASN.1 header for X25519 SubjectPublicKeyInfo (12 bytes)
        // SEQUENCE { SEQUENCE { OID 1.3.101.110 } BIT STRING { raw 32 bytes } }
        private val X25519_SPKI_HEADER = byteArrayOf(
            0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x6E, 0x03, 0x21, 0x00
        )

        /**
         * The paired key, the only reader of its stored form (SG-07); no PairingManager needed
         * (its init re-registers BouncyCastle). Opens the Keystore-wrapped key and re-seals a
         * legacy plaintext one. A key that can't be opened is deleted and the phone reads as
         * unpaired, with a notice on the pairing screen. A Keystore that is unavailable for the
         * moment returns null and deletes nothing.
         */
        fun storedKey(context: Context): ByteArray? = synchronized(PairingKeyVault) {
            val prefs = context.getSharedPreferences("swiftgreen_pairing", Context.MODE_PRIVATE)
            val read = runCatching { PairingKeyVault.read(prefs.getString(PREFS_KEY, null), PairingKeyVault::keystoreKey) }
                .onFailure { Log.w("PairingManager", "Keystore unavailable (${it.javaClass.simpleName})") }
                .getOrNull() ?: return null
            when (read.rewrite) {
                null -> Unit
                "" -> {
                    prefs.saveNow("unreadable key delete") { remove(PREFS_KEY); remove(PREFS_MAC_CERT) }
                    pairedFlow.value = false
                    noticeFlow.value = UNREADABLE_KEY_NOTICE
                    Log.w("PairingManager", "Pairing key unreadable — deleted; re-pair required")
                }
                else -> {
                    prefs.saveNow("sealed key") { putString(PREFS_KEY, read.rewrite) }
                    Log.d("PairingManager", "Legacy plaintext pairing key wrapped with the Keystore")
                }
            }
            read.key
        }
    }

    init {
        registerBouncyCastleProvider()
        restorePairingStateFromDisk()
    }

    // =========================================================================
    // QR Scanning
    // =========================================================================

    /**
     * Called when a QR code is successfully scanned. Parses the Mac's QR payload:
     * {"publicKey":"<base64-raw-32-bytes>","hostname":"<mac-hostname>"}
     * The PIN is not in the QR: the user types it from the Mac's screen (see [pinProof]).
     */
    fun onQRScanned(json: String) {
        try {
            Log.d(TAG, "QR payload received (${json.length} chars)")
            val obj = JSONObject(json)

            val macPubKeyBase64 = obj.getString("publicKey")
            val hostname = obj.getString("hostname")
            val ips = obj.optJSONArray("ips")
            val addresses = (0 until (ips?.length() ?: 0)).map { ips!!.getString(it) }
            val port = obj.optInt("port", -1)

            // Decode Mac's raw 32-byte public key
            val rawBytes = Base64.decode(macPubKeyBase64, Base64.NO_WRAP)
            if (rawBytes.size != 32) {
                throw IllegalArgumentException("Mac public key must be 32 bytes (got ${rawBytes.size})")
            }
            // The Mac's certificate fingerprint (SG-09): the pairing connection must present
            // exactly this certificate before the PIN proof is sent.
            val tls = MacCertPin.decode(obj.optString("tls", ""))
                ?: throw IllegalArgumentException("this code has no certificate fingerprint. Update SwiftGreen on the Mac and scan again")
            macPublicKeyRawBytes = rawBytes
            qrMacCertPin = tls

            // Generate Android's ephemeral X25519 key pair
            androidKeyPair = generateX25519KeyPair()
            Log.d(TAG, "Generated Android X25519 key pair")

            _pairingPin.value = ""
            scannedAddresses = addresses
            scannedPort = port
            _scannedHostname.value = hostname
            _state.value = PairingState.PIN_DISPLAYED

            Log.d(TAG, "QR parsed (${addresses.size} addresses)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse QR payload: ${e.javaClass.simpleName}")
            _errorMessage.value = "Invalid QR code: ${e.localizedMessage}"
            _state.value = PairingState.ERROR
        }
    }

    /**
     * Transitions back to scanning state (e.g. user presses "Scan Again").
     */
    fun resetToScanning() {
        androidKeyPair = null
        macPublicKeyRawBytes = null
        qrMacCertPin = null
        _pairingPin.value = ""
        _scannedHostname.value = ""
        _errorMessage.value = ""
        _state.value = PairingState.SCANNING
    }

    /** The PIN as the user types it from the Mac's screen. */
    fun setEnteredPin(pin: String) {
        _pairingPin.value = pin.filter { it.isDigit() }.take(6)
    }

    /**
     * Proof that this phone read the PIN off the Mac's screen: HMAC(pairing key,
     * "SwiftGreen-pin|<pin>"). The key comes from ECDH with the Mac's QR public key, so
     * nobody who didn't scan this QR can produce it; the Mac allows 3 tries per code.
     */
    fun pinProof(): String =
        Base64.encodeToString(computeHmac(deriveKey(), "SwiftGreen-pin|${_pairingPin.value}".toByteArray(Charsets.UTF_8)),
            Base64.NO_WRAP)

    private fun deriveKey(): ByteArray {
        val kp = androidKeyPair
            ?: throw IllegalStateException("No Android key pair — scan QR first")
        val macRawBytes = macPublicKeyRawBytes
            ?: throw IllegalStateException("No Mac public key — scan QR first")
        val sharedSecret = performECDH(kp.private, decodeRawPublicKey(macRawBytes))
        return hkdf(
            ikm = sharedSecret,
            salt = ByteArray(0),  // empty salt
            info = HKDF_INFO.toByteArray(Charsets.UTF_8),
            length = HKDF_OUTPUT_LENGTH
        )
    }

    /**
     * Called by the "Confirm & Pair" button to lock the UI and show a spinner.
     * This is the ONLY way to enter the PAIRING state — no automatic transitions.
     */
    fun setPairingInProgress() {
        _state.value = PairingState.PAIRING
    }

    /**
     * Called when the pairing handshake fails. Shows the error to the user
     * instead of silently resetting to the camera.
     */
    fun setPairingError(message: String) {
        _errorMessage.value = message
        _state.value = PairingState.ERROR
    }

    /**
     * Returns the Android's public key as Base64-encoded raw 32 bytes
     * (matching Swift CryptoKit Curve25519 raw representation).
     */
    fun getAndroidPublicKeyBase64(): String {
        val kp = androidKeyPair
            ?: throw IllegalStateException("Key pair not generated — scan QR first")

        val rawPublicKey = extractRawPublicKey(kp.public)
        return Base64.encodeToString(rawPublicKey, Base64.NO_WRAP)
    }

    // =========================================================================
    // ECDH + HKDF Key Derivation
    // =========================================================================

    /**
     * Completes the pairing by performing ECDH with the Mac's public key,
     * then HKDF to derive the final 32-byte shared key, and stores it.
     */
    fun completePairing() {
        try {
            _state.value = PairingState.PAIRING

            val macRawBytes = macPublicKeyRawBytes
                ?: throw IllegalStateException("No Mac public key — scan QR first")
            val certPin = qrMacCertPin
                ?: throw IllegalStateException("No Mac certificate fingerprint — scan QR first")
            // ECDH with the Mac's QR public key, then HKDF-SHA256
            val derivedKey = deriveKey()
            Log.d(TAG, "HKDF derived key computed (${derivedKey.size} bytes)")

            // Store the derived key and the peer identity atomically.
            storePairingMaterial(derivedKey, macRawBytes)
            pairedPeerPublicKeyRawBytes = macRawBytes.copyOf()
            prefs.edit { putString(PREFS_MAC_HOSTNAME, _scannedHostname.value) }
            // Checked against the pairing connection in connectForPairing before the PIN proof.
            saveMacCertPin(certPin)

            // Clean up ephemeral state
            androidKeyPair = null
            macPublicKeyRawBytes = null
            qrMacCertPin = null

            // A new key makes any older unpair proof meaningless to the Mac.
            prefs.edit {
remove(PREFS_PENDING_PROOF)
remove(PREFS_PENDING_HOST)
remove(PREFS_PENDING_PORT)
remove(PREFS_PENDING_CERT)
}
            noticeFlow.value = ""
            _isPaired.value = true
            _state.value = PairingState.PAIRED
            Log.d(TAG, "Pairing completed successfully!")

        } catch (e: Exception) {
            Log.e(TAG, "Pairing failed: ${e.javaClass.simpleName}")
            _errorMessage.value = "Pairing failed: ${e.localizedMessage}"
            _state.value = PairingState.ERROR
        }
    }

    // =========================================================================
    // Key Generation (X25519)
    // =========================================================================

    private fun generateX25519KeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("X25519", bouncyCastleProvider)
        return kpg.generateKeyPair()
    }

    // =========================================================================
    // ECDH Key Agreement
    // =========================================================================

    private fun performECDH(privateKey: PrivateKey, macPublicKey: PublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("X25519", bouncyCastleProvider)
        ka.init(privateKey)
        ka.doPhase(macPublicKey, true)
        return ka.generateSecret()
    }

    // =========================================================================
    // Raw Key Encoding / Decoding
    // =========================================================================

    /**
     * Extracts the raw 32-byte X25519 public key from a JCA PublicKey.
     * JCA encodes keys in X509/SPKI format; we strip the ASN.1 header.
     */
    private fun extractRawPublicKey(publicKey: PublicKey): ByteArray {
        val encoded = publicKey.encoded  // X509/SPKI encoded
        // The last 32 bytes of the SPKI encoding are the raw key
        return if (encoded.size == 44) {
            // Standard X25519 SPKI: 12-byte header + 32-byte key
            encoded.copyOfRange(12, 44)
        } else {
            // Fallback: try to extract last 32 bytes
            Log.w(TAG, "Unexpected public key encoding size: ${encoded.size}, extracting last 32 bytes")
            encoded.copyOfRange(encoded.size - 32, encoded.size)
        }
    }

    /**
     * Decodes a raw 32-byte X25519 public key into a JCA PublicKey
     * by prepending the X509/SPKI ASN.1 header.
     */
    private fun decodeRawPublicKey(rawBytes: ByteArray): PublicKey {
        require(rawBytes.size == 32) { "Raw X25519 public key must be 32 bytes" }

        // Build X509/SPKI encoded key: ASN.1 header + raw bytes
        val spkiEncoded = ByteArray(X25519_SPKI_HEADER.size + rawBytes.size)
        System.arraycopy(X25519_SPKI_HEADER, 0, spkiEncoded, 0, X25519_SPKI_HEADER.size)
        System.arraycopy(rawBytes, 0, spkiEncoded, X25519_SPKI_HEADER.size, rawBytes.size)

        val keySpec = X509EncodedKeySpec(spkiEncoded)
        val keyFactory = KeyFactory.getInstance("X25519", bouncyCastleProvider)
        return keyFactory.generatePublic(keySpec)
    }

    // =========================================================================
    // HKDF-SHA256 (manual extract-then-expand — JCA has no built-in HKDF)
    // =========================================================================


    // =========================================================================
    // HMAC-SHA256 Helper (for challenge-response)
    // =========================================================================

    /**
     * Computes HMAC-SHA256(key, data).
     */
    fun computeHmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    // =========================================================================
    // Key Storage (SharedPreferences)
    // =========================================================================

    private fun registerBouncyCastleProvider() {
        try {
            synchronized(PairingManager::class.java) {
                Security.removeProvider(BOUNCY_CASTLE_PROVIDER_NAME)
                Security.addProvider(bouncyCastleProvider)
            }
            Log.d(TAG, "BouncyCastleProvider registered and explicitly selected for X25519")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register BouncyCastle provider", e)
        }
    }

    private fun restorePairingStateFromDisk() {
        val pairedKey = loadPairedKey()
        val peerPublicKey = loadPeerPublicKey()

        if (pairedKey != null) {
            pairedPeerPublicKeyRawBytes = peerPublicKey
            _scannedHostname.value = prefs.getString(PREFS_MAC_HOSTNAME, "") ?: ""
            _isPaired.value = true
            // IDLE, not PAIRED: PAIRED means "a handshake just succeeded here" and puts the
            // success card on the pairing screen. Restored at launch, it stayed on this
            // instance after an unpair from the Mac (wiped in the service's instance), so
            // the phone showed "Paired" with a Continue that led nowhere.
            _state.value = PairingState.IDLE
            if (peerPublicKey != null) {
                Log.d(TAG, "Existing pairing material restored synchronously on startup")
            } else {
                Log.w(TAG, "Legacy paired key restored without peer public key; future pairings persist both values")
            }
        } else {
            _isPaired.value = false
            _state.value = PairingState.IDLE
            Log.d(TAG, "No complete pairing material found — QR scan required")
        }
    }

    private fun storePairingMaterial(key: ByteArray, peerPublicKeyRawBytes: ByteArray) {
        require(key.size == HKDF_OUTPUT_LENGTH) { "Paired key must be $HKDF_OUTPUT_LENGTH bytes" }
        require(peerPublicKeyRawBytes.size == 32) { "Peer public key must be 32 bytes" }

        // Sealed under the Keystore (SG-07); a phone whose Keystore can't do this fails to pair, visibly.
        val encodedKey = PairingKeyVault.seal(key, PairingKeyVault.keystoreKey())
        val encodedPeerPublicKey = Base64.encodeToString(peerPublicKeyRawBytes, Base64.NO_WRAP)
        val committed = prefs.saveNow("pairing material") {
            putString(PREFS_KEY, encodedKey)
            putString(PREFS_PEER_PUBLIC_KEY, encodedPeerPublicKey)
        }

        if (!committed) {
            throw IllegalStateException("Failed to persist pairing material")
        }

        Log.d(TAG, "Paired key (Keystore-wrapped) and peer public key stored")
    }

    /**
     * Loads the paired key from storage. Returns null if not paired.
     */
    fun loadPairedKey(): ByteArray? = storedKey(appContext)

    /** The pinned Mac certificate fingerprint, or null when none is pinned yet. */
    fun loadMacCertPin(): ByteArray? = MacCertPin.decode(prefs.getString(PREFS_MAC_CERT, null))

    fun saveMacCertPin(fingerprint: ByteArray) {
        prefs.saveNow("certificate pin") { putString(PREFS_MAC_CERT, java.util.Base64.getEncoder().encodeToString(fingerprint)) }
        Log.d(TAG, "Pinned the Mac's TLS certificate")
    }

    fun loadPeerPublicKey(): ByteArray? {
        val encoded = prefs.getString(PREFS_PEER_PUBLIC_KEY, null) ?: return null
        return try {
            Base64.decode(encoded, Base64.NO_WRAP).also {
                if (it.size != 32) {
                    Log.e(TAG, "Stored peer public key has invalid length: ${it.size}")
                    return null
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decode peer public key from SharedPreferences", e)
            null
        }
    }

    // =========================================================================
    // Reset Pairing
    // =========================================================================

    /**
     * Clears the paired key and resets all state. With [notifyPeer], the Mac is told:
     * over the live tunnel when there is one, otherwise the next time it can be
     * reached ([deliverPendingUnpair]), so it doesn't stay paired to a phone that left.
     * [notice] is shown on the pairing screen when the unpair came from the Mac.
     * [onDone] runs on the main thread once the Mac has been told (or couldn't be) and
     * the key is gone; callers that stop sync do it there, not before, or stopping the
     * tunnel races the unpair message and the Mac never hears it.
     */
    fun resetPairing(notifyPeer: Boolean = true, notice: String = "", onDone: (() -> Unit)? = null) {
        Log.d(TAG, "Resetting pairing — clearing all crypto state and stored key (notifyPeer=$notifyPeer)")
        val finish = {
            noticeFlow.value = notice
            onDone?.let { android.os.Handler(android.os.Looper.getMainLooper()).post(it) }
            Unit
        }

        val client = MdnsQuicClient.getActiveClient()
        if (notifyPeer && client != null && client.isConnected()) {
            managerScope.launch {
                try {
                    Log.d(TAG, "Bilateral Unpair: Sending unpair_request to macOS server before local wipe")
                    client.sendJsonPayload(JSONObject().put("type", "unpair_request").toString())
                    delay(500)
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send unpair_request to macOS server — will deliver later (${e.javaClass.simpleName})")
                    savePendingUnpair()
                } finally {
                    client.disconnect()
                    wipeLocalPairingState()
                    finish()
                }
            }
            return
        }

        if (notifyPeer) savePendingUnpair()
        wipeLocalPairingState()
        finish()
        if (notifyPeer) deliverPendingUnpair()
    }

    /** Keeps what's needed to tell the Mac later; must run before the wipe. */
    private fun savePendingUnpair() {
        val key = loadPairedKey() ?: return
        val tunnel = appContext.getSharedPreferences("swiftgreen_tunnel", Context.MODE_PRIVATE)
        val host = tunnel.getString("last_host", null) ?: run {
            Log.w(TAG, "No known Mac address — the Mac will learn of the unpair only when it's re-paired")
            return
        }
        prefs.saveNow("pending unpair") {
            putString(PREFS_PENDING_PROOF, Base64.encodeToString(unpairProof(key), Base64.NO_WRAP))
            putString(PREFS_PENDING_HOST, host)
            putInt(PREFS_PENDING_PORT, tunnel.getInt("last_port", -1))
            putString(PREFS_PENDING_CERT, prefs.getString(PREFS_MAC_CERT, null))
        }
        Log.d(TAG, "Unpair saved for later delivery")
    }

    /**
     * Tells a Mac that was unreachable at unpair time. Tried right after the unpair and
     * each time the pairing screen opens; dropped once delivered or once a new pairing
     * makes it moot.
     */
    fun deliverPendingUnpair() {
        val proofB64 = prefs.getString(PREFS_PENDING_PROOF, null) ?: return
        val host = prefs.getString(PREFS_PENDING_HOST, null) ?: return
        val port = prefs.getInt(PREFS_PENDING_PORT, -1)
        if (port <= 0) return
        val macCert = MacCertPin.decode(prefs.getString(PREFS_PENDING_CERT, null))
        managerScope.launch {
            val proof = Base64.decode(proofB64, Base64.NO_WRAP)
            val delivered = SwiftGreenApplication.quicClient.deliverUnpairNotice(host, port, proof, macCert)
            Log.d(TAG, "Pending unpair — ${if (delivered) "delivered" else "Mac not reachable yet"}")
            if (delivered) {
                prefs.edit {
remove(PREFS_PENDING_PROOF)
remove(PREFS_PENDING_HOST)
remove(PREFS_PENDING_PORT)
remove(PREFS_PENDING_CERT)
}
            }
        }
    }

    private fun wipeLocalPairingState() {
        // Clear SharedPreferences
        prefs.saveNow("pairing wipe") {
            remove(PREFS_KEY)
            remove(PREFS_PEER_PUBLIC_KEY)
            remove(PREFS_MAC_HOSTNAME)
            remove(PREFS_MAC_CERT)
        }

        // Per-Mac tunnel state: the cached host (else fast reconnect dials the old Mac
        // for up to 30 min) and the beacon scan keyed to the old pairing key. The sync
        // switch and force-stop canary are user settings, not pairing, so they stay.
        MacPresence.stop(appContext)
        appContext.getSharedPreferences("swiftgreen_tunnel", Context.MODE_PRIVATE).saveNow("tunnel state wipe") {
            remove("last_host")
            remove("last_port")
            remove("last_host_ts")
            remove("last_service_name")
            remove("ble_scan_sig")
            remove("ble_first_match")
            remove("ble_first_match_failed_day")
        }

        // Clear in-memory state
        androidKeyPair = null
        macPublicKeyRawBytes = null
        pairedPeerPublicKeyRawBytes = null

        // Reset flows
        _isPaired.value = false
        _pairingPin.value = ""
        _scannedHostname.value = ""
        _errorMessage.value = ""
        _state.value = PairingState.SCANNING
    }

    /**
     * Sets the state to SCANNING (called when user navigates to QR scanner).
     */
    fun startScanning() {
        _state.value = PairingState.SCANNING
        _errorMessage.value = ""
    }
}

/** Pairing state must be on disk before the caller moves on: writes synchronously, logs and returns a failure. */
// Not KTX edit(commit = true): it discards commit()'s result, and storePairingMaterial must fail on it.
@android.annotation.SuppressLint("UseKtx")
private inline fun android.content.SharedPreferences.saveNow(what: String, block: android.content.SharedPreferences.Editor.() -> Unit): Boolean {
    val editor = edit()
    editor.block()
    return editor.commit().also { if (!it) Log.w("PairingManager", "Couldn't save $what") }
}
