package com.swiftgreen.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Read-only browser over the phone's whole shared storage, for the Mac's Files pane.
 *
 * Plain java.io.File, not MediaStore: MediaStore only indexes photos, video and audio,
 * so it can never show a PDF in Download/ or an arbitrary folder. Needs "All files
 * access" (MANAGE_EXTERNAL_STORAGE) on API 30+. Nothing here writes or deletes.
 *
 * Every path on the wire is relative to shared-storage root ("" = root).
 */
object MediaBrowserStore {

    private fun root(): File = Environment.getExternalStorageDirectory()

    fun hasAccess(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Mac-supplied path → File, or null if it escapes [root]. Trust boundary: without
     * this, "../../data/data/…" from the wire would walk out of shared storage.
     * `root` is a parameter only so the check is reachable from a JVM unit test.
     */
    internal fun resolve(root: File, path: String): File? {
        val base = root.canonicalFile
        val file = File(base, path).canonicalFile
        return if (file == base || file.path.startsWith(base.path + File.separator)) file else null
    }

    fun resolveFile(path: String): File? = resolve(root(), path)?.takeIf { it.isFile }

    /** Always returns a media_list_response — listing, or an explicit error. */
    fun fetchList(context: Context, path: String): String {
        val response = JSONObject().put("type", "media_list_response").put("directory", path)
        val items = JSONArray()
        response.put("items", items)

        if (!hasAccess(context)) return response.put("error", "permission_required").toString()
        val dir = resolve(root(), path)?.takeIf { it.isDirectory }
            ?: return response.put("error", "not_found").toString()

        // ponytail: whole folder in one message, no paging. ~150 bytes/entry, so a
        // 10k-photo Camera folder is ~1.5 MB — inside the Mac's 4 MiB read window.
        // Page it if a real folder ever gets near that.
        val base = root().canonicalFile
        dir.listFiles().orEmpty()
            .filterNot { it.isHidden }
            // Folders A–Z first, then files newest-first (what you want in Camera/Download).
            .sortedWith(compareByDescending<File> { it.isDirectory }
                .thenBy { if (it.isDirectory) it.name.lowercase() else "" }
                .thenByDescending { it.lastModified() })
            .forEach { items.put(itemJson(it, base)) }
        return response.toString()
    }

    /**
     * Name search across the whole of shared storage, for the Mac's search field.
     * Skips hidden entries and the top-level Android/ tree (app-private data, huge,
     * and mostly unreadable anyway). Echoes the query so the Mac can drop stale replies.
     */
    fun search(context: Context, query: String): String {
        val response = JSONObject().put("type", "media_search_response").put("query", query)
        val items = JSONArray()
        response.put("items", items)
        if (!hasAccess(context)) return response.put("error", "permission_required").toString()
        val base = root().canonicalFile
        searchIn(base, query).forEach { items.put(itemJson(it, base)) }
        return response.toString()
    }

    /** `root` is a parameter only so the walk is reachable from a JVM unit test. */
    internal fun searchIn(root: File, query: String, limit: Int = SEARCH_LIMIT): List<File> {
        val q = query.trim().lowercase()
        if (q.length < 2) return emptyList()
        // ponytail: a plain walk, capped at depth 12 and [limit] hits. An index would
        // be instant but has to be kept fresh; add one if searches ever feel slow.
        return root.walkTopDown()
            .maxDepth(12)
            .onEnter { it == root || !(it.isHidden || (it.parentFile == root && it.name == "Android")) }
            .filter { it != root && !it.isHidden && it.name.lowercase().contains(q) }
            .take(limit)
            .toList()
    }

    private fun itemJson(f: File, base: File) = JSONObject().apply {
        put("path", f.canonicalFile.relativeTo(base).path)
        put("filename", f.name)
        put("is_dir", f.isDirectory)
        put("size_bytes", if (f.isDirectory) 0L else f.length())
        put("date_modified_ms", f.lastModified())
        put("mime_type", if (f.isDirectory) "inode/directory" else mimeFor(f))
    }

    private const val SEARCH_LIMIT = 200

    private fun mimeFor(f: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase())
            ?: "application/octet-stream"
}
