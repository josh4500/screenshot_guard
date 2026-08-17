package com.ajibolaak.screenshot_guard

import android.app.Activity
import android.content.Context
import android.provider.MediaStore
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/** Detects user screenshots and optionally prevents screen capture. */
class ScreenshotGuardPlugin :
    FlutterPlugin,
    ActivityAware,
    ScreenshotGuardHostApi {

    private var applicationContext: Context? = null
    private var activity: Activity? = null
    private var contentObserver: ScreenshotContentObserver? = null
    private var lastScreenshotName: String? = null
    private val streamHandler = ScreenshotGuardStreamHandler()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        val messenger = flutterPluginBinding.binaryMessenger
        ScreenshotGuardHostApi.setUp(messenger, this)
        OnScreenshotDetectedStreamHandler.register(messenger, streamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopObserving()
        ScreenshotGuardHostApi.setUp(binding.binaryMessenger, null)
        contentObserver = null
        applicationContext = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun startListening() {
        startObserving()
    }

    override fun stopListening() {
        stopObserving()
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

    private fun startObserving() {
        val context = applicationContext ?: return
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

    private fun stopObserving() {
        val observer = contentObserver ?: return
        applicationContext?.contentResolver?.unregisterContentObserver(observer)
        contentObserver = null
        lastScreenshotName = null
    }
}

private class ScreenshotGuardStreamHandler : OnScreenshotDetectedStreamHandler() {
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
