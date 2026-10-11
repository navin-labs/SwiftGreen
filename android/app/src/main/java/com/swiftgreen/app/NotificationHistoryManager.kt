package com.swiftgreen.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import org.json.JSONArray
import org.json.JSONObject
import androidx.core.content.edit

object NotificationHistoryManager {
    data class NotificationRecord(
        val appName: String,
        val title: String,
        val body: String,
        val timestampMs: Long,
        val key: String,
        val appIcon: String?, // base64 PNG, nullable
        // Replyable from the Mac (a RemoteInput action) — WhatsApp DMs, SMS and the like,
        // as opposed to one-way alerts. Records saved before this existed read false.
        val hasReplyAction: Boolean = false
    )

    private val _history = MutableStateFlow<List<NotificationRecord>>(emptyList())
    val history: StateFlow<List<NotificationRecord>> = _history.asStateFlow()

    private var isInitialized = false
    private const val PREFS_NAME = "swiftgreen_notification_history"
    private const val KEY_HISTORY = "history_json"
    private const val KEY_LAST_READ = "last_read_timestamp_ms"
    private const val MAX_ITEMS = 50
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lastReadTimestampMs = MutableStateFlow(0L)
    val unreadCount: StateFlow<Int> =
        combine(history, lastReadTimestampMs) { list, lastRead ->
            list.count { it.timestampMs > lastRead }
        }.stateIn(scope, SharingStarted.Eagerly, 0)

    val searchQuery = MutableStateFlow("")
    val selectedAppNames = MutableStateFlow<Set<String>>(emptySet())
    /** Messages only: notifications the Mac can reply to. Display filter, not a new feature. */
    val messagesOnly = MutableStateFlow(false)
    val filteredHistory: StateFlow<List<NotificationRecord>> =
        combine(history, searchQuery, selectedAppNames, messagesOnly) { list, query, apps, messages ->
            val q = query.trim().lowercase()
            list.filter { r ->
                (!messages || r.hasReplyAction) &&
                (apps.isEmpty() || r.appName in apps) &&
                (q.isEmpty() || r.appName.lowercase().contains(q) ||
                 r.title.lowercase().contains(q) || r.body.lowercase().contains(q))
            }
        }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    @Synchronized
    fun init(context: Context) {
        if (isInitialized) return
        isInitialized = true

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val jsonStr = prefs.getString(KEY_HISTORY, null)
        if (jsonStr != null) {
            try {
                val array = JSONArray(jsonStr)
                val loadedList = mutableListOf<NotificationRecord>()
                for (i in 0 until array.length()) {
                    val obj = array.getJSONObject(i)
                    loadedList.add(
                        NotificationRecord(
                            appName = obj.optString("appName", ""),
                            title = obj.optString("title", ""),
                            body = obj.optString("body", ""),
                            timestampMs = obj.optLong("timestampMs", 0L),
                            key = obj.optString("key", ""),
                            appIcon = if (obj.has("appIcon") && !obj.isNull("appIcon")) obj.getString("appIcon") else null,
                            hasReplyAction = obj.optBoolean("hasReplyAction", false)
                        )
                    )
                }
                _history.value = loadedList
            } catch (e: Exception) {
                // Ignore parse errors, start fresh
            }
        }
        lastReadTimestampMs.value = prefs.getLong(KEY_LAST_READ, 0L)
    }

    fun addRecord(record: NotificationRecord) {
        val currentList = _history.value.toMutableList()
        if (record.key.isNotBlank()) {
            currentList.removeAll { it.key == record.key }
        }
        currentList.add(0, record) // prepend
        if (currentList.size > MAX_ITEMS) {
            currentList.removeAt(currentList.lastIndex) // drop oldest
        }
        _history.value = currentList
        persistHistory()
    }

    fun markAllRead() {
        lastReadTimestampMs.value = System.currentTimeMillis() + 1
        SwiftGreenApplication.instance.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit { putLong(KEY_LAST_READ, lastReadTimestampMs.value) }
    }

    fun clearAll() {
        _history.value = emptyList()
        val context = SwiftGreenApplication.instance
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit { remove(KEY_HISTORY) }
    }

    private fun persistHistory() {
        val context = SwiftGreenApplication.instance
        val array = JSONArray()
        _history.value.forEach { record ->
            val obj = JSONObject().apply {
                put("appName", record.appName)
                put("title", record.title)
                put("body", record.body)
                put("timestampMs", record.timestampMs)
                put("key", record.key)
                if (record.appIcon != null) {
                    put("appIcon", record.appIcon)
                }
                put("hasReplyAction", record.hasReplyAction)
            }
            array.put(obj)
        }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit { putString(KEY_HISTORY, array.toString()) }
    }
}
