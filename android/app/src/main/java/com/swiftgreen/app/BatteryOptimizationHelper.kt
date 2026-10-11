package com.swiftgreen.app

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.net.toUri
import androidx.core.content.edit

data class OemInstructions(
    val oemName: String,
    val steps: List<String>,
    val settingsLabel: String
)

object BatteryOptimizationHelper {

    private const val PREFS_NAME = "swiftgreen_battery_opt"
    private const val KEY_DONE = "battery_opt_onboarding_done"
    private const val KEY_SKIPPED = "battery_opt_onboarding_skipped"

    fun isExempted(context: Context): Boolean {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    fun shouldShowOnboarding(context: Context): Boolean {
        if (isExempted(context)) return false
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return !prefs.getBoolean(KEY_DONE, false) && !prefs.getBoolean(KEY_SKIPPED, false)
    }

    fun recordDone(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit { putBoolean(KEY_DONE, true) }
    }

    fun recordSkipped(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit { putBoolean(KEY_SKIPPED, true) }
    }

    fun openSettings(context: Context) {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val intent = getOemIntent(manufacturer, context)
        try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            openFallbackBatterySettings(context)
        } catch (_: SecurityException) {
            openFallbackBatterySettings(context)
        }
    }

    fun getOemInstructions(): OemInstructions {
        val manufacturer = Build.MANUFACTURER.lowercase()
        return when {
            manufacturer in listOf("xiaomi", "redmi", "poco") -> OemInstructions(
                oemName = "MIUI / HyperOS",
                steps = listOf(
                    "Open Battery Saver",
                    "Tap 'No Restrictions'",
                    "Find SwiftGreen",
                    "Set to 'No Restrictions'"
                ),
                settingsLabel = "MIUI Battery Settings"
            )
            manufacturer == "samsung" -> OemInstructions(
                oemName = "One UI (Samsung)",
                steps = listOf(
                    "Open Battery Settings",
                    "Tap 'Background usage limits'",
                    "Disable 'Sleeping apps' for SwiftGreen",
                    "Tap 'Never sleeping apps' → Add SwiftGreen"
                ),
                settingsLabel = "Battery Settings"
            )
            manufacturer in listOf("oppo", "realme") -> OemInstructions(
                oemName = "ColorOS",
                steps = listOf(
                    "Open App Info for SwiftGreen",
                    "Tap Battery",
                    "Select 'Allow background activity'"
                ),
                settingsLabel = "App Settings"
            )
            manufacturer == "vivo" -> OemInstructions(
                oemName = "FuntouchOS",
                steps = listOf(
                    "Open App Info for SwiftGreen",
                    "Tap Battery",
                    "Enable background activity"
                ),
                settingsLabel = "App Settings"
            )
            manufacturer == "oneplus" -> OemInstructions(
                oemName = "OxygenOS",
                steps = listOf(
                    "Tap 'Open Battery Optimization'",
                    "Find SwiftGreen",
                    "Select 'Don't optimize'"
                ),
                settingsLabel = "Battery Optimization"
            )
            else -> OemInstructions(
                oemName = "Android",
                steps = listOf(
                    "Tap 'Open Battery Optimization'",
                    "Find SwiftGreen",
                    "Select 'Don't optimize'"
                ),
                settingsLabel = "Battery Optimization"
            )
        }
    }

    private fun getOemIntent(manufacturer: String, context: Context): Intent {
        return when {
            manufacturer in listOf("xiaomi", "redmi", "poco") -> {
                Intent("miui.intent.action.POWER_HIDE_MODE_APP_LIST")
            }
            manufacturer == "samsung" -> {
                Intent("android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS")
            }
            manufacturer in listOf("oppo", "realme") -> {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = "package:${context.packageName}".toUri()
                }
            }
            manufacturer == "vivo" -> {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = "package:${context.packageName}".toUri()
                }
            }
            else -> directBatteryOptIntent(context)
        }
    }

    // BatteryLife is a Google Play policy check. SwiftGreen isn't on Play, and holding a live
    // connection to a companion device is the use Android documents for this one-tap request;
    // the alternative is a settings list the user has to search.
    @android.annotation.SuppressLint("BatteryLife")
    private fun directBatteryOptIntent(context: Context): Intent {
        return Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = "package:${context.packageName}".toUri()
        }
    }

    private fun openFallbackBatterySettings(context: Context) {
        try {
            val fallback = directBatteryOptIntent(context)
            fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(fallback)
        } catch (_: Exception) {
            // Last resort: open general battery settings
            try {
                val general = Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                general.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(general)
            } catch (_: Exception) { }
        }
    }
}
