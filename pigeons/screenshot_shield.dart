import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/screenshot_shield_messages.dart',
    kotlinOut: 'android/src/main/kotlin/com/ajibolaak/screenshot_shield/ScreenshotShieldMessages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.ajibolaak.screenshot_shield'),
    swiftOut: 'ios/screenshot_shield/Sources/screenshot_shield/ScreenshotShieldMessages.g.swift',
    dartPackageName: 'screenshot_shield',
  ),
)
/// Calls made from Dart into the host platform.
@HostApi()
abstract class ScreenshotShieldHostApi {
  void startListening();

  void stopListening();

  void setProtected(bool protected);
}

/// Events emitted from the host platform into Dart.
@EventChannelApi()
abstract class ScreenshotShieldEventChannelApi {
  int onScreenshotDetected();
}
