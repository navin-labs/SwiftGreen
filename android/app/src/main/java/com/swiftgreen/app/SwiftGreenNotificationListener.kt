package com.swiftgreen.app

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.provider.ContactsContract
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import androidx.core.graphics.scale
import androidx.core.graphics.createBitmap

class SwiftGreenNotificationListener : NotificationListenerService() {
    private val TAG = "NotificationListener"

    companion object {
        // Package names that have well-known outgoing-message notification patterns
        private val WHATSAPP_PACKAGES = setOf(
            "com.whatsapp",
            "com.whatsapp.w4b"   // WhatsApp Business
        )

        private const val REPLY_ACTION_TTL_MS = 5 * 60 * 1000L  // 5 minutes
        private const val MAX_REPLY_ENTRIES = 200

        @Volatile
        private var connected: SwiftGreenNotificationListener? = null

        /**
         * Album art off the media notification posted by [pkg].
         *
         * Streaming players (Spotify above all) never put a bitmap in
         * MediaMetadata — they publish a remote ART_URI we can't fetch on a poll
         * path, while the decoded artwork sits right here on their notification.
         * This is the only reliable local source for them.
         */
        fun mediaNotificationArt(pkg: String): Bitmap? {
            if (pkg.isEmpty()) return null
            val svc = connected ?: return null
            return try {
                // Prefer the notification that carries the media session — an app can
                // have several (YouTube: uploads, downloads) and only this one has the art.
                val ofPkg = svc.activeNotifications?.filter { it.packageName == pkg }.orEmpty()
                (ofPkg.firstOrNull {
                    it.notification.extras.containsKey(android.app.Notification.EXTRA_MEDIA_SESSION)
                } ?: ofPkg.firstOrNull())
                    ?.let { sbn ->
                        val extras = sbn.notification.extras
                        // getLargeIcon() covers the legacy EXTRA_LARGE_ICON bitmap as well.
                        androidx.core.os.BundleCompat.getParcelable(extras, android.app.Notification.EXTRA_LARGE_ICON_BIG, Bitmap::class.java)
                            ?: sbn.notification.getLargeIcon()
                                ?.loadDrawable(svc)
                                ?.let { d ->
                                    val w = d.intrinsicWidth.coerceAtLeast(1)
                                    val h = d.intrinsicHeight.coerceAtLeast(1)
                                    val bmp = createBitmap(w, h)
                                    d.setBounds(0, 0, w, h)
                                    d.draw(android.graphics.Canvas(bmp))
                                    bmp
                                }
                    }
            } catch (_: Exception) {
                null
            }
        }

        data class ReplyActionEntry(
            val pendingIntent: PendingIntent,
            val remoteInputKey: String,
            val remoteInputs: Array<RemoteInput>?,  // original RemoteInputs from the action — needed for Gmail
            val buttonActions: Map<String, PendingIntent>,
            val insertedAt: Long
        )

        // Insertion-ordered LinkedHashMap bounded to MAX_REPLY_ENTRIES; evicts on overflow.
        private val replyActions: LinkedHashMap<String, ReplyActionEntry> =
            object : LinkedHashMap<String, ReplyActionEntry>(MAX_REPLY_ENTRIES, 0.75f, false) {
                override fun removeEldestEntry(
                    eldest: MutableMap.MutableEntry<String, ReplyActionEntry>?
                ): Boolean = size > MAX_REPLY_ENTRIES
            }

        fun lookupReplyAction(notificationKey: String): ReplyActionEntry? {
            synchronized(replyActions) {
                evictStale()
                return replyActions[notificationKey]
            }
        }

        /** The WhatsApp call notification currently mirrored to the Mac, and what we last said about it. */
        @Volatile private var appCallKey: String? = null
        @Volatile private var appCallSent: String? = null

        private val ANSWER_WORDS = listOf("answer", "accept")
        private val END_WORDS = listOf("decline", "reject", "hang up", "end", "leave")

        /**
         * Presses Answer, or Decline / Hang up, on the live WhatsApp call notification,
         * so a click on the Mac acts exactly like a tap on the phone. Titles are matched
         * in English first; other languages fall back to WhatsApp's fixed button order
         * (end first, answer last).
         */
        fun performAppCallAction(key: String, action: String): Boolean {
            val svc = connected ?: return false
            val sbn = svc.activeNotifications?.firstOrNull { it.key == key } ?: return false
            val actions = sbn.notification.actions?.filter { it.actionIntent != null }.orEmpty()
            if (actions.isEmpty()) return false
            val words = if (action == "answer") ANSWER_WORDS else END_WORDS
            val chosen = actions.firstOrNull { a -> words.any { a.title?.toString()?.lowercase()?.contains(it) == true } }
                ?: if (action == "answer") actions.last() else actions.first()
            sendWithOverlay(svc, chosen.actionIntent)
            return true
        }

        /**
         * Presses Answer or Decline/Hang up on whatever call notification is up — the
         * phone app's own (cellular, and VoIP calls it hosts, like WhatsApp on Google
         * Dialer) or a VoIP app's. That's a tap on the phone, so it works where
         * TelecomManager is refused ("self-managed" calls). Returns false if none matched.
         */
        /**
         * Reads the call notifications that are up right now. Called when the phone
         * starts ringing: the posted event for WhatsApp's ringing notification can be
         * missed, and the Mac needs it to show "WhatsApp call" and answer instantly.
         */
        /** Forget what was last sent, so the next scan repeats the live call in full. */
        fun resendActiveCall() {
            appCallSent = null
            scanActiveCalls()
        }

        /**
         * Who a call dialed on the phone itself is to. Android gives a dial started on the
         * phone no number, but the dialer's own ongoing-call notification names the contact.
         */
        fun dialerCallTitle(dialerPackage: String?): String? {
            val svc = connected ?: return null
            return svc.activeNotifications?.firstOrNull {
                it.packageName == dialerPackage && it.notification.category == android.app.Notification.CATEGORY_CALL
            }?.notification?.extras?.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString()?.takeIf { it.isNotBlank() }
        }

        fun scanActiveCalls() {
            val svc = connected ?: return
            svc.activeNotifications?.filter {
                it.notification.category == android.app.Notification.CATEGORY_CALL
            }?.forEach { sbn ->
                val text = sbn.notification.extras.getCharSequence(android.app.Notification.EXTRA_TEXT)?.toString().orEmpty()
                if (sbn.packageName in WHATSAPP_PACKAGES || text.contains("whatsapp", ignoreCase = true)) {
                    svc.handleWhatsAppCall(sbn)
                }
            }
        }

        fun pressCallButton(action: String): Boolean {
            val svc = connected ?: return false
            val words = if (action == "answer") ANSWER_WORDS else END_WORDS
            val calls = svc.activeNotifications?.filter {
                it.notification.category == android.app.Notification.CATEGORY_CALL
            }.orEmpty()
            for (sbn in calls) {
                val hit = sbn.notification.actions?.firstOrNull { a ->
                    a.actionIntent != null && words.any { a.title?.toString()?.lowercase()?.contains(it) == true }
                } ?: continue
                sendWithOverlay(svc, hit.actionIntent)
                Log.d("NotificationListener", "Pressed '${hit.title}' on ${sbn.packageName} call")
                return true
            }
            return false
        }

        /**
         * Answer opens the calling app's screen, and Android 15+ only lets a background
         * app do that while it has a *visible* "display over other apps" window. So:
         * show a 1-pixel transparent overlay, press the button, remove the overlay.
         * Without the permission the press still goes out (hang-up needs no screen).
         */
        private fun sendWithOverlay(svc: android.content.Context, pi: PendingIntent) {
            val main = android.os.Handler(android.os.Looper.getMainLooper())
            main.post {
                val wm = svc.getSystemService(android.view.WindowManager::class.java)
                val view = if (android.provider.Settings.canDrawOverlays(svc)) android.view.View(svc) else null
                if (view != null) runCatching {
                    wm.addView(view, android.view.WindowManager.LayoutParams(1, 1,
                        android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                        android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                            android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                        android.graphics.PixelFormat.TRANSLUCENT))
                }
                // Give the window a frame to become visible before the launch is judged.
                main.postDelayed({
                    runCatching { pi.send(svc, 0, null, null, null, null, backgroundStartOptions()) }
                        .onFailure { Log.w("NotificationListener", "Call button press failed", it) }
                    if (view != null) main.postDelayed({ runCatching { wm.removeView(view) } }, 1_000)
                }, if (view != null) 150 else 0)
            }
        }

        // Answer opens the call screen; allow that launch from here.
        private fun backgroundStartOptions(): android.os.Bundle? {
            val mode = when {
                android.os.Build.VERSION.SDK_INT >= 36 ->
                    android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                // API 34–35 only have ALLOWED; the platform documents ALLOW_ALWAYS (36+) as its replacement.
                android.os.Build.VERSION.SDK_INT >= 34 ->
                    @Suppress("DEPRECATION") android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                else -> return null
            }
            return android.app.ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(mode).toBundle()
        }

        fun evictReplyAction(notificationKey: String) {
            synchronized(replyActions) { replyActions.remove(notificationKey) }
        }

        // notification_key → the platform's StatusBarNotification.key
        // ("user|pkg|id|tag|uid"). The Mac's key embeds postTime, which changes when an
        // app cancels and reposts a conversation's notification (WhatsApp does, per new
        // message), so the exact-key lookup below misses. sbn.key has no postTime but
        // does carry the tag that tells one chat from another, so matching on it finds
        // the *same* conversation's current notification and never a different chat's.
        // Deliberately not cleared on removal: removal is exactly the repost case.
        private data class ReplyRef(val sbnKey: String, val packageName: String, val shortcutId: String?)

        private val stableKeys: LinkedHashMap<String, ReplyRef> =
            object : LinkedHashMap<String, ReplyRef>(MAX_REPLY_ENTRIES, 0.75f, false) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ReplyRef>?): Boolean =
                    size > MAX_REPLY_ENTRIES
            }

        fun rememberStableKey(notificationKey: String, sbn: StatusBarNotification) {
            synchronized(stableKeys) {
                stableKeys[notificationKey] = ReplyRef(sbn.key, sbn.packageName, sbn.notification.shortcutId)
            }
        }

        /**
         * WhatsApp only, and only after the exact and stable-key lookups miss: the same
         * chat found by its conversation shortcut, for a repost that also changed the
         * notification's id or tag. A conversation shortcut names exactly one chat (it is
         * what puts the notification in Android's Conversations section), so this cannot
         * reach another chat; group summaries and notifications without a reply action
         * are skipped.
         */
        private fun sameConversation(active: Array<StatusBarNotification>, ref: ReplyRef): StatusBarNotification? {
            val shortcut = ref.shortcutId ?: return null
            if (ref.packageName !in WHATSAPP_PACKAGES) return null
            return active.firstOrNull { candidate ->
                candidate.packageName == ref.packageName &&
                    candidate.notification.shortcutId == shortcut &&
                    (candidate.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY) == 0 &&
                    candidate.notification.actions?.any { !it.remoteInputs.isNullOrEmpty() } == true
            }
        }

        /**
         * Rebuild a reply action straight off a still-posted notification.
         *
         * [replyActions] is a 5-minute convenience cache; the PendingIntent stays valid
         * for as long as the notification is actually live. Falling back here means a
         * reply only fails when the notification is genuinely gone, instead of whenever
         * the cache happens to have expired. Matches, in order: the exact key, the
         * platform key the Mac echoed back ([sbnKey]), the in-memory repost map, then
         * (WhatsApp only) the same conversation shortcut.
         */
        fun resolveReplyActionLive(notificationKey: String, sbnKey: String? = null): ReplyActionEntry? {
            val svc = connected ?: return null
            return try {
                val active = svc.activeNotifications ?: return null
                val ref = synchronized(stableKeys) { stableKeys[notificationKey] }
                val sbn = active.firstOrNull {
                    "${it.packageName}|${it.id}|${it.postTime}" == notificationKey
                } ?: sbnKey?.takeIf { it.isNotEmpty() }?.let { k -> active.firstOrNull { it.key == k } }
                    ?.also { Log.d("NotificationListener", "Reply: matched by platform key for $notificationKey") }
                ?: ref?.let { r -> active.firstOrNull { it.key == r.sbnKey } }
                    ?.also { Log.d("NotificationListener", "Reply: matched reposted notification for $notificationKey") }
                ?: ref?.let { r -> sameConversation(active, r) }
                    ?.also { Log.d("NotificationListener", "Reply: matched conversation shortcut for $notificationKey") }
                ?: return null

                var replyIntent: PendingIntent? = null
                var resultKey: String? = null
                var inputs: Array<RemoteInput>? = null
                val buttons = mutableMapOf<String, PendingIntent>()

                // Same scan processNotification() does when it first caches the action.
                sbn.notification.actions?.forEach { action ->
                    val remoteInputs = action.remoteInputs
                    if (!remoteInputs.isNullOrEmpty()) {
                        if (replyIntent == null) {
                            replyIntent = action.actionIntent
                            resultKey = remoteInputs[0].resultKey
                            inputs = remoteInputs
                        }
                    } else if (action.actionIntent != null) {
                        val actionId = action.title?.toString()
                            ?.lowercase()?.replace(" ", "_") ?: return@forEach
                        buttons[actionId] = action.actionIntent
                    }
                }

                val pi = replyIntent ?: return null
                val rk = resultKey ?: return null
                ReplyActionEntry(
                    pendingIntent = pi,
                    remoteInputKey = rk,
                    remoteInputs = inputs,
                    buttonActions = buttons,
                    insertedAt = System.currentTimeMillis()
                )
            } catch (_: Exception) {
                null
            }
        }

        private fun storeReplyAction(key: String, entry: ReplyActionEntry) {
            synchronized(replyActions) {
                evictStale()
                replyActions[key] = entry
            }
        }

        private fun evictStale() {
            val now = System.currentTimeMillis()
            replyActions.entries.removeAll { now - it.value.insertedAt > REPLY_ACTION_TTL_MS }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        connected = this
        Log.d(TAG, "Notification listener connected successfully")
        scanActiveCalls()
        // Media sessions need this listener; granting access (or a rebind) retries now
        // instead of leaving controls dead until the service restarts.
        MediaSessionManager.instance?.rescanNow()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        connected = null
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        if (sbn.key == appCallKey) {
            appCallKey = null
            appCallSent = null
            sendAppCall("idle", "", sbn.key)
        }
        // The cached reply action is kept (5-minute TTL): a chat read on another device
        // cancels the notification, but its reply PendingIntent may still work, and a
        // stale one surfaces as CanceledException, which the reply path retries live.
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)

        // Retrieve immutable parameters on the binder thread
        val packageName = sbn.packageName
        val postTime = sbn.postTime
        val flags = sbn.notification.flags
        val category = sbn.notification.category
        if (category == android.app.Notification.CATEGORY_CALL) {
            Log.d(TAG, "[call] posted by $packageName ongoing=${sbn.isOngoing} actions=${sbn.notification.actions?.map { it.title }}")
        }

        // Post all remaining work to the high-priority HandlerThread
        val tunnelHandler = try { TunnelManager.handler } catch (e: Exception) {
            Log.e(TAG, "Could not access TunnelManager.handler — running on fallback thread", e)
            null
        }

        // Media notifications carry the freshest artwork for streaming players.
        if (sbn.notification.extras.containsKey(android.app.Notification.EXTRA_MEDIA_SESSION)) {
            MediaSessionManager.instance?.onMediaNotificationPosted(packageName)
        }

        val task = Runnable {
            processNotification(sbn)
        }

        if (tunnelHandler != null) {
            tunnelHandler.post(task)
        } else {
            // Fallback: run on a plain daemon thread so we never block the binder thread
            Thread(task).also { it.isDaemon = true; it.name = "SwiftGreen-Fallback"; it.start() }
        }
    }

    /**
     * Runs entirely on [TunnelManager.handler]'s HandlerThread.
     * Applies all filters, resolves app name, extracts icons/photos, serializes, and sends.
     */
    private fun processNotification(sbn: StatusBarNotification) {
        try {
            // ── Ongoing Filter ───────────────────────────────────────────────────
            // Exclude ongoing and non-clearable notifications: if (sbn.isOngoing || !sbn.isClearable) return
            // WhatsApp calls are ongoing notifications, so they're caught before that filter.
            if (sbn.notification.category == android.app.Notification.CATEGORY_CALL) {
                if (sbn.packageName in WHATSAPP_PACKAGES) { handleWhatsAppCall(sbn); return }
                // Google Dialer and others host WhatsApp's ringing screen themselves
                // (Jetpack core-telecom); their notification names the app in its text.
                val ex = sbn.notification.extras
                val text = listOf(android.app.Notification.EXTRA_TEXT, android.app.Notification.EXTRA_SUB_TEXT,
                    android.app.Notification.EXTRA_INFO_TEXT, android.app.Notification.EXTRA_BIG_TEXT)
                    .joinToString(" ") { ex.getCharSequence(it)?.toString().orEmpty() }
                Log.d(TAG, "[${sbn.packageName}] call notification (${text.length} chars) actions=${sbn.notification.actions?.map { it.title }}")
                if (text.contains("whatsapp", ignoreCase = true)) { handleWhatsAppCall(sbn); return }
                if (sbn.isOngoing) return
            }

            if (sbn.isOngoing || !sbn.isClearable) return

            val packageName = sbn.packageName
            val extras = sbn.notification.extras
            val isTestNotification = extras.getBoolean("com.swiftgreen.app.TEST_NOTIFICATION", false)

            // ── Block 1: Pure system UI ───────────────────────────────────────────
            if (packageName == "android" || packageName == "com.android.systemui") return

            // ── Block 2: Google Play Services ─────────────────────────────────────
            if (packageName == "com.google.android.gms") {
                Log.d(TAG, "[$packageName] Skipped — Google Play Services (internal)")
                return
            }

            // ── Block 3: SwiftGreen's own notifications ────────────────────────────
            if (packageName == this.packageName && !isTestNotification) return

            // ── Track seen package + per-app filter ──────────────────────────────
            AppFilterManager.trackSeenPackage(this, packageName, resolveAppName(packageName))
            if (AppFilterManager.isBlocked(this, packageName)) {
                Log.d(TAG, "[$packageName] Skipped — blocked by per-app filter")
                return
            }

            // ── Block 4: FLAG_FOREGROUND_SERVICE ──────────────────────────────────
            if (sbn.notification.flags and android.app.Notification.FLAG_FOREGROUND_SERVICE != 0) {
                Log.d(TAG, "[$packageName] Skipped — FLAG_FOREGROUND_SERVICE")
                return
            }

            // ── Block: Group summary notifications ───────────────────────────────
            if (sbn.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY != 0) {
                Log.d(TAG, "[$packageName] Skipped — FLAG_GROUP_SUMMARY")
                return
            }

            // ── Deep Text Extraction ─────────────────────────────────────────────
            // Extract standard title: check EXTRA_TITLE falling back to EXTRA_TITLE_BIG
            var title = extras.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString()
                ?: extras.getString(android.app.Notification.EXTRA_TITLE)
                ?: extras.getCharSequence(android.app.Notification.EXTRA_TITLE_BIG)?.toString()
                ?: extras.getString(android.app.Notification.EXTRA_TITLE_BIG)
                ?: ""

            // Extract body: Try to extract NotificationCompat.MessagingStyle from sbn.notification.
            val messagingStyle = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(sbn.notification)
            var body = ""
            var fromSelf = false
            if (messagingStyle != null && messagingStyle.messages.isNotEmpty()) {
                val lastMessage = messagingStyle.messages.last()
                // MessagingStyle marks the device user's own messages with no sender.
                fromSelf = lastMessage.person == null
                body = lastMessage.text?.toString() ?: ""
                val senderName = lastMessage.person?.name?.toString()
                if (!senderName.isNullOrEmpty()) {
                    title = if (messagingStyle.isGroupConversation == true && !title.isNullOrEmpty()) {
                        "$title: $senderName"
                    } else {
                        senderName
                    }
                }
            } else {
                val textLines = extras.getCharSequenceArray(android.app.Notification.EXTRA_TEXT_LINES)
                if (textLines != null && textLines.isNotEmpty()) {
                    body = textLines.joinToString("\n") { it.toString() }
                } else {
                    val bigText = (extras.getCharSequence(android.app.Notification.EXTRA_BIG_TEXT)
                        ?: extras.getString(android.app.Notification.EXTRA_BIG_TEXT))?.toString()?.trim() ?: ""
                    
                    val text = (extras.getCharSequence(android.app.Notification.EXTRA_TEXT)
                        ?: extras.getString(android.app.Notification.EXTRA_TEXT))?.toString()?.trim() ?: ""

                    val summaryText = (extras.getCharSequence(android.app.Notification.EXTRA_SUMMARY_TEXT)
                        ?: extras.getString(android.app.Notification.EXTRA_SUMMARY_TEXT))?.toString()?.trim() ?: ""

                    body = if (bigText.isNotEmpty()) {
                        bigText
                    } else if (text.isNotEmpty()) {
                        text
                    } else {
                        summaryText
                    }
                }
            }

            // ── Block 5: Empty content ────────────────────────────────────────────
            if (title.isEmpty() && body.isEmpty()) {
                Log.d(TAG, "[$packageName] Skipped — both title and body are empty")
                return
            }

            val category = sbn.notification.category
            Log.d(TAG, "[$packageName] Passed filters — category='$category'")

            // ── WhatsApp call detection ───────────────────────────────────────────
            if (packageName in WHATSAPP_PACKAGES && sbn.notification.category == "missed_call") {
                val hasCallBackAction = sbn.notification.actions?.any { it.title?.toString() == "Call back" } ?: false
                if (!hasCallBackAction) {
                    Log.d(TAG, "[$packageName] Skipped — missed_call summary with no actionable data")
                    return
                }
                Log.d(TAG, "[$packageName] WhatsApp call notification — sending to call_log_sync")
                sendWhatsAppCallRecord(title, sbn.postTime,
                    WhatsAppCallerNumber.resolve(applicationContext, sbn.notification, title))
                return
            }

            // ── WhatsApp outgoing heuristics ──────────────────────────────────────
            val senderType: String
            if (packageName in WHATSAPP_PACKAGES) {
                if (body.isBlank() || fromSelf) {
                    Log.d(TAG, "[$packageName] Skipped — outgoing WhatsApp")
                    return
                }
                senderType = "incoming"
            } else {
                senderType = "incoming"
            }

            // ── notification_key ──────────────────────────────────────────────────
            val notificationKey = "${sbn.packageName}|${sbn.id}|${sbn.postTime}"

            // ── Parse RemoteInput reply action + regular button actions ───────────
            var hasReplyAction = false
            var replyActionLabel: String? = null
            val actionButtons = JSONArray()
            var replyPendingIntent: PendingIntent? = null
            var remoteInputResultKey: String? = null
            var replyRemoteInputs: Array<RemoteInput>? = null
            val buttonPendingIntents = mutableMapOf<String, PendingIntent>()

            sbn.notification.actions?.forEach { action ->
                val remoteInputs = action.remoteInputs
                if (!remoteInputs.isNullOrEmpty() && !hasReplyAction) {
                    hasReplyAction = true
                    replyActionLabel = action.title?.toString()
                    replyPendingIntent = action.actionIntent
                    remoteInputResultKey = remoteInputs[0].resultKey
                    replyRemoteInputs = remoteInputs
                } else if (remoteInputs.isNullOrEmpty() && action.actionIntent != null) {
                    val actionId = action.title?.toString()
                        ?.lowercase()?.replace(" ", "_") ?: return@forEach
                    buttonPendingIntents[actionId] = action.actionIntent
                    actionButtons.put(JSONObject().apply {
                        put("label", action.title?.toString() ?: "")
                        put("action_id", actionId)
                    })
                }
            }

            if (hasReplyAction && replyPendingIntent != null && remoteInputResultKey != null) {
                rememberStableKey(notificationKey, sbn)
                storeReplyAction(
                    notificationKey,
                    ReplyActionEntry(
                        pendingIntent = replyPendingIntent,
                        remoteInputKey = remoteInputResultKey,
                        remoteInputs = replyRemoteInputs,
                        buttonActions = buttonPendingIntents,
                        insertedAt = System.currentTimeMillis()
                    )
                )
            }

            // ── Resolve app name ──────────────────────────────────────────────────
            var appName = packageName
            try {
                val pm = packageManager
                appName = pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
            } catch (e: Exception) {
                Log.w(TAG, "Could not resolve app name for $packageName")
            }

            // ── Universal Profile Picture Extractor ────────────────────────────────
            var avatarDrawable: Drawable? = null

            // Step A: For MessagingStyle, fetch the Person object of the last message (message.senderPerson).
            if (messagingStyle != null && messagingStyle.messages.isNotEmpty()) {
                val message = messagingStyle.messages.last()
                val icon = message.senderPerson?.icon
                if (icon != null) {
                    avatarDrawable = try {
                        icon.loadDrawable(this)
                    } catch (e: Exception) {
                        null
                    }
                }
            }

            // Step B: Fallback to Large Icon
            if (avatarDrawable == null) {
                avatarDrawable = try {
                    sbn.notification.getLargeIcon()?.loadDrawable(this)
                } catch (e: Exception) {
                    null
                }
            }

            // Step C: Fallback to Small Icon
            if (avatarDrawable == null) {
                avatarDrawable = try {
                    sbn.notification.smallIcon?.loadDrawable(this)
                } catch (e: Exception) {
                    null
                }
            }

            // Step D: Fallback to Package Application Icon
            if (avatarDrawable == null) {
                avatarDrawable = try {
                    packageManager.getApplicationIcon(packageName)
                } catch (e: Exception) {
                    null
                }
            }

            var senderPhotoBase64: String? = null
            if (avatarDrawable != null) {
                val avatarBitmap = try { drawableToBitmap(avatarDrawable) } catch (e: Exception) { null }
                senderPhotoBase64 = avatarBitmap?.let { bmp ->
                    try {
                        val stream = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
                    } catch (e: Exception) {
                        null
                    }
                }
            } else {
                senderPhotoBase64 = extractSenderPhotoBase64(title)
            }

            // Get Small App Icon for fallback / identifier
            var appIconDrawable: Drawable? = null
            appIconDrawable = try {
                sbn.notification.smallIcon?.loadDrawable(this)
            } catch (e: Exception) {
                null
            }
            if (appIconDrawable == null) {
                appIconDrawable = try {
                    packageManager.getApplicationIcon(packageName)
                } catch (e: Exception) {
                    null
                }
            }

            val finalAppIconBitmap = try { drawableToBitmap(appIconDrawable) } catch (e: Exception) { null }
            val appIconBase64 = finalAppIconBitmap?.let { bmp ->
                try {
                    val stream = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
                } catch (e: Exception) {
                    null
                }
            }

            // ── Serialize ─────────────────────────────────────────────────────────
            // Zero-Crash Guard: Wrap JSON serialization inside a try/catch block
            val json = try {
                org.json.JSONObject().apply {
                    put("appName", appName)
                    put("title", title)
                    put("body", body)
                    put("timestamp", sbn.postTime)
                    put("senderType", senderType)
                    put("notification_key", notificationKey)
                    // Echoed back with a reply: the platform key (no postTime, carries the
                    // chat's tag) still finds the conversation after WhatsApp reposts it,
                    // even across a listener rebind that empties stableKeys.
                    put("sbn_key", sbn.key)
                    put("has_reply_action", hasReplyAction)
                    if (replyActionLabel != null) put("reply_action_label", replyActionLabel)
                    if (actionButtons.length() > 0) put("action_buttons", actionButtons)
                    if (senderPhotoBase64 != null) put("senderPhoto", senderPhotoBase64)
                    if (appIconBase64 != null)    put("appIcon", appIconBase64)
                }.toString()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to serialize notification JSON for package $packageName", e)
                null
            }

            if (json != null) {
                Log.d(TAG, "Dispatching → appName=$appName senderType=$senderType")
                TunnelManager.sendMessage(json)
                NotificationHistoryManager.addRecord(
                    NotificationHistoryManager.NotificationRecord(
                        appName = appName,
                        title = title,
                        body = body,
                        timestampMs = sbn.postTime,
                        key = sbn.key,
                        appIcon = appIconBase64,
                        hasReplyAction = hasReplyAction
                    )
                )
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error in processNotification for ${sbn.packageName}", e)
        }
    }

    private fun resolveAppName(packageName: String): String {
        return try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    // ─── WhatsApp Live Calls ──────────────────────────────────────────────────────

    /** Ringing if the notification offers Answer, otherwise an active call. */
    private fun handleWhatsAppCall(sbn: StatusBarNotification) {
        val extras = sbn.notification.extras
        val name = (extras.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString() ?: "").trim()
        val titles = sbn.notification.actions?.mapNotNull { it.title?.toString()?.lowercase() }.orEmpty()
        // Ringing if a button says Answer; a call ringing in another language still has
        // two buttons, while an active call has only Hang up (and maybe Mute).
        val ringing = titles.any { t -> ANSWER_WORDS.any { t.contains(it) } } ||
            (titles.size == 2 && titles.none { t -> t.contains("mute") || t.contains("hang") })
        val state = if (ringing) "ringing" else "offhook"
        appCallKey = sbn.key
        // WhatsApp re-posts the call notification every second for its timer; only a
        // change of state goes to the Mac.
        val signature = "${sbn.key}|$state|$name"
        // Called from the listener's handler, the main thread and the ring scans at once:
        // an unlocked check-then-set let two identical sends through.
        val fresh = synchronized(Companion) { (signature != appCallSent).also { if (it) appCallSent = signature } }
        if (!fresh) return
        sendAppCall(state, name, sbn.key, callerPhotoBase64(sbn))
    }

    /** The caller's picture: CallStyle's person first, then the large icon. Small JPEG. */
    private fun callerPhotoBase64(sbn: StatusBarNotification): String? = try {
        // The typed getParcelable is API 33; on 12/12L it threw NoSuchMethodError, an Error
        // the catch below doesn't take, and the listener crashed on the first call notification.
        val extras = sbn.notification.extras
        val personIcon = when {
            android.os.Build.VERSION.SDK_INT >= 33 ->
                extras.getParcelable(android.app.Notification.EXTRA_CALL_PERSON, android.app.Person::class.java)?.icon
            android.os.Build.VERSION.SDK_INT >= 31 ->
                @Suppress("DEPRECATION") extras.getParcelable<android.app.Person>(android.app.Notification.EXTRA_CALL_PERSON)?.icon
            else -> null
        }
        val drawable = personIcon?.loadDrawable(this) ?: sbn.notification.getLargeIcon()?.loadDrawable(this)
        drawable?.let { d ->
            val bmp = (drawableToBitmap(d) ?: return@let null).scale(160, 160, true)
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }
    } catch (e: Exception) { null }

    private fun sendAppCall(state: String, name: String, key: String, photo: String? = null) {
        val payload = JSONObject().apply {
            put("type", "app_call")
            put("app", "WhatsApp")
            put("state", state)
            put("name", name)
            put("key", key)
            if (photo != null) put("photo", photo)
        }
        TunnelManager.sendRawMessage(payload.toString())
        Log.d(TAG, "WhatsApp call → Mac: $state '$name'")
    }

    // ─── WhatsApp Call Record Sender ──────────────────────────────────────────────

    private fun sendWhatsAppCallRecord(callerName: String, timestampMs: Long, phoneNumber: String) {
        try {
            val record = org.json.JSONObject().apply {
                // WhatsApp exposes no number field; see WhatsAppCallerNumber for where this
                // comes from. Empty when it can't be pinned to one number — the Mac then
                // shows the row without call-back, rather than dialling a guess.
                put("phone_number", phoneNumber)
                put("contact_name", if (callerName.isBlank()) JSONObject.NULL else callerName)
                put("call_type", "missed")
                put("timestamp", timestampMs)
                put("duration_seconds", 0)
                put("source", "whatsapp")
            }
            val payload = org.json.JSONObject().apply {
                put("type", "call_log_sync")
                put("calls", org.json.JSONArray().put(record))
            }
            TunnelManager.sendRawMessage(payload.toString())
            Log.d(TAG, "Sent WhatsApp call record: $callerName")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send WhatsApp call record: ${e.message}")
        }
    }

    // ─── Sender Contact Photo Extraction ─────────────────────────────────────────

    /**
     * Looks up [senderName] in the device's Contacts database using a 3-attempt approach,
     * then reads the contact's photo thumbnail, falling back to high-res display photo if needed.
     */
    private fun extractSenderPhotoBase64(senderName: String): String? {
        if (senderName.isBlank()) return null
        return try {
            val cr = contentResolver
            var contactId: Long? = null
            var methodSucceeded = ""

            // Attempt 1: Treat senderName as a phone number and query PhoneLookup
            try {
                val phoneUri = Uri.withAppendedPath(
                    ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                    Uri.encode(senderName)
                )
                val projection = arrayOf(ContactsContract.PhoneLookup._ID)
                cr.query(phoneUri, projection, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        contactId = cursor.getLong(cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup._ID))
                        methodSucceeded = "PhoneLookup"
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "PhoneLookup failed for '$senderName': ${e.message}")
            }

            // Attempt 2: Query ContactsContract.Contacts with DISPLAY_NAME_PRIMARY matching senderName
            if (contactId == null) {
                try {
                    val contactUri = ContactsContract.Contacts.CONTENT_URI
                    val projection = arrayOf(ContactsContract.Contacts._ID)
                    val selection = "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} = ?"
                    cr.query(contactUri, projection, selection, arrayOf(senderName), null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            contactId = cursor.getLong(cursor.getColumnIndexOrThrow(ContactsContract.Contacts._ID))
                            methodSucceeded = "DisplayNameLookup"
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "DisplayNameLookup failed for '$senderName': ${e.message}")
                }
            }

            // Attempt 3: If still no match and has an international prefix, strip it and retry PhoneLookup
            if (contactId == null && senderName.startsWith("+")) {
                val prefixRegex = Regex("^\\+\\d{1,4}\\s*")
                val localNumber = senderName.replaceFirst(prefixRegex, "")
                if (localNumber.isNotBlank()) {
                    try {
                        val phoneUri = Uri.withAppendedPath(
                            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                            Uri.encode(localNumber)
                        )
                        val projection = arrayOf(ContactsContract.PhoneLookup._ID)
                        cr.query(phoneUri, projection, null, null, null)?.use { cursor ->
                            if (cursor.moveToFirst()) {
                                contactId = cursor.getLong(cursor.getColumnIndexOrThrow(ContactsContract.PhoneLookup._ID))
                                methodSucceeded = "PhoneLookupStripped"
                            }
                        }
                    } catch (e: Exception) {
                        Log.d(TAG, "PhoneLookupStripped failed for '$localNumber': ${e.message}")
                    }
                }
            }

            if (contactId == null) {
                Log.d(TAG, "No contact found for display name / phone: '$senderName'")
                return null
            }

            Log.d(TAG, "Contact lookup succeeded using method: $methodSucceeded (contactId=$contactId)")

            val contactUriWithId = Uri.withAppendedPath(
                ContactsContract.Contacts.CONTENT_URI,
                contactId.toString()
            )

            // Step 2: Open the contact photo stream
            // First attempt: thumbnail
            var photoStream = ContactsContract.Contacts.openContactPhotoInputStream(cr, contactUriWithId, false)
            // Second attempt: high-res display photo
            if (photoStream == null) {
                photoStream = openDisplayPhotoInputStream(cr, contactUriWithId)
            }

            if (photoStream == null) {
                Log.d(TAG, "Contact '$senderName' (id=$contactId) has no photo")
                return null
            }

            // Step 3: Decode, scale, compress, encode
            val rawBitmap = BitmapFactory.decodeStream(photoStream)
            photoStream.close()

            if (rawBitmap == null) {
                Log.w(TAG, "Failed to decode contact photo bitmap for '$senderName'")
                return null
            }

            val scaled = rawBitmap.scale(96, 96, true)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            val result = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            Log.d(TAG, "Contact photo encoded for '$senderName': ${result.length} base64 chars")
            result
        } catch (e: Exception) {
            Log.w(TAG, "extractSenderPhotoBase64 failed for '$senderName': ${e.message}")
            null
        }
    }

    /**
     * Custom helper that queries high-res Photo.DISPLAY_PHOTO asset file descriptor.
     */
    private fun openDisplayPhotoInputStream(cr: android.content.ContentResolver, contactUri: Uri): java.io.InputStream? {
        val displayPhotoUri = Uri.withAppendedPath(contactUri, ContactsContract.Contacts.Photo.DISPLAY_PHOTO)
        return try {
            val fd = cr.openAssetFileDescriptor(displayPhotoUri, "r")
            fd?.createInputStream()
        } catch (e: Exception) {
            null
        }
    }

    // ─── App Icon Extraction ──────────────────────────────────────────────────────

    /**
     * Extracts the launcher icon for [packageName] as a 256×256 Base64 PNG string.
     * Returns null if the icon cannot be obtained for any reason.
     */
    private fun extractAppIconBase64(packageName: String): String? {
        return try {
            val pm = packageManager
            val drawable: Drawable = pm.getApplicationIcon(packageName)
            val bitmap: Bitmap = drawableToBitmap(drawable) ?: return null
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.w(TAG, "extractAppIconBase64 failed for $packageName: ${e.message}")
            null
        }
    }

    /**
     * Renders any [Drawable] onto a 256×256 ARGB_8888 Bitmap, handling Vector and Adaptive icons safely.
     */
    private fun drawableToBitmap(drawable: Drawable?): Bitmap? {
        if (drawable == null) return null
        return try {
            if (drawable is BitmapDrawable && drawable.bitmap != null) {
                val bmp = drawable.bitmap
                if (bmp.width == 256 && bmp.height == 256) {
                    return bmp
                }
                return bmp.scale(256, 256, true)
            }
            val bitmap = createBitmap(256, 256)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, 256, 256)
            drawable.draw(canvas)
            bitmap
        } catch (e: Exception) {
            Log.e(TAG, "drawableToBitmap failed", e)
            null
        }
    }
}

// Extension to safely support message.senderPerson syntax with null safety checks
private val NotificationCompat.MessagingStyle.Message.senderPerson: androidx.core.app.Person?
    get() = this.person
