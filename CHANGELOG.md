## Unreleased

* Android: fix `onScreenshotDetected` never firing while `preventCapture` is
  enabled. The secure window flag blanks the frame (so the media-store observer
  never fires) and, on Android 14+, the system withholds the screen-capture
  callback for secure windows, so prevention and detection are mutually
  exclusive. The guards now resolve the conflict by letting detection win on
  Android when both are requested, and the guarded screen is re-rasterized into
  a shareable image instead. The system still shows a notice when detection
  fires on Android 14+.
* Android: make media-store screenshot detection on Android 13 and below more
  reliable. The observer now queries the most recently added image (filtered to
  the last 15 seconds) instead of trusting the URI delivered by the media store,
  which varies by Android version and OEM, and it no longer crashes when the
  media query is blocked by permissions.
* Android: declare `READ_EXTERNAL_STORAGE` (scoped to API 28 and below) so
  detection can query the media store on Android 9 and older; the host app must
  still request it at runtime.
* Add `ScreenshotShieldGuard`, a non-route guard that activates while the
  widget is mounted and its `active` flag is `true`, for screens not managed
  by a `Navigator` with a `RouteObserver`.

## 0.1.2

* Add Windows and Linux platform support. The Dart widgets work on desktop,
  but screenshot detection and prevention are unavailable there (no OS APIs).
  On Windows, `setProtection(backgroundBlur: true)` cloaks the window from
  alt-tab and the taskbar preview while it is inactive or minimized.
* iOS: `preventCapture` now blanks the app-switcher preview via a hidden
  secure text field. User screenshots themselves cannot be blanked on iOS,
  but detection and the shareable-image capture still work.
* iOS: the background blur is applied on `willResignActive` so it reliably
  appears in the app switcher.
* Android: the background blur now triggers on the user-leave hint (before
  `onPause`) and forces a frame commit so the recents thumbnail includes it.
* Add a GitHub Actions workflow that publishes to pub.dev with configurable
  major/minor/patch version bumps.

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
