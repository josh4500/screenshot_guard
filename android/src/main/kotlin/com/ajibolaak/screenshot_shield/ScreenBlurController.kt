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
 * Hides an [Activity]'s content while backgrounded, on Android 12 and below (13+
 * disables the app-switcher thumbnail instead). A [RenderEffect] blur (Android 12)
 * reaches only the view hierarchy, so it is applied only when the window has a
 * [TextureView]; Flutter's default SurfaceView draws on a separate surface a parent
 * blur cannot touch and gets an opaque cover instead.
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
            setBackgroundColor(Color.BLACK)
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
