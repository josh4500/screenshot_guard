package com.example.screenshot_shield_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode

class MainActivity : FlutterActivity() {
    // TextureView render mode is required for the background blur to reach the
    // Flutter content on Android (the default SurfaceView draws on a separate
    // surface that a parent blur cannot affect).
    override fun getRenderMode(): RenderMode = RenderMode.texture
}
