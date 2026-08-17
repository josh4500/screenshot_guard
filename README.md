# screenshot_shield

Detects user screenshots and optionally prevents screen capture on Android and
iOS.

## Platform behaviour

Screenshot detection is best-effort and platform-specific:

- **Android** watches the media store and reports shortly after a screenshot is
  saved to `DCIM/Screenshots`.
- **iOS** observes the photo library for newly saved images that match the
  device screen size and reports shortly after the screenshot is saved.
- On iOS there is **no public API to prevent screenshots**; calling
  `setProtected(true)` on iOS is a no-op.

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

The iOS implementation uses `Photos.framework` to detect screenshots and
requests photo library access on the first `startListening()` call. Add the
following to the host app's `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to detect screenshots and offer an official shareable image.</string>
```

## Install

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  screenshot_shield: ^0.1.0
```

## Development

The Dart-to-native plumbing is generated with
[Pigeon](https://pub.dev/packages/pigeon) from
`pigeons/screenshot_shield.dart`. After changing that file, regenerate with:

```sh
dart run pigeon --input pigeons/screenshot_shield.dart
```

The generated Dart, Kotlin and Swift files are committed.

## Publishing

To publish to [pub.dev](https://pub.dev), remove `publish_to: none` from
`pubspec.yaml`, set a `repository:` pointing at your GitHub repo, then run:

```sh
flutter pub publish --dry-run
```
