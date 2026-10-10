import 'package:flutter/foundation.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

export 'src/screenshot_shield_guard.dart';
export 'src/screenshot_shield_route_guard.dart';
export 'src/screenshot_shield_scope.dart';
export 'src/screenshot_shield_sensitive_view.dart' hide RenderScreenshotShieldRegion, ScreenshotShieldRegionLayout;

/// Guards a screen against being captured by the user.
///
/// Screenshot detection is best-effort: Android reports it once the screenshot is
/// saved, iOS immediately. Screen-recording detection needs iOS or Android 15+.
class ScreenshotShield {
  /// Creates a shield backed by the platform implementation.
  ///
  /// Pass [platform] to substitute a fake in tests.
  ScreenshotShield({ScreenshotShieldPlatform? platform}) : _platform = platform ?? ScreenshotShieldPlatform.instance;

  final ScreenshotShieldPlatform _platform;

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => _platform.onScreenshotDetected;

  /// Emits the screen-recording state whenever it changes.
  ///
  /// The current state is emitted on first listen. iOS reports whether the app's scene is
  /// recorded, mirrored (AirPlay) or shared; Android needs API 35 and never emits below
  /// it; Windows and Linux use a best-effort heuristic that looks for recorder programs.
  Stream<bool> get onScreenRecordingChanged => _platform.onScreenRecordingChanged;

  /// Whether the app is currently visible in a screen recording or mirrored screen.
  ///
  /// [onScreenRecordingChanged] only delivers changes, so read this when a screen appears
  /// mid-recording. `false` until the platform has reported a state.
  bool get isScreenRecording => _platform.isScreenRecording;

  /// Starts observing for screenshots and screen recordings.
  ///
  /// Calls are counted: detection keeps running until [stopListening] has been called
  /// as many times as this was.
  Future<void> startListening() => _platform.startListening();

  /// Stops observing, once every [startListening] call has been matched.
  Future<void> stopListening() => _platform.stopListening();

  /// Whether whole-window capture prevention is currently enabled.
  ///
  /// Reflects the last `preventCapture` passed to [setProtection] anywhere in the process:
  /// prevention belongs to the window, not to an instance.
  static ValueListenable<bool> get preventCaptureActive => _preventCaptureActive;

  static final ValueNotifier<bool> _preventCaptureActive = ValueNotifier<bool>(false);

  /// Configures screen protection.
  ///
  /// [preventCapture] blanks captured frames: screenshots, screen recordings and the
  /// app-switcher snapshot (Android, iOS and Windows). On Android a secure window also
  /// suppresses screenshot detection, so the guards keep detection and drop prevention
  /// there when both are requested.
  ///
  /// This sets the window's state directly. The guards count their requests instead, so
  /// prevention stays on while any guard needs it; prefer them over calling this yourself.
  ///
  /// [backgroundBlur] hides the app's content in the app switcher: on Android 13+ the
  /// thumbnail is disabled (screenshots and their detection are unaffected), on Android 12
  /// and below the content is blurred or covered, on iOS it is blurred, and on Windows the
  /// taskbar and Alt+Tab previews show the app icon instead of the window.
  ///
  /// Omitted flags keep their current value.
  Future<void> setProtection({bool? preventCapture, bool? backgroundBlur}) async {
    if (preventCapture != null) {
      await _platform.setProtected(protected: preventCapture);
      _preventCaptureActive.value = preventCapture;
    }
    if (backgroundBlur != null) {
      await _platform.setBackgroundBlur(blurEnabled: backgroundBlur);
    }
  }

  /// iOS only: keeps the on-screen keyboard out of captures.
  ///
  /// The keyboard is its own system window, so neither whole-window protection nor a
  /// sensitive region covers it; this nests it in the same capture-excluded canvas the
  /// region uses. Undocumented UIKit behaviour, so verify it on the iOS versions you
  /// support. No-op on Android, where the keyboard belongs to another app.
  Future<void> setKeyboardProtection({required bool enabled}) => _platform.setKeyboardProtection(enabled: enabled);

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => _platform.dispose();
}
