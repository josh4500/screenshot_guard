import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/screenshot_guard_messages.dart',
    kotlinOut: 'android/src/main/kotlin/com/ajibolaak/screenshot_guard/ScreenshotGuardMessages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.ajibolaak.screenshot_guard'),
    swiftOut: 'ios/screenshot_guard/Sources/screenshot_guard/ScreenshotGuardMessages.g.swift',
    dartPackageName: 'screenshot_guard',
  ),
)
/// Calls made from Dart into the host platform.
@HostApi()
abstract class ScreenshotGuardHostApi {
  void startListening();

  void stopListening();

  void setProtected(bool protected);
}

/// Events emitted from the host platform into Dart.
@EventChannelApi()
abstract class ScreenshotGuardEventChannelApi {
  int onScreenshotDetected();
}
