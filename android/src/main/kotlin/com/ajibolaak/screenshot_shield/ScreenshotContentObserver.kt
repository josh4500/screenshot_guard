package com.ajibolaak.screenshot_shield

import android.content.ContentResolver
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log

/**
 * Observes the media store for newly saved screenshots (Android 13 and below; 14+
 * uses the system callback). The delivered URI varies by Android version and OEM,
 * so the most recent image is queried and its name/path tested against screenshot
 * keywords. Only recent images count, and each image is reported once: a single
 * screenshot notifies several times (insert, then metadata and thumbnail updates).
 *
 * Callbacks run on [looper], which should not be the main looper: each change
 * triggers a media store query, which is disk I/O.
 *
 * On Android 10-13 the media store only exposes other apps' images (the screenshot
 * is owned by System UI) to apps holding `READ_EXTERNAL_STORAGE` (10-12) or
 * `READ_MEDIA_IMAGES` (13); without it the query finds nothing and no event fires.
 */
internal class ScreenshotContentObserver(
    private val contentResolver: ContentResolver,
    looper: Looper,
    private val onScreenshot: () -> Unit,
) : ContentObserver(Handler(looper)) {

    private var lastReportedId: Long? = null

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        val screenshot = queryRecentScreenshot() ?: return
        if (screenshot.id == lastReportedId) {
            debugLog("media change ignored (already reported ${screenshot.name})")
            return
        }
        lastReportedId = screenshot.id
        debugLog("screenshot detected: ${screenshot.name}")
        onScreenshot()
    }

    private data class Screenshot(val id: Long, val name: String)

    private fun queryRecentScreenshot(): Screenshot? {
        // RELATIVE_PATH exists from Android 10 (API 29); asking for it on older
        // versions makes the provider reject the whole query.
        val projection = buildList {
            add(MediaStore.Images.Media._ID)
            add(MediaStore.Images.Media.DISPLAY_NAME)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) add(MediaStore.Images.Media.RELATIVE_PATH)
            @Suppress("DEPRECATION")
            add(MediaStore.Images.Media.DATA)
        }.toTypedArray()
        val selection = "${MediaStore.Images.Media.DATE_ADDED} > ?"
        val selectionArgs = arrayOf(((System.currentTimeMillis() / 1000L) - RECENT_WINDOW_S).toString())
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"
        return try {
            contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                sortOrder,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val idIndex = cursor.getColumnIndex(MediaStore.Images.Media._ID)
                if (idIndex < 0) return null
                val id = cursor.getLong(idIndex)
                val displayName = readString(cursor, MediaStore.Images.Media.DISPLAY_NAME) ?: return null
                val relativePath =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        readString(cursor, MediaStore.Images.Media.RELATIVE_PATH)
                    } else {
                        null
                    }
                @Suppress("DEPRECATION")
                val data = readString(cursor, MediaStore.Images.Media.DATA)
                val path = listOfNotNull(relativePath, data).joinToString(" ")
                if (isScreenshot(displayName, path)) Screenshot(id, displayName) else null
            }
        } catch (exception: Exception) {
            // A missing permission, an OEM provider quirk or a column the provider
            // rejects must never crash the host app: treat it as "nothing found".
            Log.w(TAG, "media store query failed", exception)
            null
        }
    }

    private fun readString(cursor: Cursor, column: String): String? {
        val index = cursor.getColumnIndex(column)
        if (index < 0) return null
        return try {
            cursor.getString(index)
        } catch (exception: Exception) {
            debugLog("column $column unreadable: $exception")
            null
        }
    }

    private fun isScreenshot(displayName: String, path: String): Boolean {
        val haystack = "$displayName $path".lowercase()
        return SCREENSHOT_KEYWORDS.any(haystack::contains)
    }

    private companion object {
        const val TAG = "ScreenshotShield"
        const val RECENT_WINDOW_S = 15L
        val SCREENSHOT_KEYWORDS = listOf(
            "screenshot",
            "screen_shot",
            "screencap",
            "screen_capture",
            "screencapture",
        )
    }
}
