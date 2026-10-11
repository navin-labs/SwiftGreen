package com.swiftgreen.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings sync back after a reboot or app update — only if the user left it on.
 * QUICKBOOT_POWERON covers OnePlus/ColorOS fast boot, which skips BOOT_COMPLETED.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == "com.swiftgreen.app.FORCE_STOP_CANARY") return
        // LOCKED_BOOT_COMPLETED arrives before the first unlock, when the app's preferences
        // (credential-encrypted storage) throw on access. BOOT_COMPLETED follows the unlock.
        if (context.getSystemService(android.os.UserManager::class.java)?.isUserUnlocked == false) return
        if (!SyncSwitch.isOn(context)) return
        Log.i("BootReceiver", "${intent?.action} — sync is on, starting service")
        runCatching { SwiftGreenTunnelService.start(context) }
            .onFailure { Log.e("BootReceiver", "Failed to start service", it) }
    }
}
