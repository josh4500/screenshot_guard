# screenshot_shield

Detects user screenshots and optionally prevents screen capture on Android and
iOS.

## Platform behaviour

Screenshot detection is best-effort and platform-specific:

| Capability | Android | iOS |
|---|---|---|
| Screenshot detection | Yes - Android 14+ uses the system `DETECT_SCREEN_CAPTURE` API; older versions watch the media store and report shortly after a screenshot is saved | Yes - reports immediately via the `UIApplicationUserDidTakeScreenshotNotification` system notification |
| Prevent screen capture (`setProtection(preventCapture: true)`) | Yes - adds the secure window flag so the captured frame is blank | No - no public API to prevent screenshots; it is a no-op |
| Screenshot events while protected | Below Android 14 the blanked capture is never saved, so no event fires; on Android 14+ the system API still reports the screenshot | N/A - protection is not supported |
| Runtime permission | `DETECT_SCREEN_CAPTURE` (auto-granted, Android 14+ only) | Not required |

On Android 14+, the system shows a notice whenever the screenshot detection
API fires. Screenshots taken via ADB or instrumentation tests are not
detected by either path.

### Desktop (Windows, Linux)

The package registers on Windows and Linux so the widget layer works there,
but desktop has no OS screenshot-detection or screenshot-prevention APIs, so
`onScreenshotDetected` never fires, `startListening` is a no-op, and
`preventCapture` cannot blank the capture. What does apply:

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
flag (default `true`), a `captureOnScreenshot` flag (default `true`), and an
optional `onScreenshotDetected` callback. With `captureOnScreenshot` the
guarded subtree is re-rasterized into a PNG on each screenshot, so the app
can show exactly what was on screen even when the OS frame is blanked or
unavailable.

### Detect-and-notify mode

By default `preventCapture` blanks the captured frame on Android, so the user
sees a black screenshot. To follow a Snapchat-style flow instead - let the
screenshot succeed and react in `onScreenshotDetected` (for example by sending
the captured image or notifying a peer) - set `preventCapture: false`.

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
await shield.setProtection(preventCapture: true); // Android only: blanks the capture.

// When leaving the screen:
await shield.stopListening();
```

When a screenshot is detected, present the user with your own shareable image
(e.g. via `share_plus`) instead of the captured frame. Note that while
`preventCapture` is enabled on Android the screenshot is blanked and
detection events will not fire.

## iOS configuration

The iOS implementation observes `UIApplicationUserDidTakeScreenshotNotification`
and requires no permissions or `Info.plist` entries. Screenshot detection fires
while the app is in the foreground; screenshots taken while the app is
backgrounded (e.g. from the app switcher) are not reported.

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
