package com.swiftgreen.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

/** Where a received file is written while it arrives. [publish] makes it visible and returns where; [discard] leaves no trace. */
internal interface ReceiveSink {
    val out: OutputStream
    fun publish(): String?
    fun discard()
}

/**
 * One incoming file's order, size and checksum, apart from Android so it's unit-tested.
 * Bytes stream into the sink and the hash; nothing is buffered whole.
 */
internal class IncomingFile(private val sink: ReceiveSink, val totalChunks: Int, val totalBytes: Long,
                            private val expectedSha256: String) {
    var nextIndex = 0
        private set
    var bytesWritten = 0L
        private set
    private val digest = MessageDigest.getInstance("SHA-256")

    /** Appends chunk [index]; a replay is skipped. False is fatal: a gap or a failed write. */
    fun accept(index: Int, data: ByteArray): Boolean {
        if (index < nextIndex) return true
        if (index > nextIndex) return false
        try { sink.out.write(data) } catch (e: IOException) { return false }
        digest.update(data)
        nextIndex++
        bytesWritten += data.size
        return true
    }

    /** Where the file was saved, or null after discarding it: incomplete, wrong checksum, or not publishable. */
    fun finish(): String? {
        val complete = nextIndex == totalChunks && (totalBytes <= 0 || bytesWritten == totalBytes)
        val hex = digest.digest().joinToString("") { "%02x".format(it) }
        if (!complete || !MessageDigest.isEqual(hex.toByteArray(), expectedSha256.lowercase().toByteArray())) {
            discard(); return null
        }
        return runCatching { sink.publish() }.getOrNull() ?: run { discard(); null }
    }

    fun discard() = sink.discard()
}

/** API 29+: a pending MediaStore Downloads row, which needs no storage permission. MediaStore picks a free name. */
@RequiresApi(Build.VERSION_CODES.Q)
private class MediaStoreSink(context: Context, name: String, mime: String) : ReceiveSink {
    private val resolver = context.contentResolver
    private val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, name)
        put(MediaStore.Downloads.MIME_TYPE, mime.ifBlank { "application/octet-stream" })
        put(MediaStore.Downloads.IS_PENDING, 1)
    }) ?: throw IOException("MediaStore refused the download row")
    override val out: OutputStream = runCatching { resolver.openOutputStream(uri) }.getOrNull()
        ?: run { resolver.delete(uri, null, null); throw IOException("Can't write the download row") }

    override fun publish(): String {
        out.close()
        resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        return uri.toString()
    }

    override fun discard() {
        runCatching { out.close() }
        runCatching { resolver.delete(uri, null, null) }
    }
}

/** API 26–28: a .part file in Downloads (WRITE_EXTERNAL_STORAGE), renamed onto a name reserved atomically. */
private class LegacyFileSink(private val dir: File, private val name: String) : ReceiveSink {
    private val part = File.createTempFile("swiftgreen-", ".part", dir)
    override val out: OutputStream = runCatching { java.io.FileOutputStream(part) }.getOrNull()
        ?: run { part.delete(); throw IOException("Can't open the .part file") }

    override fun publish(): String? {
        out.close()
        // createNewFile reserves the name atomically; renameTo then replaces only our empty placeholder.
        val dest = freeDownloadName(name) { !File(dir, it).createNewFile() }?.let { File(dir, it) } ?: return null
        if (!part.renameTo(dest)) { dest.delete(); return null }
        return dest.absolutePath
    }

    override fun discard() {
        runCatching { out.close() }
        part.delete()
    }
}

/** [name], else "name_1.ext" … "name_99.ext": the first one [taken] says is free; null if all are taken. */
internal fun freeDownloadName(name: String, taken: (String) -> Boolean): String? {
    if (!taken(name)) return name
    val base = name.substringBeforeLast(".", name)
    val ext = name.substringAfterLast(".", "")
    return (1..99).asSequence()
        .map { if (ext.isEmpty()) "${base}_$it" else "${base}_$it.$ext" }
        .firstOrNull { !taken(it) }
}

/**
 * Mac → phone files (SG-15). Called from the tunnel's reader thread and, for a cancel, from
 * the main thread, hence @Synchronized. Every failure, cancel and mismatch discards what was
 * written, so no partial file or pending row survives.
 */
object FileTransferReceiver {
    private const val TAG = "FileTransferReceiver"
    private const val PROGRESS_NOTIFICATION_ID = 2001
    private const val CHANNEL_ID = "file_transfer"

    private var activeTransferId: String? = null
    private var activeFilename: String? = null
    private var incoming: IncomingFile? = null

    /** API 26–28 need WRITE_EXTERNAL_STORAGE for Downloads; 29+ write through MediaStore without it. */
    fun canReceive(context: Context): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
        context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun openSink(context: Context, name: String, mime: String): ReceiveSink =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStoreSink(context, name, mime)
        else LegacyFileSink(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).apply { mkdirs() }, name)

    @Synchronized
    fun handleBegin(json: JSONObject, context: Context) {
        val transferId = json.optString("transfer_id", "")
        val filename = safeFileName(json.optString("filename", ""))
        val totalChunks = json.optInt("total_chunks", 0)

        if (transferId.isEmpty() || filename.isEmpty()) {
            Log.e(TAG, "Missing transfer_id or filename in file_transfer_begin")
            return
        }
        // Resume: the same transfer_id again keeps what's written.
        if (transferId == activeTransferId && incoming != null) {
            Log.d(TAG, "Resume detected — keeping ${incoming?.nextIndex} chunks")
            return
        }

        resetState()
        if (!canReceive(context)) {
            Log.w(TAG, "No storage permission (Android 8–9) — refusing the transfer")
            sendCancel(transferId)
            showNotification(context, "File not received", "Allow storage access for SwiftGreen, then send again.")
            return
        }
        val sink = try {
            openSink(context, filename, json.optString("mime_type", ""))
        } catch (e: Exception) {
            Log.e(TAG, "Couldn't open a download for writing: ${e.javaClass.simpleName}")
            sendCancel(transferId)
            return
        }
        incoming = IncomingFile(sink, totalChunks, json.optLong("total_bytes", 0L), json.optString("checksum_sha256", ""))
        activeTransferId = transferId
        activeFilename = filename

        Log.d(TAG, "Transfer begun — $totalChunks chunks")
        showProgressNotification(context, filename, 0, totalChunks, indeterminate = true)
    }

    @Synchronized
    fun handleChunk(json: JSONObject, context: Context) {
        val transferId = json.optString("transfer_id", "")
        val chunkIndex = json.optInt("chunk_index", -1)
        val totalChunks = json.optInt("total_chunks", 0)
        val file = incoming

        if (transferId.isEmpty() || chunkIndex == -1 || totalChunks == 0) {
            Log.e(TAG, "Missing required fields in file_transfer_chunk")
            return
        }
        if (transferId != activeTransferId || file == null) {
            Log.w(TAG, "Chunk for no active transfer — ignoring")
            return
        }
        val data = json.optString("data", "")
        val bytes = try {
            if (data.isEmpty()) ByteArray(0) else android.util.Base64.decode(data, android.util.Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            Log.e(TAG, "Bad base64 in chunk $chunkIndex — aborting")
            sendResult(transferId, ok = false)
            abort(context); return
        }
        // One ordered TCP stream, so chunks arrive in order; a gap or failed write is fatal.
        if (!file.accept(chunkIndex, bytes)) {
            Log.e(TAG, "Chunk $chunkIndex out of order or not written — aborting")
            sendResult(transferId, ok = false)
            abort(context); return
        }
        showProgressNotification(context, activeFilename ?: "", chunkIndex + 1, totalChunks, indeterminate = false)

        if (json.optBoolean("is_final", false)) {
            val name = activeFilename ?: "file"
            val bytesWritten = file.bytesWritten
            val saved = file.finish()
            incoming = null   // finish() published or discarded it
            resetState()
            cancelProgressNotification(context)
            sendResult(transferId, ok = saved != null)
            if (saved == null) {
                Log.e(TAG, "Incomplete, checksum mismatch or not publishable — discarded")
                showNotification(context, "File not received", "$name didn't arrive intact and was discarded.")
                return
            }
            Log.d(TAG, "File saved ($bytesWritten bytes)")
            FileTransferManager.addReceivedRecord(name, bytesWritten, context, saved)
            showNotification(context, "File Received", "$name saved to Downloads", saved)
        }
    }

    private fun ensureChannel(notificationManager: NotificationManager) {
        if (notificationManager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "File Transfer",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun showProgressNotification(
        context: Context,
        filename: String,
        progress: Int,
        total: Int,
        indeterminate: Boolean
    ) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(notificationManager)

        val cancelIntent = Intent("com.swiftgreen.app.CANCEL_FILE_TRANSFER").apply {
            setPackage(context.packageName)
        }
        val cancelPendingIntent = PendingIntent.getBroadcast(
            context,
            2001,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val text = if (indeterminate || total == 0) filename else "$filename • $progress of $total chunks"

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Receiving file")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(total, progress, indeterminate)
            .addAction(
                android.R.drawable.ic_delete,
                "Cancel",
                cancelPendingIntent
            )

        notificationManager.notify(PROGRESS_NOTIFICATION_ID, builder.build())
    }

    private fun cancelProgressNotification(context: Context) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(PROGRESS_NOTIFICATION_ID)
    }

    /** Tapping opens the saved file (a MediaStore Uri on 29+), else the Downloads list. */
    private fun showNotification(context: Context, title: String, text: String, saved: String? = null) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureChannel(notificationManager)

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
        if (saved != null) {
            val open = if (saved.startsWith("content://"))
                Intent(Intent.ACTION_VIEW, Uri.parse(saved)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            else Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS)
            builder.setContentIntent(PendingIntent.getActivity(context, saved.hashCode(),
                open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE))
        }

        val notificationId = System.currentTimeMillis().toInt()
        notificationManager.notify(notificationId, builder.build())
    }

    /** Every failure path ends here, so no path leaves a partial file or the "Receiving file" notification behind. */
    private fun abort(context: Context) {
        resetState()
        cancelProgressNotification(context)
    }

    private fun resetState() {
        incoming?.discard()
        incoming = null
        activeTransferId = null
        activeFilename = null
    }

    /** The Mac shows the transfer complete only after this: the file is written and its checksum verified. */
    private fun sendResult(transferId: String, ok: Boolean) {
        TunnelManager.sendCancelMessage(JSONObject().put("type", "file_transfer_result")
            .put("transfer_id", transferId).put("ok", ok).toString())
    }

    private fun sendCancel(transferId: String) {
        TunnelManager.sendCancelMessage(JSONObject().put("type", "file_transfer_cancel").put("transfer_id", transferId).toString())
    }

    /** The Mac cancelled: drop what's written without echoing a cancel back. */
    @Synchronized
    fun peerCancelled(context: Context) = abort(context)

    @Synchronized
    fun cancelTransfer(context: Context) {
        val transferId = activeTransferId ?: ""
        abort(context)
        sendCancel(transferId)
        Log.d(TAG, "Sent file_transfer_cancel to Mac")
    }
}

class FileTransferCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.swiftgreen.app.CANCEL_FILE_TRANSFER") {
            FileTransferReceiver.cancelTransfer(context)
        }
    }
}
