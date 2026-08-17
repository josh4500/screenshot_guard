# screenshot_shield

Detects user screenshots and optionally prevents screen capture on Android and
iOS.

## Platform behaviour

Screenshot detection is best-effort and platform-specific:

| Capability | Android | iOS |
|---|---|---|
| Screenshot detection | Yes - Android 14+ uses the system `DETECT_SCREEN_CAPTURE` API; older versions watch the media store and report shortly after a screenshot is saved | Yes - reports immediately via the `UIApplicationUserDidTakeScreenshotNotification` system notification |
| Prevent screen capture (`setProtected(true)`) | Yes - adds the secure window flag so the captured frame is blank | No - no public API to prevent screenshots; it is a no-op |
| Screenshot events while protected | Below Android 14 the blanked capture is never saved, so no event fires; on Android 14+ the system API still reports the screenshot | N/A - protection is not supported |
| Runtime permission | `DETECT_SCREEN_CAPTURE` (auto-granted, Android 14+ only) | Not required |

On Android 14+, the system shows a notice whenever the screenshot detection
API fires. Screenshots taken via ADB or instrumentation tests are not
detected by either path.
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
      onScreenshotDetected: () {
        // Show your own shareable image here.
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
flag (default `true`), and an optional `onScreenshotDetected` callback.

For lower-level control you can drive `ScreenshotShield` directly:

```dart
final shield = ScreenshotShield();
shield.onScreenshotDetected.listen((_) {
  // Show your own shareable image here.
});

// While this screen is visible:
await shield.startListening();
await shield.setProtected(true); // Android only: blanks the capture.

// When leaving the screen:
await shield.stopListening();
```

When a screenshot is detected, present the user with your own shareable image
(e.g. via `share_plus`) instead of the captured frame. Note that while
`setProtected(true)` is enabled on Android the screenshot is blanked and
detection events will not fire.

## iOS configuration

The iOS implementation observes `UIApplicationUserDidTakeScreenshotNotification`
and requires no permissions or `Info.plist` entries. Screenshot detection fires
while the app is in the foreground; screenshots taken while the app is
backgrounded (e.g. from the app switcher) are not reported.

## Install

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  screenshot_shield: ^0.1.0
```
