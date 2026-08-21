import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

export 'src/screenshot_shield_route_guard.dart';
export 'src/screenshot_shield_scope.dart';

/// Guards a screen against being captured by the user.
///
/// Use [startListening] to begin reporting [onScreenshotDetected] events and
/// [setProtection] to configure screen protection.
///
/// Screenshot detection is best-effort: on Android it is reported shortly
/// after the screenshot is saved to the media store, on iOS it is reported
/// immediately when the screenshot is taken.
class ScreenshotShield {
  ScreenshotShield({ScreenshotShieldPlatform? platform}) : _platform = platform ?? ScreenshotShieldPlatform.instance;

  final ScreenshotShieldPlatform _platform;

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => _platform.onScreenshotDetected;

  /// Starts observing for screenshots.
  Future<void> startListening() => _platform.startListening();

  /// Stops observing for screenshots.
  Future<void> stopListening() => _platform.stopListening();

  /// Configures screen protection.
  ///
  /// [preventCapture] prevents screen capture while the guarded route is in
  /// view. On Android the secure window flag blanks the captured frame. On iOS
  /// a hidden secure text field makes the system exclude the window from
  /// snapshots, so user screenshots come out blank too. While blanked, the
  /// screenshot event still fires and the guarded screen can still be
  /// re-rasterized via the guard's capture.
  ///
  /// [backgroundBlur] blurs the app content while the app is in the
  /// background, hiding it in the app switcher. On iOS the key window is
  /// covered with a native blur effect. On Android 12+ the window is blurred
  /// with `RenderEffect`; on older Android versions a dim overlay is shown
  /// because no public blur API exists.
  ///
  /// Both flags default to disabled. Omitted flags keep their current value,
  /// so a single call can toggle one setting without disturbing the other.
  Future<void> setProtection({bool? preventCapture, bool? backgroundBlur}) async {
    if (preventCapture != null) {
      await _platform.setProtected(protected: preventCapture);
    }
    if (backgroundBlur != null) {
      await _platform.setBackgroundBlur(blurEnabled: backgroundBlur);
    }
  }

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => _platform.dispose();
}
