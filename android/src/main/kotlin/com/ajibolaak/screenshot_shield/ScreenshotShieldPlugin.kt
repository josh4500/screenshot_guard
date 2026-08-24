package com.ajibolaak.screenshot_shield

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference
import io.flutter.plugin.common.PluginRegistry

/**
 * Detects user screenshots, optionally prevents screen capture, and can blur
 * the app content while the app is in the background.
 *
 * On Android 14+ (API 34) the framework `DETECT_SCREEN_CAPTURE` API is used
 * when the activity is started; on older devices the media store is observed
 * while the activity is started. Background blur uses `RenderEffect` on
 * Android 12+ and a dim overlay below that.
 */
class ScreenshotShieldPlugin :
    FlutterPlugin,
    ActivityAware,
    ScreenshotShieldHostApi {

    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var lifecycle: Lifecycle? = null
    private var lifecycleObserver: LifecycleEventObserver? = null
    private var userLeaveHintListener: PluginRegistry.UserLeaveHintListener? = null
    private var contentObserver: ScreenshotContentObserver? = null
    private var screenCaptureCallback: Activity.ScreenCaptureCallback? = null
    private var backgroundDimView: View? = null
    private var listening = false
    private var activityStarted = false
    private var backgrounded = false
    private var backgroundBlurEnabled = false
    private val streamHandler = ScreenshotShieldStreamHandler()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        val messenger = flutterPluginBinding.binaryMessenger
        ScreenshotShieldHostApi.setUp(messenger, this)
        OnScreenshotDetectedStreamHandler.register(messenger, streamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopObserving()
        clearBackgroundBlur()
        ScreenshotShieldHostApi.setUp(binding.binaryMessenger, null)
        contentObserver = null
        applicationContext = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        lifecycle = (binding.lifecycle as? HiddenLifecycleReference)?.lifecycle
        // If the lifecycle is unavailable (e.g. a custom activity embedding that
        // does not expose one), fall back to treating the activity as started so
        // screenshot detection can still be registered.
        if (lifecycle == null) {
            activityStarted = true
        }
        // Fires before onPause when the user leaves the app (home/recents/back),
        // so the blur is applied before the recents thumbnail is captured.
        val userLeaveHintListener = PluginRegistry.UserLeaveHintListener {
            applyBackgroundBlur()
        }
        this.userLeaveHintListener = userLeaveHintListener
        binding.addOnUserLeaveHintListener(userLeaveHintListener)
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    activityStarted = true
                    clearBackgroundBlur()
                    updateObservation()
                }
                Lifecycle.Event.ON_STOP -> {
                    activityStarted = false
                    applyBackgroundBlur()
                    updateObservation()
                }
                Lifecycle.Event.ON_PAUSE -> {
                    backgrounded = true
                    applyBackgroundBlur()
                }
                Lifecycle.Event.ON_RESUME -> {
                    backgrounded = false
                    clearBackgroundBlur()
                }
                else -> {}
            }
        }
        lifecycleObserver = observer
        lifecycle?.addObserver(observer)
        updateObservation()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        userLeaveHintListener?.let { activityBinding?.removeOnUserLeaveHintListener(it) }
        userLeaveHintListener = null
        activityBinding = null
        lifecycleObserver?.let { lifecycle?.removeObserver(it) }
        lifecycleObserver = null
        lifecycle = null
        unregisterScreenCaptureCallback()
        clearBackgroundBlur()
        activity = null
    }

    override fun startListening() {
        Log.d(TAG, "startListening")
        listening = true
        updateObservation()
    }

    override fun stopListening() {
        Log.d(TAG, "stopListening")
        listening = false
        updateObservation()
    }

    override fun setProtected(protected: Boolean) {
        val window = activity?.window ?: return
        if (protected) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun setBackgroundBlur(blurEnabled: Boolean) {
        backgroundBlurEnabled = blurEnabled
        if (backgrounded) {
            applyBackgroundBlur()
        } else {
            clearBackgroundBlur()
        }
    }

    private fun applyBackgroundBlur() {
        if (!backgroundBlurEnabled) return
        val decorView = activity?.window?.decorView as? ViewGroup ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            decorView.setRenderEffect(
                RenderEffect.createBlurEffect(
                    BLUR_RADIUS,
                    BLUR_RADIUS,
                    Shader.TileMode.MIRROR,
                ),
            )
        } else {
            val dimView = backgroundDimView ?: View(applicationContext).apply {
                setBackgroundColor(Color.argb(217, 0, 0, 0))
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
            }.also { backgroundDimView = it }
            if (dimView.parent == null) {
                decorView.addView(dimView)
                decorView.requestLayout()
            }
        }
        // Commit the blur into the next frame before the recents thumbnail is
        // captured (the Android analog of the iOS CATransaction.flush).
        decorView.invalidate()
    }

    private fun clearBackgroundBlur() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity?.window?.decorView?.setRenderEffect(null)
        } else {
            val dimView = backgroundDimView ?: return
            (dimView.parent as? ViewGroup)?.removeView(dimView)
            backgroundDimView = null
        }
    }

    private fun updateObservation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            updateScreenCaptureCallback()
        } else {
            updateContentObserver()
        }
    }

    private fun updateScreenCaptureCallback() {
        val currentActivity = activity
        if (listening && activityStarted && currentActivity != null) {
            if (screenCaptureCallback != null) return
            val callback = Activity.ScreenCaptureCallback {
                Log.d(TAG, "system screen capture callback fired")
                streamHandler.emitScreenshotDetected()
            }
            screenCaptureCallback = callback
            Log.d(TAG, "registering screen capture callback")
            currentActivity.registerScreenCaptureCallback(currentActivity.mainExecutor, callback)
        } else {
            unregisterScreenCaptureCallback()
        }
    }

    private fun unregisterScreenCaptureCallback() {
        val callback = screenCaptureCallback ?: return
        activity?.unregisterScreenCaptureCallback(callback)
        screenCaptureCallback = null
    }

    private fun updateContentObserver() {
        val context = applicationContext ?: return
        if (!listening || !activityStarted) {
            stopContentObserver()
            return
        }
        if (contentObserver != null) return
        contentObserver = ScreenshotContentObserver(context.contentResolver) {
            streamHandler.emitScreenshotDetected()
        }
        Log.d(TAG, "registering media store content observer")
        context.contentResolver.registerContentObserver(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true,
            contentObserver!!,
        )
    }

    private fun stopContentObserver() {
        val observer = contentObserver ?: return
        applicationContext?.contentResolver?.unregisterContentObserver(observer)
        contentObserver = null
    }

    private fun stopObserving() {
        unregisterScreenCaptureCallback()
        stopContentObserver()
    }

    private companion object {
        const val TAG = "ScreenshotShield"
        const val BLUR_RADIUS = 24f
    }
}

private class ScreenshotShieldStreamHandler : OnScreenshotDetectedStreamHandler() {
    private var eventSink: PigeonEventSink<Long>? = null

    override fun onListen(arguments: Any?, sink: PigeonEventSink<Long>) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun emitScreenshotDetected() {
        eventSink?.success(0)
    }
}
