package com.swiftgreen.app

import android.content.Context
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

data class Contact(
    val id: Long,
    val displayName: String,
    val phoneNumbers: List<String>,
    val photoUri: String?
)

object ContactsStore {
    private const val TAG = "ContactsStore"

    fun fetchContacts(context: Context): List<Contact> {
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.PHOTO_URI
        )

        data class Row(val displayName: String?, val number: String?, val photoUri: String?)
        val rowsByContactId = LinkedHashMap<Long, MutableList<Row>>()

        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            projection,
            null,
            null,
            null
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
            val nameIdx = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)
            val numberIdx = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
            val photoIdx = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.PHOTO_URI)

            while (cursor.moveToNext()) {
                val contactId = cursor.getLong(idIdx)
                rowsByContactId.getOrPut(contactId) { mutableListOf() }.add(
                    Row(
                        displayName = cursor.getString(nameIdx),
                        number = cursor.getString(numberIdx),
                        photoUri = cursor.getString(photoIdx)
                    )
                )
            }
        }

        val contacts = rowsByContactId.map { (contactId, rows) ->
            val distinctNumbers = LinkedHashMap<String, String>()
            for (row in rows) {
                val raw = row.number ?: continue
                val normalized = raw.filterNot { it.isWhitespace() }
                distinctNumbers.putIfAbsent(normalized, raw)
            }
            Contact(
                id = contactId,
                displayName = rows.firstOrNull { !it.displayName.isNullOrEmpty() }?.displayName ?: "",
                phoneNumbers = distinctNumbers.values.toList(),
                photoUri = rows.firstOrNull { it.photoUri != null }?.photoUri
            )
        }

        Log.d(TAG, "fetchContacts: ${contacts.size} contacts from ${rowsByContactId.values.sumOf { it.size }} rows")
        return contacts
    }

    fun fetchContactsListResponse(context: Context): String {
        val contacts = fetchContacts(context)
        val array = JSONArray()
        for (contact in contacts) {
            array.put(JSONObject().apply {
                put("id", contact.id)
                put("display_name", contact.displayName)
                put("phone_numbers", JSONArray(contact.phoneNumbers))
                put("photo_available", contact.photoUri != null)
            })
        }
        return JSONObject().apply {
            put("type", "contacts_list_response")
            put("contacts", array)
        }.toString()
    }
}
