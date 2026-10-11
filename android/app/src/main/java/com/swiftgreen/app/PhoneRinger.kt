package com.swiftgreen.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import org.json.JSONObject

/**
 * "Find my phone": loud, looping alarm on the alarm stream (it sounds through
 * silent and vibrate mode), plus vibration. Stops when the Mac says so, when the
 * user presses the power button (screen turns on), or after [MAX_MS].
 */
object PhoneRinger {
    private const val TAG = "PhoneRinger"
    private const val MAX_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var savedAlarmVolume = -1
    private var screenReceiver: BroadcastReceiver? = null

    val isRinging: Boolean get() = player != null

    fun start(context: Context) { main.post { startInternal(context) } }

    private fun startInternal(context: Context) {
        val ctx = context.applicationContext
        stopInternal(ctx, notify = false)
        val am = ctx.getSystemService(AudioManager::class.java)
        try {
            savedAlarmVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
            am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (e: SecurityException) {
            Log.w(TAG, "Alarm volume not changeable: ${e.message}")   // DND policy; ring at current volume
        }
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = try {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(ctx, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Ring failed: ${e.message}")
            null
        }
        ctx.getSystemService(Vibrator::class.java)?.vibrate(
            VibrationEffect.createWaveform(longArrayOf(0, 800, 400), 0))

        // Found it: pressing power (screen on) silences it on the spot.
        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { stop(ctx) }
        }.also { ctx.registerReceiver(it, IntentFilter(Intent.ACTION_SCREEN_ON)) }

        main.postDelayed({ stop(ctx) }, MAX_MS)
        sendState(true)
    }

    fun stop(context: Context) { main.post { stopInternal(context.applicationContext, notify = true) } }

    private fun stopInternal(ctx: Context, notify: Boolean) {
        main.removeCallbacksAndMessages(null)
        val wasRinging = player != null
        player?.let { runCatching { it.stop(); it.release() } }
        player = null
        ctx.getSystemService(Vibrator::class.java)?.cancel()
        screenReceiver?.let { runCatching { ctx.unregisterReceiver(it) } }
        screenReceiver = null
        if (savedAlarmVolume >= 0) {
            runCatching {
                ctx.getSystemService(AudioManager::class.java)
                    .setStreamVolume(AudioManager.STREAM_ALARM, savedAlarmVolume, 0)
            }
            savedAlarmVolume = -1
        }
        if (notify && wasRinging) sendState(false)
    }

    /** Tells the Mac, so its button flips back when the phone stops on its own. */
    private fun sendState(ringing: Boolean) {
        TunnelManager.sendRawMessage(JSONObject().apply {
            put("type", "find_phone_state")
            put("ringing", ringing)
        }.toString())
    }
}
