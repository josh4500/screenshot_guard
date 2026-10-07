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
| Region shielding (`ScreenshotShieldSensitiveRegion`) | Yes - hides the region while the app is not in the foreground, and while recording on Android 15+ | Yes - hides the region while recording or mirroring, and while the app is not in the foreground |
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

| Mechanism | Covers | Granularity | Rendering |
|---|---|---|---|
| `setProtection(preventCapture: true)` / `ScreenshotShieldRouteGuard` | screenshots, screen recordings, app-switcher snapshot | the whole window | untouched |
| `ScreenshotShieldSensitiveRegion` | screen recordings (iOS, Android 15+) and the app-switcher snapshot (all platforms) | one subtree | untouched - the widget stays live |
| `ScreenshotShieldSensitiveView` (deprecated) | screenshots, screen recordings, app-switcher snapshot | one subtree, **iOS only** | replaced by a bitmap while it is shown |

So: use a guard on a screen that must come out blank in a screenshot, and a
sensitive region to keep one part of the screen out of recordings and the app
switcher while everything else stays live and shareable.

**Why a screenshot cannot be covered per region:** iOS excludes a *native view's*
own layer from captures, and Flutter renders every widget into one surface
(`PlatformViewLayer` is the only composited native view; pictures, textures and
filters all land in the same Flutter drawable). Live Flutter pixels therefore
cannot be excluded from a foreground screenshot, and the only way to blank a
region in a screenshot is to put a bitmap or native UI in a native view - which
is what the deprecated widget below does. There is no `RenderObject`, layer or
`Texture` that changes this.

### Region shielding (screen recording and app switcher)

`ScreenshotShieldSensitiveRegion` keeps its child live and hides it only while it
matters:

```dart
ScreenshotShieldSensitiveRegion(
  child: Text('Account number: 1234'),
)
```

It shields the subtree while the screen is being recorded or mirrored
(`shieldWhileRecording`, reported by `onScreenRecordingChanged`: iOS and
Android 15+) and while the app is not in the foreground (`shieldInBackground`,
which keeps the region out of the app-switcher snapshot on every platform).
While shielded the child is covered - by `shield`, or by an opaque `shieldColor`
defaulting to the ambient scaffold background - or blurred when `blur` is set.
Either way the child keeps its layout, so shielding never moves anything around
it, and the subtree itself is never rasterised: it renders correctly through
size changes, animations, text input and anything Flutter draws on top of it.
While it is covered the child stops receiving pointers and leaves the semantics
tree, so a hidden field cannot be typed into or read by assistive technology.

Also useful: `shielded` overrides the automatic triggers, for app-driven rules
(for example "shield while a session is active") or to preview the shield.

The region reads its `ScreenshotShield` from the nearest
`ScreenshotShieldScope`, and creates one if there is no scope above it. It takes
care of `startListening`/`stopListening` itself; those calls are reference
counted, so a region and a guard can be active at the same time without
cancelling each other.

Gaps to be aware of: Android 14 and older cannot report screen recording, so
`shieldWhileRecording` never fires there - use `preventCapture` on those devices.
A foreground screenshot is not covered (see above); use a guard on screens that
must come out blank.

### Deprecated: snapshot region (`ScreenshotShieldSensitiveView`)

`ScreenshotShieldSensitiveView` is deprecated and will be removed in 0.2.0. It
was an attempt at covering *screenshots* per region: it rasterises its subtree
and displays the bitmap in a platform view whose layer is nested in its own
capture-excluded canvas. That works only for effectively static content, and it
is iOS only:

- The region is displayed from a snapshot, so animations, video and text carets
  are only as fresh as the last refresh (`refreshInterval`, or
  `ScreenshotShieldSensitiveViewController.refresh()`, which captures after the
  next frame). A resize re-rasterises, but the native view scales the previous
  bitmap until it does.
- The region is a native view, so it renders above the Flutter content: anything
  Flutter paints over it (a selection toolbar, a dialog, a tooltip) shows up
  behind it.
- `placeholderColor` is what a capture sees in the region *and* what shows
  through any transparent part of the child on screen, so it defaults to the
  ambient scaffold background and should be set when the region sits on a
  gradient, an image or a card. It is only painted once the native view holds a
  snapshot, so an opaque rectangle never covers the region before that.
- It derives from the same undocumented UIKit behaviour as the whole-window
  protection, so verify it on a real device. `xcrun simctl io screenshot` cannot
  show capture exclusion at all.

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
