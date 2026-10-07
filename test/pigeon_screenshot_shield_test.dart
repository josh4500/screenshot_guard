import 'dart:async';

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
      // Nothing has been reported yet.
      expect(platform.isScreenRecording, isFalse);

      await platform.startListening();

      controller.add(true);
      await Future<void>.delayed(Duration.zero);
      // Something mounting now has to learn this without any further event: the
      // broadcast stream never replays the change it missed.
      expect(platform.isScreenRecording, isTrue);

      controller.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(platform.isScreenRecording, isFalse);
    });

    test('survives a screen recording stream that is never answered', () async {
      // No stream is provided, so the default event channel has no handler here:
      // the eager subscription must swallow that rather than surface an unhandled
      // error to the caller.
      final platform = PigeonScreenshotShield(hostApi: _FakeHostApi());
      await platform.startListening();
      await Future<void>.delayed(Duration.zero);

      expect(platform.isScreenRecording, isFalse);
    });
  });
}
