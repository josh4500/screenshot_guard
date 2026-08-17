# screenshot_guard

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

```dart
final screenshotGuard = ScreenshotGuard();
screenshotGuard.onScreenshotDetected.listen((_) {
  // Show your own shareable image here.
});

// While this screen is visible:
await screenshotGuard.startListening();
await screenshotGuard.setProtected(true); // Android only: blanks the capture.

// When leaving the screen:
await screenshotGuard.stopListening();
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
  screenshot_guard: ^0.1.0
```

## Development

The Dart-to-native plumbing is generated with
[Pigeon](https://pub.dev/packages/pigeon) from
`pigeons/screenshot_guard.dart`. After changing that file, regenerate with:

```sh
dart run pigeon --input pigeons/screenshot_guard.dart
```

The generated Dart, Kotlin and Swift files are committed.

## Publishing

To publish to [pub.dev](https://pub.dev), remove `publish_to: none` from
`pubspec.yaml`, set a `repository:` pointing at your GitHub repo, then run:

```sh
flutter pub publish --dry-run
```
