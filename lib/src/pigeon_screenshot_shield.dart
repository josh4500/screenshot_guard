import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/screenshot_shield_messages.dart' as messages;

/// A [ScreenshotShieldPlatform] that talks to the host over Pigeon channels.
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

  /// Number of consumers that asked for listening. The host has a single flag,
  /// so a stop from one consumer would silently stop detection for the others.
  int _listeningCount = 0;

  StreamSubscription<bool>? _screenRecordingSubscription;

  late final _events = _eventStream();
  late final _screenRecordingEvents = _screenRecordingStream();

  /// Whether any consumer currently asked for listening.
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
      // Subscribe on first listen, not in the constructor: without a binding the
      // channel is never listened to. Kept after stopping to keep state readable.
      _screenRecordingSubscription ??= _screenRecordingEvents.listen(
        reportScreenRecordingState,
        onError: (Object _) {},
      );
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
  Future<void> setKeyboardProtection({required bool enabled}) async {
    try {
      await _hostApi.setKeyboardProtected(enabled);
    } catch (_) {
      // Best-effort: Android, desktop and older hosts do not implement this.
    }
  }

  @override
  Future<void> dispose() async {}
}
