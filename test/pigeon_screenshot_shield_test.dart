import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/src/pigeon_screenshot_shield.dart';
import 'package:screenshot_shield/src/screenshot_shield_messages.dart';

class _FakeHostApi extends ScreenshotShieldHostApi {
  final calls = <String>[];

  @override
  Future<void> startListening() async => calls.add('startListening');

  @override
  Future<void> stopListening() async => calls.add('stopListening');

  @override
  Future<void> setProtected(bool protected) async => calls.add('setProtected:$protected');

  @override
  Future<void> setBackgroundBlur(bool blurEnabled) async => calls.add('setBackgroundBlur:$blurEnabled');

  @override
  Future<void> setKeyboardProtected(bool enabled) async => calls.add('setKeyboardProtected:$enabled');
}

/// A host that predates the keyboard call, or a platform without it.
class _UnsupportedKeyboardHostApi extends _FakeHostApi {
  @override
  Future<void> setKeyboardProtected(bool enabled) async => throw PlatformException(code: 'no');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PigeonScreenshotShield', () {
    test('forwards startListening to the host api', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.startListening();

      expect(hostApi.calls, contains('startListening'));
    });

    test('starts the host only once for several consumers', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.startListening();
      await platform.startListening();

      expect(hostApi.calls, ['startListening']);
      expect(platform.isListening, isTrue);
    });

    test('keeps the host listening while another consumer still listens', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.startListening();
      await platform.startListening();
      await platform.stopListening();

      expect(hostApi.calls, ['startListening']);
      expect(platform.isListening, isTrue);
    });

    test('forwards keyboard protection to the host', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.setKeyboardProtection(enabled: true);
      await platform.setKeyboardProtection(enabled: false);

      expect(hostApi.calls, ['setKeyboardProtected:true', 'setKeyboardProtected:false']);
    });

    test('ignores a host that cannot protect the keyboard', () async {
      final platform = PigeonScreenshotShield(hostApi: _UnsupportedKeyboardHostApi());

      await expectLater(platform.setKeyboardProtection(enabled: true), completes);
    });

    test('stops the host when the last consumer stops', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.startListening();
      await platform.startListening();
      await platform.stopListening();
      await platform.stopListening();

      expect(hostApi.calls, ['startListening', 'stopListening']);
      expect(platform.isListening, isFalse);
    });

    test('ignores stopListening without consumers', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.stopListening();

      expect(hostApi.calls, isEmpty);
      expect(platform.isListening, isFalse);
    });

    test('forwards setProtected to the host api', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.setProtected(protected: true);

      expect(hostApi.calls, contains('setProtected:true'));
    });

    test('forwards setBackgroundBlur to the host api', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.setBackgroundBlur(blurEnabled: true);

      expect(hostApi.calls, contains('setBackgroundBlur:true'));
    });

    test('forwards events from the event channel', () async {
      final controller = StreamController<int>.broadcast();
      final platform = PigeonScreenshotShield(eventStream: () => controller.stream);
      final events = <void>[];
      final subscription = platform.onScreenshotDetected.listen(events.add);

      controller.add(1);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      await subscription.cancel();
      await controller.close();
    });

    test('forwards screen recording events from the event channel', () async {
      final controller = StreamController<bool>.broadcast();
      final platform = PigeonScreenshotShield(screenRecordingStream: () => controller.stream);
      final events = <bool>[];
      final subscription = platform.onScreenRecordingChanged.listen(events.add);

      controller.add(true);
      await Future<void>.delayed(Duration.zero);

      expect(events, [true]);
      await subscription.cancel();
      await controller.close();
    });

    test('remembers the screen recording state for listeners that arrive late', () async {
      final controller = StreamController<bool>.broadcast();
      final platform = PigeonScreenshotShield(hostApi: _FakeHostApi(), screenRecordingStream: () => controller.stream);
      addTearDown(controller.close);
      expect(platform.isScreenRecording, isFalse);

      await platform.startListening();

      controller.add(true);
      await Future<void>.delayed(Duration.zero);
      // The broadcast stream never replays a change a late listener missed.
      expect(platform.isScreenRecording, isTrue);

      controller.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(platform.isScreenRecording, isFalse);
    });

    test('survives a screen recording stream that is never answered', () async {
      // With no stream provided the default event channel has no handler here,
      // so the subscription must swallow the error instead of surfacing it.
      final platform = PigeonScreenshotShield(hostApi: _FakeHostApi());
      await platform.startListening();
      await Future<void>.delayed(Duration.zero);

      expect(platform.isScreenRecording, isFalse);
    });
  });
}
