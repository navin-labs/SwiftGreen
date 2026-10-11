package com.swiftgreen.app

import android.content.Context
import androidx.core.content.edit

object AppFilterManager {
    private const val TAG = "AppFilterManager"
    private const val PREFS_NAME = "notification_filter"
    private const val KEY_BLOCKED = "blocked_packages"
    private const val KEY_SEEN = "seen_packages"
    private const val KEY_APP_NAMES = "app_names"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isBlocked(context: Context, packageName: String): Boolean =
        getBlockedPackages(context).contains(packageName)

    fun getBlockedPackages(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_BLOCKED, emptySet()) ?: emptySet()

    fun setPackageBlocked(context: Context, packageName: String, blocked: Boolean) {
        val current = getBlockedPackages(context).toMutableSet()
        if (blocked) current.add(packageName) else current.remove(packageName)
        prefs(context).edit { putStringSet(KEY_BLOCKED, current) }
        Log.d(TAG, "setPackageBlocked: $packageName → blocked=$blocked")
    }

    fun trackSeenPackage(context: Context, packageName: String, appName: String) {
        val p = prefs(context)
        val seen = p.getStringSet(KEY_SEEN, emptySet())?.toMutableSet() ?: mutableSetOf()
        seen.add(packageName)
        val names = p.getStringSet(KEY_APP_NAMES, emptySet())?.toMutableSet() ?: mutableSetOf()
        names.add("$packageName|$appName")
        p.edit {
            putStringSet(KEY_SEEN, seen)
            putStringSet(KEY_APP_NAMES, names)
        }
    }

    fun getSeenPackages(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_SEEN, emptySet()) ?: emptySet()

    fun getAppName(context: Context, packageName: String): String {
        val names = prefs(context).getStringSet(KEY_APP_NAMES, emptySet()) ?: emptySet()
        for (entry in names) {
            val parts = entry.split("|", limit = 2)
            if (parts.size == 2 && parts[0] == packageName) return parts[1]
        }
        return packageName
    }
}
