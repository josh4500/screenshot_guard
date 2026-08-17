import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

/// Guards a screen against being captured by the user.
///
/// Use [startListening] to begin reporting [onScreenshotDetected] events and
/// [setProtected] to prevent screen capture entirely on Android.
///
/// Screenshot detection is best-effort: on Android it is reported shortly
/// after the screenshot is saved to the media store, on iOS it is reported
/// shortly after the screenshot is saved to the photo library.
class ScreenshotShield {
  ScreenshotShield({ScreenshotShieldPlatform? platform}) : _platform = platform ?? ScreenshotShieldPlatform.instance;

  final ScreenshotShieldPlatform _platform;

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => _platform.onScreenshotDetected;

  /// Starts observing for screenshots.
  ///
  /// On iOS this prompts the user for photo library access the first time it
  /// is called.
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

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => _platform.dispose();
}
