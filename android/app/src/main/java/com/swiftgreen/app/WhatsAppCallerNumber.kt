package com.swiftgreen.app

import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract

/**
 * WhatsApp's missed-call notification carries only a display name, never a number
 * field, so its call-log row had no number and the Mac could not call back. The number
 * is usually still recoverable, cheapest source first:
 *  1. a `tel:` URI on the notification's Person (set by some WhatsApp versions),
 *  2. the title itself — an unsaved caller is shown as their number,
 *  3. the phone's contacts — a saved caller is shown by their contact name, which
 *     is only trusted when it maps to exactly one number.
 * Empty when none of these give a single answer; the row then stays name-only.
 */
object WhatsAppCallerNumber {
    private const val TAG = "WhatsAppCallerNumber"

    fun resolve(context: Context, notification: Notification, title: String): String {
        fromPeople(notification)?.let { return it }
        numberFromTitle(title)?.let { return it }
        return fromContacts(context, title) ?: ""
    }

    /** "+91 98765 43210", "(555) 123-4567" → digits with any leading '+'; null for names. */
    fun numberFromTitle(title: String): String? {
        val t = title.trim().replace('‪', ' ').replace('‬', ' ').trim() // bidi marks around numbers
        if (t.isEmpty() || !t.all { it.isDigit() || it in "+ -(). " }) return null
        if (t.indexOf('+') > 0 || t.count { it == '+' } > 1) return null
        val digits = t.filter { it.isDigit() }
        if (digits.length !in 7..15) return null
        return if (t.startsWith("+")) "+$digits" else digits
    }

    /** Distinct numbers once formatting is ignored; a single survivor is the answer. */
    fun singleNumber(numbers: List<String>): String? {
        val normalized = numbers.mapNotNull { numberFromTitle(it) }.distinctBy { it.takeLast(10) }
        return normalized.singleOrNull()
    }

    private fun fromPeople(notification: Notification): String? = runCatching {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) return null
        @Suppress("DEPRECATION")
        val people = notification.extras.getParcelableArrayList<android.app.Person>(Notification.EXTRA_PEOPLE_LIST)
        people?.firstNotNullOfOrNull { p ->
            p.uri?.takeIf { it.startsWith("tel:") }?.removePrefix("tel:")?.let { numberFromTitle(android.net.Uri.decode(it)) }
        }
    }.getOrNull()

    private fun fromContacts(context: Context, name: String): String? {
        if (name.isBlank() ||
            context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) return null
        return try {
            val numbers = mutableListOf<String>()
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} = ?",
                arrayOf(name.trim()),
                null
            )?.use { c -> while (c.moveToNext()) c.getString(0)?.let { numbers.add(it) } }
            singleNumber(numbers)
        } catch (e: Exception) {
            Log.w(TAG, "Contact lookup failed: ${e.message}")
            null
        }
    }
}
