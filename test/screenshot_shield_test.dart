import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/pigeon_screenshot_shield.dart';

class _FakeScreenshotShieldPlatform extends ScreenshotShieldPlatform {
  final controller = StreamController<void>.broadcast();
  final calls = <String>[];

  @override
  Stream<void> get onScreenshotDetected => controller.stream;

  @override
  Future<void> startListening() async => calls.add('startListening');

  @override
  Future<void> stopListening() async => calls.add('stopListening');

  @override
  Future<void> setProtected({required bool protected}) async => calls.add('setProtected:$protected');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenshotShieldPlatform.instance', () {
    test('defaults to the Pigeon implementation', () {
      expect(ScreenshotShieldPlatform.instance, isA<PigeonScreenshotShield>());
    });
  });

  group('ScreenshotShield', () {
    late _FakeScreenshotShieldPlatform fakePlatform;
    late ScreenshotShield screenshotGuard;

    setUp(() {
      fakePlatform = _FakeScreenshotShieldPlatform();
      ScreenshotShieldPlatform.instance = fakePlatform;
      screenshotGuard = ScreenshotShield();
    });

    tearDown(() async {
      await screenshotGuard.dispose();
    });

    test('forwards startListening to the platform', () async {
      await screenshotGuard.startListening();

      expect(fakePlatform.calls, contains('startListening'));
    });

    test('forwards stopListening to the platform', () async {
      await screenshotGuard.stopListening();

      expect(fakePlatform.calls, contains('stopListening'));
    });

    test('forwards setProtected to the platform', () async {
      await screenshotGuard.setProtected(protected: true);

      expect(fakePlatform.calls, contains('setProtected:true'));
    });

    test('forwards onScreenshotDetected events', () async {
      final events = <void>[];
      final subscription = screenshotGuard.onScreenshotDetected.listen(events.add);

      fakePlatform.controller.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      await subscription.cancel();
    });
  });
}
