package com.swiftgreen.app

import android.content.Context
import android.content.SharedPreferences
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
import java.util.UUID
import androidx.core.content.edit

data class ClipboardRecord(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    val source: String,
    val timestampMs: Long,
    val pinned: Boolean = false
)

object ClipboardHistoryManager {
    private val _history = MutableStateFlow<List<ClipboardRecord>>(emptyList())
    val history: StateFlow<List<ClipboardRecord>> = _history.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val searchQuery = MutableStateFlow("")
    val filteredHistory: StateFlow<List<ClipboardRecord>> =
        combine(history, searchQuery) { list, query ->
            val q = query.trim().lowercase()
            val filtered = if (q.isEmpty()) list else list.filter { it.text.lowercase().contains(q) }
            filtered.sortedWith(compareByDescending<ClipboardRecord> { it.pinned }.thenByDescending { it.timestampMs })
        }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private var prefs: SharedPreferences? = null
    private const val PREFS_NAME = "swiftgreen_clipboard"
    private const val KEY_HISTORY = "clipboard_history"
    private const val MAX_ITEMS = 20

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        loadFromPrefs()
    }

    private fun loadFromPrefs() {
        val jsonString = prefs?.getString(KEY_HISTORY, "[]") ?: "[]"
        try {
            val array = JSONArray(jsonString)
            val list = mutableListOf<ClipboardRecord>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                list.add(
                    ClipboardRecord(
                        id = obj.optString("id", UUID.randomUUID().toString()),
                        text = obj.optString("text", ""),
                        source = obj.optString("source", ""),
                        timestampMs = obj.optLong("timestampMs", 0L),
                        pinned = obj.optBoolean("pinned", false)
                    )
                )
            }
            val pinned = list.filter { it.pinned }
            val unpinned = list.filter { !it.pinned }.take(MAX_ITEMS)
            _history.value = pinned + unpinned
        } catch (e: Exception) {
            _history.value = emptyList()
        }
    }

    fun addRecord(text: String, source: String) {
        if (text.isEmpty()) return
        val current = _history.value
        if (current.firstOrNull()?.text == text) return

        val record = ClipboardRecord(
            text = text,
            source = source,
            timestampMs = System.currentTimeMillis()
        )
        
        val combined = listOf(record) + current
        val pinned = combined.filter { it.pinned }
        val unpinned = combined.filter { !it.pinned }.take(MAX_ITEMS)
        val newList = pinned + unpinned
        _history.value = newList
        persist()
    }

    fun togglePin(id: String) {
        val current = _history.value.toMutableList()
        val idx = current.indexOfFirst { it.id == id }
        if (idx == -1) return
        current[idx] = current[idx].copy(pinned = !current[idx].pinned)
        _history.value = current
        persist()
    }

    fun clearAll() {
        _history.value = emptyList()
        prefs?.edit { remove(KEY_HISTORY) }
    }

    private fun persist() {
        try {
            val array = JSONArray()
            for (record in _history.value) {
                val obj = JSONObject().apply {
                    put("id", record.id)
                    put("text", record.text)
                    put("source", record.source)
                    put("timestampMs", record.timestampMs)
                    put("pinned", record.pinned)
                }
                array.put(obj)
            }
            prefs?.edit { putString(KEY_HISTORY, array.toString()) }
        } catch (e: Exception) {
            // Ignore exceptions
        }
    }
}
