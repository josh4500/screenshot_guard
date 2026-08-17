import 'dart:async';

import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/screenshot_shield_messages.dart' as messages;

/// An implementation of [ScreenshotShieldPlatform] that uses Pigeon-generated
/// message channels to talk to the host platform.
class PigeonScreenshotShield extends ScreenshotShieldPlatform {
  PigeonScreenshotShield({messages.ScreenshotShieldHostApi? hostApi, Stream<int> Function()? eventStream})
    : _hostApi = hostApi ?? messages.ScreenshotShieldHostApi(),
      _eventStream = eventStream ?? messages.onScreenshotDetected;

  final messages.ScreenshotShieldHostApi _hostApi;
  final Stream<int> Function() _eventStream;

  late final _events = _eventStream();

  @override
  Stream<void> get onScreenshotDetected => _events.map((_) {});

  @override
  Future<void> startListening() => _hostApi.startListening();

  @override
  Future<void> stopListening() => _hostApi.stopListening();

  @override
  Future<void> setProtected({required bool protected}) => _hostApi.setProtected(protected);

  @override
  Future<void> dispose() async {}
}
