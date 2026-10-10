package com.ajibolaak.screenshot_shield

import android.content.ContentResolver
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log

/**
 * Observes the media store for newly saved screenshots. The delivered URI varies by
 * Android version and OEM, so the most recent image is queried and its name/path
 * tested against screenshot keywords; only recent images count, and events are
 * debounced because one screenshot can notify several times.
 */
internal class ScreenshotContentObserver(
    private val contentResolver: ContentResolver,
    private val onScreenshot: () -> Unit,
) : ContentObserver(Handler(Looper.getMainLooper())) {

    private var lastScreenshotTime = 0L

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        val now = System.currentTimeMillis()
        if (now - lastScreenshotTime < DEBOUNCE_MS) {
            Log.d(TAG, "media change ignored (debounced)")
            return
        }
        val name = queryRecentScreenshotName() ?: return
        Log.d(TAG, "screenshot detected: $name")
        lastScreenshotTime = now
        onScreenshot()
    }

    private fun queryRecentScreenshotName(): String? {
        val projection = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATA,
        )
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
                val displayName = readString(cursor, MediaStore.Images.Media.DISPLAY_NAME) ?: return null
                val relativePath = readString(cursor, MediaStore.Images.Media.RELATIVE_PATH)
                val data = readString(cursor, MediaStore.Images.Media.DATA)
                val path = listOfNotNull(relativePath, data).joinToString(" ")
                if (isScreenshot(displayName, path)) displayName else null
            }
        } catch (exception: SecurityException) {
            Log.w(TAG, "media query blocked", exception)
            null
        }
    }

    private fun readString(cursor: android.database.Cursor, column: String): String? {
        val index = cursor.getColumnIndex(column)
        if (index < 0) return null
        return try {
            cursor.getString(index)
        } catch (exception: SecurityException) {
            Log.w(TAG, "column $column blocked", exception)
            null
        }
    }

    private fun isScreenshot(displayName: String, path: String): Boolean {
        val haystack = "$displayName $path".lowercase()
        return SCREENSHOT_KEYWORDS.any(haystack::contains)
    }

    private companion object {
        const val TAG = "ScreenshotShield"
        const val DEBOUNCE_MS = 1_000L
        const val RECENT_WINDOW_S = 15L
        val SCREENSHOT_KEYWORDS = listOf(
            "screenshot",
            "screen_shot",
            "screencap",
            "screen_capture",
            "screenshots",
            "screencapture",
        )
    }
}
