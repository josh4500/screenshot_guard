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

    test('forwards stopListening to the host api', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.stopListening();

      expect(hostApi.calls, contains('stopListening'));
    });

    test('forwards setProtected to the host api', () async {
      final hostApi = _FakeHostApi();
      final platform = PigeonScreenshotShield(hostApi: hostApi);

      await platform.setProtected(protected: true);

      expect(hostApi.calls, contains('setProtected:true'));
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
  });
}
