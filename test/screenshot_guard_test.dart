import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_guard/screenshot_guard.dart';
import 'package:screenshot_guard/screenshot_guard_platform_interface.dart';
import 'package:screenshot_guard/src/pigeon_screenshot_guard.dart';

class _FakeScreenshotGuardPlatform extends ScreenshotGuardPlatform {
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

  group('ScreenshotGuardPlatform.instance', () {
    test('defaults to the Pigeon implementation', () {
      expect(ScreenshotGuardPlatform.instance, isA<PigeonScreenshotGuard>());
    });
  });

  group('ScreenshotGuard', () {
    late _FakeScreenshotGuardPlatform fakePlatform;
    late ScreenshotGuard screenshotGuard;

    setUp(() {
      fakePlatform = _FakeScreenshotGuardPlatform();
      ScreenshotGuardPlatform.instance = fakePlatform;
      screenshotGuard = ScreenshotGuard();
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
