package com.ajibolaak.screenshot_guard

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
 * Android stores screenshots in the `DCIM/Screenshots` directory, so any
 * inserted image whose display name or relative path contains "screenshot" is
 * reported to [onScreenshot].
 */
internal class ScreenshotContentObserver(
    private val contentResolver: ContentResolver,
    private val onScreenshot: (String) -> Unit,
) : ContentObserver(Handler(Looper.getMainLooper())) {

    override fun onChange(selfChange: Boolean, uri: Uri?) {
        super.onChange(selfChange, uri)
        val screenshotUri = uri ?: return
        queryScreenshots(screenshotUri).lastOrNull()?.let(onScreenshot)
    }

    private fun queryScreenshots(uri: Uri): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            queryScreenshotNames(uri)
        } else {
            queryScreenshotPaths(uri)
        }
    }

    private fun queryScreenshotNames(uri: Uri): List<String> {
        val projection = arrayOf(
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
        )
        val screenshots = mutableListOf<String>()
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val displayNameIndex = cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
            val relativePathIndex = cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
            while (cursor.moveToNext()) {
                val displayName = cursor.getString(displayNameIndex)
                val relativePath =
                    if (relativePathIndex >= 0) cursor.getString(relativePathIndex) else null
                if (displayName.contains("screenshot", ignoreCase = true) ||
                    relativePath?.contains("screenshot", ignoreCase = true) == true
                ) {
                    screenshots.add(displayName)
                }
            }
        }
        return screenshots
    }

    private fun queryScreenshotPaths(uri: Uri): List<String> {
        val projection = arrayOf(MediaStore.Images.Media.DATA)
        val screenshots = mutableListOf<String>()
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val dataIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
            while (cursor.moveToNext()) {
                val data = cursor.getString(dataIndex)
                if (data.contains("screenshot", ignoreCase = true)) {
                    screenshots.add(data.substringAfterLast('/'))
                }
            }
        }
        return screenshots
    }
}
