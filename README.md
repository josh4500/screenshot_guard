# screenshot_shield

Detects user screenshots and screen recording, and optionally prevents screen
capture, on Android and iOS.

## Platform behaviour

Screenshot and screen-recording detection are best-effort and
platform-specific:

| Capability | Android | iOS |
|---|---|---|
| Screenshot detection | Yes - Android 14+ uses the system `DETECT_SCREEN_CAPTURE` API; older versions watch the media store and report shortly after a screenshot is saved | Yes - reports immediately via the `UIApplicationUserDidTakeScreenshotNotification` system notification |
| Screen-recording detection (`onScreenRecordingChanged`) | Yes - Android 15+ (API 35) reports whether the app's activities are visible in a screen recording via `DETECT_SCREEN_RECORDING`; older versions never emit | Yes - reflects `UIScreen.isCaptured`, which is also `true` while the screen is mirrored (for example via AirPlay); the simulator always reports not recording |
| Prevent screen capture (`setProtection(preventCapture: true)`) | Yes - adds the secure window flag so the captured frame is blank | Yes - the app's content layer is nested inside a secure text field's capture-excluded layer, so screenshots come out blank (undocumented UIKit behaviour, see [iOS configuration](#ios-configuration)) |
| Region protection (`ScreenshotShieldSensitiveView`) | No | Yes - one region at a time is kept out of captures by hosting a Flutter-rendered copy of it in a native view whose layer is nested in a capture-excluded canvas (undocumented UIKit behaviour); by default only while the screen is recorded/mirrored or the app is backgrounded, and permanently with `protection: always` |
| Screenshot events while protected | No - the secure window flag blanks the frame (it is never saved, so the media-store observer never fires) and, on Android 14+, the system withholds the capture callback for secure windows. The guards resolve this by dropping prevention when detection is also requested, so the event fires and the guarded screen is re-rasterized into a shareable image | Yes - the detection notification still fires, and the guarded screen can still be re-rasterized into a shareable image |
| Runtime permission | `DETECT_SCREEN_CAPTURE` (auto-granted, Android 14+ only) and `DETECT_SCREEN_RECORDING` (auto-granted, Android 15+ only); on Android 9 (API 28) and below, screenshot detection reads the media store and needs `READ_EXTERNAL_STORAGE`, which the host app must request at runtime | Not required |

On Android, `preventCapture` (the secure window flag) and screenshot detection
are mutually exclusive: the blanked frame is never saved and the system withholds
the capture callback for secure windows, so no event fires while prevention is
on. The guards handle this automatically by dropping prevention when
`detectScreenshots` is also enabled on Android. To keep the blanked frame
instead, set `forcePreventCapture: true` on the guard (accepting that
`onScreenshotDetected` will not fire). On Android 14+, the system shows a notice
whenever the screenshot detection API fires. Screenshots taken via ADB or
instrumentation tests are not detected by either path.

### Desktop (Windows, Linux)

The package registers on Windows and Linux so the widget layer works there,
but desktop has no OS screenshot-detection or screenshot-prevention APIs, so
`onScreenshotDetected` never fires, `startListening` is a no-op for
screenshots, and `preventCapture` cannot blank the capture. Screen-recording
detection is available as a best-effort heuristic: while `startListening` is
active the running process list is sampled every two seconds and
`onScreenRecordingChanged` emits `true` when a well-known screen recorder (for
example OBS, Bandicam, Camtasia, Kazam, Kooha, `wf-recorder`) is found. This is
intentionally conservative but still unreliable - a recorder that is open but
idle is reported as recording, and an unlisted or sandboxed recorder is missed.
What does apply:

- On **Windows**, enabling `setProtection(backgroundBlur: true)` cloaks the
  window when it is deactivated or minimized, hiding it from alt-tab and the
  taskbar preview.
- On **Linux**, detection and protection are unavailable (no standard
  mechanism); the Dart widgets still work.

## Usage

Provide a `ScreenshotShield` to the tree with `ScreenshotShieldScope`, then
wrap the screen you want to guard with a `ScreenshotShieldRouteGuard`. The
guard observes the route it lives on: protection and screenshot listening are
enabled while the route is in view and released automatically when another
route covers it.

```dart
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

// Wrap your app with the scope and register the observer with the navigator:
ScreenshotShieldScope(
  shield: ScreenshotShield(),
  routeObserver: routeObserver,
  child: MaterialApp(
    navigatorObservers: [routeObserver],
    home: const HomeScreen(),
  ),
);

// Inside a guarded screen:
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenshotShieldRouteGuard(
      onScreenshotDetected: (image) {
        // `image` is a PNG of the guarded screen (null if capture failed).
        // Present it to the user, e.g. via `share_plus`.
      },
      child: const Scaffold(
        body: Center(child: Text('Guarded')),
      ),
    );
  }
}
```

The guard reads its `ScreenshotShield` from the nearest `ScreenshotShieldScope`
with `ScreenshotShieldScope.of(context)`. Configure the guard with a
`preventCapture` flag (Android only, default `true`), a `detectScreenshots`
flag (default `true`), a `forcePreventCapture` flag (default `false`) that
makes blanking win over detection on Android, a `captureOnScreenshot` flag
(default `true`), and an optional `onScreenshotDetected` callback. With
`captureOnScreenshot` the guarded subtree is re-rasterized into a PNG on each
screenshot, so the app can show exactly what was on screen even when the OS
frame is blanked or unavailable.

For screens that are not managed by a `Navigator` (custom tabs, embedded
views, overlays), use `ScreenshotShieldGuard` instead of the route guard. It
provides the same flags and callback but activates while the widget is mounted
and its `active` flag is `true`, without needing a `RouteObserver`.

### Detect-and-notify mode

By default `preventCapture` blanks the captured frame on Android and iOS, so the
user sees a black screenshot. To follow a Snapchat-style flow instead - let the
screenshot succeed and react in `onScreenshotDetected` (for example by sending
the captured image or notifying a peer) - set `preventCapture: false`.

### Which protection for which situation

| Mechanism | Covers | Granularity | What the user sees |
|---|---|---|---|
| `setProtection(preventCapture: true)` / `ScreenshotShieldRouteGuard` | screenshots, screen recordings, app-switcher snapshot | the whole window | the app itself, untouched |
| `ScreenshotShieldSensitiveView` (`whileRecording`) | screen recordings and mirroring | one subtree, **iOS only** | the original widget, untouched |
| `ScreenshotShieldSensitiveView` (`whileCaptured`, the default) | screen recordings and mirroring, app-switcher snapshot | one subtree, **iOS only** | the original widget, untouched |
| `ScreenshotShieldSensitiveView(protection: always)` | the above plus foreground screenshots | one subtree, **iOS only** | a continuously refreshed copy of the subtree |

Use a guard when a whole screen must be blank in a capture, and a sensitive view
when one part of the screen must be blank while the rest stays capturable.

**Why a foreground screenshot cannot be blanked per region:** iOS excludes a
*native view's own layer* from captures, and Flutter renders every widget into one
surface (`PlatformViewLayer` is the only composited native view; pictures,
textures and filters all land in the same Flutter drawable). Nesting live Flutter
content in the excluded layer is therefore impossible, and an excluded layer is
*omitted* from the capture rather than replaced by black - so a "shield" that is
transparent on screen would simply reveal the live widget to the capture as well.
The only way to blank a region in a screenshot is to display something native in
it: a rasterised copy, which is what `protection: always` does.

### Region protection (iOS)

```dart
ScreenshotShieldSensitiveView(
  // What a capture shows where the region is. Defaults to black.
  captureColor: Colors.black,
  // What the user sees behind the copy, where the child is transparent
  // (the gaps between rounded cells, for example).
  backdropColor: Theme.of(context).scaffoldBackgroundColor,
  child: Text('Account number: 1234'),
)
```

By default the widget is effectively not there: it wraps `child` in a
layout-neutral box that paints nothing, creates no platform view and rasterises
nothing, and the original widget is what is laid out, painted and interactive. It
takes over only while protection is needed:

- while the screen is being recorded or mirrored
  (`ScreenshotShield.onScreenRecordingChanged`, i.e. `UIScreen.isCaptured` on iOS -
  also `true` while mirroring, such as AirPlay - and the Android 15 callback). The
  current state is also available as `ScreenshotShield.isScreenRecording`, which is
  what lets a region that appears during a recording engage immediately instead of
  waiting for the next change, and
- while the app is not in the foreground, which is what keeps the region out of the
  app-switcher snapshot (set `protection: SensitiveProtection.whileRecording` to drop
  this case and protect recordings only).

While it is engaged, the subtree stays live and interactive - taps, drags, focus and
text input reach `child` as usual - and a platform view whose layer is nested in its
own capture-excluded canvas covers it. The user sees the subtree as a copy that is
refreshed **whenever the subtree repaints**, at most once per frame, so typing, a
blinking caret, animations and size changes all track; a capture gets no pixels from
the region and instead shows `captureColor`. Nothing is painted over the region
before the first copy lands, so it shows the live subtree and is simply not excluded
from captures yet. `ScreenshotShieldSensitiveViewController.refresh()` refreshes on
demand.

`captureColor` (black by default) is painted in Flutter behind the excluded canvas,
which is why the user never sees it. `backdropColor` (the ambient scaffold
background by default) is painted *inside* the canvas behind the copy, so the
transparent parts of the child look right on screen while a capture still sees
`captureColor`.

`protection: SensitiveProtection.always` keeps the region engaged permanently, in
exchange for also blanking foreground screenshots. While it is on, these costs
apply; with the default they only apply while a capture is happening:

- The region is a native view, so it composites above the Flutter content: a
  Flutter overlay that covers the region (a selection toolbar, a dialog, a tooltip)
  draws behind it.
- Rasterising costs a GPU readback per refresh, so a region containing something
  that repaints continuously (video, a large animation) keeps the CPU busy. Cap it
  with `refreshInterval`, or use whole-window protection for content like that.
- The copy is one frame behind.

Layout is deliberately neutral: the region lays the subtree out with the constraints
it received, unchanged, sizes itself from the subtree, sizes the overlay to match it
exactly, clips nothing, and only the subtree is a pointer target or contributes
semantics. Wrapping a widget in it does not change how that widget lays out.

It is iOS only, stands down while whole-window prevention is active (no platform
view is created and nothing is rasterised), and derives from the same undocumented
UIKit behaviour as the whole-window protection, so verify it on a real device.
`xcrun simctl io screenshot` cannot show capture exclusion at all.

Note that Flutter's own `SensitiveContent` widget is *not* an alternative here:
any `SensitiveContent(sensitive:)` in the tree obscures the **entire screen**
during media projection, and only on Android 15+.

### Background privacy

Screenshot detection only runs while the app is in the foreground, so a user
in the background or the app switcher can take screenshots freely. To hide the
app's content in the app switcher, enable the native background blur:

```dart
final shield = ScreenshotShield();
await shield.setProtection(backgroundBlur: true);
```

On iOS the key window is covered with a `UIVisualEffectView` blur when the app
enters the background. On Android 12+ the window is blurred with
`RenderEffect`; on older Android versions a dim overlay is shown because no
public blur API exists. The feature is disabled by default.

Note that if `preventCapture` (`FLAG_SECURE`) is also enabled, the app-switcher
snapshot stays blank and wins over the blur.

For lower-level control you can drive `ScreenshotShield` directly:

```dart
final shield = ScreenshotShield();
shield.onScreenshotDetected.listen((_) {
  // Show your own shareable image here.
});

// While this screen is visible:
await shield.startListening();
await shield.setProtection(preventCapture: true); // Blanks the captured frame.

// When leaving the screen:
await shield.stopListening();
```

When a screenshot is detected, present the user with your own shareable image
(e.g. via `share_plus`) instead of the captured frame. Note that on Android
`preventCapture` and screenshot detection cannot both be enabled: the secure
window flag blanks the frame (never saved) and the system withholds the
capture callback for secure windows, so no event fires while prevention is on.
To get detection events on Android, keep `preventCapture` disabled; to blank
the frame, accept that no events will fire. On iOS the screenshot is blanked
and the detection event still fires, and the guarded screen can be
re-rasterized into a shareable image.

### Screen-recording detection

While `startListening` is active you can observe whether the app is currently
visible in a screen recording:

```dart
final shield = ScreenshotShield();
shield.onScreenRecordingChanged.listen((isRecording) {
  if (isRecording) {
    // The app is being recorded.
  }
});

await shield.startListening();
```

The stream emits the current state when it is first listened to and then on
every change. Support is platform-specific: iOS reports `UIScreen.isCaptured`
(which is also `true` while the screen is mirrored, for example via AirPlay),
Android reports recording visibility on Android 15 (API 35) and newer, and
Windows and Linux use a best-effort process-name heuristic (see below). Screen
recording does not affect `onScreenshotDetected`.

## iOS configuration

The iOS implementation observes `UIApplicationUserDidTakeScreenshotNotification`
and requires no permissions or `Info.plist` entries. Screenshot detection fires
while the app is in the foreground; screenshots taken while the app is
backgrounded (e.g. from the app switcher) are not reported.

Screen-recording detection observes `UIScreen.capturedDidChangeNotification`
and reads `UIScreen.isCaptured`, so it also reports screen mirroring (for
example AirPlay). The simulator always reports `isCaptured == true`, so it is
treated as not recording.

### How `preventCapture` works on iOS

iOS has no public API for blocking screenshots. The implementation relies on a
`UITextField` with `isSecureTextEntry` set to `true`: UIKit renders such a field
through a private, capture-excluded canvas layer. That layer only protects its
own content, so the app's content layer is nested inside it. Merely adding the
secure field next to the app content - as this package did before 0.1.5 -
protects nothing but the empty field itself, which is why screenshots stayed
visible.

The field is sized to the window and inserted at the window's origin so the
canvas layer's coordinate space matches the window's; the content layer keeps
its frame across the move. While protection is enabled the guarded screen comes
out blank in screenshots, screen recordings and the app-switcher snapshot, and
`onScreenshotDetected` still fires so the guarded screen can be re-rasterized
into a shareable image.

This depends on undocumented UIKit behaviour, so a future iOS release can break
it, and it may be judged risky in App Store review. Verify it on every iOS
version you support, and keep `preventCapture: false` (detect-and-notify mode)
as the fallback: [`captureOnScreenshot`](#detect-and-notify-mode) still hands
you a PNG of the guarded screen even when the OS frame is not blanked.

Note that `xcrun simctl io screenshot` (and any tool that reads the simulator
framebuffer directly) is never masked - it will show the app even when
protection is working, so it cannot be used to test this. Check on a device, or
with the simulator's own screenshot service
(`Device > Trigger Screenshot`).

## Example app

A runnable example lives in `example/`. It demonstrates detection, the
captured-image callback, and the background blur, with toggles for each
feature:

```sh
cd example
flutter run
```

## Install

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  screenshot_shield: ^0.1.0
```
