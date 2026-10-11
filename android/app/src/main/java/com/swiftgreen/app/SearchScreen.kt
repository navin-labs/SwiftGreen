package com.swiftgreen.app

import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.io.File

/** One field over alerts, clipboard and files; results in the same groups as their tabs. */
@Composable
fun SearchScreen(viewModel: SearchViewModel, onBack: () -> Unit) {
    val colors = getThemeColors()
    val context = LocalContext.current
    val haptics = rememberHaptics()
    val query by viewModel.searchQuery.collectAsState()
    val results by viewModel.searchResults.collectAsState()
    var copiedId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(copiedId) { if (copiedId != null) { delay(1500); copiedId = null } }
    val nothing = results.notifications.isEmpty() && results.clipboardEntries.isEmpty() &&
        results.fileTransfers.isEmpty()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item {
            Row(Modifier.clip(RoundedCornerShape(12.dp)).clickable(onClick = onBack).padding(vertical = 6.dp, horizontal = 2.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.ChevronLeft, contentDescription = "Back to Overview", tint = colors.textSecondary)
                Text("Overview", color = colors.textSecondary, fontSize = 15.sp)
            }
            ScreenHeader("Search", "Alerts, clipboard and files")
        }
        item { SearchPill(query, { viewModel.searchQuery.value = it }, "Search everything", autoFocus = true) }

        when {
            query.isBlank() -> item { EmptyNote("Type a name, a word from a message, or part of a file name") }
            nothing && !results.isSearching -> item { EmptyNote("No results for “${query.trim()}”") }
        }

        if (results.notifications.isNotEmpty()) item {
            SectionTitle("Alerts")
            GroupCard {
                results.notifications.forEachIndexed { i, record ->
                    if (i > 0) Hairline(64.dp)
                    AlertRow(record)
                }
            }
        }

        if (results.clipboardEntries.isNotEmpty()) item {
            SectionTitle("Clipboard")
            GroupCard {
                results.clipboardEntries.forEachIndexed { i, record ->
                    if (i > 0) Hairline(16.dp)
                    GroupRow(null, record.text.trim(),
                        "${if (record.source == "mac") "From your Mac" else "From this phone"} · ${formatTimestamp(record.timestampMs)}",
                        titleLines = 2,
                        onClick = {
                            ClipboardSyncManager.writeLocalOnly(context, record.text)
                            copiedId = record.id; haptics.tick()
                        }) {
                        Icon(if (copiedId == record.id) Icons.Default.Check else Icons.Default.ContentCopy,
                            contentDescription = if (copiedId == record.id) "Copied" else "Copy",
                            tint = colors.textSecondary, modifier = Modifier.size(18.dp))
                    }
                }
            }
        }

        if (results.fileTransfers.isNotEmpty()) item {
            SectionTitle("Files")
            GroupCard {
                results.fileTransfers.forEachIndexed { i, record ->
                    if (i > 0) Hairline()
                    val received = record.direction == "received"
                    val onDisk = received && record.path != null && (record.path.startsWith("content://") || File(record.path).exists())
                    GroupRow(if (received) Icons.Default.Download else Icons.Default.Upload, record.filename,
                        "${if (received) "Received" else "Sent"} · ${Formatter.formatShortFileSize(context, record.bytes)} · ${formatTimestamp(record.timestampMs)}",
                        onClick = if (onDisk) ({ openReceivedFile(context, record.path) }) else null) {
                        if (onDisk) Chevron()
                    }
                }
            }
        }
    }
}
