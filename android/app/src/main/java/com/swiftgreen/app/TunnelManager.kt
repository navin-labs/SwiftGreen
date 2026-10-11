package com.swiftgreen.app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.BufferedOutputStream
import java.util.concurrent.ConcurrentHashMap

object TunnelManager {
    private const val TAG = "TunnelManager"
    private const val DEDUP_WINDOW_MS    = 5_000L   // Suppress identical content within 5 s
    private const val STALE_DROP_MS      = 8_000L   // Drop notifications older than 8 s

    // ── High-priority HandlerThread ───────────────────────────────────────────────
    // Initialization order matters on Kotlin objects:
    //  1. Create the HandlerThread
    //  2. Call start() — this spawns the OS thread and prepares its Looper
    //  3. Access .looper — this property BLOCKS until the Looper is ready (safe)
    //  4. Wrap in Handler — now safe because the Looper is guaranteed initialized
    //  5. Post a priority-set task onto the handler — Process.setThreadPriority must
    //     be called FROM the target thread itself to take effect reliably.
    private val tunnelThread: HandlerThread = HandlerThread("SwiftGreen-Tunnel").also { it.start() }

    // HandlerThread.looper blocks until the looper is initialized — this is the
    // correct and safe way to obtain the Looper after start().
    val handler: Handler = try {
        Handler(tunnelThread.looper).also { h ->
            // Set thread priority from within the thread itself — the only reliable way.
            // THREAD_PRIORITY_URGENT_DISPLAY = -8 (same as UI rendering thread).
            h.post { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY) }
            Log.d("TunnelManager", "SwiftGreen-Tunnel HandlerThread started and handler ready")
        }
    } catch (e: Exception) {
        Log.e("TunnelManager", "Failed to create Handler from HandlerThread looper — falling back", e)
        // This should never happen, but ensures the app does not crash at object init time.
        Handler(android.os.Looper.getMainLooper())
    }

    @Volatile
    private var activeSocket: java.net.Socket? = null

    private val _isTunnelActive = MutableStateFlow(false)
    val isTunnelActive: StateFlow<Boolean> = _isTunnelActive.asStateFlow()

    /**
     * Tracks content hash → last-sent timestamp for deduplication.
     * Keyed on (appName + title + body).hashCode() — timestamp excluded
     * intentionally to absorb the ~20 ms variance in Android postTime.
     */
    private val recentHashes = ConcurrentHashMap<Int, Long>()

    // ── Socket registration ───────────────────────────────────────────────────────

    fun registerSocket(socket: java.net.Socket) {
        handler.post {
            activeSocket = socket
            _isTunnelActive.value = true
            Log.d(TAG, "Socket registered. Tunnel is active.")
        }
    }

    fun unregisterSocket() {
        handler.post {
            activeSocket = null
            _isTunnelActive.value = false
            Log.d(TAG, "Socket unregistered. Tunnel is inactive.")
        }
    }

    // ── Send path ─────────────────────────────────────────────────────────────────

    /**
     * Sends [json] payload over the active socket.
     *
     * Synchronously on the calling thread:
     *  1. **Staleness check** — drop if the notification's timestamp field is
     *     more than [STALE_DROP_MS] old.
     *  2. **Deduplication** — drop if the same content hash was sent within
     *     [DEDUP_WINDOW_MS]. Evict expired entries inline.
     *
     * On the HandlerThread:
     *  3. **Write raw socket** — wrap the raw socket outputStream in a BufferedOutputStream,
     *     write the bytes, and immediately flush.
     */
    fun sendMessage(json: String) {
        val now = System.currentTimeMillis()

        // ── 1. Staleness check (Synchronous) ──────────────────────────────────
        val notificationTimestamp = extractTimestamp(json)
        if (notificationTimestamp > 0 && (now - notificationTimestamp) > STALE_DROP_MS) {
            Log.w(TAG, "Dropped stale notification (${now - notificationTimestamp}ms old): " +
                    json.take(120))
            return
        }

        // ── 2. Deduplication (Synchronous) ────────────────────────────────────
        val hashKey = contentHashOf(json)
        val lastSent = recentHashes[hashKey]
        if (lastSent != null && (now - lastSent) < DEDUP_WINDOW_MS) {
            Log.d(TAG, "Duplicate suppressed (hash=$hashKey, ${now - lastSent}ms ago)")
            return
        }
        // Evict expired hashes to prevent unbounded memory growth
        recentHashes.entries.removeAll { (now - it.value) >= DEDUP_WINDOW_MS }
        recentHashes[hashKey] = now

        // Post with zero delay — no queuing, no Executor overhead
        handler.post {
            val socket = activeSocket
            if (socket == null || socket.isClosed) {
                Log.e(TAG, "No active Socket — message dropped")
                return@post
            }

            try {
                val outputStream = BufferedOutputStream(socket.getOutputStream())
                val payload = json + "\n"
                outputStream.write(payload.toByteArray(Charsets.UTF_8))
                outputStream.flush()
                Log.d(TAG, "Sent (hash=$hashKey, ${payload.length} bytes)")
            } catch (e: Exception) {
                Log.e(TAG, "Write failed — unregistering socket: ${e.message}")
                unregisterSocket()
            }
        }
    }

    /**
     * Sends [json] payload directly over the active socket, bypassing
     * staleness and deduplication checks. Use for file transfer messages
     * where content hashing is meaningless and dedup must not apply.
     */
    fun sendRawMessage(json: String) {
        handler.post {
            // Drop only leftover frames of the cancelled transfer. isCancelled stays set
            // until the next send starts, so an unscoped check silently swallowed media
            // state, telemetry and notifications after any cancel.
            if (FileTransferManager.isCancelled && json.contains("\"file_transfer_")) {
                Log.d(TAG, "sendRawMessage: skipping — transfer cancelled")
                return@post
            }
            val socket = activeSocket
            if (socket == null || socket.isClosed) {
                Log.e(TAG, "No active Socket — raw message dropped")
                return@post
            }
            try {
                val outputStream = BufferedOutputStream(socket.getOutputStream())
                val payload = json + "\n"
                outputStream.write(payload.toByteArray(Charsets.UTF_8))
                outputStream.flush()
                Log.d(TAG, "Raw sent (${payload.length} bytes)")
            } catch (e: Exception) {
                Log.e(TAG, "Raw write failed — unregistering socket: ${e.message}")
                unregisterSocket()
            }
        }
    }

    fun sendCancelMessage(json: String) {
        val socket = activeSocket
        if (socket == null || socket.isClosed) {
            Log.w(TAG, "sendCancelMessage: socket null or closed")
            return
        }
        Thread {
            try {
                synchronized(socket) {
                    val payload = json + "\n"
                    socket.getOutputStream().write(payload.toByteArray(Charsets.UTF_8))
                    socket.getOutputStream().flush()
                }
                Log.d(TAG, "Cancel message sent on dedicated thread")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send cancel message: ${e.message}")
            }
        }.start()
    }

    fun cancelPendingMessages() {
        handler.removeCallbacksAndMessages(null)
        Log.d(TAG, "Handler queue cleared — all pending sends cancelled")
    }

    /**
     * Sends [json] from the dedicated HandlerThread and suspends until the write
     * completes. Returns `true` only if the bytes were written and flushed; `false`
     * if the send was skipped (transfer cancelled), dropped (no/closed socket), or
     * the write threw. Callers that need to know whether the write landed (file
     * transfer) should check the result; fire-and-forget callers may ignore it.
     */
    suspend fun sendRawMessageSuspend(json: String): Boolean {
        if (FileTransferManager.isCancelled) {
            Log.d(TAG, "sendRawMessageSuspend: skipping — transfer cancelled")
            return false
        }
        return kotlinx.coroutines.suspendCancellableCoroutine<Boolean> { cont ->
            val runnable = Runnable {
                if (FileTransferManager.isCancelled) {
                    Log.d(TAG, "sendRawMessageSuspend: skipping — transfer cancelled")
                    if (cont.isActive) cont.resumeWith(Result.success(false))
                    return@Runnable
                }
                val socket = activeSocket
                if (socket == null || socket.isClosed) {
                    Log.e(TAG, "No active Socket — raw message dropped")
                    if (cont.isActive) cont.resumeWith(Result.success(false))
                    return@Runnable
                }
                var ok = false
                try {
                    val outputStream = BufferedOutputStream(socket.getOutputStream())
                    val payload = json + "\n"
                    outputStream.write(payload.toByteArray(Charsets.UTF_8))
                    outputStream.flush()
                    Log.d(TAG, "Raw sent suspend (${payload.length} bytes)")
                    ok = true
                } catch (e: Exception) {
                    Log.e(TAG, "Raw write failed: ${e.message}")
                    unregisterSocket()
                }
                if (cont.isActive) cont.resumeWith(Result.success(ok))
            }
            handler.post(runnable)
            cont.invokeOnCancellation {
                handler.removeCallbacks(runnable)
            }
        }
    }

    private fun readBatteryState(context: Context): Pair<Int, Boolean>? {
        val ifilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = context.registerReceiver(null, ifilter)
        val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val pct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
        if (pct < 0) return null
        val charging = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val isCharging = charging == BatteryManager.BATTERY_STATUS_CHARGING ||
                         charging == BatteryManager.BATTERY_STATUS_FULL
        return Pair(pct, isCharging)
    }

    // Lint can't see it: every permission-gated call in here is inside try/catch.
    @android.annotation.SuppressLint("MissingPermission")
    fun sendBatteryTelemetry(context: Context) {
        val (pct, isCharging) = readBatteryState(context) ?: return
        val sims = org.json.JSONArray()
        try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                    as? android.telephony.SubscriptionManager
            sm?.activeSubscriptionInfoList?.forEach { sub ->
                sims.put(org.json.JSONObject().apply {
                    put("subscription_id", sub.subscriptionId)
                    put("sim_slot_index", sub.simSlotIndex)
                    put("display_name", sub.displayName?.toString() ?: "")
                    put("carrier_name", sub.carrierName?.toString() ?: "")
                })
            }
        } catch (e: Exception) {
            Log.w(TAG, "sims telemetry failed: ${e.message}")
        }
        val json = org.json.JSONObject().apply {
            put("type", "telemetry")
            put("battery_level", pct)
            put("battery_charging", isCharging)
            put("sims", sims)
            put("notification_access", isNotificationServiceEnabled(context))
        }
        sendRawMessage(json.toString())
    }

    /**
     * Static device facts. Pushed once per connection — nothing here changes while
     * the tunnel is up, so it does not belong on the 60 s telemetry heartbeat.
     */
    fun sendDeviceInfo(context: Context) {
        val json = org.json.JSONObject().apply {
            put("type", "device_info")
            // Settings.Global.DEVICE_NAME is the user's own name for the phone
            // ("Navin's Pixel"). Absent on some OEM builds — Build.* is the floor.
            put("device_name",
                android.provider.Settings.Global.getString(
                    context.contentResolver, android.provider.Settings.Global.DEVICE_NAME
                ) ?: "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
            // MODEL alone is useless on Samsung ("SM-S911B") — the Mac joins the two.
            put("manufacturer", android.os.Build.MANUFACTURER)
            put("model", android.os.Build.MODEL)
            put("android_version", android.os.Build.VERSION.RELEASE)
            // ponytail: PackageManager rather than BuildConfig.VERSION_NAME — the
            // module has buildFeatures.buildConfig off, and generating that class
            // for one string is a build-system change for nothing.
            put("app_version",
                context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "")
            // StatFs stats the volume; it reads no file contents, so no permission.
            try {
                val stat = android.os.StatFs(
                    android.os.Environment.getExternalStorageDirectory().path
                )
                put("storage_total_bytes", stat.totalBytes)
                put("storage_free_bytes", stat.availableBytes)
            } catch (e: Exception) {
                // Omit rather than send zeros — the Mac renders absent as "Not reported".
                Log.w(TAG, "storage telemetry failed: ${e.message}")
            }
        }
        sendRawMessage(json.toString())
    }

    fun sendTelemetry(context: Context, latencyMs: Int) {
        val (pct, isCharging) = readBatteryState(context) ?: return
        val json = org.json.JSONObject().apply {
            put("type", "telemetry")
            put("battery_level", pct)
            put("battery_charging", isCharging)
            put("latency_ms", latencyMs)
            // Live, not connect-time: the user can revoke notification access in
            // Android Settings mid-session, and a stale "granted" would be a lie.
            put("notification_access", isNotificationServiceEnabled(context))
        }
        Log.d("MdnsSslClient", "Sent telemetry: $json")
        sendRawMessage(json.toString())
    }

    // ── Hash / extraction helpers ─────────────────────────────────────────────────

    /**
     * Stable content hash over appName + title + body only.
     * Timestamp excluded to absorb Android's ~20ms postTime variance.
     */
    private fun contentHashOf(json: String): Int {
        val appName = json.substringAfter("\"appName\":\"").substringBefore("\"")
        val title   = json.substringAfter("\"title\":\"").substringBefore("\"")
        val body    = json.substringAfter("\"body\":\"").substringBefore("\"")
        return (appName + title + body).hashCode()
    }

    /** Extracts the numeric timestamp field from the JSON string. Returns 0 on failure. */
    private fun extractTimestamp(json: String): Long {
        return try {
            json.substringAfter("\"timestamp\":").substringBefore(",")
                .substringBefore("}").trim().toLong()
        } catch (e: Exception) {
            0L
        }
    }
}
