package com.swiftgreen.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Step 15.3 — incoming cellular call control (answer / decline only).
 *
 * Detects call state via a context-registered PHONE_STATE broadcast (single path,
 * API 26-35), pushes call_state to the Mac, and executes answer/decline commands.
 *
 * Mute and call-waiting (a second incoming call during an active call) are explicitly
 * out of scope for v1 — an active call is unaffected, a waiting call is ignored.
 *
 * Threading: onReceive runs on the main thread (cheap state-machine work only); contact
 * lookup + socket writes hop to [scope]. Command handling runs on the caller's read-loop
 * thread. The two never touch the same mutable field, so no locks are needed.
 * // ponytail: single-reader-per-field, no synchronization. Add locks only if a second
 * //           caller ever drives handleCommand concurrently.
 */
class CallControlManager(
    private val context: Context,
    private val send: (String) -> Unit
) {
    private val telecom = context.getSystemService(TelecomManager::class.java)
    private val audio = context.getSystemService(android.media.AudioManager::class.java)
    private val telephony = context.getSystemService(TelephonyManager::class.java)
    // One thread: call_state messages leave in the order the states happened. On the
    // shared IO pool the numberless and numbered RINGING could overtake each other and
    // the Mac would end on the version without the caller's name.
    private val scope = CoroutineScope(
        java.util.concurrent.Executors.newSingleThreadExecutor().asCoroutineDispatcher() + SupervisorJob())
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    @Volatile private var registered = false

    // State-machine fields — touched only on the main thread (onReceive)
    private var prevState = TelephonyManager.CALL_STATE_IDLE
    private var incomingActive = false
    private var lastRingingNumber = ""
    // A numberless RINGING held back briefly: Android 10+ follows it with the numbered
    // one ~65 ms later, and sending both made the Mac replace its banner mid-delivery.
    private var bareRing: Runnable? = null
    // The listener is live: the broadcast only adds the number to a ring already under way.
    // Otherwise a broadcast landing after the listener moved on replays a finished state.
    private var listenerActive = false

    /// Number of the dial the Mac just asked for, so an outgoing call can be announced
    /// with a number attached. Written from the dial coroutine, read on the main thread.
    @Volatile private var pendingDialNumber = ""

    // Idempotency — touched only on the read-loop thread (handleCommand).
    // request_id → the exact result line already sent; a duplicate re-sends it verbatim.
    private val handledRequests = object : LinkedHashMap<String, String>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > 16
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
            val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
            // EXTRA_INCOMING_NUMBER is only populated on RINGING, and only because we
            // hold READ_CALL_LOG. Empty on some OEM/carrier combos — tolerated downstream.
            // Deprecated at API 29; the replacement needs the call-screening role, which this app doesn't hold.
            val number = intent.getStringExtra(@Suppress("DEPRECATION") TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""
            val newState = when (stateStr) {
                TelephonyManager.EXTRA_STATE_RINGING -> TelephonyManager.CALL_STATE_RINGING
                TelephonyManager.EXTRA_STATE_OFFHOOK -> TelephonyManager.CALL_STATE_OFFHOOK
                else -> TelephonyManager.CALL_STATE_IDLE
            }
            Log.d(TAG, "broadcast: state=$newState number=${if (number.isEmpty()) "none" else "present"} t=${android.os.SystemClock.elapsedRealtime()}")
            if (listenerActive && !(newState == TelephonyManager.CALL_STATE_RINGING &&
                    prevState == TelephonyManager.CALL_STATE_RINGING && number.isNotEmpty())) return
            onPhoneState(newState, number)
        }
    }

    // Same call states as the broadcast, but delivered straight from TelephonyRegistry
    // over binder instead of through the broadcast queue (which ran 1.1 s behind the ring
    // in one capture), and with the number (READ_CALL_LOG). Deprecated in favour of
    // TelephonyCallback, which carries no number. Whichever of the two lands first drives
    // onPhoneState; the same-state guard drops the other. Created on the main thread so
    // its callbacks arrive there, like onReceive's.
    @Suppress("DEPRECATION")
    private val stateListener by lazy {
        object : android.telephony.PhoneStateListener() {
            // Overrides a deprecated callback on purpose: TelephonyCallback, its replacement, carries no number (see above).
            @Deprecated("PhoneStateListener is deprecated; kept for the number it delivers")
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                Log.d(TAG, "listener: state=$state number=${if (phoneNumber.isNullOrEmpty()) "none" else "present"} t=${android.os.SystemClock.elapsedRealtime()}")
                onPhoneState(state, phoneNumber.orEmpty())
            }
        }
    }

    fun start() {
        if (registered) return
        // PHONE_STATE is exempt from the implicit-broadcast ban; context-registered so it
        // lives and dies with the tunnel connection (a call during a reconnect gap is missed).
        context.registerReceiver(receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED))
        registered = true
        mainHandler.post {
            @Suppress("DEPRECATION")
            runCatching { telephony?.listen(stateListener, android.telephony.PhoneStateListener.LISTEN_CALL_STATE) }
                .onSuccess { listenerActive = telephony != null }
                .onFailure { Log.w(TAG, "Call-state listener unavailable, broadcast only: ${it.message}") }
        }
        Log.d(TAG, "PHONE_STATE receiver registered")
    }

    fun stop() {
        if (!registered) return
        try { context.unregisterReceiver(receiver) } catch (e: Exception) {
            Log.e(TAG, "Error unregistering PHONE_STATE receiver", e)
        }
        registered = false
        @Suppress("DEPRECATION")
        mainHandler.post {
            listenerActive = false
            runCatching { telephony?.listen(stateListener, android.telephony.PhoneStateListener.LISTEN_NONE) }
        }
        bareRing?.let { mainHandler.removeCallbacks(it); bareRing = null }
        prevState = TelephonyManager.CALL_STATE_IDLE
        // incomingActive, lastRingingNumber and pendingDialNumber survive a tunnel drop:
        // resetting them turned an answered incoming call into "dialing Unknown" on the
        // Mac after a reconnect. pushCurrentState() clears them once the phone is idle.
        clearAudioOverrides()
        Log.d(TAG, "PHONE_STATE receiver unregistered")
    }

    // ── State machine (main thread) ───────────────────────────────────────────────
    private fun onPhoneState(newState: Int, number: String) {
        // Same-state callback = registration's initial IDLE or duplicate spam → skip.
        // This is the IDLE-from-IDLE guard that crashes naive implementations.
        // Android 10+ sends RINGING twice: first without the number, then (with
        // READ_CALL_LOG) with it. The second is the one that names the caller, so it
        // must not be dropped as a duplicate.
        if (newState == prevState && newState == TelephonyManager.CALL_STATE_RINGING &&
            number.isNotEmpty() && lastRingingNumber.isEmpty()) {
            lastRingingNumber = number
            bareRing?.let { mainHandler.removeCallbacks(it); bareRing = null }
            scope.launch { pushState("ringing", number, resolveContactName(number)) }
            return
        }
        if (newState == prevState) return
        prevState = newState
        // Any other transition supersedes a ring still waiting for its number.
        bareRing?.let { mainHandler.removeCallbacks(it); bareRing = null }

        when (newState) {
            TelephonyManager.CALL_STATE_RINGING -> {
                incomingActive = true
                lastRingingNumber = number
                if (number.isNotEmpty()) {
                    scope.launch { pushState("ringing", number, resolveContactName(number)) }
                } else {
                    // Wait up to 250 ms for the numbered RINGING; if none comes (a hidden
                    // number, or a VoIP call like WhatsApp), send the bare ring.
                    val ring = Runnable {
                        bareRing = null
                        scope.launch { pushState("ringing", "", null) }
                    }
                    bareRing = ring
                    mainHandler.postDelayed(ring, 250)
                    // A numberless ring is usually a VoIP call (WhatsApp). Its call
                    // notification lands a moment after the state, so look twice.
                    scope.launch {
                        for (wait in longArrayOf(300, 1_200)) {
                            kotlinx.coroutines.delay(wait)
                            SwiftGreenNotificationListener.scanActiveCalls()
                        }
                    }
                }
            }
            // Any offhook is a live call, whichever way it started. Deriving that from
            // the state itself rather than from flag bookkeeping matters: a missed IDLE
            // (receiver registered mid-call, or the tunnel dropped between RINGING and
            // IDLE) used to strand incomingActive=true, and from then on every outgoing
            // call reported nothing and the Mac never offered a hang-up button.
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                val incoming = incomingActive
                val n = if (incoming) lastRingingNumber else pendingDialNumber
                scope.launch {
                    pushState(if (incoming) "offhook" else "dialing", n, resolveContactName(n))
                    // Dialed on the phone: no number. The dialer's notification, posted a moment
                    // after OFFHOOK, names who it is to.
                    if (!incoming && n.isEmpty()) {
                        kotlinx.coroutines.delay(800)
                        SwiftGreenNotificationListener.dialerCallTitle(telecom?.defaultDialerPackage)
                            ?.let { pushState("dialing", "", it) }
                    }
                }
            }
            // IDLE — the call ended, whatever kind it was. Reached only after a
            // non-IDLE state, since the same-state guard above drops repeats.
            else -> {
                val n = if (incomingActive) lastRingingNumber else pendingDialNumber
                incomingActive = false
                pendingDialNumber = ""
                // Mute set through AudioManager is device-global and outlives the call.
                clearAudioOverrides()
                scope.launch { pushState("idle", n, null) }
            }
        }
    }

    /// Called just before an outgoing ACTION_CALL so the OFFHOOK that follows can be
    /// reported with the number attached.
    fun noteOutgoingDial(number: String) {
        pendingDialNumber = number
    }

    // getCallState() is deprecated at API 31 for getCallStateForSubscription(), which reports
    // only the default SIM. The device-wide state (a call on either SIM) has no other getter.
    @Suppress("DEPRECATION")
    private fun deviceCallState(): Int? = telephony?.callState

    /**
     * Answers the Mac's call_state_request with a snapshot of what the phone reports now.
     *
     * The broadcast receiver is still the live source; this exists because a single lost
     * edge — tunnel gap, receiver torn down mid-call — otherwise leaves the Mac's banner
     * wrong forever, with nothing that could ever correct it. Unlike [onPhoneState] this
     * always sends, even when nothing changed: a request with no reply is exactly the
     * stuck-banner case it is meant to fix.
     *
     * Hops to the main thread so it reads and writes the state-machine fields on the same
     * thread onReceive owns, keeping the no-locks invariant at the top of this class.
     */
    fun pushCurrentState() {
        mainHandler.post {
            // On denial this throws, and a fabricated "idle" would clear a banner for a
            // live call — so stay silent instead and let the Mac's own timeout handle it.
            val live = try {
                deviceCallState() ?: return@post
            } catch (e: Exception) {
                Log.e(TAG, "callState read failed — not answering call_state_request", e)
                return@post
            }

            // Realign the state machine. If an edge was missed, prevState is wrong and the
            // same-state guard in onPhoneState would swallow the next real transition too.
            prevState = live
            when (live) {
                TelephonyManager.CALL_STATE_RINGING -> incomingActive = true
                TelephonyManager.CALL_STATE_IDLE -> {
                    incomingActive = false
                    pendingDialNumber = ""
                }
            }

            val state = when (live) {
                TelephonyManager.CALL_STATE_RINGING -> "ringing"
                TelephonyManager.CALL_STATE_OFFHOOK -> if (incomingActive) "offhook" else "dialing"
                else -> "idle"
            }
            val number = when {
                state == "idle"  -> ""
                incomingActive   -> lastRingingNumber
                else             -> pendingDialNumber
            }
            scope.launch {
                pushState(state, number, resolveContactName(number))
                // The plain state has no name for a WhatsApp call; re-send that call too,
                // or a Mac that just (re)connected only knows "unknown caller".
                if (state != "idle") SwiftGreenNotificationListener.resendActiveCall()
            }
        }
    }

    private fun pushState(state: String, number: String, name: String?) {
        Log.d(TAG, "call_state -> $state (number=${if (number.isEmpty()) "none" else "present"})")
        val json = JSONObject().apply {
            put("type", "call_state")
            put("state", state)
            put("phone_number", number)
            put("contact_name", name ?: JSONObject.NULL)
        }
        send(json.toString())
    }

    private fun resolveContactName(number: String): String? {
        if (number.isEmpty()) return null
        if (context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS)
                != PackageManager.PERMISSION_GRANTED) return null
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number)
            )
            context.contentResolver.query(
                uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (e: Exception) {
            Log.e(TAG, "PhoneLookup failed", e); null
        }
    }

    // ── Command handling (read-loop thread) ───────────────────────────────────────
    fun handleCommand(json: JSONObject) {
        val requestId = json.optString("request_id")
        val action = json.optString("action")
        if (requestId.isEmpty()) {
            sendResult(requestId, action, false, "missing_request_id"); return
        }
        handledRequests[requestId]?.let { prior ->
            Log.d(TAG, "Duplicate request_id $requestId — re-sending prior result")
            send(prior); return
        }

        // Telephony actions need ANSWER_PHONE_CALLS; the audio ones need only
        // MODIFY_AUDIO_SETTINGS (install-time), so they must not share that gate.
        val telephonyDenied =
            context.checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) !=
                PackageManager.PERMISSION_GRANTED

        // VoIP calls hosted by Telecom (WhatsApp via Jetpack core-telecom) are
        // "self-managed": Telecom silently ignores acceptRingingCall/endCall for them.
        // If the call hasn't moved 1.5 s later, press the button on its call
        // notification instead — a tap on the phone, which works for any app.
        if (action == "answer" || action == "decline" || action == "hangup") {
            val before = runCatching { deviceCallState() }.getOrNull()
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                val now = runCatching { deviceCallState() }.getOrNull()
                // Self-managed calls may not show in the legacy call state at all, so
                // "unchanged" is the test, not "still ringing".
                if (now == before) {
                    val pressed = SwiftGreenNotificationListener.pressCallButton(if (action == "answer") "answer" else "hangup")
                    Log.d(TAG, "Telecom $action had no effect — pressed call notification: $pressed")
                }
            }, 1_500)
        }

        val (success, error) = when (action) {
            "answer" -> if (telephonyDenied) false to "permission_denied" else {
                try {
                    // Deprecated at API 29; the replacements need the default-dialer role.
                    if (telecom != null) { @Suppress("DEPRECATION") telecom.acceptRingingCall(); true to null }
                    else false to "call_failed"
                } catch (e: Exception) { Log.e(TAG, "acceptRingingCall failed", e); false to "call_failed" }
            }
            // One API for both: it ends a connected call and rejects a ringing one, so
            // this covers incoming and outgoing alike. Split only so the Mac's intent
            // is legible in the result echo.
            "decline", "hangup" -> if (telephonyDenied) false to "permission_denied" else {
                // endCall() is API 28 and minSdk is 26. NoSuchMethodError is an Error,
                // not an Exception, so the catch below would not stop it.
                if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) {
                    Log.w(TAG, "endCall needs API 28 (have ${android.os.Build.VERSION.SDK_INT})")
                    false to "unsupported_api_level"
                } else try {
                    // Deprecated at API 29; the replacements need the default-dialer role.
                    val result = @Suppress("DEPRECATION") (telecom?.endCall() == true)
                    if (result) true to null else false to "call_failed"
                } catch (e: Exception) { Log.e(TAG, "endCall failed", e); false to "call_failed" }
            }
            // Default false: a malformed request must never mute by accident.
            "mute" -> setMicMute(json.optBoolean("enabled", false))
            else -> false to "invalid_action"
        }
        sendResult(requestId, action, success, error, json.optBoolean("enabled", false))
    }

    /**
     * Mic mute via AudioManager — the only route available to an app that is neither the
     * default dialer nor a bound InCallService.
     *
     * The value is read straight back and only reported as success if it actually stuck:
     * a toggle that lies about muting your microphone is worse than one that admits it
     * failed. Note this is a *device-global* setting, not a call-scoped one, so
     * [clearAudioOverrides] must undo it when the call ends.
     *
     * There is no speaker equivalent: AudioManager's speakerphone setter is a no-op for
     * a call we don't own and perturbs the audio route on the way, which silenced live
     * calls. Speaker is therefore not offered at all.
     */
    private fun setMicMute(enabled: Boolean): Pair<Boolean, String?> {
        val am = audio ?: return false to "call_failed"
        return try {
            am.isMicrophoneMute = enabled
            if (am.isMicrophoneMute == enabled) true to null else {
                Log.w(TAG, "mute=$enabled not applied by the platform")
                false to "not_applied"
            }
        } catch (e: Exception) {
            Log.e(TAG, "mute failed", e); false to "call_failed"
        }
    }

    /**
     * Undoes anything we forced on the device's audio. AudioManager's mic mute is
     * global and survives the call, so leaving it set would mute the microphone for
     * every other app with nothing in SwiftGreen to reveal it.
     */
    private fun clearAudioOverrides() {
        try {
            audio?.let { if (it.isMicrophoneMute) it.isMicrophoneMute = false }
        } catch (e: Exception) {
            Log.w(TAG, "could not clear mic mute: ${e.message}")
        }
    }

    private fun sendResult(
        requestId: String, action: String, success: Boolean, error: String?,
        enabled: Boolean = true
    ) {
        val result = JSONObject().apply {
            put("type", "call_control_result")
            put("request_id", requestId)
            put("action", action)
            put("success", success)
            put("error", error ?: JSONObject.NULL)
            // Echoed so the Mac can settle its toggle on the value that was actually
            // requested, rather than assuming.
            if (action == "mute") put("enabled", enabled)
        }.toString()
        if (requestId.isNotEmpty()) handledRequests[requestId] = result
        send(result)
    }

    companion object { private const val TAG = "CallControlManager" }
}
