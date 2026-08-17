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
