package com.swiftgreen.app

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

data class MacFileBrowserItem(
    val fileId: Int,
    val filename: String,
    val sizeBytes: Long,
    val dateModifiedMs: Long,
    val mimeType: String
)

/** Read-only browser for a directory the Mac user picked (Step 19b). Mac pushes the listing
 * unsolicited; this only stores it and lets the user request a file by id. */
object MacFileBrowserStore {
    private val _directoryName = MutableStateFlow("")
    val directoryName: StateFlow<String> = _directoryName

    private val _items = MutableStateFlow<List<MacFileBrowserItem>>(emptyList())
    val items: StateFlow<List<MacFileBrowserItem>> = _items

    fun replace(json: JSONObject) {
        _directoryName.value = json.optString("directory_name", "")
        val itemsArray = json.optJSONArray("items")
        val list = mutableListOf<MacFileBrowserItem>()
        if (itemsArray != null) {
            for (i in 0 until itemsArray.length()) {
                val obj = itemsArray.optJSONObject(i) ?: continue
                list.add(MacFileBrowserItem(
                    fileId = obj.optInt("file_id", -1),
                    filename = obj.optString("filename", "unknown"),
                    sizeBytes = obj.optLong("size_bytes", 0L),
                    dateModifiedMs = obj.optLong("date_modified_ms", 0L),
                    mimeType = obj.optString("mime_type", "application/octet-stream")
                ))
            }
        }
        _items.value = list
    }

    fun requestFile(fileId: Int) {
        val json = JSONObject().apply {
            put("type", "mac_directory_file_request")
            put("file_id", fileId)
        }
        TunnelManager.sendRawMessage(json.toString())
    }
}
