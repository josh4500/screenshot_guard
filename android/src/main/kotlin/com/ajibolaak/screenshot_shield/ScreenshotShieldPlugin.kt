package com.ajibolaak.screenshot_shield

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.HandlerThread
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.HiddenLifecycleReference
import io.flutter.plugin.common.PluginRegistry

/**
 * Detects user screenshots, optionally prevents capture, and hides the app content
 * from the app switcher. Android 14+ uses `DETECT_SCREEN_CAPTURE`; older devices
 * observe the media store. The app-switcher thumbnail is disabled outright on
 * Android 13+; below that the content is blurred or dimmed while backgrounded.
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
    private var screenRecordingCallback: java.util.function.Consumer<Int>? = null
    private var blurController: ScreenBlurController? = null
    private var observerThread: HandlerThread? = null
    private var listening = false
    // Requested by Dart; re-applied to every activity that attaches.
    private var protectRequested = false
    private var activityStarted = false
    private var backgrounded = false
    private var backgroundBlurEnabled = false
    private val streamHandler = ScreenshotShieldStreamHandler()
    private val screenRecordingStreamHandler = ScreenRecordingStreamHandler()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        val messenger = flutterPluginBinding.binaryMessenger
        ScreenshotShieldHostApi.setUp(messenger, this)
        OnScreenshotDetectedStreamHandler.register(messenger, streamHandler)
        OnScreenRecordingChangedStreamHandler.register(messenger, screenRecordingStreamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopObserving()
        clearBackgroundBlur()
        ScreenshotShieldHostApi.setUp(binding.binaryMessenger, null)
        contentObserver = null
        observerThread?.quitSafely()
        observerThread = null
        blurController = null
        applicationContext = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        // A new activity (config change, cached engine) starts without the secure flag.
        applyProtection()
        applyRecentsScreenshotPolicy()
        lifecycle = (binding.lifecycle as? HiddenLifecycleReference)?.lifecycle
        // No lifecycle exposed (a custom activity embedding): treat the activity as
        // started so screenshot detection can still be registered.
        if (lifecycle == null) {
            activityStarted = true
        }
        // Fires before onPause, so the blur lands before the recents thumbnail.
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
                Lifecycle.Event.ON_DESTROY -> {
                    activityStarted = false
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
        unregisterScreenRecordingCallback()
        clearBackgroundBlur()
        activity = null
        // Without an activity nothing is visible to capture, so stop observing too.
        activityStarted = false
        backgrounded = false
        updateObservation()
    }

    override fun startListening() {
        debugLog("startListening")
        listening = true
        updateObservation()
    }

    override fun stopListening() {
        debugLog("stopListening")
        listening = false
        updateObservation()
    }

    override fun setProtected(protected: Boolean) {
        protectRequested = protected
        applyProtection()
    }

    private fun applyProtection() {
        val window = activity?.window ?: return
        if (protectRequested) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun setKeyboardProtected(enabled: Boolean) {
        // The IME is another app's window and cannot be excluded from captures at
        // all, so this only accepts the call; keep sensitive input inside the app.
    }

    override fun setBackgroundBlur(blurEnabled: Boolean) {
        backgroundBlurEnabled = blurEnabled
        applyRecentsScreenshotPolicy()
        if (backgrounded) {
            applyBackgroundBlur()
        } else {
            clearBackgroundBlur()
        }
    }

    /**
     * Android 13+ can drop the app-switcher thumbnail outright. Unlike FLAG_SECURE it
     * leaves screenshots and their detection alone, and unlike a view blur it also
     * works with Flutter's default SurfaceView, which a parent RenderEffect cannot reach.
     */
    private fun applyRecentsScreenshotPolicy() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        activity?.setRecentsScreenshotEnabled(!backgroundBlurEnabled)
    }

    /** Older versions have no thumbnail switch: cover the content while backgrounded. */
    private fun applyBackgroundBlur() {
        if (!backgroundBlurEnabled || Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
        val currentActivity = activity ?: return
        val controller = blurController
            ?: ScreenBlurController(currentActivity.applicationContext).also { blurController = it }
        controller.apply(currentActivity)
    }

    private fun clearBackgroundBlur() {
        blurController?.clear()
    }

    private fun updateObservation() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            updateScreenCaptureCallback()
        } else {
            updateContentObserver()
        }
        updateScreenRecordingCallback()
    }

    private fun updateScreenCaptureCallback() {
        val currentActivity = activity
        if (listening && activityStarted && currentActivity != null) {
            if (screenCaptureCallback != null) return
            val callback = Activity.ScreenCaptureCallback {
                debugLog("system screen capture callback fired")
                streamHandler.emitScreenshotDetected()
            }
            screenCaptureCallback = callback
            debugLog("registering screen capture callback")
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

    /** Screen recording changes on Android 15+; older versions have no public API. */
    private fun updateScreenRecordingCallback() {
        val currentActivity = activity
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
            listening &&
            activityStarted &&
            currentActivity != null
        ) {
            if (screenRecordingCallback != null) return
            val callback = java.util.function.Consumer<Int> { state ->
                screenRecordingStreamHandler.emitScreenRecordingChanged(
                    state == WindowManager.SCREEN_RECORDING_STATE_VISIBLE,
                )
            }
            screenRecordingCallback = callback
            debugLog("registering screen recording callback")
            val initialState = currentActivity.windowManager.addScreenRecordingCallback(
                currentActivity.mainExecutor,
                callback,
            )
            screenRecordingStreamHandler.emitScreenRecordingChanged(
                initialState == WindowManager.SCREEN_RECORDING_STATE_VISIBLE,
            )
        } else {
            unregisterScreenRecordingCallback()
        }
    }

    private fun unregisterScreenRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            screenRecordingCallback = null
            return
        }
        val callback = screenRecordingCallback ?: return
        activity?.windowManager?.removeScreenRecordingCallback(callback)
        screenRecordingCallback = null
    }

    private fun updateContentObserver() {
        val context = applicationContext ?: return
        if (!listening || !activityStarted) {
            stopContentObserver()
            return
        }
        if (contentObserver != null) return
        // Media store queries are disk I/O: run them off the main thread.
        val thread = observerThread ?: HandlerThread("ScreenshotShieldObserver").also {
            it.start()
            observerThread = it
        }
        contentObserver = ScreenshotContentObserver(context.contentResolver, thread.looper) {
            streamHandler.emitScreenshotDetected()
        }
        debugLog("registering media store content observer")
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
        unregisterScreenRecordingCallback()
        stopContentObserver()
    }

    private companion object {
        const val TAG = "ScreenshotShield"
    }
}

/** Debug logging, off unless enabled with `adb shell setprop log.tag.ScreenshotShield DEBUG`. */
internal fun debugLog(message: String) {
    if (Log.isLoggable("ScreenshotShield", Log.DEBUG)) Log.d("ScreenshotShield", message)
}

private class ScreenshotShieldStreamHandler : OnScreenshotDetectedStreamHandler() {
    private var eventSink: PigeonEventSink<Long>? = null

    override fun onListen(arguments: Any?, sink: PigeonEventSink<Long>) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Safe from any thread: event sinks must be used on the main thread. */
    fun emitScreenshotDetected() {
        mainHandler.post { eventSink?.success(0) }
    }
}

private class ScreenRecordingStreamHandler : OnScreenRecordingChangedStreamHandler() {
    private var eventSink: PigeonEventSink<Boolean>? = null
    private var lastState: Boolean? = null

    override fun onListen(arguments: Any?, sink: PigeonEventSink<Boolean>) {
        eventSink = sink
        lastState?.let { sink.success(it) }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun emitScreenRecordingChanged(isRecording: Boolean) {
        lastState = isRecording
        eventSink?.success(isRecording)
    }
}
