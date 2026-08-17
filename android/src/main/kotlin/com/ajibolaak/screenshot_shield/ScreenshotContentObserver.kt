package com.ajibolaak.screenshot_shield

import android.content.ContentResolver
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore

/**
 * Observes the media store for newly saved screenshots.
 *
 * Android stores screenshots under a path whose name or directory contains a
 * screenshot-like keyword (e.g. `DCIM/Screenshots/Screenshot_2024-...`), so any
 * recently inserted image matching those keywords is reported to [onScreenshot].
 *
 * The media store can notify the observer several times for a single screenshot
 * write, so events are debounced: reports are suppressed for [DEBOUNCE_MS]
 * after a screenshot has already been classified.
 */
internal class ScreenshotContentObserver(
    private val contentResolver: ContentResolver,
    private val onScreenshot: () -> Unit,
) : ContentObserver(Handler(Looper.getMainLooper())) {

    private var lastScreenshotName: String? = null
    private var lastScreenshotTime: Long = 0

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        val screenshotUri = uri ?: return
        val now = System.currentTimeMillis()
        if (now - lastScreenshotTime < DEBOUNCE_MS) return
        val name = queryScreenshotName(screenshotUri) ?: return
        if (name == lastScreenshotName) return
        lastScreenshotName = name
        lastScreenshotTime = now
        onScreenshot()
    }

    private fun queryScreenshotName(uri: Uri): String? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            queryScreenshotNameQ(uri)
        } else {
            queryScreenshotNamePreQ(uri)
        }
    }

    private fun queryScreenshotNameQ(uri: Uri): String? {
        val projection = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
        )
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val displayNameIndex = cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
            val relativePathIndex = cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(displayNameIndex) ?: continue
                val relativePath =
                    if (relativePathIndex >= 0) cursor.getString(relativePathIndex) else null
                if (isScreenshot(displayName, relativePath.orEmpty())) {
                    return displayName
                }
            }
        }
        return null
    }

    private fun queryScreenshotNamePreQ(uri: Uri): String? {
        val projection = arrayOf(MediaStore.Images.Media.DATA)
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val dataIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
            while (cursor.moveToNext()) {
                val data = cursor.getString(dataIndex) ?: continue
                if (isScreenshot(data.substringAfterLast('/'), data)) {
                    return data.substringAfterLast('/')
                }
            }
        }
        return null
    }

    private fun isScreenshot(displayName: String, path: String): Boolean {
        val haystack = "$displayName $path".lowercase()
        return SCREENSHOT_KEYWORDS.any(haystack::contains)
    }

    private companion object {
        val SCREENSHOT_KEYWORDS = listOf(
            "screenshot",
            "screen_shot",
            "screencap",
            "screen_capture",
            "screenshots",
            "screencapture",
        )

        const val DEBOUNCE_MS = 1_000L
    }
}
