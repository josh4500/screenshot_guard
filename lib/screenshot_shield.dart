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
  ScreenshotShield({ScreenshotShieldPlatform? platform}) : _platform = platform ?? ScreenshotShieldPlatform.instance;

  final ScreenshotShieldPlatform _platform;

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => _platform.onScreenshotDetected;

  /// Emits the screen-recording state whenever it changes.
  ///
  /// The current state is emitted on first listen. On iOS this is `UIScreen.isCaptured`,
  /// also `true` while mirroring; Android needs API 35 and never emits below it.
  Stream<bool> get onScreenRecordingChanged => _platform.onScreenRecordingChanged;

  /// Whether the app is currently visible in a screen recording or mirrored screen.
  ///
  /// [onScreenRecordingChanged] only delivers changes, so read this when a screen appears
  /// mid-recording. `false` until the platform has reported a state.
  bool get isScreenRecording => _platform.isScreenRecording;

  /// Starts observing for screenshots.
  Future<void> startListening() => _platform.startListening();

  /// Stops observing for screenshots.
  Future<void> stopListening() => _platform.stopListening();

  /// Whether whole-window capture prevention is currently enabled.
  ///
  /// Reflects the last `preventCapture` passed to [setProtection] anywhere in the process:
  /// prevention belongs to the window, not to an instance.
  static ValueListenable<bool> get preventCaptureActive => _preventCaptureActive;

  static final ValueNotifier<bool> _preventCaptureActive = ValueNotifier<bool>(false);

  /// Configures screen protection.
  ///
  /// [preventCapture] blanks captured frames. On Android a secure window also suppresses
  /// screenshot detection, so the guards re-rasterise the screen there when detection is
  /// requested as well.
  ///
  /// [backgroundBlur] hides the app content in the app switcher: a native blur on iOS and
  /// Android 12+, a dim overlay below that.
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

  /// Releases the native resources held by the plugin.
  /// iOS only: keeps the on-screen keyboard out of captures.
  ///
  /// The keyboard is its own system window, so neither whole-window protection nor a
  /// sensitive region covers it; this nests it in the same capture-excluded canvas the
  /// region uses. Undocumented UIKit behaviour, so verify it on the iOS versions you
  /// support. No-op on Android, where the keyboard belongs to another app.
  Future<void> setKeyboardProtection({required bool enabled}) => _platform.setKeyboardProtection(enabled: enabled);

  Future<void> dispose() => _platform.dispose();
}
