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

  /// Emits the current screen-recording state whenever it changes.
  ///
  /// The stream emits `true` when the app is visible in a screen recording and
  /// `false` when it is no longer recorded. The current state is emitted as
  /// soon as the stream is listened to. Detection depends on the platform:
  /// on iOS it reflects `UIScreen.isCaptured` (recording or mirroring), and on
  /// Android it requires Android 15 (API 35) or newer — older versions never
  /// emit. Observation is tied to [startListening]/[stopListening].
  Stream<bool> get onScreenRecordingChanged =>
      throw UnsupportedError('onScreenRecordingChanged() has not been implemented.');

  /// Whether the app is currently visible in a screen recording (or a mirrored
  /// screen).
  ///
  /// [onScreenRecordingChanged] only delivers *changes*, so anything that starts
  /// watching while a recording is already running has to read the current state
  /// here: the stream will not replay the change it missed. It is `false` until
  /// the platform has reported a state.
  bool get isScreenRecording => _screenRecordingActive;

  bool _screenRecordingActive = false;

  /// Records the state the platform reported, which is what [isScreenRecording]
  /// returns from then on.
  ///
  /// Platform implementations call this when an event arrives; the
  /// implementations shipped with this package already do, and an implementation
  /// that never calls it simply leaves [isScreenRecording] `false`.
  @protected
  void reportScreenRecordingState(bool screenRecordingActive) {
    _screenRecordingActive = screenRecordingActive;
  }

  /// Starts observing for screenshots.
  Future<void> startListening() => throw UnsupportedError('startListening() has not been implemented.');

  /// Stops observing for screenshots.
  Future<void> stopListening() => throw UnsupportedError('stopListening() has not been implemented.');

  /// Prevents screen capture on Android. No-op on iOS.
  Future<void> setProtected({required bool protected}) =>
      throw UnsupportedError('setProtected() has not been implemented.');

  /// Blurs the app content while the app is in the background.
  Future<void> setBackgroundBlur({required bool blurEnabled}) =>
      throw UnsupportedError('setBackgroundBlur() has not been implemented.');

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => throw UnsupportedError('dispose() has not been implemented.');
}
