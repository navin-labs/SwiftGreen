package com.swiftgreen.app

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.nio.ByteBuffer
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import androidx.core.content.edit

/**
 * Apple-style presence: the Mac broadcasts a tiny Bluetooth LE beacon while it's ready
 * and the phone isn't connected; the phone hands a filtered scan to its Bluetooth chip.
 * Matching runs in hardware, so the app sleeps until the Mac is actually in range, and
 * Android wakes it through a PendingIntent even if the process was killed.
 *
 * The beacon's UUID is HMAC(pairing key, UTC day): only this phone recognises its Mac,
 * and the value rotates daily so a passer-by can't track it. The phone matches
 * yesterday/today/tomorrow to absorb clock and timezone skew. Mac side: ProximityBeacon.swift.
 *
 * Android 12+ only: the "Nearby devices" permission scans without location. Older phones
 * fall back to the Wi-Fi callback and the 15-minute job.
 */
object MacPresence {
    private const val TAG = "MacPresence"
    private const val PREFS = "swiftgreen_tunnel"
    private const val KEY_SIG = "ble_scan_sig"
    private const val KEY_FM_ACTIVE = "ble_first_match"
    private const val KEY_FM_FAILED_DAY = "ble_first_match_failed_day"
    private const val REQUEST_CODE = 7

    /** Last time the Mac's beacon was seen, 0 when it went out of range. The service reacts. */
    private val _seenAt = MutableStateFlow(0L)
    val seenAt: StateFlow<Long> = _seenAt

    /** Days since the Unix epoch in UTC — both sides compute the same value. */
    fun utcDay(nowMs: Long = System.currentTimeMillis()): Long = Math.floorDiv(nowMs, 86_400_000L)

    /** Same derivation as ProximityBeacon.swift: first 16 bytes of HMAC-SHA256. */
    fun presenceUuid(key: ByteArray, day: Long): UUID {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        val digest = mac.doFinal("SwiftGreen-presence-v1|$day".toByteArray(Charsets.UTF_8))
        val buf = ByteBuffer.wrap(digest, 0, 16)
        return UUID(buf.long, buf.long)
    }

    fun isSupported(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    /**
     * Scan only while it's useful: sync on, paired, and not connected. Re-registers only
     * when the day or pairing changed — Android silently drops apps that start scans more
     * than five times in 30 seconds, and a fresh registration re-fires "first seen".
     */
    fun update(context: Context, connected: Boolean) {
        val key = PairingManager.storedKey(context)
        if (!isSupported(context) || !hasPermission(context) || key == null || connected || !SyncSwitch.isOn(context)) {
            stop(context)
            return
        }
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner ?: run { forget(context); return }

        // Today's beacon only, plus a neighbour within an hour of UTC midnight for clock
        // skew. Fewer filters matter: "first seen" needs a scarce hardware tracking slot
        // per filter, and other apps (Nearby, Quick Share) already hold some.
        val now = System.currentTimeMillis()
        val day = utcDay(now)
        val intoDay = now - day * 86_400_000L
        val days = listOfNotNull(day, (day - 1).takeIf { intoDay < 3_600_000L }, (day + 1).takeIf { intoDay > 82_800_000L })
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // After the chip refuses "first seen" once, use the plain scan for the rest of the day.
        val firstMatch = prefs.getLong(KEY_FM_FAILED_DAY, -1L) != day
        val sig = "${days.joinToString()}|${presenceUuid(key, 0)}|$firstMatch"
        if (prefs.getString(KEY_SIG, null) == sig) return

        val filters = days.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(presenceUuid(key, it))).build() }
        val pi = pendingIntent(context)
        try {
            scanner.stopScan(pi)
            // Its hardware check needs BLUETOOTH_CONNECT on some versions; a refusal
            // falls through to the plain scan rather than giving up.
            var result = if (!firstMatch) -1 else runCatching {
                scanner.startScan(filters, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST)
                    .build(), pi)
            }.getOrElse { Log.w(TAG, "First-seen scan refused: ${it.message}"); -1 }
            var mode = "first-seen"
            if (result != 0) {
                // Every sighting, batched by the chip to once a minute where it can; the
                // sighting throttle below covers chips that can't batch.
                val batching = runCatching { adapter.isOffloadedScanBatchingSupported }.getOrDefault(false)
                val fallback = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                if (batching) fallback.setReportDelay(60_000L)
                result = scanner.startScan(filters, fallback.build(), pi)
                mode = if (batching) "batched" else "every sighting"
            }
            if (result == 0) {
                prefs.edit { putString(KEY_SIG, sig); putBoolean(KEY_FM_ACTIVE, mode == "first-seen") }
                Log.d(TAG, "Watching for the Mac's beacon (day $day, ${filters.size} filter(s), $mode)")
            } else {
                Log.w(TAG, "Bluetooth scan failed to start: $result")
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "No Bluetooth scan permission", e)
        } catch (e: Exception) {
            Log.w(TAG, "Bluetooth scan failed", e)
        }
    }

    /** The chip reported a scan error after accepting it (e.g. no free tracking slot). */
    internal fun onScanError(context: Context, error: Int) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wasFirstMatch = prefs.getBoolean(KEY_FM_ACTIVE, false) && prefs.contains(KEY_SIG)
        forget(context)
        if (wasFirstMatch) {
            // Once only per day: switch to the plain scan now. A plain-scan error isn't
            // retried here (no loop); the next disconnect, Bluetooth-on or job re-registers.
            Log.w(TAG, "First-seen scan failed ($error) — switching to plain scan")
            prefs.edit { putLong(KEY_FM_FAILED_DAY, utcDay()) }
            update(context, SwiftGreenApplication.quicClient.isConnected())
        } else {
            Log.w(TAG, "Scan error $error")
        }
    }

    // Lint can't see it: every permission-gated call in here is inside try/catch.
    @android.annotation.SuppressLint("MissingPermission")
    fun stop(context: Context) {
        try {
            if (hasPermission(context)) {
                context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner
                    ?.stopScan(pendingIntent(context))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Stopping scan failed", e)
        }
        forget(context)
    }

    /** Mark the scan as not registered, e.g. after Bluetooth turned off or a process restart. */
    fun forget(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { remove(KEY_SIG) }
    }

    /** Throttle for chips that report every sighting: one reconnect burst per 2 minutes. */
    private var lastAcceptedMs = 0L

    internal fun onSighting(context: Context, lost: Boolean) {
        if (lost) {
            _seenAt.value = 0L
            Log.d(TAG, "Mac went out of range")
            return
        }
        val now = System.currentTimeMillis()
        if (SwiftGreenApplication.quicClient.isConnected() || now - lastAcceptedMs < 120_000L) return
        lastAcceptedMs = now
        _seenAt.value = now
        Log.d(TAG, "Mac is nearby — reconnecting")
        if (!SwiftGreenTunnelService.isRunning) {
            // Allowed from the background: the app is exempt from battery optimisation
            // (an Essential), and Bluetooth scan broadcasts are an FGS-start exemption.
            runCatching { SwiftGreenTunnelService.start(context) }
                .onFailure { Log.w(TAG, "Couldn't start the service from a Bluetooth sighting", it) }
        }
    }

    private fun pendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(context, REQUEST_CODE,
            Intent(context, MacPresenceReceiver::class.java).setAction("com.swiftgreen.app.MAC_NEARBY"),
            // Mutable: the Bluetooth stack writes the scan results into the intent.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
}

class MacPresenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val error = intent.getIntExtra(android.bluetooth.le.BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            MacPresence.onScanError(context, error)
            return
        }
        if (!SyncSwitch.isOn(context)) { MacPresence.stop(context); return }
        val type = intent.getIntExtra(android.bluetooth.le.BluetoothLeScanner.EXTRA_CALLBACK_TYPE,
            ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        MacPresence.onSighting(context, lost = type == ScanSettings.CALLBACK_TYPE_MATCH_LOST)
    }
}
