package com.swiftgreen.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ClipboardShareActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.component?.className == "com.swiftgreen.app.ClipboardImageShareAlias") {
            handleImageClipboardShare()
            return
        }

        if (intent?.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("text/") == true
        ) {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!sharedText.isNullOrEmpty()) {
                if (ClipboardSyncManager.isTunnelConnected()) {
                    // Tunnel is live — send on IO, finish on main
                    lifecycleScope.launch(Dispatchers.IO) {
                        ClipboardSyncManager.sendToMac(sharedText)
                        withContext(Dispatchers.Main) {
                            Toast.makeText(this@ClipboardShareActivity, "Copied to Mac",
                                Toast.LENGTH_SHORT).show()
                            finish()
                        }
                    }
                    return  // coroutine owns finish(); don't fall through
                } else {
                    // Tunnel not connected — queue for later
                    ClipboardSyncManager.sendToMac(sharedText)
                    Toast.makeText(this,
                        "Queued — open SwiftGreen to sync",
                        Toast.LENGTH_SHORT).show()
                }
            }
        } else if (intent?.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("text/") != true) {
            val fileUri = androidx.core.content.IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, android.net.Uri::class.java)
                ?.takeIf { isShareableScheme(it.scheme) }
            if (fileUri != null) {
                if (TunnelManager.isTunnelActive.value) {
                    FileTransferManager.sendFile(
                        uri = fileUri,
                        context = applicationContext,
                        onProgress = { },
                        onComplete = {
                            runOnUiThread {
                                Toast.makeText(this@ClipboardShareActivity,
                                    "File sent to Mac", Toast.LENGTH_SHORT).show()
                                finish()
                            }
                        },
                        onError = { err ->
                            runOnUiThread {
                                Toast.makeText(this@ClipboardShareActivity,
                                    "Send failed: $err", Toast.LENGTH_SHORT).show()
                                finish()
                            }
                        }
                    )
                    return  // CRITICAL: do not fall through to finish()
                } else {
                    Toast.makeText(this, "SwiftGreen not connected",
                        Toast.LENGTH_SHORT).show()
                }
            }
        }
        finish()
    }

    private fun handleImageClipboardShare() {
        val imageUri = androidx.core.content.IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, android.net.Uri::class.java)
            ?.takeIf { isShareableScheme(it.scheme) }
        if (imageUri == null) {
            Toast.makeText(this, "No image found", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        if (!ClipboardSyncManager.isTunnelConnected()) {
            Toast.makeText(this, "SwiftGreen not connected", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        val mimeType = contentResolver.getType(imageUri) ?: intent.type ?: "image/png"
        lifecycleScope.launch(Dispatchers.IO) {
            val result = ClipboardSyncManager.sendImageToMac(applicationContext, imageUri, mimeType)
            val msg = when (result) {
                "OK" -> "Image copied to Mac clipboard"
                "TOO_LARGE" -> "Image too large (max 10 MB)"
                "NOT_CONNECTED" -> "SwiftGreen not connected"
                else -> "Failed to copy image"
            }
            withContext(Dispatchers.Main) {
                Toast.makeText(this@ClipboardShareActivity, msg, Toast.LENGTH_SHORT).show()
                finish()
            }
        }
    }
}

/**
 * Only content:// may be shared. Any installed app can start this activity, and a
 * file:// URI is opened with SwiftGreen's own permissions: "file:///data/data/
 * com.swiftgreen.app/shared_prefs/swiftgreen_pairing.xml" sent the pairing key to the Mac.
 */
internal fun isShareableScheme(scheme: String?) = scheme == "content"
