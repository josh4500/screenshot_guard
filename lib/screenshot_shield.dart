import 'package:flutter/foundation.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

export 'src/screenshot_shield_guard.dart';
export 'src/screenshot_shield_route_guard.dart';
export 'src/screenshot_shield_scope.dart';
export 'src/screenshot_shield_sensitive_view.dart' hide RenderScreenshotShieldRegion, ScreenshotShieldRegionLayout;

/// Guards a screen against being captured by the user.
///
/// Use [startListening] to begin reporting [onScreenshotDetected] and
/// [onScreenRecordingChanged] events, and [setProtection] to configure screen
/// protection.
///
/// Screenshot detection is best-effort: on Android it is reported shortly
/// after the screenshot is saved to the media store, on iOS it is reported
/// immediately when the screenshot is taken. Screen-recording detection is
/// supported on iOS and on Android 15 (API 35) and newer.
class ScreenshotShield {
  ScreenshotShield({ScreenshotShieldPlatform? platform}) : _platform = platform ?? ScreenshotShieldPlatform.instance;

  final ScreenshotShieldPlatform _platform;

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => _platform.onScreenshotDetected;

  /// Emits the current screen-recording state whenever it changes.
  ///
  /// The stream emits `true` when the app is visible in a screen recording and
  /// `false` when it is no longer recorded, including the current state when
  /// first listened to. Detection requires [startListening] to be active and
  /// is platform-specific: on iOS it reflects `UIScreen.isCaptured`, which is
  /// also `true` while the screen is mirrored (for example via AirPlay); on
  /// Android it uses the Android 15 (API 35) `DETECT_SCREEN_RECORDING` API and
  /// never emits on older versions.
  Stream<bool> get onScreenRecordingChanged => _platform.onScreenRecordingChanged;

  /// Starts observing for screenshots.
  Future<void> startListening() => _platform.startListening();

  /// Stops observing for screenshots.
  Future<void> stopListening() => _platform.stopListening();

  /// Whether whole-window capture prevention is currently enabled.
  ///
  /// This reflects the last `preventCapture` value passed to [setProtection] on
  /// any [ScreenshotShield] in the process, which is what the platform plugin
  /// applies - capture prevention is a property of the window, not of a
  /// [ScreenshotShield] instance. [ScreenshotShieldSensitiveView] listens to it
  /// so that a guarded region stays inactive (and does no rasterising) while the
  /// whole window is already excluded from captures.
  static ValueListenable<bool> get preventCaptureActive => _preventCaptureActive;

  static final ValueNotifier<bool> _preventCaptureActive = ValueNotifier<bool>(false);

  /// Configures screen protection.
  ///
  /// [preventCapture] prevents screen capture while the guarded route is in
  /// view. On Android the secure window flag blanks the captured frame; on iOS
  /// a hidden secure text field makes the system exclude the window from
  /// snapshots, so user screenshots come out blank too. On Android the secure
  /// flag also suppresses screenshot detection (the blanked frame is never
  /// saved and the system withholds the capture callback for secure windows),
  /// so the guards drop prevention when detection is also requested there and
  /// instead re-rasterize the guarded screen into a shareable image when a
  /// screenshot is detected.
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
      _preventCaptureActive.value = preventCapture;
    }
    if (backgroundBlur != null) {
      await _platform.setBackgroundBlur(blurEnabled: backgroundBlur);
    }
  }

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => _platform.dispose();
}
