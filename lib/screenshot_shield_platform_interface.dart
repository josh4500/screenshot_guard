import 'package:flutter/foundation.dart' show protected;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screenshot_shield/src/pigeon_screenshot_shield.dart';

/// The interface that platform implementations of `screenshot_shield` must
/// extend.
abstract class ScreenshotShieldPlatform extends PlatformInterface {
  /// Constructs a [ScreenshotShieldPlatform].
  ScreenshotShieldPlatform() : super(token: _token);

  static final _token = Object();

  static ScreenshotShieldPlatform _instance = PigeonScreenshotShield();

  /// The default instance of [ScreenshotShieldPlatform] to use.
  ///
  /// Defaults to [PigeonScreenshotShield].
  static ScreenshotShieldPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ScreenshotShieldPlatform] when
  /// they register themselves.
  static set instance(ScreenshotShieldPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => throw UnsupportedError('onScreenshotDetected() has not been implemented.');

  /// Emits the screen-recording state whenever it changes.
  ///
  /// The current state is emitted on first listen. iOS reports `UIScreen.isCaptured`
  /// (recording or mirroring); Android needs API 35 and never emits below it. Observation
  /// is tied to [startListening]/[stopListening].
  Stream<bool> get onScreenRecordingChanged =>
      throw UnsupportedError('onScreenRecordingChanged() has not been implemented.');

  /// Whether the app is currently visible in a screen recording or mirrored screen.
  ///
  /// [onScreenRecordingChanged] only delivers changes, so anything that starts watching
  /// mid-recording must read the state here. `false` until the platform reports one.
  bool get isScreenRecording => _screenRecordingActive;

  bool _screenRecordingActive = false;

  /// Records the state the platform reported, which [isScreenRecording] then returns.
  ///
  /// Implementations that never call it leave [isScreenRecording] `false`.
  @protected
  void reportScreenRecordingState(bool screenRecordingActive) {
    _screenRecordingActive = screenRecordingActive;
  }

  /// Starts observing for screenshots.
  Future<void> startListening() => throw UnsupportedError('startListening() has not been implemented.');

  /// Stops observing for screenshots.
  Future<void> stopListening() => throw UnsupportedError('stopListening() has not been implemented.');

  /// Blanks screen captures of the app window while [protected] is `true`.
  Future<void> setProtected({required bool protected}) =>
      throw UnsupportedError('setProtected() has not been implemented.');

  /// Blurs the app content while the app is in the background.
  Future<void> setBackgroundBlur({required bool blurEnabled}) =>
      throw UnsupportedError('setBackgroundBlur() has not been implemented.');

  /// iOS only: keeps the on-screen keyboard out of captures.
  ///
  /// The keyboard is a private system window, so it survives whole-window protection and
  /// regions alike. iOS can nest it in a capture-excluded canvas, which is what this does;
  /// platforms where the keyboard belongs to another app leave it as a no-op.
  Future<void> setKeyboardProtection({required bool enabled}) =>
      throw UnsupportedError('setKeyboardProtection() has not been implemented.');

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => throw UnsupportedError('dispose() has not been implemented.');
}
