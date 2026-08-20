## 0.1.2

* Release 0.1.2.

## 0.1.1

* Fix iOS builds: correct the Swift Package library product name to
  `screenshot-shield`.
* Background blur on Android now only applies the `RenderEffect` blur when the
  FlutterView uses `RenderMode.texture` (where it actually reaches Flutter
  content); otherwise a dim overlay is shown. Use `RenderMode.texture` in
  `MainActivity` for a real blur.
* Make the iOS background blur appear reliably in the app switcher by
  committing it immediately when the app enters the background.
* `ScreenshotShieldRouteGuard` now applies `preventCapture` /
  `detectScreenshots` changes immediately instead of only on route changes.
* Add an example app demonstrating detection, captured-image callbacks, and
  background blur.

## 0.1.0

* Detect user screenshots on Android and iOS.
* Android 14+ uses the system `DETECT_SCREEN_CAPTURE` API; older Android
  versions watch the media store for new screenshots.
* iOS reports immediately via the `UIApplicationUserDidTakeScreenshotNotification`
  system notification.
* `ScreenshotShieldScope` provides a shared `ScreenshotShield` to the widget
  tree.
* `ScreenshotShieldRouteGuard` scopes protection to a route: capture prevention
  and screenshot listening are enabled while the route is in view and released
  when another route covers it.
* Optional re-rasterized PNG of the guarded screen passed to
  `onScreenshotDetected`.
* Optional native background blur that hides the app content in the app
  switcher (`setProtection(backgroundBlur: true)`).
* Prevent screen capture on Android via the secure window flag
  (`setProtection(preventCapture: true)`).
