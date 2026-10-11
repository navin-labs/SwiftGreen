package com.swiftgreen.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

private val screenPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp)

private fun hhmm(ms: Long) = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms))

/** "Today", "Yesterday", or "Mon 22 Sep" — the day sections of every list. */
private fun dayLabel(ms: Long): String {
    val day = Calendar.getInstance().apply { timeInMillis = ms }
    val today = Calendar.getInstance()
    fun sameDay(a: Calendar, b: Calendar) =
        a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    if (sameDay(day, today)) return "Today"
    today.add(Calendar.DAY_OF_YEAR, -1)
    if (sameDay(day, today)) return "Yesterday"
    return SimpleDateFormat("EEE d MMM", Locale.getDefault()).format(Date(ms))
}

private class PermissionRow(
    val icon: ImageVector, val label: String, val purpose: String, val granted: Boolean, val fix: () -> Unit
)

/** Every permission the app uses, re-read on each resume. First two are essentials. */
@Composable
private fun rememberPermissionRows(context: Context): List<PermissionRow> {
    val tick = rememberResumeTick()
    fun granted(vararg perms: String) = perms.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
    val openAppSettings = {
        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    return remember(tick) {
        listOf(
            PermissionRow(Icons.Default.Notifications, "Notification access", "Mirror notifications to your Mac",
                isNotificationServiceEnabled(context)) {
                context.startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            },
            PermissionRow(Icons.Default.BatteryFull, "Unrestricted battery", "Stay connected with the screen off",
                BatteryOptimizationHelper.isExempted(context)) { BatteryOptimizationHelper.openSettings(context) },
            PermissionRow(Icons.Default.Sms, "SMS", "Read and reply to texts from your Mac",
                granted(android.Manifest.permission.READ_SMS, android.Manifest.permission.SEND_SMS), openAppSettings),
            PermissionRow(Icons.Default.Call, "Phone & call log", "Call history, dialing, answer from Mac",
                granted(android.Manifest.permission.READ_CALL_LOG, android.Manifest.permission.CALL_PHONE), openAppSettings),
            PermissionRow(Icons.Default.Contacts, "Contacts", "Names and favourites on your Mac",
                granted(android.Manifest.permission.READ_CONTACTS), openAppSettings),
            nearbyRow(context, openAppSettings).takeIf { MacPresence.isSupported(context) },
            // Android only lets an app open another app's call screen from the
            // background with "Display over other apps"; answering needs exactly that.
            PermissionRow(Icons.Default.PhoneInTalk, "Answer calls from Mac",
                "Lets Answer on your Mac pick up WhatsApp and other app calls",
                Settings.canDrawOverlays(context)) {
                context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            },
            PermissionRow(Icons.Default.Folder, "All files access", "Browse every folder from your Mac",
                MediaBrowserStore.hasAccess(context)) {
                // A special permission: its own settings screen, never a runtime dialog.
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    context.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } else openAppSettings()
            }
        ).filterNotNull()
    }
}

/** Needs both the permission and Bluetooth itself on; says which one is missing. */
private fun nearbyRow(context: Context, openAppSettings: () -> Unit): PermissionRow {
    val permitted = MacPresence.hasPermission(context)
    val bluetoothOn = runCatching {
        context.getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter?.isEnabled == true
    }.getOrDefault(false)
    return if (permitted && !bluetoothOn) {
        PermissionRow(Icons.Default.BluetoothDisabled, "Nearby devices",
            "Bluetooth is off. Turn it on to reconnect the moment your Mac is near", false) {
            context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    } else {
        PermissionRow(Icons.Default.Bluetooth, "Nearby devices", "Reconnect the moment your Mac is near",
            permitted, openAppSettings)
    }
}

/**
 * Makers like Xiaomi, Oppo, Vivo, Huawei and Samsung stop background apps beyond what
 * stock Android does. Their "autostart" screens have no public API or readable state,
 * so the row only opens the right screen, and only on phones where one exists.
 * Component names follow dontkillmyapp.com.
 */
private val oemBackgroundScreens = listOf(
    "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
    "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
    "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
    "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
    "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
    "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
    "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
    "com.hihonor.systemmanager" to "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
    "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
    "com.asus.mobilemanager" to "com.asus.mobilemanager.powersaver.PowerSaverSettings",
    "com.letv.android.letvsafe" to "com.letv.android.letvsafe.AutobootManageActivity",
)

private fun oemBackgroundIntent(context: Context): Intent? = oemBackgroundScreens.firstNotNullOfOrNull { (pkg, cls) ->
    val intent = Intent().setComponent(android.content.ComponentName(pkg, cls)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val info = runCatching { context.packageManager.resolveActivity(intent, 0) }.getOrNull()
    intent.takeIf { info?.activityInfo?.exported == true }
}

// MARK: Overview

/**
 * Priority order: the Mac link, anything blocking it, the two things you send,
 * the transfer in flight, then the latest things your Mac sent over.
 */
@Composable
fun OverviewTab(
    macName: String,
    isConnected: Boolean,
    isConnecting: Boolean,
    linkIssue: String?,
    latencyMs: Int?,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit,
    onSearch: () -> Unit,
    onDevLogs: () -> Unit,
    onOpen: (SyncTab) -> Unit
) {
    val context = LocalContext.current
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    val essentialsOff = rememberPermissionRows(context).take(2).count { !it.granted }
    val activeTransfer by FileTransferManager.activeTransfer.collectAsState()
    val progress by FileTransferManager.transferProgress.collectAsState()
    val clips by ClipboardHistoryManager.history.collectAsState()
    val transfers by FileTransferManager.transferHistory.collectAsState()
    // Clippings and files from the Mac, newest first: what you'd reach for next.
    val recent = remember(clips, transfers) {
        (clips.filter { it.source == "mac" }.map { it.timestampMs to (it as Any) } +
            transfers.filter { it.direction == "received" && it.state == "complete" }.map { it.timestampMs to it })
            .sortedByDescending { it.first }.take(4).map { it.second }
    }
    var clipNote by remember { mutableStateOf<String?>(null) }
    var copiedId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(clipNote) { if (clipNote != null) { delay(1800); clipNote = null } }
    LaunchedEffect(copiedId) { if (copiedId != null) { delay(1500); copiedId = null } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri?.let { FileTransferManager.sendFile(uri = it, context = context, onProgress = {}, onComplete = {}, onError = {}) }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(24.dp)) {
        item {
            ScreenHeader("Overview",
                when {
                    isConnected -> "Connected to $macName"
                    linkIssue != null -> linkIssue
                    isConnecting -> "Looking for $macName…"
                    else -> "Not connected"
                },
                onTitleLongPress = onDevLogs) {
                IconButton(onClick = onSearch) {
                    Icon(Icons.Default.Search, contentDescription = "Search", tint = colors.textSecondary)
                }
            }
        }

        item {
            GroupCard {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(52.dp).clip(CircleShape).background(colors.surfaceHigh),
                        contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.Laptop, null, tint = colors.textPrimary, modifier = Modifier.size(26.dp))
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(macName, color = colors.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            StatusDot(isConnected, connecting = isConnecting && linkIssue == null)
                            Spacer(Modifier.width(6.dp))
                            Text(when {
                                    isConnected -> "Connected" + (latencyMs?.let { " · $it ms" } ?: "")
                                    linkIssue != null -> "Not accepted by your Mac"
                                    isConnecting -> "Connecting…"
                                    else -> "Not connected"
                                }, color = colors.textPrimary, fontSize = 13.sp)
                        }
                        Text("Encrypted · local network", color = colors.textSecondary, fontSize = 12.sp)
                    }
                    when {
                        isConnected -> PillButton("Disconnect", primary = false, small = true) { haptics.tap(); onDisconnect() }
                        isConnecting -> CircularProgressIndicator(color = colors.textSecondary, strokeWidth = 2.dp,
                            modifier = Modifier.size(20.dp))
                        else -> PillButton("Connect", primary = true, small = true) { haptics.tap(); onConnect() }
                    }
                }
            }
        }

        if (essentialsOff > 0) {
            item {
                GroupCard {
                    GroupRow(Icons.Default.Warning, "Finish setup",
                        "$essentialsOff ${if (essentialsOff == 1) "permission is" else "permissions are"} off, so sync can stop",
                        onClick = { onOpen(SyncTab.SETTINGS) }) { Chevron() }
                }
            }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ActionTile(Icons.Default.Upload, "Send a file", "to $macName", isConnected,
                    Modifier.weight(1f)) { picker.launch("*/*") }
                ActionTile(Icons.Default.ContentPaste, "Send clipboard", clipNote ?: "to $macName", isConnected,
                    Modifier.weight(1f),
                    detailColor = when (clipNote) { null -> null; "Sent" -> SGSuccess; else -> SGDanger }) {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                    val text = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
                    if (text.isNullOrEmpty()) { clipNote = "Clipboard is empty"; haptics.failure() }
                    else { ClipboardSyncManager.sendToMac(text); clipNote = "Sent"; haptics.confirm() }
                }
            }
        }

        activeTransfer?.let { transfer ->
            item {
                GroupCard {
                    GroupRow(Icons.Default.Upload, transfer.filename, "Sending · ${(progress * 100).toInt()}%",
                        trailing = {
                            if (transfer.state == "sending") IconButton(onClick = { FileTransferManager.cancelSend(context) }) {
                                Icon(Icons.Default.Close, contentDescription = "Cancel", tint = colors.textSecondary)
                            }
                        })
                    LinearProgressIndicator(progress = { progress }, color = colors.textPrimary,
                        trackColor = colors.surfaceHigh,
                        modifier = Modifier.fillMaxWidth().padding(start = RowTextInset, end = 16.dp, bottom = 14.dp)
                            .height(3.dp).clip(CircleShape))
                }
            }
        }

        item {
            SectionTitle("From $macName")
            GroupCard {
                if (recent.isEmpty()) EmptyNote("Text you copy and files you send on your Mac appear here")
                recent.forEachIndexed { i, entry ->
                    if (i > 0) Hairline()
                    when (entry) {
                        is ClipboardRecord -> GroupRow(Icons.Default.ContentCopy, entry.text.trim(),
                            "Copied · ${formatTimestamp(entry.timestampMs)}",
                            onClick = {
                                ClipboardSyncManager.writeLocalOnly(context, entry.text)
                                copiedId = entry.id; haptics.tick()
                            }) {
                            Text(if (copiedId == entry.id) "Copied" else "Copy", color = colors.textSecondary,
                                fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        }
                        is FileTransferManager.TransferRecord -> GroupRow(Icons.AutoMirrored.Filled.InsertDriveFile, entry.filename,
                            "Received · ${Formatter.formatShortFileSize(context, entry.bytes)} · ${formatTimestamp(entry.timestampMs)}",
                            onClick = { entry.path?.let { openReceivedFile(context, it) } }) { Chevron() }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionTile(icon: ImageVector, title: String, detail: String, enabled: Boolean,
                       modifier: Modifier, detailColor: Color? = null, onClick: () -> Unit) {
    val colors = getThemeColors()
    // Dimming goes on the content only, so the card itself always reads as a card.
    Column(modifier.clip(RoundedCornerShape(20.dp)).background(colors.surface)
            .clickable(enabled = enabled, onClick = onClick).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.alpha(if (enabled) 1f else 0.4f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(36.dp).clip(CircleShape).background(colors.textPrimary), contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = colors.background, modifier = Modifier.size(20.dp))
            }
            Column {
                Text(title, color = colors.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(detail, color = detailColor ?: colors.textSecondary, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

// MARK: Alerts

/** Notifications this phone has sent to the Mac, by day. */
@Composable
fun MessagesTabContent(isNotificationListenerGranted: Boolean, macName: String, onConfigureClick: () -> Unit) {
    val colors = getThemeColors()
    val history by NotificationHistoryManager.history.collectAsState()
    val filtered by NotificationHistoryManager.filteredHistory.collectAsState()
    val query by NotificationHistoryManager.searchQuery.collectAsState()
    val selectedApps by NotificationHistoryManager.selectedAppNames.collectAsState()
    val messagesOnly by NotificationHistoryManager.messagesOnly.collectAsState()
    val hasMessages = remember(history) { history.any { it.hasReplyAction } }
    LaunchedEffect(Unit) {
        NotificationHistoryManager.unreadCount.collect { if (it > 0) NotificationHistoryManager.markAllRead() }
    }
    val apps = remember(history) { history.map { it.appName }.filter { it.isNotBlank() }.distinct().sorted() }
    val days = remember(filtered) { filtered.groupBy { dayLabel(it.timestampMs) }.toList() }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item {
            ScreenHeader("Alerts", if (history.isEmpty()) "Notifications sent to $macName"
                else "${history.size} sent to $macName")
        }
        if (!isNotificationListenerGranted) {
            item {
                GroupCard {
                    GroupRow(Icons.Default.NotificationsOff, "Notification access is off",
                        "Turn it on so $macName gets your notifications", onClick = onConfigureClick) {
                        PillButton("Turn On", primary = true, small = true, onClick = onConfigureClick)
                    }
                }
            }
        }
        if (history.isNotEmpty()) {
            item {
                SearchPill(query, { NotificationHistoryManager.searchQuery.value = it }, "Search alerts")
                if (apps.size > 1 || hasMessages) {
                    Spacer(Modifier.height(12.dp))
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        item {
                            Chip("All", selectedApps.isEmpty() && !messagesOnly) {
                                NotificationHistoryManager.selectedAppNames.value = emptySet()
                                NotificationHistoryManager.messagesOnly.value = false
                            }
                        }
                        // Ones the Mac can reply to; reply itself stays Mac-only.
                        if (hasMessages) item {
                            Chip("Messages", messagesOnly) {
                                NotificationHistoryManager.messagesOnly.value = !messagesOnly
                            }
                        }
                        items(apps) { app ->
                            Chip(app, app in selectedApps) {
                                NotificationHistoryManager.selectedAppNames.value =
                                    if (app in selectedApps) selectedApps - app else selectedApps + app
                            }
                        }
                    }
                }
            }
        }
        when {
            history.isEmpty() && isNotificationListenerGranted ->
                item { EmptyNote("Nothing yet. Notifications appear here as they reach $macName.") }
            history.isNotEmpty() && filtered.isEmpty() -> item { EmptyNote("No alerts match") }
        }
        days.forEachIndexed { index, (day, records) ->
            item(key = "day-$day") {
                SectionTitle(day) {
                    if (index == 0) SectionAction("Clear") { NotificationHistoryManager.clearAll() }
                }
                GroupCard {
                    records.forEachIndexed { i, record ->
                        if (i > 0) Hairline(64.dp)
                        AlertRow(record)
                    }
                }
            }
        }
    }
}

@Composable
internal fun AlertRow(record: NotificationHistoryManager.NotificationRecord) {
    val colors = getThemeColors()
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        val icon = decodeBase64ToImageBitmap(record.appIcon)
        if (icon != null) Image(icon, null, Modifier.size(36.dp).clip(RoundedCornerShape(9.dp)))
        else Box(Modifier.size(36.dp).clip(RoundedCornerShape(9.dp)).background(colors.surfaceHigh))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(record.appName.ifBlank { "App" }, color = colors.textSecondary, fontSize = 12.sp,
                    fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                Text(hhmm(record.timestampMs), color = colors.textSecondary, fontSize = 12.sp)
            }
            if (record.title.isNotBlank()) Text(record.title, color = colors.textPrimary, fontSize = 15.sp,
                fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (record.body.isNotBlank()) Text(record.body, color = colors.textSecondary, fontSize = 14.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = getThemeColors()
    Text(label, color = if (selected) colors.background else colors.textPrimary, fontSize = 13.sp,
        fontWeight = FontWeight.Medium, maxLines = 1,
        modifier = Modifier.clip(CircleShape).background(if (selected) colors.textPrimary else colors.surface)
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp))
}

// MARK: Clipboard

@Composable
fun ClipboardTabContent(context: Context, macName: String) {
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    val history by ClipboardHistoryManager.history.collectAsState()
    val filtered by ClipboardHistoryManager.filteredHistory.collectAsState()
    val query by ClipboardHistoryManager.searchQuery.collectAsState()
    var copiedId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(copiedId) { if (copiedId != null) { delay(1500); copiedId = null } }
    val pinned = filtered.filter { it.pinned }
    val recent = filtered.filter { !it.pinned }

    @Composable
    fun ClipGroup(records: List<ClipboardRecord>) = GroupCard {
        records.forEachIndexed { i, record ->
            if (i > 0) Hairline(16.dp)
            GroupRow(null, record.text.trim(),
                "${if (record.source == "mac") "From $macName" else "From this phone"} · ${formatTimestamp(record.timestampMs)}",
                titleLines = 3,
                onClick = {
                    ClipboardSyncManager.writeLocalOnly(context, record.text)
                    copiedId = record.id; haptics.tick()
                }) {
                IconButton(onClick = { ClipboardHistoryManager.togglePin(record.id); haptics.tick() },
                    modifier = Modifier.size(36.dp)) {
                    Icon(if (record.pinned) Icons.Default.PushPin else Icons.Outlined.PushPin,
                        contentDescription = if (record.pinned) "Unpin" else "Pin",
                        tint = if (record.pinned) colors.textPrimary else colors.textSecondary,
                        modifier = Modifier.size(18.dp))
                }
                Icon(if (copiedId == record.id) Icons.Default.Check else Icons.Default.ContentCopy,
                    contentDescription = if (copiedId == record.id) "Copied" else "Copy",
                    tint = colors.textSecondary, modifier = Modifier.size(18.dp))
            }
        }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { ScreenHeader("Clipboard", "Copy on $macName, paste here. Tap any item to copy it again.") }
        if (history.isNotEmpty()) {
            item { SearchPill(query, { ClipboardHistoryManager.searchQuery.value = it }, "Search clipboard") }
        }
        when {
            history.isEmpty() -> item { EmptyNote("Nothing copied yet. Text you copy on $macName lands here and on this phone's clipboard.") }
            filtered.isEmpty() -> item { EmptyNote("Nothing matches") }
        }
        if (pinned.isNotEmpty()) item { SectionTitle("Pinned"); ClipGroup(pinned) }
        if (recent.isNotEmpty()) item {
            SectionTitle("Recent") { SectionAction("Clear") { ClipboardHistoryManager.clearAll(); haptics.tick() } }
            ClipGroup(recent)
        }
    }
}

// MARK: Files

@Composable
fun FilesTabContent(context: Context, isConnected: Boolean, macName: String) {
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    val history by FileTransferManager.transferHistory.collectAsState()
    val folderName by MacFileBrowserStore.directoryName.collectAsState()
    val folderItems by MacFileBrowserStore.items.collectAsState()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { ScreenHeader("Files", "Shared by $macName, and everything sent between you") }

        // The Mac's shared folder sits first: it's something to act on.
        item {
            SectionTitle(if (folderName.isEmpty()) "From $macName" else "From $macName · $folderName")
            GroupCard {
                when {
                    !isConnected -> EmptyNote("Connect to see the folder $macName shares")
                    folderName.isEmpty() -> EmptyNote("Nothing shared yet. On your Mac, open Bridge → Mac Folder.")
                    folderItems.isEmpty() -> EmptyNote("The shared folder is empty")
                }
                if (isConnected) folderItems.forEachIndexed { i, item ->
                    if (i > 0) Hairline()
                    GroupRow(Icons.AutoMirrored.Filled.InsertDriveFile, item.filename,
                        Formatter.formatShortFileSize(context, item.sizeBytes),
                        onClick = { MacFileBrowserStore.requestFile(item.fileId); haptics.tick() }) {
                        Icon(Icons.Default.Download, contentDescription = "Download", tint = colors.textPrimary,
                            modifier = Modifier.size(20.dp))
                    }
                }
            }
        }

        item {
            SectionTitle("History") {
                if (history.isNotEmpty()) SectionAction("Clear") { FileTransferManager.clearHistory(context); haptics.tick() }
            }
            GroupCard {
                if (history.isEmpty()) EmptyNote("Files you send or receive show up here")
                history.forEachIndexed { i, record ->
                    if (i > 0) Hairline()
                    val received = record.direction == "received"
                    val onDisk = received && record.path != null && (record.path.startsWith("content://") || File(record.path).exists())
                    val state = when (record.state) {
                        "complete" -> if (received) "Received" else "Sent"
                        "cancelled" -> "Cancelled"
                        else -> "Failed"
                    }
                    GroupRow(if (received) Icons.Default.Download else Icons.Default.Upload, record.filename,
                        "$state · ${Formatter.formatShortFileSize(context, record.bytes)} · ${hhmm(record.timestampMs)}" +
                            if (received && record.state == "complete" && !onDisk) " · removed" else "",
                        detailColor = when (record.state) { "complete", "cancelled" -> null; else -> SGDanger },
                        onClick = if (onDisk) ({ openReceivedFile(context, record.path) }) else null) {
                        if (onDisk) Chevron()
                    }
                }
            }
        }
    }
}

// MARK: Settings

@Composable
fun SettingsTabContent(macName: String, isConnected: Boolean, onUnpairClick: () -> Unit) {
    val context = LocalContext.current
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    val rows = rememberPermissionRows(context)
    var confirmUnpair by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    BackHandler(enabled = showHelp) { showHelp = false }

    if (showHelp) { HelpPage { showHelp = false }; return }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Unpair from $macName?", fontWeight = FontWeight.Bold) },
            text = { Text("Sync stops right away. You'll scan a new code on your Mac to connect again.") },
            confirmButton = {
                TextButton(onClick = { confirmUnpair = false; haptics.confirm(); onUnpairClick() }) {
                    Text("Unpair", color = SGDanger, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmUnpair = false }) { Text("Cancel", color = colors.textSecondary) }
            },
            containerColor = SGSheet, titleContentColor = colors.textPrimary,
            textContentColor = colors.textSecondary
        )
    }

    @Composable
    fun PermissionItem(row: PermissionRow) =
        GroupRow(row.icon, row.label, row.purpose, onClick = row.fix) {
            if (row.granted) Text("On", color = colors.textSecondary, fontSize = 14.sp)
            else PillButton("Turn On", primary = true, small = true, onClick = row.fix)
        }

    @Composable
    fun PermissionGroup(list: List<PermissionRow>) = GroupCard {
        list.forEachIndexed { i, row ->
            if (i > 0) Hairline()
            PermissionItem(row)
        }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { ScreenHeader("Settings", "Your Mac, permissions and help") }
        item {
            SectionTitle("Paired Mac")
            GroupCard {
                GroupRow(Icons.Default.Laptop, macName, if (isConnected) "Connected · encrypted" else "Not connected",
                    leading = {
                        Box(contentAlignment = Alignment.BottomEnd) {
                            IconTile(Icons.Default.Laptop)
                            Box(Modifier.offset(2.dp, 2.dp).clip(CircleShape).background(colors.surface).padding(2.dp)) {
                                StatusDot(isConnected)
                            }
                        }
                    }) {
                    PillButton("Unpair", primary = false, small = true) { confirmUnpair = true }
                }
            }
        }
        item {
            SectionTitle("Essentials")
            val oem = remember { oemBackgroundIntent(context) }
            GroupCard {
                rows.take(2).forEachIndexed { i, row ->
                    if (i > 0) Hairline()
                    PermissionItem(row)
                }
                if (oem != null) {
                    Hairline()
                    val brand = android.os.Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                    val open = { runCatching { context.startActivity(oem) }; Unit }
                    GroupRow(Icons.Default.PowerSettingsNew, "Background on $brand",
                        "$brand can stop apps on its own. Allow SwiftGreen to start and run in the background.",
                        onClick = open) {
                        PillButton("Open", primary = false, small = true, onClick = open)
                    }
                }
            }
        }
        item { SectionTitle("Feature permissions"); PermissionGroup(rows.drop(2)) }
        item {
            SectionTitle("Support")
            GroupCard {
                GroupRow(Icons.AutoMirrored.Filled.HelpOutline, "Help", "Pairing, connection, clipboard, files and more",
                    onClick = { showHelp = true }) { Chevron() }
                Hairline()
                // Read from the build so the UI can't drift from the real version.
                val version = remember {
                    context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
                }
                GroupRow(Icons.Default.Info, "Version") {
                    Text(version, color = colors.textSecondary, fontSize = 14.sp)
                }
            }
        }
    }
}

// MARK: Help

private class HelpTopic(val name: String, val icon: ImageVector, val items: List<Pair<String, String>>)

/** Every answer names a real control on this phone or the Mac, so it can be checked. */
private val helpTopics = listOf(
    HelpTopic("Getting Started", Icons.Default.AutoAwesome, listOf(
        "What does SwiftGreen do?" to
            "It links this phone to your Mac. Notifications, texts, calls, the clipboard and files move between them over your own Wi‑Fi, with no cloud account.",
        "How do I pair with my Mac?" to
            "Open SwiftGreen on your Mac and go to Settings to show the pairing code. Open SwiftGreen on this phone, point the camera at the code, type the PIN your Mac shows, then tap Pair. Both need to be on the same Wi‑Fi network.",
    )),
    HelpTopic("Connection", Icons.Default.Wifi, listOf(
        "Why does it say Not connected?" to
            "Keep SwiftGreen open on your Mac and make sure both are on the same Wi‑Fi network. It reconnects by itself: the moment your Mac is nearby (with Nearby devices on), when Wi‑Fi comes back, or when you tap Connect on Overview. In Settings → Essentials, turn on Unrestricted battery, otherwise Android can stop the connection when the screen turns off.",
        "How does it know my Mac is nearby?" to
            "Your Mac sends a tiny Bluetooth signal while it's ready and this phone isn't connected. This phone's Bluetooth chip listens for it without waking the app, so SwiftGreen reconnects within seconds of you sitting down. The signal's ID changes every day and only your paired phone recognises it. It needs Nearby devices in Settings → Feature permissions (Android 12 and later).",
        "Does my data go through the cloud?" to
            "No. This phone and your Mac talk directly over an encrypted connection on your local network, and the pairing keys stay on your devices.",
        "Do I need Bluetooth on?" to
            "No. Everything works over Wi‑Fi. Bluetooth only makes reconnecting instant when you come back to your Mac; without it, SwiftGreen reconnects when Wi‑Fi returns or within 15 minutes. You never need to pair the phone and Mac in Bluetooth settings.",
        "Does SwiftGreen drain my battery?" to
            "No. It never keeps your phone awake. While connected it sleeps like any idle app and wakes only when your Mac sends something; while your Mac is away, only the Bluetooth chip listens for it. Swiping the app away from Recent apps keeps sync running. To stop it completely, tap Turn Off on its notification or Disconnect on Overview, or force stop it in Android settings. It stays off until you open it again.",
        "How do I unpair?" to
            "Tap Unpair in Settings → Paired Mac. Both devices forget each other, and you'll scan a new code to connect again.",
    )),
    HelpTopic("Notifications", Icons.Default.Notifications, listOf(
        "Notifications aren't reaching my Mac." to
            "Turn on Notification access in Settings → Essentials. On your Mac, check Settings → Notification Filters in case that app is turned off.",
        "What is the Alerts tab?" to
            "Notifications this phone has sent to your Mac, grouped by day. Clearing it here doesn't touch your phone's own notifications.",
    )),
    HelpTopic("Clipboard", Icons.Default.ContentPaste, listOf(
        "How does the clipboard sync?" to
            "Text you copy on your Mac lands on this phone's clipboard straight away. To send the other way, tap Send clipboard on Overview, or share text to Send to Mac from any app.",
        "Can I copy something again later?" to
            "Yes. Open Clipboard and tap any item to copy it. Pin the ones you use often and they stay at the top.",
    )),
    HelpTopic("Files", Icons.Default.Folder, listOf(
        "How do I send a file to my Mac?" to
            "Tap Send a file on Overview, or share it to Send to Mac from any app.",
        "Where do files from my Mac go?" to
            "Into this phone's Downloads folder. Open Files and tap one to open it.",
        "How do I get files from my Mac's shared folder?" to
            "When your Mac shares a folder from Bridge → Mac Folder, its files appear in Files under From your Mac. Tap one to download it.",
        "Why can't my Mac browse my folders?" to
            "Your Mac opens this phone's folders in Bridge → Phone only when All files access is on. Turn it on in Settings → Feature permissions.",
    )),
    HelpTopic("Calls & Texts", Icons.Default.Call, listOf(
        "Why doesn't Answer on my Mac pick up a WhatsApp call?" to
            "Android only lets SwiftGreen open WhatsApp's call screen if you allow it. Turn on Answer calls from Mac in Settings → Feature permissions (Android calls it Display over other apps). Declining and hanging up work without it. The call's audio stays on this phone.",
        "How do calls and texts work from my Mac?" to
            "Your Mac asks this phone to place the call or send the text, using its own SIM. Turn on SMS and Phone & call log in Settings → Feature permissions.",
        "What does Find my phone do?" to
            "When you click Find my phone on your Mac, this phone rings at full volume, even on silent, and stops after 30 seconds.",
    )),
)

@Composable
private fun HelpPage(onBack: () -> Unit) {
    val colors = getThemeColors()
    val haptics = rememberHaptics()
    var query by remember { mutableStateOf("") }
    var topic by remember { mutableStateOf<String?>(null) }
    var open by remember { mutableStateOf(setOf<String>()) }
    val q = query.trim().lowercase()
    val shown = helpTopics.mapNotNull { t ->
        if (q.isEmpty()) t.takeIf { topic == null || topic == t.name }
        else t.items.filter { (qq, a) -> qq.lowercase().contains(q) || a.lowercase().contains(q) }
            .takeIf { it.isNotEmpty() }?.let { HelpTopic(t.name, t.icon, it) }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = screenPadding,
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item {
            Row(Modifier.clip(RoundedCornerShape(12.dp)).clickable(onClick = onBack).padding(vertical = 6.dp, horizontal = 2.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.ChevronLeft, contentDescription = "Back to Settings", tint = colors.textSecondary)
                Text("Settings", color = colors.textSecondary, fontSize = 15.sp)
            }
            ScreenHeader("Help", "Answers to common questions")
        }
        item { SearchPill(query, { query = it }, "Search Help") }
        if (q.isEmpty()) item {
            // Topic tiles, two across; tapping narrows the page, tapping again shows all.
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                helpTopics.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        pair.forEach { t ->
                            val selected = topic == t.name
                            Column(Modifier.weight(1f).clip(RoundedCornerShape(20.dp))
                                    .background(if (selected) colors.textPrimary else colors.surface)
                                    .clickable { topic = if (selected) null else t.name; haptics.tick() }
                                    .padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                val ink = if (selected) colors.background else colors.textPrimary
                                Icon(t.icon, null, tint = ink, modifier = Modifier.size(22.dp))
                                Column {
                                    Text(t.name, color = ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    Text("${t.items.size} ${if (t.items.size == 1) "answer" else "answers"}",
                                        color = ink.copy(alpha = 0.6f), fontSize = 12.sp)
                                }
                            }
                        }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        if (shown.isEmpty()) item { EmptyNote("No answers for “${query.trim()}”") }
        shown.forEach { t ->
            item(key = "topic-${t.name}") {
                SectionTitle(t.name)
                GroupCard {
                    t.items.forEachIndexed { i, (question, answer) ->
                        if (i > 0) Hairline(16.dp)
                        // A search opens every match, so the answer is right there.
                        val isOpen = q.isNotEmpty() || question in open
                        val turn by animateFloatAsState(if (isOpen) 90f else 0f, label = "chevron")
                        Column(Modifier.fillMaxWidth()
                                .clickable { open = if (question in open) open - question else open + question }
                                .padding(horizontal = 16.dp, vertical = 14.dp)
                                .animateContentSize()) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(question, color = colors.textPrimary, fontSize = 15.sp,
                                    fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                                Spacer(Modifier.width(8.dp))
                                Icon(Icons.Default.ChevronRight, null, tint = colors.textSecondary,
                                    modifier = Modifier.size(20.dp).rotate(turn))
                            }
                            if (isOpen) {
                                Spacer(Modifier.height(8.dp))
                                Text(answer, color = colors.textSecondary, fontSize = 14.sp, lineHeight = 20.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}
