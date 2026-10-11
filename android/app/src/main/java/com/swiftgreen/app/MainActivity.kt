package com.swiftgreen.app

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.delay
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.provider.Settings
import android.app.NotificationChannel
import android.app.NotificationManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.*
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Assignment
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.clickable
import com.swiftgreen.app.ui.theme.SwiftGreenTheme

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.ImageBitmap
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
class MainActivity : ComponentActivity() {
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        results.forEach { (permission, granted) ->
            Log.d("MainActivity", "Permission result: $permission → ${if (granted) "GRANTED ✅" else "DENIED ❌"}")
        }
        MacPresence.update(this, SwiftGreenApplication.quicClient.isConnected())
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Light status/nav bar icons always: the app is dark whatever the system theme.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))

        requestAppPermissions()


        setContent {
            SwiftGreenTheme {
                Surface(
                    modifier = Modifier.fillMaxSize().background(SGBlack),
                    color = Color.Transparent
                ) {
                    val context = LocalContext.current
                    val pairingManager = remember { PairingManager(context) }
                    val isPaired by pairingManager.isPaired.collectAsState()
                    val haptics = rememberHaptics()
                    var wasPaired by remember { mutableStateOf(isPaired) }
                    LaunchedEffect(isPaired) {
                        if (isPaired && !wasPaired) haptics.confirm()
                        wasPaired = isPaired
                    }

                    if (isPaired) {
                        SwiftGreenDashboard(pairingManager = pairingManager)
                    } else {
                        QRScannerScreen(
                            pairingManager = pairingManager,
                            onPairingComplete = { /* pairingManager updates isPaired automatically */ }
                        )
                    }
                }
            }
        }
    }

    private fun requestAppPermissions() {
        val permissionsToRequest = mutableListOf<String>()

        // POST_NOTIFICATIONS — dangerous permission introduced in API 33
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                permissionsToRequest.add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        // READ_CONTACTS — dangerous permission since API 23 (Marshmallow)
        if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.READ_CONTACTS)
        }

        // BLUETOOTH_SCAN ("Nearby devices") — reconnect the moment the Mac is in range
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
            checkSelfPermission(android.Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.BLUETOOTH_SCAN)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
            checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.BLUETOOTH_CONNECT)
        }

        // CAMERA — for QR code scanning
        if (checkSelfPermission(android.Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.CAMERA)
        }

        // READ_CALL_LOG — for call log sync feature
        if (checkSelfPermission(android.Manifest.permission.READ_CALL_LOG)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.READ_CALL_LOG)
        }

        // READ_SMS — for SMS thread sync feature (Step 16.1)
        if (checkSelfPermission(android.Manifest.permission.READ_SMS)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.READ_SMS)
        }
        // SEND_SMS — for SMS reply feature (Step 16.2)
        if (checkSelfPermission(android.Manifest.permission.SEND_SMS)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.SEND_SMS)
        }

        // CALL_PHONE — for outgoing dial from Mac (Step 15.2)
        if (checkSelfPermission(android.Manifest.permission.CALL_PHONE)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.CALL_PHONE)
        }

        // ANSWER_PHONE_CALLS — for incoming call control (Step 15.3)
        if (checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.ANSWER_PHONE_CALLS)
        }

        // READ_PHONE_STATE — for call state detection (Step 15.3)
        if (checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.READ_PHONE_STATE)
        }

        // Files pane (MediaBrowserStore.hasAccess): READ_EXTERNAL_STORAGE below API 30 (manifest
        // caps it at 32); 30+ uses "All files access" instead, so no media permissions are needed.
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.READ_EXTERNAL_STORAGE)
        }

        // Android 8–9: receiving files from the Mac into Downloads (FileTransferReceiver.canReceive)
        if (android.os.Build.VERSION.SDK_INT <= android.os.Build.VERSION_CODES.P &&
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            permissionsToRequest.add(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }

        if (permissionsToRequest.isNotEmpty()) {
            Log.d("MainActivity", "Requesting permissions: $permissionsToRequest")
            permissionLauncher.launch(permissionsToRequest.toTypedArray())
        } else {
            Log.d("MainActivity", "All required permissions already granted")
        }
    }
}

// ponytail: slot names are inherited from the old purple palette so SearchScreen
// and BatteryOptimizationScreen need zero edits. The values are monochrome now —
// success/warning/error all hold white on purpose, not by oversight (status colours
// live in DesignKit). Rename the slots only if a second palette ever ships.
// `background` is pure black: the screen, and the ink on white controls. Cards are
// flat and solid (surface #121417, within the #0E0F11–#15171A band); surfaceHigh is
// the one step up for tiles and controls inside them. Nothing is translucent.
data class ThemeColors(
    val background: Color, val surface: Color, val surfaceHigh: Color,
    val primary: Color, val primaryDark: Color, val onPrimary: Color,
    val success: Color, val warning: Color, val error: Color,
    val textPrimary: Color, val textSecondary: Color, val border: Color
)

@Composable
fun getThemeColors(): ThemeColors = ThemeColors(
    background = Color(0xFF000000), surface = Color(0xFF121417),
    surfaceHigh = Color(0xFF1E2125), primary = Color(0xFFFFFFFF),
    primaryDark = Color(0xFF2A2A2A), onPrimary = Color(0xFF000000),
    success = Color(0xFFFFFFFF), warning = Color(0xFFFFFFFF),
    error = Color(0xFFFFFFFF), textPrimary = Color(0xFFFFFFFF),
    textSecondary = Color(0x99FFFFFF), border = Color(0x14FFFFFF)
)

enum class SyncTab { DEVICES, MESSAGES, FILES, CLIPBOARD, SEARCH, SETTINGS }

@Composable
fun BottomNavigationBar(
    selectedTab: SyncTab,
    onTabSelected: (SyncTab) -> Unit
) {
    val colors = getThemeColors()
    val unreadCount by NotificationHistoryManager.unreadCount.collectAsState()
    Column {
        // Hairline separator — the only thing dividing nav from content on pure black.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(colors.border)
        )
        NavigationBar(containerColor = SGBlack, tonalElevation = 0.dp) {
            val tabs = listOf(
                Triple(SyncTab.DEVICES, Icons.Default.Smartphone, "Overview"),
                Triple(SyncTab.MESSAGES, Icons.Default.Notifications, "Alerts"),
                Triple(SyncTab.FILES, Icons.Default.Folder, "Files"),
                Triple(SyncTab.CLIPBOARD, Icons.AutoMirrored.Filled.Assignment, "Clipboard"),
                Triple(SyncTab.SETTINGS, Icons.Default.Settings, "Settings")
            )
            tabs.forEach { (tab, icon, label) ->
                NavigationBarItem(
                    selected = selectedTab == tab,
                    onClick = { onTabSelected(tab) },
                    icon = {
                        if (tab == SyncTab.MESSAGES && unreadCount > 0) {
                            BadgedBox(badge = {
                                Badge(
                                    containerColor = colors.textPrimary,
                                    contentColor = colors.background
                                ) { Text("$unreadCount") }
                            }) {
                                Icon(icon, contentDescription = label)
                            }
                        } else {
                            Icon(icon, contentDescription = label)
                        }
                    },
                    label = { Text(label, fontSize = 12.sp, fontWeight = FontWeight.Medium) },
                    colors = NavigationBarItemDefaults.colors(
                        // Neutral selection: white icon and label on a faint white pill.
                        // Green is kept for status only.
                        selectedIconColor = Color.White,
                        selectedTextColor = Color.White,
                        unselectedIconColor = Color(0x66FFFFFF),
                        unselectedTextColor = Color(0x66FFFFFF),
                        indicatorColor = Color(0x1FFFFFFF)
                    )
                )
            }
        }
    }
}

@Composable
fun decodeBase64ToImageBitmap(base64Str: String?): ImageBitmap? {
    if (base64Str.isNullOrEmpty()) return null
    return remember(base64Str) {
        try {
            val decodedBytes = Base64.decode(base64Str, Base64.DEFAULT)
            val bitmap = BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.size)
            bitmap?.asImageBitmap()
        } catch (e: Exception) {
            null
        }
    }
}

fun formatTimestamp(timestampMs: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - timestampMs
    if (diff < 60_000) return "Just now"
    if (diff < 3600_000) return "${diff / 60_000}m ago"
    if (diff < 86400_000) return "${diff / 3600_000}h ago"
    val sdf = SimpleDateFormat("MMM dd", Locale.getDefault())
    return sdf.format(Date(timestampMs))
}

@Composable
fun DeveloperLogsDialog(
    onDismissRequest: () -> Unit,
    receivedMessage: String
) {
    AlertDialog(
        onDismissRequest = onDismissRequest,
        title = {
            Text(
                text = "Developer Console",
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.SansSerif
            )
        },
        text = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black)
                    .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(8.dp))
                    .padding(12.dp)
            ) {
                Text(
                    text = if (receivedMessage.isEmpty()) "No messages received yet." else receivedMessage,
                    color = Color.White,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier.fillMaxSize()
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismissRequest) {
                Text("Close", color = Color.White)
            }
        },
        containerColor = Color(0xFF1A1A1A),
        titleContentColor = Color.White,
        textContentColor = Color.White
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwiftGreenDashboard(pairingManager: PairingManager) {
    val context = LocalContext.current
    val discoveryManager = remember { MdnsDiscoveryManager(context) }
    val quicClient = remember { SwiftGreenApplication.quicClient }

    // Wire pairingManager on every composition — singleton, no new socket
    LaunchedEffect(Unit) {
        quicClient.pairingManager = pairingManager
    }

    // Opening the app is the user asking for sync, so it turns back on (swiping the
    // app away or tapping Disconnect turned it off).
    androidx.compose.runtime.LaunchedEffect(Unit) {
        SyncSwitch.turnOn(context)
    }
    
    val isDiscovering by discoveryManager.isDiscovering.collectAsState()
    val status by discoveryManager.status.collectAsState()
    val devices by discoveryManager.discoveredServices.collectAsState()
    val quicStatus by quicClient.connectionStatus.collectAsState()
    val receivedMessage by quicClient.receivedMessage.collectAsState()
    val isPaired by pairingManager.isPaired.collectAsState()
    val macHostname by pairingManager.scannedHostname.collectAsState()
    // Pairings made before the hostname was persisted have none; say "your Mac".
    val macName = macHostname.removeSuffix(".local").ifBlank { "Your Mac" }
    val haptics = rememberHaptics()
    // On when sync is on: the discovery loop below is the only reconnect path that
    // doesn't need a saved Mac address, and it used to wait for a tap on Connect.
    var autoSyncEnabled by remember { mutableStateOf(SyncSwitch.isOn(context)) }
    var retryCount by remember { mutableIntStateOf(0) }
    val maxRetries = 5

    var isNotificationListenerGranted by remember { mutableStateOf(isNotificationServiceEnabled(context)) }

    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                isNotificationListenerGranted = isNotificationServiceEnabled(context)
                // Picks up "Nearby devices" granted from system settings.
                MacPresence.update(context, quicClient.isConnected())
                if (isNotificationListenerGranted) {
                    toggleNotificationListenerService(context)
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val isConnected = quicStatus.contains("Connected") || quicStatus.contains("Completed")
    val reconnecting by quicClient.reconnecting.collectAsState()
    val linkIssue by quicClient.linkIssue.collectAsState()
    // "Connecting" only while an attempt is running or scheduled. It used to also cover
    // "auto-sync on and not connected", which stayed true after every attempt had
    // given up, so the phone said Connecting forever while the Mac said Disconnected.
    val isConnecting = quicStatus == "Connecting over TLS..." || quicStatus.startsWith("Retrying") || reconnecting
    val latencyMs by quicClient.latencyMs.collectAsState()

    // Zero-touch auto-connect daemon: paired devices continuously self-heal
    // from app restarts, socket EOFs, Wi-Fi churn, and Mac server restarts.
    // Only while the app is on screen: discovery holds a Wi-Fi multicast lock, and with
    // the Mac unreachable it ran on in the background until the activity was destroyed.
    // In the background the client's saved-host reconnect and MacPresence cover it.
    val lifecycleState by lifecycleOwner.lifecycle.currentStateFlow.collectAsState()
    val visible = lifecycleState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
    androidx.compose.runtime.LaunchedEffect(autoSyncEnabled, devices, isPaired, isDiscovering, visible) {
        if (!isPaired) {
            autoSyncEnabled = true
            quicClient.disconnect()
            discoveryManager.stopDiscovery()
            return@LaunchedEffect
        }

        if (!visible) {
            discoveryManager.stopDiscovery()
            return@LaunchedEffect
        }

        if (!autoSyncEnabled) {
            return@LaunchedEffect
        }

        if (!isDiscovering && autoSyncEnabled && !quicClient.isConnected()) {
            discoveryManager.startDiscovery()
        }

        if (!quicClient.isConnected() && !isConnecting) {
            val device = devices.firstOrNull()
            if (device != null && !isConnecting && !quicClient.isConnected()) {
                if (retryCount < maxRetries) {
                    retryCount++
                    Log.d("MainActivity", "Auto-connect attempt $retryCount/$maxRetries for: ${device.serviceName}")
                    quicClient.connectForStandardSync(device)
                    kotlinx.coroutines.delay(8_000)
                } else {
                    Log.d("MainActivity", "Max retries ($maxRetries) reached — stopping auto-connect")
                    autoSyncEnabled = false
                    // Stops this screen's loop only; the client's own bounded reconnect
                    // loop (Mac dropped the link) keeps going.
                    quicClient.disconnect(keepAutoReconnect = true)
                    discoveryManager.stopDiscovery()
                }
            }
        }

        // Reset retry counter on successful connection
        if (isConnected) {
            retryCount = 0
        }
    }

    // mDNS discovery holds a multicast lock on the Wi-Fi radio: run it only while
    // looking for the Mac, never once connected or after the screen goes away.
    LaunchedEffect(isConnected) { if (isConnected) discoveryManager.stopDiscovery() }
    DisposableEffect(Unit) { onDispose { discoveryManager.stopDiscovery() } }

    var selectedTab by remember { mutableStateOf(SyncTab.DEVICES) }

    // Transfer outcomes buzz on any tab. Keyed on the newest record; the first
    // emission is history loaded from disk, not a transfer that just finished.
    val transferHistory by FileTransferManager.transferHistory.collectAsState()
    val latestTransfer = transferHistory.firstOrNull()
    var seenTransferTs by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(latestTransfer?.timestampMs) {
        val ts = latestTransfer?.timestampMs ?: return@LaunchedEffect
        if (seenTransferTs != null && ts != seenTransferTs) {
            when (latestTransfer.state) {
                "complete" -> haptics.confirm()
                "error" -> haptics.failure()
            }
        }
        seenTransferTs = ts
    }
    var showDeveloperLogs by remember { mutableStateOf(false) }
    var showBatteryOptScreen by remember { mutableStateOf(false) }
    var batteryOptChecked by remember { mutableStateOf(false) }

    LaunchedEffect(isConnected) {
        if (isConnected && !batteryOptChecked) {
            batteryOptChecked = true
            if (BatteryOptimizationHelper.shouldShowOnboarding(context)) {
                showBatteryOptScreen = true
            }
        }
    }

    if (showDeveloperLogs) {
        DeveloperLogsDialog(
            onDismissRequest = { showDeveloperLogs = false },
            receivedMessage = receivedMessage
        )
    }

    if (showBatteryOptScreen) {
        BatteryOptimizationScreen(
            onDismiss = { showBatteryOptScreen = false }
        )
        return
    }

    androidx.activity.compose.BackHandler(enabled = selectedTab == SyncTab.SEARCH) { selectedTab = SyncTab.DEVICES }

    Scaffold(
        bottomBar = {
            BottomNavigationBar(
                selectedTab = selectedTab,
                onTabSelected = { tab ->
                    selectedTab = tab
                    if (tab == SyncTab.MESSAGES) {
                        NotificationHistoryManager.markAllRead()
                    }
                }
            )
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (selectedTab) {
                SyncTab.DEVICES -> OverviewTab(
                    macName = macName,
                    isConnected = isConnected,
                    isConnecting = isConnecting,
                    linkIssue = linkIssue,
                    latencyMs = latencyMs,
                    onConnect = {
                        quicClient.retryAfterIssue()
                        SyncSwitch.turnOn(context)
                        autoSyncEnabled = true
                        retryCount = 0
                        if (!isDiscovering) discoveryManager.startDiscovery()
                    },
                    onDisconnect = {
                        autoSyncEnabled = false
                        retryCount = 0
                        discoveryManager.stopDiscovery()
                        SyncSwitch.turnOff(context)
                    },
                    onSearch = { selectedTab = SyncTab.SEARCH },
                    onDevLogs = { showDeveloperLogs = true },
                    onOpen = { selectedTab = it }
                )
                SyncTab.MESSAGES -> MessagesTabContent(isNotificationListenerGranted, macName) {
                    context.startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                SyncTab.SEARCH -> {
                    val searchViewModel = remember { SearchViewModel() }
                    DisposableEffect(Unit) { onDispose { searchViewModel.destroy() } }
                    SearchScreen(viewModel = searchViewModel, onBack = { selectedTab = SyncTab.DEVICES })
                }
                SyncTab.CLIPBOARD -> ClipboardTabContent(context = context, macName = macName)
                SyncTab.FILES -> FilesTabContent(context = context, isConnected = isConnected, macName = macName)
                SyncTab.SETTINGS -> SettingsTabContent(
                    macName = macName,
                    isConnected = isConnected,
                    onUnpairClick = {
                        autoSyncEnabled = false
                        discoveryManager.stopDiscovery()
                        // Sync goes off only after the Mac has been told: turning it off
                        // first closed the tunnel under the unpair message, so the Mac
                        // never heard it and stayed paired.
                        pairingManager.resetPairing(onDone = { SyncSwitch.turnOff(context) })
                    }
                )
            }
        }
    }
}

private fun toggleNotificationListenerService(context: Context) {
    try {
        val pm = context.packageManager
        val componentName = ComponentName(context, SwiftGreenNotificationListener::class.java)
        pm.setComponentEnabledSetting(
            componentName,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
        pm.setComponentEnabledSetting(
            componentName,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        Log.d("MainActivity", "NotificationListenerService re-bind forced successfully")
    } catch (e: Exception) {
        Log.e("MainActivity", "Failed to force re-bind NotificationListenerService", e)
    }
}

// Not private: TunnelManager reports this to the Mac as the Notifications capability.
internal fun isNotificationServiceEnabled(context: Context): Boolean {
    try {
        val enabledPackages = NotificationManagerCompat.getEnabledListenerPackages(context)
        if (enabledPackages.contains(context.packageName)) {
            return true
        }
    } catch (e: Exception) {
        // Fallback
    }

    try {
        val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
        if (!flat.isNullOrEmpty()) {
            val names = flat.split(":")
            for (name in names) {
                val cn = ComponentName.unflattenFromString(name)
                if (cn != null && cn.packageName == context.packageName) {
                    return true
                }
            }
        }
    } catch (e: Exception) {
        // Fallback
    }

    try {
        val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
        if (flat != null && flat.contains(context.packageName)) {
            return true
        }
    } catch (e: Exception) {
        // Ignored
    }

    return false
}

private fun triggerTestLocalNotification(context: Context) {
    val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    val channelId = "swiftgreen_test_channel"
    
    val channel = NotificationChannel(
        channelId,
        "SwiftGreen Test Alerts",
        NotificationManager.IMPORTANCE_DEFAULT
    ).apply {
        description = "Channel for SwiftGreen notification mirroring tests"
    }
    notificationManager.createNotificationChannel(channel)
    
    val extras = Bundle().apply {
        putBoolean("com.swiftgreen.app.TEST_NOTIFICATION", true)
    }
    
    val builder = NotificationCompat.Builder(context, channelId)
        .setSmallIcon(R.drawable.ic_stat_swift)
        .setContentTitle("Listener Interception Ok 🔮")
        .setContentText("The NotificationListenerService successfully captured, serialized, and mirrored this notification!")
        .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        .addExtras(extras)
        .setAutoCancel(true)
        
    try {
        notificationManager.notify(999, builder.build())
        Log.d("MainActivity", "Posted local test notification for listener interception")
    } catch (e: Exception) {
        Log.e("MainActivity", "Failed to post local test notification", e)
    }
}
