import 'dart:async';

import 'package:screenshot_guard/screenshot_guard_platform_interface.dart';
import 'package:screenshot_guard/src/screenshot_guard_messages.dart' as messages;

/// An implementation of [ScreenshotGuardPlatform] that uses Pigeon-generated
/// message channels to talk to the host platform.
class PigeonScreenshotGuard extends ScreenshotGuardPlatform {
  PigeonScreenshotGuard({messages.ScreenshotGuardHostApi? hostApi, Stream<int> Function()? eventStream})
    : _hostApi = hostApi ?? messages.ScreenshotGuardHostApi(),
      _eventStream = eventStream ?? messages.onScreenshotDetected;

  final messages.ScreenshotGuardHostApi _hostApi;
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
