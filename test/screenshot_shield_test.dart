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
  Future<void> setBackgroundBlur({required bool blurEnabled}) async => calls.add('setBackgroundBlur:$blurEnabled');

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

    test('forwards preventCapture to the platform', () async {
      await screenshotGuard.setProtection(preventCapture: true);

      expect(fakePlatform.calls, contains('setProtected:true'));
    });

    test('forwards backgroundBlur to the platform', () async {
      await screenshotGuard.setProtection(backgroundBlur: true);

      expect(fakePlatform.calls, contains('setBackgroundBlur:true'));
    });

    test('omitted protection flags are not forwarded', () async {
      await screenshotGuard.setProtection();

      expect(fakePlatform.calls, isEmpty);
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
