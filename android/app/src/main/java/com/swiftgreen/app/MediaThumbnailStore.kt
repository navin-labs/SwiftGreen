package com.swiftgreen.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import androidx.core.graphics.scale

/**
 * 200x200 JPEG previews for image rows in the Files browser (Step 22.5).
 *
 * Images only — video and audio rows stay metadata-only, and nothing here extracts
 * frames or renders waveforms.
 *
 * Aspect ratio: **scale-to-cover then centre-crop**. The source is never distorted;
 * the long edge is trimmed. Chosen because the Mac row tile is square.
 */
object MediaThumbnailStore {
    private const val TAG = "MediaThumbnailStore"
    private const val SIZE = 200
    private const val QUALITY = 80

    /**
     * Largest power-of-two sample size that still leaves both decoded dimensions at or
     * above [target], so the crop never has to upscale.
     *
     * Pure and internal purely so the arithmetic is reachable from a JVM unit test —
     * getting it wrong one step in either direction means either an OOM or a blurry tile.
     */
    internal fun inSampleSizeFor(width: Int, height: Int, target: Int = SIZE): Int {
        var sample = 1
        while (width / (sample * 2) >= target && height / (sample * 2) >= target) {
            sample *= 2
        }
        return sample
    }

    /** Always returns a media_thumbnail_response JSON string — success or explicit error. */
    fun fetchThumbnail(context: Context, path: String): String {
        val uri = MediaBrowserStore.resolveFile(path)?.let { Uri.fromFile(it) }
            ?: return errorResponse(path, "unresolvable_path")

        return try {
            val bitmap = decode(context, uri) ?: return errorResponse(path, "decode_failed")
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, out)
            bitmap.recycle()

            JSONObject().apply {
                put("type", "media_thumbnail_response")
                put("path", path)
                put("thumbnail_base64", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP))
            }.toString()
        } catch (e: Exception) {
            // Corrupt file, or deleted between the listing and this request.
            Log.w(TAG, "thumbnail failed for $path: ${e.message}")
            errorResponse(path, "decode_failed")
        } catch (e: OutOfMemoryError) {
            // Should be unreachable given the sampled decode below, but a pathological
            // image must not take the process down — and the Mac must still get an answer.
            Log.w(TAG, "thumbnail OOM for $path")
            errorResponse(path, "decode_failed")
        }
    }

    /** Never silently drop a request: an unanswered one leaves the Mac waiting out its timeout. */
    private fun errorResponse(path: String, reason: String): String = JSONObject().apply {
        put("type", "media_thumbnail_response")
        put("path", path)
        put("error", reason)
    }.toString()

    private fun decode(context: Context, uri: Uri): Bitmap? {
        // Pass 1 — bounds only, no pixel data. A full-size decode of a 50MP DCIM photo is
        // ~200MB as ARGB_8888 and OOMs before any downsampling could help. Not optional.
        // decodeStream returns null by design in bounds mode — the result lives in
        // `bounds`. Elvis-returning on it rejected every image; only a null stream fails.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val stream = context.contentResolver.openInputStream(uri) ?: return null
        stream.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        // Pass 2 — sampled decode. This is the only decode that allocates pixels.
        val opts = BitmapFactory.Options().apply {
            inSampleSize = inSampleSizeFor(bounds.outWidth, bounds.outHeight)
        }
        val sampled = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        } ?: return null

        // Rotate before cropping: cropping first would take the wrong region of a
        // portrait photo, and BitmapFactory never applies EXIF on its own.
        return centreCrop(applyExifRotation(context, uri, sampled))
    }

    /**
     * Phone cameras store portrait shots as landscape pixels plus an orientation tag.
     * Without this every portrait photo arrives sideways — the default case, not an edge case.
     */
    private fun applyExifRotation(context: Context, uri: Uri, source: Bitmap): Bitmap {
        val orientation = try {
            context.contentResolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } ?: ExifInterface.ORIENTATION_NORMAL
        } catch (e: Exception) {
            ExifInterface.ORIENTATION_NORMAL   // PNG/WebP carry no EXIF; not an error
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return source
        }

        val rotated = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (rotated != source) source.recycle()
        return rotated
    }

    /** Scale so the short edge lands on SIZE, then take the centre SIZE x SIZE square. */
    private fun centreCrop(source: Bitmap): Bitmap {
        val scale = SIZE.toFloat() / minOf(source.width, source.height)
        val scaledW = maxOf(SIZE, (source.width * scale).toInt())
        val scaledH = maxOf(SIZE, (source.height * scale).toInt())

        val scaled = source.scale(scaledW, scaledH, true)
        if (scaled != source) source.recycle()

        val cropped = Bitmap.createBitmap(
            scaled, (scaledW - SIZE) / 2, (scaledH - SIZE) / 2, SIZE, SIZE)
        if (cropped != scaled) scaled.recycle()
        return cropped
    }
}
