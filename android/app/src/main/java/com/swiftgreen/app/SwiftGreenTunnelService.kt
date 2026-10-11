package com.swiftgreen.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import androidx.core.content.edit

/**
 * The user's on/off for background sync. Off means nothing runs — no service, no
 * Bluetooth watch, no scheduled checks, no start on boot — until the app is opened
 * again or Connect is tapped. Swiping the app away from Recents leaves sync running
 * (like Apple Continuity); Force stop in Android settings ends everything, as Android
 * itself cancels the service, jobs and Bluetooth watch until the app is opened.
 */
object SyncSwitch {
    private const val PREFS = "swiftgreen_tunnel"
    private const val KEY = "sync_on"

    fun isOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, true)

    fun turnOn(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY, true) }
        SwiftGreenTunnelService.start(context)
    }

    /**
     * Force stop means "stop", but Android restarts the process right away to rebind the
     * notification listener, and on recent versions also sends it LOCKED_BOOT_COMPLETED,
     * which would restart sync. So detect it the way WorkManager does: a far-future alarm
     * that only a force stop (or a reboot, told apart by BOOT_COUNT, or an update, told
     * apart by lastUpdateTime) can erase. Called first thing in Application.onCreate.
     */
    fun checkForceStop(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val intent = Intent(context, BootReceiver::class.java).setAction("com.swiftgreen.app.FORCE_STOP_CANARY")
        val alive = android.app.PendingIntent.getBroadcast(context, 99, intent,
            android.app.PendingIntent.FLAG_NO_CREATE or android.app.PendingIntent.FLAG_IMMUTABLE) != null
        val boot = android.provider.Settings.Global.getInt(context.contentResolver,
            android.provider.Settings.Global.BOOT_COUNT, -1)
        val installed = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)
        if (!alive && prefs.getInt("canary_boot", -2) == boot && prefs.getLong("canary_install", -1L) == installed) {
            Log.d("SyncSwitch", "App was force stopped — sync stays off until it's opened")
            prefs.edit { putBoolean(KEY, false) }
        }
        if (!alive) {
            val pi = android.app.PendingIntent.getBroadcast(context, 99, intent, android.app.PendingIntent.FLAG_IMMUTABLE)
            // Never fires in practice; it exists only to be erased by a force stop.
            context.getSystemService(android.app.AlarmManager::class.java)
                .set(android.app.AlarmManager.RTC, System.currentTimeMillis() + 3650L * 86_400_000L, pi)
        }
        prefs.edit { putInt("canary_boot", boot); putLong("canary_install", installed) }
    }

    fun turnOff(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(KEY, false) }
        // Closing a TLS socket writes close_notify: network I/O, so never on the main thread.
        Thread { SwiftGreenApplication.quicClient.disconnect() }.start()
        context.getSystemService(JobScheduler::class.java).cancel(SwiftGreenTunnelService.KEEPALIVE_JOB_ID)
        MacPresence.stop(context)
        SwiftGreenTunnelService.stop(context)
        Log.d("SyncSwitch", "Sync turned off — service stopped, checks cancelled")
    }
}

/**
 * Holds the connection while sync is on. Apple's model, not a wake lock: the CPU and
 * Wi-Fi radio sleep, and an incoming packet wakes the phone. The Mac (usually on power)
 * sends the periodic ping; this side only answers, so nothing here needs a timer.
 *
 * Reconnect triggers, all event-driven: the Mac's Bluetooth beacon coming into range
 * (MacPresence), Wi-Fi coming back, and a 15-minute job as the last safety net.
 */
class SwiftGreenTunnelService : Service() {

    private val TAG = "SwiftGreenTunnelService"
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var isInitialized = false
    private var scope: CoroutineScope? = null
    private var bluetoothReceiver: android.content.BroadcastReceiver? = null

    companion object {
        private const val CHANNEL_ID = "swiftgreen_tunnel"
        private const val CHANNEL_NAME = "SwiftGreen Sync"
        private const val NOTIFICATION_ID = 1001
        const val KEEPALIVE_JOB_ID = 1002
        private const val ACTION_TURN_OFF = "com.swiftgreen.app.TURN_OFF"

        /** Liveness flag the keepalive job reads (getRunningServices is unreliable on API 26+). */
        @Volatile
        var isRunning = false

        fun start(context: Context) {
            context.startForegroundService(Intent(context, SwiftGreenTunnelService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SwiftGreenTunnelService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        // A new process may have lost the scan registration; register once more.
        MacPresence.forget(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground must run on every start, even one that's about to stop.
        startForeground(NOTIFICATION_ID, buildNotification("Looking for your Mac"))

        if (intent?.action == ACTION_TURN_OFF) {
            SyncSwitch.turnOff(this)
            return START_NOT_STICKY
        }
        if (!SyncSwitch.isOn(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (isInitialized && MdnsQuicClient.getActiveClient() == null) {
            Log.d(TAG, "Process was killed and restarted — activeClient lost, resetting init flag")
            isInitialized = false
        }

        if (!isInitialized) {
            isInitialized = true

            val pm = PairingManager(applicationContext)
            val client = SwiftGreenApplication.quicClient
            client.pairingManager = pm
            if (!client.isConnected()) {
                Log.d(TAG, "Fast reconnect on service start: ${client.connectToLastKnownHost()}")
            }

            scope = CoroutineScope(SupervisorJob() + Dispatchers.Main).also { s ->
                // The notification says what's actually true, not a fixed "Connected".
                s.launch {
                    client.connectionStatus.collect {
                        val mac = pm.scannedHostname.value.removeSuffix(".local").ifBlank { "your Mac" }
                        updateNotification(if (client.isConnected()) "Connected to $mac" else "Looking for $mac")
                    }
                }
                // Watch for the Mac's beacon only while disconnected. Debounced so a
                // flapping link can't hit Android's five-scans-in-30-seconds limit.
                s.launch {
                    client.connectionStatus.collectLatest {
                        delay(3_000)
                        MacPresence.update(this@SwiftGreenTunnelService, client.isConnected())
                    }
                }
                // Mac seen nearby: reconnect now, then back off. Bounded, so a Mac that's
                // near but on another network costs five attempts, not a loop.
                s.launch {
                    MacPresence.seenAt.collectLatest { seen ->
                        if (seen == 0L) return@collectLatest
                        for (wait in longArrayOf(0, 10, 30, 60, 120)) {
                            delay(wait * 1000)
                            if (client.isConnected()) break
                            client.reconnectIfNeeded()
                        }
                    }
                }
            }

            registerBluetoothReceiver()
            registerNetworkCallback()
            scheduleKeepaliveJob()

            val mediaMgr = MediaSessionManager()
            MediaSessionManager.instance = mediaMgr
            mediaMgr.start()

            Log.d(TAG, "Tunnel service initialized — NetworkCallback, keepalive job, MediaSession")
        }

        return START_STICKY
    }

    override fun onDestroy() {
        try {
            networkCallback?.let {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(it)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering NetworkCallback", e)
        }
        networkCallback = null
        bluetoothReceiver?.let { runCatching { unregisterReceiver(it) } }
        bluetoothReceiver = null
        scope?.cancel()
        scope = null

        MediaSessionManager.instance?.stop()
        MediaSessionManager.instance = null

        isInitialized = false
        isRunning = false
        Log.d(TAG, "Tunnel service destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Notification ──────────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows while SwiftGreen syncs with your Mac"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(contentText: String): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE)
        val turnOff = PendingIntent.getService(this, 1,
            Intent(this, SwiftGreenTunnelService::class.java).setAction(ACTION_TURN_OFF),
            PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SwiftGreen")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_stat_swift)
            .setContentIntent(open)
            .addAction(0, "Turn Off", turnOff)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(contentText: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(contentText))
    }

    // ── Reconnect triggers ────────────────────────────────────────────────────────

    /** Scans don't survive Bluetooth turning off; register again when it comes back on. */
    private fun registerBluetoothReceiver() {
        bluetoothReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(android.bluetooth.BluetoothAdapter.EXTRA_STATE, -1)) {
                    android.bluetooth.BluetoothAdapter.STATE_OFF -> MacPresence.forget(context)
                    android.bluetooth.BluetoothAdapter.STATE_ON -> {
                        MacPresence.forget(context)
                        MacPresence.update(context, SwiftGreenApplication.quicClient.isConnected())
                    }
                }
            }
        }
        // NOT_EXPORTED still receives system broadcasts; it only blocks other apps.
        androidx.core.content.ContextCompat.registerReceiver(this, bluetoothReceiver,
            android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED),
            androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    /** Event-driven: Wi-Fi coming back is the moment to reconnect, not a polling loop. */
    private fun registerNetworkCallback() {
        try {
            val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    Log.d(TAG, "Wi-Fi available — reconnecting if needed")
                    MdnsQuicClient.getActiveClient()?.reconnectIfNeeded()
                }
                // Log only: tells a Wi-Fi drop apart from anything else when the tunnel
                // resets mid-call, without acting on a network that may not
                // be the one the tunnel runs on.
                override fun onLost(network: Network) {
                    Log.w(TAG, "Wi-Fi lost ($network) — tunnel connected=${SwiftGreenApplication.quicClient.isConnected()}")
                }
            }
            (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                .registerNetworkCallback(request, networkCallback!!)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register NetworkCallback", e)
        }
    }

    /**
     * The one safety net: a 15-minute check on Wi-Fi, batched by Android with other
     * apps' work. Restarts the service if the OEM killed it; cancelled when sync is off.
     */
    private fun scheduleKeepaliveJob() {
        try {
            val job = JobInfo.Builder(KEEPALIVE_JOB_ID, ComponentName(this, TunnelKeepaliveJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build()
            getSystemService(JobScheduler::class.java).schedule(job)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule keepalive job", e)
        }
    }
}
