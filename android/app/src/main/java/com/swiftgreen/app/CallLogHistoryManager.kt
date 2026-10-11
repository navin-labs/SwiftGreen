package com.swiftgreen.app

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CallLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import androidx.core.content.edit

object CallLogHistoryManager {
    private const val TAG = "CallLogHistoryManager"
    private const val PREFS_NAME = "swiftgreen_call_log"
    private const val KEY_CALLS = "call_log"
    private const val MAX_ITEMS = 50

    /// One finished call writes the log more than once — the row lands, then type and
    /// duration are filled in — so a fire is not a call. Coalescing on the *last* fire
    /// is also what makes the query see a settled row instead of racing the write: this
    /// is why the observer needs no retry loop and no guessed-at fixed delay.
    private const val DEBOUNCE_MS = 1_000L

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    @Volatile private var debounceJob: Job? = null

    @Volatile private var registered = false
    @Volatile private var appContext: Context? = null

    /// Registration does not fire an initial callback, so this never duplicates the
    /// sync the connect path already sends.
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            val context = appContext ?: return
            debounceJob?.cancel()
            debounceJob = scope.launch {
                delay(DEBOUNCE_MS)
                // stop() may have won the race while this was sleeping; sending then
                // would push through a socket that is already gone.
                if (!registered) return@launch
                fetchAndSerialize(context)?.let { TunnelManager.sendRawMessage(it) }
            }
        }
    }

    /**
     * Watches the call log for the lifetime of one tunnel connection, mirroring
     * [CallControlManager.start]. Idempotent via [registered].
     *
     * The observer fires when the row is actually written, which is the whole point:
     * PHONE_STATE's IDLE arrives before the platform has finished writing the entry, so
     * hanging this off the call-state machine would intermittently query too early.
     * It also catches log writes no IDLE was seen for at all.
     */
    fun start(context: Context) {
        if (registered) return
        appContext = context.applicationContext
        // Descendants included: some OEMs notify on the per-entry URI, not the table.
        context.contentResolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, observer)
        registered = true
        Log.d(TAG, "Call log observer registered")
    }

    /// Lives and dies with the connection, like the PHONE_STATE receiver. A call that
    /// ends while this is unregistered is caught by the sync on the next connect.
    fun stop() {
        if (!registered) return
        registered = false
        debounceJob?.cancel()
        debounceJob = null
        try {
            appContext?.contentResolver?.unregisterContentObserver(observer)
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering call log observer", e)
        }
        appContext = null
        Log.d(TAG, "Call log observer unregistered")
    }

    /** Fetches recent calls, persists locally, returns JSON string ready to send. Null on failure. */
    fun fetchAndSerialize(context: Context): String? {
        return try {
            val calls = JSONArray()
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.CACHED_NAME,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.DURATION
                ),
                null, null,
                "${CallLog.Calls.DATE} DESC"
            )?.use { cursor ->
                var count = 0
                while (cursor.moveToNext()) {
                    if (count >= MAX_ITEMS) break
                    count++
                    val callType = when (cursor.getInt(2)) {
                        CallLog.Calls.INCOMING_TYPE -> "incoming"
                        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                        CallLog.Calls.MISSED_TYPE   -> "missed"
                        else                        -> "unknown"
                    }
                    calls.put(JSONObject().apply {
                        put("phone_number",      cursor.getString(0) ?: "")
                        val name = cursor.getString(1)
                        put("contact_name", if (name.isNullOrBlank()) JSONObject.NULL else name)
                        put("call_type",         callType)
                        put("timestamp",         cursor.getLong(3))
                        put("duration_seconds",  cursor.getInt(4))
                        put("source",            "cellular")
                    })
                }
            }
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit { putString(KEY_CALLS, calls.toString()) }
            Log.d(TAG, "Fetched ${calls.length()} call log records")
            JSONObject().apply {
                put("type", "call_log_sync")
                put("calls", calls)
            }.toString()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to fetch call log: ${e.message}")
            null
        }
    }
}
