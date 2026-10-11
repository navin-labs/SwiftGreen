package com.swiftgreen.app

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Handler
import android.util.Base64
import org.json.JSONObject
import androidx.core.graphics.drawable.toBitmap
import java.io.ByteArrayOutputStream
import androidx.core.net.toUri
import androidx.core.graphics.scale

class MediaSessionManager {
    // The static [instance] must not keep a Context alive, so this reads the process-wide one.
    private val context: Context get() = SwiftGreenApplication.instance

    private val TAG = "MediaSessionMgr"
    private val handler = TunnelManager.handler

    private var sessionManager: android.media.session.MediaSessionManager? = null
    private var activeController: MediaController? = null
    private var isPolling = false
    private var lastArtSignature: String? = null
    /** Hash of the last art actually sent, so a forced re-check never re-sends identical bytes. */
    private var lastSentArtHash: Int? = null

    /**
     * Network artwork keyed by URL or lookup query; a null value is a cached miss.
     * Several entries because one track can try both a URL and a lookup, and a
     * single slot made them evict each other and refetch forever.
     */
    private val webArt = object : LinkedHashMap<String, Bitmap?>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap?>) = size > 6
    }
    private var webArtInFlight: String? = null
    private val webArtExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    private val listenerComponent = ComponentName(context, SwiftGreenNotificationListener::class.java)

    private val sessionListener = android.media.session.MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        handler.post { onSessionsChanged(controllers ?: emptyList()) }
    }

    private val metadataCallback = object : MediaController.Callback() {
        override fun onSessionDestroyed() {
            handler.post { rescanSessions() }
        }
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            handler.post { sendMediaState() }
        }
        override fun onPlaybackStateChanged(state: PlaybackState?) {
            handler.post {
                sendMediaState()
                updatePolling(state?.state == PlaybackState.STATE_PLAYING)
            }
        }
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (isPolling) {
                sendMediaState()
                handler.postDelayed(this, 2000)
            }
        }
    }

    /**
     * Some phones never fire OnActiveSessionsChanged when a second, already-listed
     * player starts playing (paused Spotify, then YouTube): the list is unchanged,
     * only the order. Re-pick on a slow tick so we follow whatever is playing.
     */
    private val rescanRunnable = object : Runnable {
        override fun run() {
            rescanSessions()
            handler.postDelayed(this, 3000)
        }
    }

    private var running = false
    private var listenerAdded = false
    private var rescanFailing = false

    /**
     * Also the recovery path: sessions can only be read once notification access is
     * granted, and a fresh install starts sync before that. Each tick retries the
     * listener registration, so controls come alive without restarting the service.
     */
    private fun rescanSessions() {
        if (!running) return
        try {
            val mgr = sessionManager
                ?: (context.getSystemService(Context.MEDIA_SESSION_SERVICE) as android.media.session.MediaSessionManager)
                    .also { sessionManager = it }
            if (!listenerAdded) {
                mgr.addOnActiveSessionsChangedListener(sessionListener, listenerComponent, handler)
                listenerAdded = true
            }
            val sessions = mgr.getActiveSessions(listenerComponent)
            if (rescanFailing) Log.d(TAG, "Media sessions readable again — ${sessions.size} active")
            rescanFailing = false
            onSessionsChanged(sessions)
        } catch (e: Exception) {
            // Once per failing stretch, not every 3 s.
            if (!rescanFailing) Log.w(TAG, "getActiveSessions failed: ${e.javaClass.simpleName} ${e.message}")
            rescanFailing = true
        }
    }

    fun start() {
        handler.post {
            running = true
            rescanSessions()
            // Armed whatever happened above, so a first failure is retried.
            handler.removeCallbacks(rescanRunnable)
            handler.postDelayed(rescanRunnable, 3000)
            Log.d(TAG, "Started")
        }
    }

    /** Notification access just (re)connected: pick up sessions now, not at the next tick. */
    fun rescanNow() {
        handler.post { rescanSessions() }
    }

    fun stop() {
        handler.post {
            running = false
            isPolling = false
            handler.removeCallbacks(pollRunnable)
            handler.removeCallbacks(rescanRunnable)
            activeController?.unregisterCallback(metadataCallback)
            activeController = null
            try {
                sessionManager?.removeOnActiveSessionsChangedListener(sessionListener)
            } catch (e: Exception) {
                Log.w(TAG, "Error removing session listener: ${e.localizedMessage}")
            }
            sessionManager = null
            listenerAdded = false
            Log.d(TAG, "Stopped")
        }
    }

    /**
     * Full state, artwork included, for a fresh connection. The art latch outlives
     * connections (this object lives in the service), so without this a Mac that
     * restarted or reconnected showed the track with no art until the next song.
     */
    fun resendOnConnect() {
        handler.post {
            lastArtSignature = null
            lastSentArtHash = null
            // Nothing playing still gets said, or the Mac keeps its cached last track.
            if (activeController != null) sendMediaState() else sendNoMedia()
        }
    }

    /**
     * A player posted or updated its media notification. Streaming apps (Spotify)
     * often change the notification *after* the track metadata, so art read at the
     * metadata change can belong to the previous song. Re-check now; the hash in
     * sendMediaState keeps unchanged art off the wire.
     */
    fun onMediaNotificationPosted(pkg: String) {
        handler.post {
            if (activeController?.packageName != pkg) return@post
            lastArtSignature = null
            sendMediaState()
        }
    }

    fun handleMediaAction(json: JSONObject) {
        handler.post {
            // Nothing attached yet (sessions changed between ticks): look once more first.
            val controller = activeController ?: run { rescanSessions(); activeController }
            if (controller == null) {
                // No player holds an active session: paused long enough for the OS to drop
                // it, or killed in the background (Moto and MIUI do this aggressively). A
                // media key through AudioManager still reaches the last player that played,
                // as a headset button would, so play/pause, next and previous keep working.
                val code = when (json.optString("action", "")) {
                    "play_pause" -> android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                    "next" -> android.view.KeyEvent.KEYCODE_MEDIA_NEXT
                    "previous" -> android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS
                    else -> null
                }
                if (code == null) {
                    Log.w(TAG, "No active media controller for action")
                    return@post
                }
                val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, code))
                am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, code))
                Log.d(TAG, "No active media session — sent media key $code to the last player")
                return@post
            }
            val action = json.optString("action", "")
            val controls = controller.transportControls
            val actions = controller.playbackState?.actions ?: 0L
            Log.d(TAG, "action=$action pkg=${controller.packageName} state=${controller.playbackState?.state} actions=0x${actions.toString(16)}")
            fun supports(flag: Long) = (actions and flag != 0L).also { if (it) Log.d(TAG, "route=transport") }
            // A player that doesn't declare an action usually still honours the
            // hardware media key for it (YouTube declares no "previous").
            fun mediaKey(code: Int) {
                Log.d(TAG, "route=mediaKey $code")
                controller.dispatchMediaButtonEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, code))
                controller.dispatchMediaButtonEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, code))
            }
            when (action) {
                "play_pause" -> {
                    val state = controller.playbackState?.state
                    val playing = state == PlaybackState.STATE_PLAYING || state == PlaybackState.STATE_BUFFERING
                    when {
                        playing && supports(PlaybackState.ACTION_PAUSE) -> controls.pause()
                        !playing && supports(PlaybackState.ACTION_PLAY) -> controls.play()
                        else -> mediaKey(android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                    }
                }
                "next" ->
                    if (supports(PlaybackState.ACTION_SKIP_TO_NEXT)) controls.skipToNext()
                    else mediaKey(android.view.KeyEvent.KEYCODE_MEDIA_NEXT)
                "previous" ->
                    if (supports(PlaybackState.ACTION_SKIP_TO_PREVIOUS)) controls.skipToPrevious()
                    else mediaKey(android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                "seek" -> {
                    val pos = json.optLong("position_ms", -1L)
                    if (pos >= 0) controls.seekTo(pos)
                }
                "play_queue_item" -> {
                    val queueId = json.optLong("queue_id", -1L)
                    if (queueId >= 0) controls.skipToQueueItem(queueId)
                }
                "volume_set" -> {
                    val vol = json.optInt("volume", -1)
                    if (vol >= 0) {
                        val info = controller.playbackInfo
                        if (info.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE) {
                            // Casting: the Chromecast/TV volume, not the phone speaker's.
                            controller.setVolumeTo((vol * info.maxVolume / 100).coerceIn(0, info.maxVolume), 0)
                        } else {
                            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            val scaled = (vol * maxVol / 100).coerceIn(0, maxVol)
                            try { am.setStreamVolume(AudioManager.STREAM_MUSIC, scaled, 0) }
                            catch (e: SecurityException) { Log.w(TAG, "Volume change refused: ${e.message}") }
                        }
                    }
                }
            }
        }
    }

    private fun onSessionsChanged(controllers: List<MediaController>) {
        // Playing beats paused; among paused, stay on the current one so two idle
        // players don't flip-flop. Sessions with nothing to show (the telecom
        // session, a player that stopped) are skipped entirely.
        val usable = controllers.filter { trackTitle(it).isNotEmpty() }
        val newController = usable.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: usable.firstOrNull { it.sessionToken == activeController?.sessionToken }
            ?: usable.firstOrNull()
        if (newController?.sessionToken == activeController?.sessionToken) return

        activeController?.unregisterCallback(metadataCallback)
        activeController = newController
        if (newController != null) {
            newController.registerCallback(metadataCallback, handler)
            Log.d(TAG, "Attached to session: ${newController.packageName}")
            val playing = newController.playbackState?.state == PlaybackState.STATE_PLAYING
            updatePolling(playing)
            sendMediaState()
        } else {
            updatePolling(false)
            sendNoMedia()
        }
    }

    private fun updatePolling(shouldPoll: Boolean) {
        if (shouldPoll && !isPolling) {
            isPolling = true
            handler.postDelayed(pollRunnable, 2000)
        } else if (!shouldPoll && isPolling) {
            isPolling = false
            handler.removeCallbacks(pollRunnable)
        }
    }

    private fun sendMediaState() {
        val controller = activeController ?: return
        val metadata = controller.metadata
        val playbackState = controller.playbackState

        val info = controller.playbackInfo
        val (currentVol, maxVol) = if (info.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE)
            info.currentVolume to info.maxVolume
        else (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).let {
            it.getStreamVolume(AudioManager.STREAM_MUSIC) to it.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        }
        val volumePct = if (maxVol > 0) (currentVol * 100 / maxVol) else 0
        val title = trackTitle(controller)

        var appName = controller.packageName ?: ""
        try {
            val pm = context.packageManager
            appName = pm.getApplicationLabel(pm.getApplicationInfo(controller.packageName, 0)).toString()
        } catch (_: Exception) {}

        // Artwork changes only on track change, but this runs every 2s. Encode it
        // only when the track actually changed and omit the field otherwise —
        // the Mac keeps the art it already has when the key is absent.
        val artSignature = "${controller.packageName}|" +
            "$title|" +
            "${metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM)}"
        var artBase64: String? = null
        val artChanged = artSignature != lastArtSignature
        if (artChanged) {
            val art = resolveAlbumArt(controller)
            if (art != null) {
                try {
                    artBase64 = encodeArt(art)
                } catch (e: Exception) {
                    Log.w(TAG, "Album art encode failed for ${controller.packageName}: ${e.message}")
                }
            }
            // Only latch once art was actually found, so a player that publishes
            // metadata before its notification still gets picked up on a later poll.
            if (artBase64 != null) lastArtSignature = artSignature
        }
        // Forced re-checks (new connection excepted — it resets the hash) often find
        // the same image; omit the key so the Mac keeps what it has.
        // Nothing found for this track → tell the Mac "no art" so the last song's
        // art doesn't linger.
        val artExplicitlyNone = artChanged && artBase64 == null
        if (artExplicitlyNone) lastSentArtHash = null
        if (artBase64 != null && artBase64.hashCode() == lastSentArtHash) artBase64 = null
        else if (artBase64 != null) lastSentArtHash = artBase64.hashCode()

        val json = JSONObject().apply {
            put("type", "media_state")
            put("app_name", appName)
            put("package_name", controller.packageName ?: "")
            put("track_title", title)
            put("artist", listOf(
                metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
                metadata?.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE),
                metadata?.description?.subtitle?.toString()
            ).firstOrNull { !it.isNullOrBlank() } ?: "")
            put("album", metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: "")
            put("is_playing", playbackState?.state == PlaybackState.STATE_PLAYING)
            val duration = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
            put("duration_ms", duration.coerceAtLeast(0L))   // 0 = live / unknown
            put("position_ms", currentPosition(playbackState, duration))
            put("playback_speed", playbackState?.playbackSpeed?.takeIf { it > 0f }?.toDouble() ?: 1.0)
            put("can_seek", (playbackState?.actions ?: 0L) and PlaybackState.ACTION_SEEK_TO != 0L)
            put("volume", volumePct)
            put("max_volume", 100)
            // Absent key = "unchanged, keep yours". Explicit null = "no art".
            if (artBase64 != null) put("album_art_base64", artBase64)
            else if (artExplicitlyNone) put("album_art_base64", JSONObject.NULL)

            // Up-next queue. Many players expose none (getQueue returns null),
            // in which case the Mac simply hides the queue section.
            val queueArray = org.json.JSONArray()
            controller.queue?.take(25)?.forEach { item ->
                val desc = item.description
                queueArray.put(JSONObject().apply {
                    put("queue_id", item.queueId)
                    put("title", desc?.title?.toString() ?: "")
                    put("subtitle", desc?.subtitle?.toString() ?: "")
                })
            }
            put("queue", queueArray)
        }

        TunnelManager.sendRawMessage(json.toString())
    }

    /** Players disagree on where the title lives; take the first one set. */
    private fun trackTitle(c: MediaController): String {
        val md = c.metadata ?: return ""
        return listOf(
            md.getString(MediaMetadata.METADATA_KEY_TITLE),
            md.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE),
            md.description.title?.toString()
        ).firstOrNull { !it.isNullOrBlank() } ?: ""
    }

    /**
     * `position` is a snapshot from the player's last update, which can be many
     * seconds old (YouTube updates only on state changes). Advance it by the time
     * since, at the current speed — what the framework's own UI does.
     */
    private fun currentPosition(state: PlaybackState?, durationMs: Long): Long {
        state ?: return 0L
        var pos = state.position
        if (state.state == PlaybackState.STATE_PLAYING && state.lastPositionUpdateTime > 0) {
            val elapsed = android.os.SystemClock.elapsedRealtime() - state.lastPositionUpdateTime
            pos += (elapsed * state.playbackSpeed).toLong()
        }
        return if (durationMs > 0) pos.coerceIn(0L, durationMs) else pos.coerceAtLeast(0L)
    }

    /**
     * Album art, trying every local source in order of fidelity. Players differ
     * wildly here: local players fill the bitmap keys, others only set a
     * description icon, and Spotify sets neither — hence the notification
     * fallback at the end.
     */
    private fun resolveAlbumArt(controller: MediaController): Bitmap? {
        val md = controller.metadata
        md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)?.let { return it }
        md?.getBitmap(MediaMetadata.METADATA_KEY_ART)?.let { return it }
        md?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)?.let { return it }
        md?.description?.iconBitmap?.let { return it }

        val uris = listOfNotNull(
            md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI),
            md?.getString(MediaMetadata.METADATA_KEY_ART_URI),
            md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI),
            md?.description?.iconUri?.toString()
        )
        uris.forEach { uri -> loadLocalBitmap(uri)?.let { return it } }

        // https artwork (YouTube Music, most streaming apps publish only this).
        // Never fetched on this poll path: served from cache, or fetched in the
        // background and re-sent when it lands.
        val webUri = uris.firstOrNull { it.startsWith("https://") || it.startsWith("http://") }
        if (webUri != null) cachedOrFetch(webUri) { downloadBitmap(webUri) }?.let { return it }

        // Possibly one track stale — onMediaNotificationPosted and the web fetch both
        // correct it when better art arrives.
        SwiftGreenNotificationListener.mediaNotificationArt(controller.packageName ?: "")?.let { return it }

        // YouTube publishes no artwork at all, and its notification may be muted:
        // look the track up by name.
        val query = artLookupQuery(
            trackTitle(controller),
            md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
        )
        if (query != null) cachedOrFetch("lookup:$query") { lookupArt(query) }?.let { return it }

        // Always show something: the player's own icon until (or unless) a lookup hits.
        return try {
            context.packageManager.getApplicationIcon(controller.packageName ?: "").toBitmap(256, 256)
        } catch (_: Exception) { null }
    }

    private fun cachedOrFetch(key: String, fetch: () -> Bitmap?): Bitmap? {
        if (webArt.containsKey(key)) return webArt[key]
        if (webArtInFlight == key) return null
        webArtInFlight = key
        webArtExecutor.execute {
            val bmp = try { fetch() } catch (e: Exception) {
                Log.w(TAG, "Album art fetch failed: ${e.message}")
                null
            }
            handler.post {
                webArtInFlight = null
                webArt[key] = bmp
                if (bmp == null) return@post
                lastArtSignature = null      // re-resolve now that the real art is here
                sendMediaState()
            }
        }
        return null
    }

    private fun downloadBitmap(url: String): Bitmap? =
        (java.net.URL(url).openConnection() as java.net.HttpURLConnection).run {
            connectTimeout = 4000
            readTimeout = 4000
            try { inputStream.use { android.graphics.BitmapFactory.decodeStream(it) } }
            finally { disconnect() }
        }

    /** iTunes Search (no key). Only a hit whose track name appears in the query counts. */
    private fun lookupArt(query: String): Bitmap? {
        val url = "https://itunes.apple.com/search?media=music&entity=song&limit=5&term=" +
            java.net.URLEncoder.encode(query, "UTF-8")
        val body = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).run {
            connectTimeout = 4000
            readTimeout = 4000
            try { inputStream.bufferedReader().use { it.readText() } } finally { disconnect() }
        }
        val results = JSONObject(body).optJSONArray("results") ?: return null
        val q = artMatchKey(query)
        for (i in 0 until results.length()) {
            val r = results.getJSONObject(i)
            val name = artMatchKey(r.optString("trackName"))
            val art = r.optString("artworkUrl100")
            if (name.length >= 3 && q.contains(name) && art.isNotEmpty())
                return downloadBitmap(art.replace("100x100bb", "600x600bb"))
        }
        return null
    }

    /**
     * JPEG q85, long edge 512 so the Mac's 300pt hero stays sharp on Retina.
     * Aspect is kept: forcing 512x512 stretched 16:9 video thumbnails.
     */
    private fun encodeArt(source: Bitmap): String {
        // GPU-only bitmaps (Config.HARDWARE, common from notification icons) throw
        // when scaled or compressed in software — copy to a normal bitmap first.
        val art = if (source.config == Bitmap.Config.HARDWARE)
            source.copy(Bitmap.Config.ARGB_8888, false) else source
        val scale = 512f / maxOf(art.width, art.height).coerceAtLeast(1)
        val scaled = if (scale < 1f)
            art.scale((art.width * scale).toInt().coerceAtLeast(1),
                (art.height * scale).toInt().coerceAtLeast(1), true)
        else art
        val stream = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 85, stream)
        return Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    }

    /** content:// and file:// only — this runs on a 2s poll, never block it on network. */
    private fun loadLocalBitmap(uri: String): Bitmap? {
        if (uri.isEmpty() || uri.startsWith("http")) return null
        return try {
            context.contentResolver.openInputStream(uri.toUri())?.use {
                android.graphics.BitmapFactory.decodeStream(it)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sendNoMedia() {
        // Clear the latch so art is re-sent when a session comes back.
        lastArtSignature = null
        lastSentArtHash = null
        val json = JSONObject().apply {
            put("type", "media_state")
            put("app_name", "")
            put("package_name", "")
            put("track_title", "")
            put("artist", "")
            put("album", "")
            put("is_playing", false)
            put("duration_ms", 0)
            put("position_ms", 0)
            put("volume", 0)
            put("max_volume", 100)
            put("album_art_base64", JSONObject.NULL)
        }
        TunnelManager.sendRawMessage(json.toString())
    }

    companion object {
        @Volatile
        var instance: MediaSessionManager? = null

        private val videoNoise = Regex(
            """\(.*?\)|\[.*?]|\b(official|lyrics?|lyrical|video|audio|full song|hd|4k|mv)\b""",
            RegexOption.IGNORE_CASE
        )

        /** "Teri Tasveer (Lyrics) - Bayaan | Channel" → "Teri Tasveer - Bayaan". */
        fun artLookupQuery(title: String?, artist: String?): String? {
            if (title.isNullOrBlank()) return null
            val t = title.substringBefore("|").replace(videoNoise, " ")
                .replace(Regex("\\s+"), " ").trim().trim('-', ' ')
            if (t.isEmpty()) return null
            // "Song - Artist" titles already name the artist; the channel would only add noise.
            return if (t.contains(" - ") || artist.isNullOrBlank()) t else "$t $artist"
        }

        fun artMatchKey(s: String) = s.lowercase().filter { it.isLetterOrDigit() }
    }
}
