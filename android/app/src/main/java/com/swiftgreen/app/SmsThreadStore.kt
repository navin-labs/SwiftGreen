package com.swiftgreen.app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import androidx.core.net.toUri

object SmsThreadStore {
    private const val TAG = "SmsThreadStore"
    const val PAGE_SIZE = 100
    private const val MAX_MESSAGES = 50
    // A send with no outcome by then is reported as timed out; the provider is checked
    // for the outcome every SEND_POLL_MS until then (see sendSms).
    private const val SEND_TIMEOUT_MS = 60_000L
    private const val SEND_POLL_MS = 2_000L

    // Gate PhoneLookup to real phone numbers. Alphanumeric sender IDs (banks, OTP services)
    // are passed through as-is; PhoneLookup silently returns null for them.
    private val phoneRegex = Regex("^[+]?[0-9][0-9\\s().+-]{2,}$")

    /** Returns sms_thread_list JSON string for the given page, or null on failure. */
    fun fetchThreadPage(context: Context, page: Int): String? {
        return try {
            val totalCount = context.contentResolver.query(
                Telephony.Sms.Conversations.CONTENT_URI,
                arrayOf(Telephony.Sms.Conversations.THREAD_ID), null, null, null
            )?.use { it.count } ?: 0

            // Newest message first, first row per thread wins. Conversations has no
            // date column, and sorting it by THREAD_ID ordered threads by when they
            // were *created*: a years-old bank thread with today's OTP fell off page 0.
            // ponytail: scans (thread_id, date) of the whole SMS table — fine to ~100k rows.
            val latest = LinkedHashMap<Long, Triple<String, String, Long>>()   // thread → (address, body, date)
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
                null, null, "${Telephony.Sms.DATE} DESC"
            )?.use { c ->
                val wanted = (page + 1) * PAGE_SIZE
                while (latest.size < wanted && c.moveToNext()) {
                    val id = c.getLong(0)
                    if (id !in latest) latest[id] = Triple(c.getString(1) ?: "", c.getString(2) ?: "", c.getLong(3))
                }
            }

            val threads = JSONArray()
            latest.entries.drop(page * PAGE_SIZE).forEach { (threadId, row) ->
                val (address, snippet, date) = row
                threads.put(JSONObject().apply {
                    put("thread_id",       threadId)
                    put("contact_name",    resolveContactName(context, address) ?: JSONObject.NULL)
                    put("phone_number",    address)
                    put("snippet",         snippet)
                    put("timestamp_ms",    date)
                    put("unread_count",    fetchUnreadCount(context, threadId))
                    put("subscription_id", SubscriptionManager.getDefaultSmsSubscriptionId())
                    put("carrier_name",    JSONObject.NULL) // SIM-naive v1; real carrier at Step 17
                })
            }

            JSONObject().apply {
                put("type",        "sms_thread_list")
                put("threads",     threads)
                put("total_count", totalCount)
                put("page",        page)
                put("page_size",   PAGE_SIZE)
            }.toString()
        } catch (e: Exception) {
            Log.e(TAG, "fetchThreadPage failed: ${e.message}")
            null
        }
    }

    /**
     * Returns sms_thread_messages JSON for a thread, or null on failure: the latest
     * MAX_MESSAGES, or with [beforeMs] the MAX_MESSAGES just older than it — a time
     * cursor rather than a page number, so a message arriving between requests can't
     * shift the window. `has_more` says whether anything older remains.
     */
    fun fetchMessages(context: Context, threadId: Long, beforeMs: Long? = null): String? {
        return try {
            val nameCache = HashMap<String, String?>()
            val messages  = JSONArray()
            var count     = 0
            var hasMore   = false

            val selection = "${Telephony.Sms.THREAD_ID} = ?" +
                if (beforeMs != null) " AND ${Telephony.Sms.DATE} < ?" else ""
            val args = listOfNotNull(threadId.toString(), beforeMs?.toString()).toTypedArray()
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
                        Telephony.Sms.DATE, Telephony.Sms.TYPE),
                selection,
                args,
                "${Telephony.Sms.DATE} DESC"
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (count++ >= MAX_MESSAGES) { hasMore = true; break }
                    val msgType = when (cursor.getInt(4)) {
                        Telephony.Sms.MESSAGE_TYPE_INBOX -> "inbox"
                        Telephony.Sms.MESSAGE_TYPE_SENT  -> "sent"
                        else                             -> "other"
                    }
                    val address = cursor.getString(1) ?: ""
                    val name    = if (msgType == "inbox")
                        nameCache.getOrPut(address) { resolveContactName(context, address) }
                    else null

                    messages.put(JSONObject().apply {
                        put("message_id",   cursor.getLong(0))
                        put("address",      address)
                        put("contact_name", name ?: JSONObject.NULL)
                        put("body",         cursor.getString(2) ?: "")
                        put("timestamp_ms", cursor.getLong(3))
                        put("type",         msgType)
                    })
                }
            }

            JSONObject().apply {
                put("type",      "sms_thread_messages")
                put("thread_id", threadId)
                put("messages",  messages)
                put("has_more",  hasMore)
                if (beforeMs != null) put("before_ms", beforeMs)
            }.toString()
        } catch (e: Exception) {
            Log.e(TAG, "fetchMessages failed: ${e.message}")
            null
        }
    }

    /** Returns sms_search_result JSON for the given query + page, or null on failure. */
    fun fetchSearchResults(context: Context, query: String, page: Int): String? {
        return try {
            // Escape SQLite LIKE wildcards in user input so literal % and _ are searched as-is.
            val escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            val likeArg = "%$escaped%"

            val totalCount = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID),
                "${Telephony.Sms.BODY} LIKE ? ESCAPE '\\'",
                arrayOf(likeArg),
                null
            )?.use { it.count } ?: 0

            val queryArgs = Bundle().apply {
                putInt(ContentResolver.QUERY_ARG_LIMIT, PAGE_SIZE)
                putInt(ContentResolver.QUERY_ARG_OFFSET, page * PAGE_SIZE)
                putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(Telephony.Sms.DATE))
                putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            }

            val results = JSONArray()
            val nameCache = HashMap<String, String?>()

            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
                Bundle().apply {
                    putAll(queryArgs)
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${Telephony.Sms.BODY} LIKE ? ESCAPE '\\'")
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(likeArg))
                },
                null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val msgType = when (cursor.getInt(5)) {
                        Telephony.Sms.MESSAGE_TYPE_INBOX -> "inbox"
                        Telephony.Sms.MESSAGE_TYPE_SENT  -> "sent"
                        else                             -> "other"
                    }
                    val address = cursor.getString(2) ?: ""
                    val name = if (msgType == "inbox")
                        nameCache.getOrPut(address) { resolveContactName(context, address) }
                    else null

                    results.put(JSONObject().apply {
                        put("message_id",   cursor.getLong(0))
                        put("thread_id",    cursor.getLong(1))
                        put("address",      address)
                        put("contact_name", name ?: JSONObject.NULL)
                        put("body",         cursor.getString(3) ?: "")
                        put("timestamp_ms", cursor.getLong(4))
                        put("type",         msgType)
                    })
                }
            }

            if (results.length() != PAGE_SIZE && (page + 1) * PAGE_SIZE < totalCount) {
                Log.w(TAG, "fetchSearchResults: Bundle queryArgs may not be honored — got ${results.length()} rows, expected $PAGE_SIZE (page=$page, totalCount=$totalCount)")
            }

            JSONObject().apply {
                put("type",        "sms_search_result")
                put("query",       query)
                put("results",     results)
                put("total_count", totalCount)
                put("page",        page)
                put("page_size",   PAGE_SIZE)
            }.toString()
        } catch (e: Exception) {
            Log.e(TAG, "fetchSearchResults failed: ${e.message}")
            null
        }
    }

    private fun fetchUnreadCount(context: Context, threadId: Long): Int =
        context.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID),
            "${Telephony.Sms.THREAD_ID} = ? AND read = 0",
            arrayOf(threadId.toString()),
            null
        )?.use { it.count } ?: 0

    /**
     * Sends an SMS and calls onResult with a sms_send_result JSON string.
     * Runs the send on the calling thread; the sentIntent callback fires asynchronously.
     */
    // Lint can't see it: every permission-gated call in here is inside try/catch.
    @android.annotation.SuppressLint("MissingPermission")
    fun sendSms(context: Context, toNumber: String, body: String, threadId: Long, scope: CoroutineScope, subscriptionId: Int = -1, onResult: (String) -> Unit) {
        val sentBeforeMs = System.currentTimeMillis()
        val action = "com.swiftgreen.SMS_SENT_${threadId}_${sentBeforeMs}"
        // One per SMS part; the request code keeps each part's PendingIntent distinct.
        fun sentIntent(part: Int) = PendingIntent.getBroadcast(
            context, part, Intent(action).setPackage(context.packageName),
            // Mutable so the platform's fill-in reaches us (it adds the Sent row's "uri");
            // an immutable PendingIntent drops fill-in extras. Safe: explicit to this app.
            PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_MUTABLE
        )

        val tally = SmsPartTally()
        var receiverRef: BroadcastReceiver? = null

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                Log.i(TAG, "sendSms: sentIntent rc=$resultCode after ${System.currentTimeMillis() - sentBeforeMs} ms")
                // An earlier part already failed, or parts are still pending.
                if (!tally.onPart(resultCode == Activity.RESULT_OK)) return
                try { context.unregisterReceiver(this) } catch (_: Exception) {}
                val rc = resultCode
                // The platform writes the Sent row just before this broadcast and hands its
                // URI over; more reliable than matching ADDRESS, which it may have reformatted.
                val rowId = intent.getStringExtra("uri")?.let { it.toUri().lastPathSegment?.toLongOrNull() }
                scope.launch(Dispatchers.IO) {
                    val success = rc == Activity.RESULT_OK
                    val failureReason: String? = if (!success) when (rc) {
                        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "generic_failure"
                        SmsManager.RESULT_ERROR_NO_SERVICE      -> "no_service"
                        SmsManager.RESULT_ERROR_NULL_PDU        -> "null_pdu"
                        SmsManager.RESULT_ERROR_RADIO_OFF       -> "radio_off"
                        else                                    -> "unknown_error_$rc"
                    } else null

                    val messageId: Long = if (success) rowId ?: run {
                        context.contentResolver.query(
                            Telephony.Sms.Sent.CONTENT_URI,
                            arrayOf(Telephony.Sms._ID),
                            "${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.DATE} >= ?",
                            arrayOf(toNumber, sentBeforeMs.toString()),
                            "${Telephony.Sms.DATE} DESC"
                        )?.use { if (it.moveToFirst()) it.getLong(0) else -1L } ?: -1L
                    } else -1L

                    if (success && messageId == -1L) {
                        Log.w(TAG, "sendSms: sent row not found for $toNumber after $sentBeforeMs, emitting message_id=-1")
                    }

                    val json = JSONObject().apply {
                        put("type",           "sms_send_result")
                        put("thread_id",      threadId)
                        put("message_id",     messageId)
                        put("success",        success)
                        put("failure_reason", failureReason ?: JSONObject.NULL)
                        put("timestamp_ms",   sentBeforeMs)
                    }.toString()
                    onResult(json)
                }
            }
        }
        receiverRef = receiver

        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)

        try {
            // Only a SIM that's in the phone now: an id with no SIM behind it (a stale pick on
            // the Mac, or an older Mac build's made-up 1) fails the send with
            // RESULT_USER_NOT_ALLOWED, so the default SIM is the better answer. If the check
            // itself isn't allowed (no READ_PHONE_STATE), the requested id is kept.
            val subs = context.getSystemService(SubscriptionManager::class.java)
            val useSub = subscriptionId >= 0 && (subs == null ||
                runCatching { subs.getActiveSubscriptionInfo(subscriptionId) != null }.getOrDefault(true))
            if (subscriptionId >= 0 && !useSub) Log.w(TAG, "sendSms: subscriptionId=$subscriptionId has no SIM — using the default SIM")
            @Suppress("DEPRECATION")
            val mgr = if (useSub)
                SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            else
                SmsManager.getDefault()
            Log.d(TAG, if (useSub) "sendSms: using subscriptionId=$subscriptionId" else "sendSms: using default SmsManager")
            val parts = mgr.divideMessage(body)
            if (parts.size <= 1) {
                @Suppress("DEPRECATION")
                mgr.sendTextMessage(toNumber, null, body, sentIntent(0), null)
            } else {
                // sendTextMessage carries one SMS only: the platform rejects a longer body
                // ("Message too long" in getSubmitPdu) and reports generic_failure. That is
                // anything over 160 GSM-7 characters, or 70 with an emoji or non-Latin script.
                tally.expect(parts.size)
                @Suppress("DEPRECATION")
                mgr.sendMultipartTextMessage(toNumber, null, parts,
                    ArrayList(parts.indices.map { sentIntent(it) }), null)
            }
        } catch (e: Exception) {
            if (tally.claim()) {
                try { context.unregisterReceiver(receiver) } catch (_: Exception) {}
            }
            Log.e(TAG, "sendSms: sendTextMessage threw: ${e.message}")
            onResult(JSONObject().apply {
                put("type",           "sms_send_result")
                put("thread_id",      threadId)
                put("message_id",     -1L)
                put("success",        false)
                put("failure_reason", "send_exception: ${e.message}")
                put("timestamp_ms",   sentBeforeMs)
            }.toString())
            return
        }

        // The outcome without the broadcast. For an app that isn't the default SMS
        // app, telephony writes the finished message to the provider itself (into
        // Telephony.Sms.Sent, then type 5 if it failed) just before it fires the
        // sentIntent. Watching for that row gives the real result when the broadcast
        // never arrives, and stops a slow send being reported as timed out while it is
        // still going out. Whichever answers first wins; SmsPartTally keeps it to one.
        scope.launch(Dispatchers.IO) {
            while (System.currentTimeMillis() - sentBeforeMs < SEND_TIMEOUT_MS) {
                delay(SEND_POLL_MS)
                if (tally.isFinal()) return@launch  // the sentIntent (or the send's own failure) answered
                val row = findSentRow(context, toNumber, body, sentBeforeMs) ?: continue
                if (!tally.claim()) return@launch
                try { context.unregisterReceiver(receiverRef) } catch (_: Exception) {}
                val sent = row.second == Telephony.Sms.MESSAGE_TYPE_SENT
                Log.w(TAG, "sendSms: sentIntent not received; provider reports ${if (sent) "sent" else "failed"}, row=${row.first}")
                onResult(JSONObject().apply {
                    put("type",           "sms_send_result")
                    put("thread_id",      threadId)
                    put("message_id",     if (sent) row.first else -1L)
                    put("success",        sent)
                    put("failure_reason", if (sent) JSONObject.NULL else "send_failed")
                    put("timestamp_ms",   sentBeforeMs)
                }.toString())
                return@launch
            }
            // Nothing from either source in time: a provisional answer by address and time
            // only (a carrier may rewrite the stored text). The receiver stays registered, and
            // a sentIntent that arrives later still reports the real outcome.
            if (tally.timeout()) {
                val lateId: Long = context.contentResolver.query(
                    Telephony.Sms.Sent.CONTENT_URI,
                    arrayOf(Telephony.Sms._ID),
                    "${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.DATE} >= ?",
                    arrayOf(toNumber, sentBeforeMs.toString()),
                    "${Telephony.Sms.DATE} DESC"
                )?.use { if (it.moveToFirst()) it.getLong(0) else -1L } ?: -1L

                if (lateId != -1L) {
                    Log.w(TAG, "sendSms: sentIntent never fired but Sent row found after timeout — treating as success, message_id=$lateId")
                    onResult(JSONObject().apply {
                        put("type",           "sms_send_result")
                        put("thread_id",      threadId)
                        put("message_id",     lateId)
                        put("success",        true)
                        put("failure_reason", JSONObject.NULL)
                        put("timestamp_ms",   sentBeforeMs)
                    }.toString())
                } else {
                    Log.w(TAG, "sendSms: timeout waiting for sentIntent for $toNumber")
                    onResult(JSONObject().apply {
                        put("type",           "sms_send_result")
                        put("thread_id",      threadId)
                        put("message_id",     -1L)
                        put("success",        false)
                        put("failure_reason", "timeout")
                        put("timestamp_ms",   sentBeforeMs)
                    }.toString())
                }
                // Give the radio 10 minutes in all before letting the receiver go.
                delay(10 * 60_000L - SEND_TIMEOUT_MS)
                if (tally.claim()) {
                    try { context.unregisterReceiver(receiverRef) } catch (_: Exception) {}
                    Log.w(TAG, "sendSms: no sentIntent within 10 min for thread $threadId — receiver released")
                }
            }
        }
    }

    /**
     * The provider's record of one of our sends: (row id, type) once telephony has written
     * it, else null. Matched on address, exact body and time, so two quick messages to the
     * same person can't be mistaken for each other; a carrier that rewrites the stored text
     * (forced 7-bit) simply never matches, and the send falls back to the timeout check.
     *
     * A failed send is inserted as sent and updated to failed a moment later (two provider
     * calls), so a row is only trusted once it is a second old; the next poll takes it.
     */
    private fun findSentRow(context: Context, toNumber: String, body: String, sentBeforeMs: Long): Pair<Long, Int>? =
        try {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.TYPE, Telephony.Sms.DATE),
                "${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.BODY} = ? AND ${Telephony.Sms.DATE} >= ? AND " +
                    "${Telephony.Sms.TYPE} IN (${Telephony.Sms.MESSAGE_TYPE_SENT}, ${Telephony.Sms.MESSAGE_TYPE_FAILED})",
                arrayOf(toNumber, body, sentBeforeMs.toString()),
                "${Telephony.Sms.DATE} DESC"
            )?.use {
                if (it.moveToFirst() && System.currentTimeMillis() - it.getLong(2) >= 1_000L)
                    it.getLong(0) to it.getInt(1)
                else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "sendSms: provider check failed: ${e.message}")
            null
        }

    private fun resolveContactName(context: Context, address: String): String? {
        if (address.isEmpty() || !phoneRegex.matches(address)) return null
        if (context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)
            )
            context.contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (e: Exception) {
            Log.e(TAG, "PhoneLookup failed", e); null
        }
    }
}
