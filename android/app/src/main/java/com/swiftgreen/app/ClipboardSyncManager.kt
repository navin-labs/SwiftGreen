package com.swiftgreen.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper

object ClipboardSyncManager {

    private const val TAG = "SwiftGreen.Clipboard"
    private const val MAX_TEXT_BYTES = 1_048_576 // 1 MiB

    // Injected by MdnsQuicClient after tunnel is authenticated
    var sendMessage: ((String) -> Unit)? = null

    // Loop prevention — content we just wrote to the clipboard ourselves
    @Volatile private var lastWrittenContent: String? = null

    @Volatile private var pendingClipboard: String? = null

    /**
     * Called by MdnsQuicClient when a clipboard_push message arrives from Mac.
     * Must be called on any thread — internally dispatches to main for
     * ClipboardManager write.
     */
    fun handleIncomingClipboard(context: Context, body: Map<String, Any?>) {
        val source = body["source"] as? String
        if (source == "android") {
            Log.d(TAG, "Dropping clipboard echo from self")
            return
        }

        val contentType = body["content_type"] as? String

        if (contentType == "image") {
            handleIncomingImage(context, body)
            return
        }

        if (contentType != "text") {
            Log.d(TAG, "Ignoring unknown clipboard content_type: $contentType")
            return
        }

        val text = body["text"] as? String
        if (text.isNullOrEmpty()) {
            Log.d(TAG, "Dropping empty clipboard push")
            return
        }

        if (text.toByteArray(Charsets.UTF_8).size > MAX_TEXT_BYTES) {
            Log.w(TAG, "Clipboard text exceeds 1 MiB limit, dropping")
            return
        }

        lastWrittenContent = text
        ClipboardHistoryManager.addRecord(text, "mac")

        Handler(Looper.getMainLooper()).post {
            try {
                val clipboard = context.getSystemService(
                    Context.CLIPBOARD_SERVICE
                ) as ClipboardManager
                val clip = ClipData.newPlainText("SwiftGreen", text)
                clipboard.setPrimaryClip(clip)
                Log.d(TAG, "Clipboard written from Mac (${text.length} chars)")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write clipboard", e)
            }
        }
    }

    /**
     * Called by the Share target activity when the user shares text to
     * SwiftGreen. Sends clipboard_push message to Mac over the tunnel.
     */
    fun sendToMac(text: String) {
        val send = sendMessage
        if (send == null) {
            Log.w(TAG, "Tunnel not connected — queuing clipboard for next connection")
            pendingClipboard = text
            return
        }

        if (text == lastWrittenContent) {
            Log.d(TAG, "Skipping clipboard send — content matches last write")
            return
        }

        pendingClipboard = null
        val payload = buildJsonPayload(text)
        ClipboardHistoryManager.addRecord(text, "android")
        send(payload)
        Log.d(TAG, "Clipboard pushed to Mac (${text.length} chars)")
    }

    fun flushPendingClipboard() {
        val pending = pendingClipboard ?: return
        pendingClipboard = null
        val send = sendMessage ?: return
        if (pending == lastWrittenContent) return
        val payload = buildJsonPayload(pending)
        send(payload)
        Log.d(TAG, "Flushed pending clipboard to Mac (${pending.length} chars)")
    }

    fun writeLocalOnly(context: Context, text: String) {
        lastWrittenContent = text
        Handler(Looper.getMainLooper()).post {
            try {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("SwiftGreen", text))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to write clipboard", e)
            }
        }
    }

    fun isTunnelConnected(): Boolean = sendMessage != null

    fun sendImageToMac(context: android.content.Context, uri: android.net.Uri, mimeType: String): String {
        val send = sendMessage ?: return "NOT_CONNECTED"
        val bytes = try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read image URI", e)
            return "ERROR"
        } ?: return "ERROR"
        val base64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        if (base64.length > 10 * 1024 * 1024) {
            Log.w(TAG, "Image exceeds 10 MiB cap (${base64.length} chars) — rejecting")
            return "TOO_LARGE"
        }
        val actualMime = context.contentResolver.getType(uri) ?: mimeType
        val timestamp = System.currentTimeMillis()
        val payload = """{"type":"clipboard_push","content_type":"image","text":null,"image_base64":"$base64","image_mime_type":"$actualMime","source":"android","timestamp_ms":$timestamp}"""
        send(payload)
        Log.d(TAG, "Image clipboard pushed to Mac (${base64.length} base64 chars, mime=$actualMime)")
        return "OK"
    }

    private fun handleIncomingImage(context: android.content.Context, body: Map<String, Any?>) {
        val base64 = body["image_base64"] as? String ?: return
        val mimeType = body["image_mime_type"] as? String ?: "image/png"
        val bytes = try {
            android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decode image base64", e)
            return
        }
        val ext = when {
            mimeType.contains("jpeg") || mimeType.contains("jpg") -> "jpg"
            mimeType.contains("webp") -> "webp"
            mimeType.contains("gif") -> "gif"
            else -> "png"
        }
        try {
            val dir = java.io.File(context.cacheDir, "clipboard_images").apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }  // delete-on-next-receipt
            val file = java.io.File(dir, "clipboard_image_${System.currentTimeMillis()}.$ext")
            file.writeBytes(bytes)
            val uri = androidx.core.content.FileProvider.getUriForFile(
                context, "${context.packageName}.fileprovider", file
            )
            val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newUri(context.contentResolver, "SwiftGreen Image", uri)
            clipboard.setPrimaryClip(clip)
            Log.d(TAG, "Clipboard image written from Mac (${bytes.size} bytes, mime=$mimeType)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write image clipboard", e)
        }
    }

    private fun buildJsonPayload(text: String): String {
        // Escape the text for JSON safely
        val escaped = text
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
            .replace(Regex("[\u0000-\u0008\u000B\u000C\u000E-\u001F]")) { 
                "\\u%04x".format(it.value[0].code) 
            }
        val timestamp = System.currentTimeMillis()
        return """{"type":"clipboard_push","content_type":"text","text":"$escaped","image_base64":null,"image_mime_type":null,"source":"android","timestamp_ms":$timestamp}"""
    }
}
