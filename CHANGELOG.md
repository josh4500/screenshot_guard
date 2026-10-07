## 0.1.8

* iOS: fix two `EXC_BAD_ACCESS` crashes in `ScreenshotShieldSensitiveView`
  reported from a real app. The private canvas layer UIKit builds inside the
  secure text field was cached on its own, but its owner view is only reachable
  through `CALayer.delegate`, which is `unowned(unsafe)`: when UIKit rebuilt the
  canvas - which it does while laying the field out, including during a scene
  snapshot pass, and while Flutter's platform-views controller resets - the cached
  layer outlived its delegate and the next layer operation retained the dead view.
  The canvas is now held as its *view* and re-resolved from the live field on every
  layout pass, the region no longer moves layers when it leaves the window, and the
  canvas view is released a runloop turn later. The whole-window protection had the
  same latent bug - its cached layer was even `weak`, which silently stopped
  re-asserting the nesting - and now follows the same pattern.
* `ScreenshotShieldSensitiveView` no longer shows a copy in normal use: it wraps the
  subtree in a layout-neutral box that paints nothing, creates no platform view and
  rasterises nothing, and only engages while protection is needed.
  `protection: SensitiveProtection.whileCaptured` (the new default) covers screen
  recordings and mirroring plus the app-switcher snapshot;
  `protection: SensitiveProtection.always` keeps it engaged permanently for apps
  that also need foreground screenshots blanked.
* While engaged, a capture shows `captureColor` (black by default) and the user sees
  the subtree as a copy refreshed whenever it repaints, composited over
  `backdropColor` (the ambient scaffold background by default) inside the
  capture-excluded canvas. `placeholderColor` is renamed to `captureColor`. A shield
  that is transparent on screen and black in a capture cannot exist: an excluded
  layer is omitted from the capture rather than replaced by black.
* The region is laid out by a custom render box instead of a `Stack`: the subtree
  receives the constraints the region received, unchanged, the region sizes itself
  from the subtree, the overlay is sized to match it exactly, nothing is clipped,
  and only the subtree is a pointer target or contributes semantics.
* The copy crosses the channel as raw RGBA pixels plus the backdrop colour instead
  of PNG, and a refresh scheduled outside a frame now asks for one, so the last
  state always reaches the native view.
* Reference count `startListening`/`stopListening` in the platform implementation,
  so several consumers no longer cancel each other's detection.

## 0.1.7

* Add `ScreenshotShieldSensitiveView`, an experimental iOS-only widget that
  excludes a single region from screenshots and screen recordings instead of
  blanking the whole window. The subtree is rasterised into a native platform
  view whose layer is nested in its own capture-excluded canvas layer, so the
  rest of the app stays capturable. The region renders from a snapshot, so it is
  only as fresh as the last refresh; `refreshInterval` or the widget's controller
  can refresh it. Relies on undocumented UIKit behaviour and has to be verified
  on a device.
* `ScreenshotShieldSensitiveView` stands down while whole-window prevention is
  active, since the region is blanked by the window anyway: no platform view is
  created and no snapshot is taken. It activates again when the protection is
  released. `ScreenshotShield.preventCaptureActive` exposes that state.
* Add `SecureCanvas`, the shared secure-text-field helper used by the
  whole-window protection and the new region widget.
* iOS: fix a crash when a sensitive region was disposed, for example when
  popping the screen it lives on. Flutter disposes platform views from inside a
  frame submit, so the rasterised layer is no longer moved back out of the
  secure canvas from `deinit`; the view tree is simply released. The transparent
  placeholder and the capture exclusion still behave the same while the region
  is alive.
* iOS: keep a sensitive region interactive. The capture placeholder sat above the
  wrapped subtree and, being opaque, absorbed pointers, so taps, drags, focus and
  text input never reached the widget inside the region. It is now transparent to
  pointers, and the wrapped subtree behaves normally.
* iOS: stop covering a sensitive region with the placeholder before the native
  view holds a snapshot, which showed an opaque rectangle on screen. The child
  stays visible instead (and the region is simply not excluded from captures
  yet), the first snapshot is retried until it lands, and it is re-taken when the
  region is laid out at a new size. `ScreenshotShieldSensitiveViewController`
  captures after the next frame and coalesces bursts of requests, so refreshing
  on a change - a text field's `onChanged`, for example - rasterises what was just
  typed.
* iOS: fix the region's platform view being rebuilt on every snapshot, which
  reset the snapshot state and looped. The placeholder now stays in the tree and
  only changes colour.

## 0.1.6

Not recommended: the sensitive region platform view in this version crashed when
it was disposed, did not receive pointer events, and could cover the region with
an opaque placeholder on screen. Use 0.1.7, which fixes all three.

## 0.1.5

* iOS: fix `preventCapture` not blanking screenshots. The secure text field was
  added as a sibling subview of the window, which protects only the (empty)
  field itself; the app's content layer is now nested inside the field's
  capture-excluded canvas layer, so screenshots and screen recordings of the
  guarded screen come out blank. The content layer is restored exactly when
  protection is released, and the window is now resolved from the
  foreground-active scene. This relies on undocumented UIKit behaviour and can
  break on a future iOS release.
* Reformat the Dart sources with the current formatter so the analysis and
  formatting checks pass again.

## 0.1.4

* Add `ScreenshotShield.onScreenRecordingChanged`, a `Stream<bool>` that emits
  the current screen-recording state (and the current value on subscription)
  while `startListening` is active.
* iOS: report screen recording (and screen mirroring) via
  `UIScreen.capturedDidChangeNotification` / `UIScreen.isCaptured`.
* Android: report screen recording on Android 15 (API 35) and newer via the
  `DETECT_SCREEN_RECORDING` API; older versions never emit. The
  `DETECT_SCREEN_RECORDING` permission is declared.
* Windows and Linux: best-effort screen-recording detection by sampling the
  running process list for well-known recorders (OBS, Bandicam, Camtasia,
  Kazam, Kooha, `wf-recorder`, and others) every two seconds. This is
  heuristic and can both miss unlisted recorders and report an idle recorder.

## 0.1.3

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
* Add `forcePreventCapture` to `ScreenshotShieldRouteGuard` and
  `ScreenshotShieldGuard`. On Android it makes capture prevention win over
  screenshot detection when both are requested (blanking the frame and
  suppressing detection events), instead of the default where detection wins.

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
