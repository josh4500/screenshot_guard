import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

export 'src/screenshot_shield_route_guard.dart';
export 'src/screenshot_shield_scope.dart';

/// Guards a screen against being captured by the user.
///
/// Use [startListening] to begin reporting [onScreenshotDetected] events and
/// [setProtected] to prevent screen capture entirely on Android.
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

  /// Prevents screen capture on Android by adding the secure window flag.
  ///
  /// While [protected] is true the captured frame is blank and screenshot
  /// detections are not reported because the screenshot is never saved. On
  /// iOS this is a no-op because there is no public API to prevent
  /// screenshots.
  Future<void> setProtected({required bool protected}) => _platform.setProtected(protected: protected);

  /// Blurs the app content while the app is in the background, hiding it in
  /// the app switcher. Defaults to disabled.
  ///
  /// On iOS the key window is covered with a native blur effect. On Android 12+
  /// the window is blurred with `RenderEffect`; on older Android versions a
  /// dim overlay is shown because no public blur API exists.
  Future<void> setBackgroundBlur({required bool blurEnabled}) => _platform.setBackgroundBlur(blurEnabled: blurEnabled);

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => _platform.dispose();
}
