package com.swiftgreen.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import kotlinx.coroutines.*
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import androidx.core.net.toUri
import androidx.core.content.edit

object FileTransferManager {
    private const val TAG = "FileTransferManager"
    private const val HISTORY_PREFS = "swiftgreen_transfer_history"
    private const val HISTORY_KEY = "history_json"

    @Volatile var isCancelled: Boolean = false
    @Volatile private var activeTransferJob: Job? = null
    @Volatile private var historyLoaded = false

    data class TransferRecord(
        val filename: String,
        val bytes: Long,
        val state: String,      // "complete" | "error" | "sending" | "cancelled"
        val direction: String = "sent",  // "sent" | "received"
        val timestampMs: Long = System.currentTimeMillis(),
        val path: String? = null  // absolute path on disk; non-null only for received records
    )

    private val _transferHistory = kotlinx.coroutines.flow.MutableStateFlow<List<TransferRecord>>(emptyList())
    val transferHistory: kotlinx.coroutines.flow.StateFlow<List<TransferRecord>> = _transferHistory

    private val _activeTransfer = kotlinx.coroutines.flow.MutableStateFlow<TransferRecord?>(null)
    val activeTransfer: kotlinx.coroutines.flow.StateFlow<TransferRecord?> = _activeTransfer

    private val _transferProgress = kotlinx.coroutines.flow.MutableStateFlow(0f)
    val transferProgress: kotlinx.coroutines.flow.StateFlow<Float> = _transferProgress

    private fun emitProgress(filename: String, bytes: Long, state: String, context: Context) {
        loadHistoryIfNeeded(context)
        val record = TransferRecord(filename, bytes, state, direction = "sent")
        _activeTransfer.value = record
        if (state == "complete" || state == "error" || state == "cancelled") {
            _transferHistory.value = listOf(record) + _transferHistory.value.take(19)
            _activeTransfer.value = null
            _transferProgress.value = 0f
            saveHistory(context)
        }
    }

    private fun saveHistory(context: Context) {
        val arr = JSONArray()
        for (r in _transferHistory.value) {
            arr.put(JSONObject().apply {
                put("filename", r.filename)
                put("bytes", r.bytes)
                put("state", r.state)
                put("direction", r.direction)
                put("timestampMs", r.timestampMs)
                if (r.path != null) put("path", r.path)
            })
        }
        context.getSharedPreferences(HISTORY_PREFS, Context.MODE_PRIVATE)
            .edit { putString(HISTORY_KEY, arr.toString()) }
    }

    private fun loadHistoryIfNeeded(context: Context) {
        if (historyLoaded) return
        historyLoaded = true
        val json = context.getSharedPreferences(HISTORY_PREFS, Context.MODE_PRIVATE)
            .getString(HISTORY_KEY, null) ?: return
        try {
            val arr = JSONArray(json)
            val records = mutableListOf<TransferRecord>()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                records.add(TransferRecord(
                    filename  = obj.optString("filename", "unknown"),
                    bytes     = obj.optLong("bytes", 0L),
                    state     = obj.optString("state", "complete"),
                    direction = obj.optString("direction", "sent"),
                    timestampMs = obj.optLong("timestampMs", 0L),
                    path      = obj.optString("path", "").ifEmpty { null }
                ))
            }
            if (records.isNotEmpty()) _transferHistory.value = records
        } catch (_: Exception) {}
    }

    fun sendFile(
        uri: Uri,
        context: Context,
        onProgress: (Float) -> Unit,
        onComplete: () -> Unit,
        onError: (String) -> Unit
    ) {
        loadHistoryIfNeeded(context)

        if (!TunnelManager.isTunnelActive.value) {
            CoroutineScope(Dispatchers.Main).launch {
                emitProgress("unknown", 0L, "error", context)
                onError("Not connected")
            }
            return
        }

        isCancelled = false
        activeTransferJob = CoroutineScope(Dispatchers.IO).launch {
            var sanitizedFilename = "unknown"
            var totalBytes = 0L
            try {
                val prefs = context.getSharedPreferences("swiftgreen_filetransfer", Context.MODE_PRIVATE)
                // 1. Get metadata
                var filename = "unknown"
                totalBytes = 0L
                var mimeType = "application/octet-stream"

                if (uri.scheme == "content") {
                    context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameIndex != -1) {
                                filename = cursor.getString(nameIndex) ?: "unknown"
                            }
                            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeIndex != -1) {
                                totalBytes = cursor.getLong(sizeIndex)
                            }
                        }
                    }
                    mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
                } else if (uri.scheme == "file") {
                    val file = java.io.File(uri.path ?: "")
                    filename = file.name
                    totalBytes = file.length()
                    val extension = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
                    if (extension != null) {
                        mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.lowercase()) ?: "application/octet-stream"
                    }
                } else {
                    filename = uri.lastPathSegment ?: "unknown"
                }

                // 3. Filename sanitization
                val nameNoPath = filename.substringAfterLast('/').substringAfterLast('\\')
                sanitizedFilename = nameNoPath.take(255).ifEmpty { "file" }
                emitProgress(sanitizedFilename, totalBytes, "sending", context)

                val transferId = UUID.randomUUID().toString()
                val chunkSize = 256 * 1024 // 256KB
                val totalChunks = if (totalBytes == 0L) 1 else ((totalBytes + chunkSize - 1) / chunkSize).toInt()

                // Persist transfer state for resume
                prefs.edit {
                    putString("active_transfer_id", transferId)
                    putString("active_filename", sanitizedFilename)
                    putLong("active_total_bytes", totalBytes)
                    putInt("active_total_chunks", totalChunks)
                    putString("active_sha256", "")
                    putLong("active_resume_offset", 0L)
                    putString("active_uri", uri.toString())
                }

                // 5. Send file_transfer_begin
                val beginJson = JSONObject().apply {
                    put("type", "file_transfer_begin")
                    put("transfer_id", transferId)
                    put("filename", sanitizedFilename)
                    put("mime_type", mimeType)
                    put("total_bytes", totalBytes)
                    put("total_chunks", totalChunks)
                    put("checksum_sha256", "")  // sent in file_transfer_complete
                    put("resume_offset", 0)
                }
                val beginSent = TunnelManager.sendRawMessageSuspend(beginJson.toString())
                if (!beginSent && !isCancelled) {
                    withContext(Dispatchers.Main) {
                        emitProgress(sanitizedFilename, totalBytes, "error", context)
                        onError("Send failed sending file_transfer_begin")
                    }
                    return@launch
                }

                // 6. Send chunks
                if (totalBytes == 0L) {
                    val chunkJson = JSONObject().apply {
                        put("type", "file_transfer_chunk")
                        put("transfer_id", transferId)
                        put("chunk_index", 0)
                        put("total_chunks", 1)
                        put("data", "")
                        put("is_final", true)
                    }
                    TunnelManager.sendRawMessage(chunkJson.toString())
                    withContext(Dispatchers.Main) {
                        onProgress(1.0f)
                    }
                } else {
                    val digest = MessageDigest.getInstance("SHA-256")
                    var bytesReadSoFar = 0L
                    context.contentResolver.openInputStream(uri)?.use { inputStream ->
                        val chunkBuffer = ByteArray(chunkSize)
                        var chunkIndex = 0
                        while (bytesReadSoFar < totalBytes) {
                            if (isCancelled) {
                                withContext(Dispatchers.Main) {
                                    emitProgress(sanitizedFilename, totalBytes, "cancelled", context)
                                    onError("Cancelled")
                                }
                                return@launch
                            }
                            if (!TunnelManager.isTunnelActive.value) {
                                withContext(Dispatchers.Main) {
                                    emitProgress(sanitizedFilename, totalBytes, "error", context)
                                    onError("Send failed at chunk $chunkIndex")
                                }
                                return@launch
                            }
                            val bytesToRead = minOf(chunkBuffer.size.toLong(), totalBytes - bytesReadSoFar).toInt()
                            var totalBytesRead = 0
                            while (totalBytesRead < bytesToRead) {
                                if (isCancelled) break
                                val bytesRead = inputStream.read(chunkBuffer, totalBytesRead, bytesToRead - totalBytesRead)
                                if (bytesRead == -1) break
                                totalBytesRead += bytesRead
                            }
                            if (isCancelled) {
                                withContext(Dispatchers.Main) {
                                    emitProgress(sanitizedFilename, totalBytes, "cancelled", context)
                                    onError("Cancelled")
                                }
                                return@launch
                            }

                            if (totalBytesRead == 0) {
                                break
                            }

                            bytesReadSoFar += totalBytesRead
                            val isFinal = bytesReadSoFar >= totalBytes

                            val chunkBytes = if (totalBytesRead == chunkBuffer.size) {
                                chunkBuffer
                            } else {
                                chunkBuffer.copyOf(totalBytesRead)
                            }

                            digest.update(chunkBytes, 0, totalBytesRead)

                            val base64Data = Base64.getEncoder().encodeToString(chunkBytes)

                            val chunkJson = JSONObject().apply {
                                put("type", "file_transfer_chunk")
                                put("transfer_id", transferId)
                                put("chunk_index", chunkIndex)
                                put("total_chunks", totalChunks)
                                put("data", base64Data)
                                put("is_final", isFinal)
                            }

                            val sent = TunnelManager.sendRawMessageSuspend(chunkJson.toString())
                            if (!sent && !isCancelled) {
                                withContext(Dispatchers.Main) {
                                    emitProgress(sanitizedFilename, totalBytes, "error", context)
                                    onError("Send failed at chunk $chunkIndex")
                                }
                                return@launch
                            }

                            prefs.edit { putLong("active_resume_offset", bytesReadSoFar) }

                            val progress = (chunkIndex + 1).toFloat() / totalChunks
                            _transferProgress.value = progress
                            withContext(Dispatchers.Main) {
                                onProgress(progress)
                            }
                            showProgressNotification(context, sanitizedFilename, progress)

                            chunkIndex++
                            if (isFinal) {
                                break
                            }
                        }
                    } ?: throw java.io.FileNotFoundException("Could not open input stream for URI: $uri")

                    val finalJson = JSONObject().apply {
                        put("type", "file_transfer_complete")
                        put("transfer_id", transferId)
                        put("checksum_sha256", digest.digest().joinToString("") { "%02x".format(it) })
                    }
                    val finalSent = TunnelManager.sendRawMessageSuspend(finalJson.toString())
                    if (!finalSent && !isCancelled) {
                        withContext(Dispatchers.Main) {
                            emitProgress(sanitizedFilename, totalBytes, "error", context)
                            onError("Send failed sending file_transfer_complete")
                        }
                        return@launch
                    }
                }

                withContext(Dispatchers.Main) {
                    emitProgress(sanitizedFilename, totalBytes, "complete", context)
                    onComplete()
                }
                // Bug 2 fix: cancel notification 2002 instead of posting a stuck 100% state
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager).cancel(2002)
                prefs.edit { clear() }

            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) {
                    Log.d(TAG, "File transfer coroutine cancelled cleanly")
                    withContext(Dispatchers.Main) {
                        emitProgress(sanitizedFilename, totalBytes, "cancelled", context)
                    }
                } else {
                    Log.e(TAG, "Error during file transfer", e)
                    withContext(Dispatchers.Main) {
                        emitProgress(sanitizedFilename, totalBytes, "error", context)
                        onError(e.message ?: "Unknown error")
                    }
                }
            }
        }
    }

    private fun showProgressNotification(context: Context, filename: String, progress: Float) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "file_transfer_progress"
        if (nm.getNotificationChannel(channelId) == null) {
            nm.createNotificationChannel(
                android.app.NotificationChannel(channelId, "File Transfer", android.app.NotificationManager.IMPORTANCE_LOW)
            )
        }
        if (isCancelled) return
        val pct = (progress * 100).toInt()
        val builder = androidx.core.app.NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Sending $filename")
            .setContentText("$pct%")
            .setProgress(100, pct, false)
            .setOngoing(progress < 1f)
            .setOnlyAlertOnce(true)
        if (progress < 1f) {
            val cancelIntent = Intent("com.swiftgreen.app.CANCEL_FILE_SEND").apply {
                setPackage(context.packageName)
            }
            val cancelPendingIntent = android.app.PendingIntent.getBroadcast(
                context,
                2002,
                cancelIntent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(android.R.drawable.ic_delete, "Cancel", cancelPendingIntent)
        }
        nm.notify(2002, builder.build())
    }

    fun cancelSend(context: Context) {
        activeTransferJob?.cancel()
        activeTransferJob = null
        isCancelled = true
        val current = _activeTransfer.value
        val json = JSONObject().apply {
            put("type", "file_transfer_cancel")
            put("transfer_id", "")
        }
        TunnelManager.sendCancelMessage(json.toString())
        TunnelManager.cancelPendingMessages()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.cancel(2002)
        if (current != null) {
            emitProgress(current.filename, current.bytes, "cancelled", context)
        } else {
            _activeTransfer.value = null
            _transferProgress.value = 0f
        }
        Log.d(TAG, "Transfer cancelled by user (sender side)")
    }

    fun resumeIfNeeded(context: Context, onProgress: (Float) -> Unit, onComplete: () -> Unit, onError: (String) -> Unit) {
        val prefs = context.getSharedPreferences("swiftgreen_filetransfer", Context.MODE_PRIVATE)
        val transferId = prefs.getString("active_transfer_id", null) ?: return
        val filename = prefs.getString("active_filename", null) ?: return
        val totalBytes = prefs.getLong("active_total_bytes", 0L)
        val totalChunks = prefs.getInt("active_total_chunks", 0)
        val sha256Hex = prefs.getString("active_sha256", null) ?: return
        val resumeOffset = prefs.getLong("active_resume_offset", 0L)
        val uriString = prefs.getString("active_uri", null) ?: return
        val uri = uriString.toUri()

        if (!TunnelManager.isTunnelActive.value) return
        if (resumeOffset >= totalBytes && totalBytes > 0) {
            // Already complete — clear and return
            prefs.edit { clear() }
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val chunkSize = 256 * 1024 // 256KB
                val resumeChunkIndex = (resumeOffset / chunkSize).toInt()

                // Send file_transfer_begin with resume_offset
                val beginJson = JSONObject().apply {
                    put("type", "file_transfer_begin")
                    put("transfer_id", transferId)
                    put("filename", filename)
                    put("mime_type", "application/octet-stream")
                    put("total_bytes", totalBytes)
                    put("total_chunks", totalChunks)
                    put("checksum_sha256", "")  // sent in file_transfer_complete
                    put("resume_offset", resumeOffset)
                }
                TunnelManager.sendRawMessage(beginJson.toString())

                // Skip to resumeOffset in the stream
                val digest = MessageDigest.getInstance("SHA-256")
                context.contentResolver.openInputStream(uri)?.use { inputStream ->
                    inputStream.skip(resumeOffset)
                    val chunkBuffer = ByteArray(chunkSize)
                    var bytesReadSoFar = resumeOffset
                    var chunkIndex = resumeChunkIndex

                    while (bytesReadSoFar < totalBytes) {
                        if (!TunnelManager.isTunnelActive.value) {
                            withContext(Dispatchers.Main) { onError("Disconnected during resume") }
                            return@launch
                        }
                        val bytesToRead = minOf(chunkBuffer.size.toLong(), totalBytes - bytesReadSoFar).toInt()
                        var totalBytesRead = 0
                        while (totalBytesRead < bytesToRead) {
                            val bytesRead = inputStream.read(chunkBuffer, totalBytesRead, bytesToRead - totalBytesRead)
                            if (bytesRead == -1) break
                            totalBytesRead += bytesRead
                        }
                        if (totalBytesRead == 0) break
                        bytesReadSoFar += totalBytesRead
                        val isFinal = bytesReadSoFar >= totalBytes
                        val chunkBytes = if (totalBytesRead == chunkBuffer.size) chunkBuffer else chunkBuffer.copyOf(totalBytesRead)
                        digest.update(chunkBytes, 0, totalBytesRead)
                        val base64Data = Base64.getEncoder().encodeToString(chunkBytes)
                        val chunkJson = JSONObject().apply {
                            put("type", "file_transfer_chunk")
                            put("transfer_id", transferId)
                            put("chunk_index", chunkIndex)
                            put("total_chunks", totalChunks)
                            put("data", base64Data)
                            put("is_final", isFinal)
                        }
                        TunnelManager.sendRawMessage(chunkJson.toString())
                        prefs.edit { putLong("active_resume_offset", bytesReadSoFar) }
                        val progress = bytesReadSoFar.toFloat() / totalBytes
                        withContext(Dispatchers.Main) { onProgress(progress) }
                        chunkIndex++
                        if (isFinal) break
                    }
                }

                val finalJson = JSONObject().apply {
                    put("type", "file_transfer_complete")
                    put("transfer_id", transferId)
                    put("checksum_sha256", digest.digest().joinToString("") { "%02x".format(it) })
                }
                TunnelManager.sendRawMessage(finalJson.toString())
                prefs.edit { clear() }
                withContext(Dispatchers.Main) { onComplete() }
            } catch (e: Exception) {
                Log.e(TAG, "Resume failed", e)
                withContext(Dispatchers.Main) { onError(e.message ?: "Resume error") }
            }
        }
    }

    fun clearHistory(context: Context) {
        _transferHistory.value = emptyList()
        context.getSharedPreferences(HISTORY_PREFS, Context.MODE_PRIVATE)
            .edit { remove(HISTORY_KEY) }
    }

    fun addReceivedRecord(filename: String, bytes: Long, context: Context, path: String? = null) {
        loadHistoryIfNeeded(context)
        val record = TransferRecord(
            filename  = filename,
            bytes     = bytes,
            state     = "complete",
            direction = "received",
            timestampMs = System.currentTimeMillis(),
            path      = path
        )
        _transferHistory.value = listOf(record) + _transferHistory.value.take(19)
        saveHistory(context)
    }
}

class FileTransferSendCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.swiftgreen.app.CANCEL_FILE_SEND") {
            FileTransferManager.cancelSend(context)
        }
    }
}
