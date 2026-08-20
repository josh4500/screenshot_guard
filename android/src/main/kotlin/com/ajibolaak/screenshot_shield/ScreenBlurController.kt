package com.ajibolaak.screenshot_shield

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout

/**
 * Hides the content of an [Activity] while it is backgrounded.
 *
 * A true blur via [RenderEffect] (Android 12+) only affects content that is
 * part of the view hierarchy. Flutter renders to a [SurfaceView] by default,
 * which draws on a separate surface that a parent blur cannot reach, so the
 * blur is only applied when the window contains a [TextureView] (e.g. a
 * FlutterActivity using `RenderMode.texture`). Otherwise a dim overlay is shown.
 */
internal class ScreenBlurController(private val context: Context) {

    private var dimView: View? = null
    private var blurredDecorView: View? = null

    fun apply(activity: Activity) {
        val decorView = activity.window.decorView
        val canBlurInPlace =
            decorView is ViewGroup &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                containsTextureView(decorView)
        if (canBlurInPlace) {
            decorView.setRenderEffect(
                RenderEffect.createBlurEffect(
                    BLUR_RADIUS,
                    BLUR_RADIUS,
                    Shader.TileMode.MIRROR,
                ),
            )
            blurredDecorView = decorView
        } else {
            showDimOverlay(decorView)
        }
    }

    fun clear() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            blurredDecorView?.setRenderEffect(null)
        }
        blurredDecorView = null
        dimView?.let { (it.parent as? ViewGroup)?.removeView(it) }
        dimView = null
    }

    private fun showDimOverlay(decorView: View) {
        if (decorView !is ViewGroup) return
        val view = dimView ?: View(context).apply {
            setBackgroundColor(Color.argb(217, 0, 0, 0))
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }.also { dimView = it }
        if (view.parent == null) {
            decorView.addView(view)
        }
    }

    private fun containsTextureView(view: View): Boolean {
        if (view is TextureView) return true
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                if (containsTextureView(view.getChildAt(i))) return true
            }
        }
        return false
    }

    private companion object {
        const val BLUR_RADIUS = 24f
    }
}
