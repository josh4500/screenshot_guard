import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screenshot_guard/src/pigeon_screenshot_guard.dart';

/// The interface that platform implementations of `screenshot_guard` must
/// extend.
abstract class ScreenshotGuardPlatform extends PlatformInterface {
  /// Constructs a [ScreenshotGuardPlatform].
  ScreenshotGuardPlatform() : super(token: _token);

  static final _token = Object();

  static ScreenshotGuardPlatform _instance = PigeonScreenshotGuard();

  /// The default instance of [ScreenshotGuardPlatform] to use.
  ///
  /// Defaults to [PigeonScreenshotGuard].
  static ScreenshotGuardPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ScreenshotGuardPlatform] when
  /// they register themselves.
  static set instance(ScreenshotGuardPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Emits an event each time the user captures a screenshot.
  Stream<void> get onScreenshotDetected => throw UnsupportedError('onScreenshotDetected() has not been implemented.');

  /// Starts observing for screenshots.
  Future<void> startListening() => throw UnsupportedError('startListening() has not been implemented.');

  /// Stops observing for screenshots.
  Future<void> stopListening() => throw UnsupportedError('stopListening() has not been implemented.');

  /// Prevents screen capture on Android. No-op on iOS.
  Future<void> setProtected({required bool protected}) =>
      throw UnsupportedError('setProtected() has not been implemented.');

  /// Releases the native resources held by the plugin.
  Future<void> dispose() => throw UnsupportedError('dispose() has not been implemented.');
}
