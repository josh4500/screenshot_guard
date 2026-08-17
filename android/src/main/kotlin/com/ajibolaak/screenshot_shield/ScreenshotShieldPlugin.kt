package com.ajibolaak.screenshot_shield

import android.app.Activity
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference

/**
 * Detects user screenshots and optionally prevents screen capture.
 *
 * On Android 14+ (API 34) the framework `DETECT_SCREEN_CAPTURE` API is used
 * when the activity is started; on older devices the media store is observed
 * instead.
 */
class ScreenshotShieldPlugin :
    FlutterPlugin,
    ActivityAware,
    ScreenshotShieldHostApi {

    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var lifecycle: Lifecycle? = null
    private var lifecycleObserver: LifecycleEventObserver? = null
    private var contentObserver: ScreenshotContentObserver? = null
    private var screenCaptureCallback: Activity.ScreenCaptureCallback? = null
    private var lastScreenshotName: String? = null
    private var listening = false
    private var activityStarted = false
    private val streamHandler = ScreenshotShieldStreamHandler()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        val messenger = flutterPluginBinding.binaryMessenger
        ScreenshotShieldHostApi.setUp(messenger, this)
        OnScreenshotDetectedStreamHandler.register(messenger, streamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopObserving()
        ScreenshotShieldHostApi.setUp(binding.binaryMessenger, null)
        contentObserver = null
        applicationContext = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        lifecycle = (binding.lifecycle as? HiddenLifecycleReference)?.lifecycle
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    activityStarted = true
                    updateObservation()
                }
                Lifecycle.Event.ON_STOP -> {
                    activityStarted = false
                    updateObservation()
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
        lifecycleObserver?.let { lifecycle?.removeObserver(it) }
        lifecycleObserver = null
        lifecycle = null
        unregisterScreenCaptureCallback()
        activity = null
    }

    override fun startListening() {
        listening = true
        updateObservation()
    }

    override fun stopListening() {
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
                streamHandler.emitScreenshotDetected()
            }
            screenCaptureCallback = callback
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
        if (!listening) {
            stopContentObserver()
            return
        }
        if (contentObserver != null) return
        contentObserver = ScreenshotContentObserver(context.contentResolver) { displayName ->
            if (displayName != lastScreenshotName) {
                lastScreenshotName = displayName
                streamHandler.emitScreenshotDetected()
            }
        }
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
        lastScreenshotName = null
    }

    private fun stopObserving() {
        unregisterScreenCaptureCallback()
        stopContentObserver()
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
