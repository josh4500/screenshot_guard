import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/screenshot_shield_messages.dart' as messages;

/// An implementation of [ScreenshotShieldPlatform] that uses Pigeon-generated
/// message channels to talk to the host platform.
class PigeonScreenshotShield extends ScreenshotShieldPlatform {
  PigeonScreenshotShield({
    messages.ScreenshotShieldHostApi? hostApi,
    Stream<int> Function()? eventStream,
    Stream<bool> Function()? screenRecordingStream,
  }) : _hostApi = hostApi ?? messages.ScreenshotShieldHostApi(),
       _eventStream = eventStream ?? messages.onScreenshotDetected,
       _screenRecordingStream = screenRecordingStream ?? messages.onScreenRecordingChanged;

  final messages.ScreenshotShieldHostApi _hostApi;
  final Stream<int> Function() _eventStream;
  final Stream<bool> Function() _screenRecordingStream;

  /// Number of consumers that asked for listening.
  ///
  /// The host only has a single "listening" flag, so stopping on behalf of one
  /// consumer would silently stop detection for every other one - which happens
  /// as soon as two guarded routes, or a guarded route and a sensitive region,
  /// are alive at the same time. Counting here, in the platform implementation
  /// shared by every [ScreenshotShield], keeps them independent.
  int _listeningCount = 0;

  late final _events = _eventStream();
  late final _screenRecordingEvents = _screenRecordingStream();

  /// Whether the host is currently observing, i.e. whether any consumer asked
  /// for listening.
  @visibleForTesting
  bool get isListening => _listeningCount > 0;

  @override
  Stream<void> get onScreenshotDetected => _events.map((_) {});

  @override
  Stream<bool> get onScreenRecordingChanged => _screenRecordingEvents;

  @override
  Future<void> startListening() async {
    _listeningCount++;
    if (_listeningCount == 1) {
      await _hostApi.startListening();
    }
  }

  @override
  Future<void> stopListening() async {
    if (_listeningCount == 0) {
      return;
    }
    _listeningCount--;
    if (_listeningCount == 0) {
      await _hostApi.stopListening();
    }
  }

  @override
  Future<void> setProtected({required bool protected}) => _hostApi.setProtected(protected);

  @override
  Future<void> setBackgroundBlur({required bool blurEnabled}) => _hostApi.setBackgroundBlur(blurEnabled);

  @override
  Future<void> dispose() async {}
}
