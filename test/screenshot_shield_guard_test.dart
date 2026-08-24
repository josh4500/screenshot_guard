import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

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
  Future<void> dispose() async {}
}

class _GuardHarness extends StatefulWidget {
  const _GuardHarness({
    required this.shield,
    this.onScreenshotDetected,
    this.captureOnScreenshot = true,
    this.detectScreenshots = true,
  });

  final ScreenshotShield shield;
  final ValueChanged<Uint8List?>? onScreenshotDetected;
  final bool captureOnScreenshot;
  final bool detectScreenshots;

  @override
  State<_GuardHarness> createState() => _GuardHarnessState();
}

class _GuardHarnessState extends State<_GuardHarness> {
  bool _active = true;

  @override
  Widget build(BuildContext context) {
    return ScreenshotShieldScope(
      shield: widget.shield,
      child: Scaffold(
        body: Column(
          children: [
            ScreenshotShieldGuard(
              active: _active,
              onScreenshotDetected: widget.onScreenshotDetected,
              captureOnScreenshot: widget.captureOnScreenshot,
              detectScreenshots: widget.detectScreenshots,
              child: const Text('guarded'),
            ),
            TextButton(
              onPressed: () => setState(() => _active = !_active),
              child: const Text('toggle'),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  late _FakeScreenshotShieldPlatform platform;
  late ScreenshotShield shield;

  setUp(() {
    platform = _FakeScreenshotShieldPlatform();
    ScreenshotShieldPlatform.instance = platform;
    shield = ScreenshotShield();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('ScreenshotShieldGuard', () {
    testWidgets('activates protection and listening while active', (tester) async {
      await tester.pumpWidget(_GuardHarness(shield: shield));
      await tester.pump();

      expect(platform.calls, contains('startListening'));
      expect(platform.calls, contains('setProtected:true'));
    });

    testWidgets('releases protection and listening when deactivated', (tester) async {
      await tester.pumpWidget(_GuardHarness(shield: shield));
      await tester.pump();

      await tester.tap(find.text('toggle'));
      await tester.pump();

      expect(platform.calls, contains('setProtected:false'));
      expect(platform.calls, contains('stopListening'));
    });

    testWidgets('re-activates protection and listening when activated again', (tester) async {
      await tester.pumpWidget(_GuardHarness(shield: shield));
      await tester.pump();

      await tester.tap(find.text('toggle'));
      await tester.pump();

      await tester.tap(find.text('toggle'));
      await tester.pump();

      expect(platform.calls, contains('setProtected:true'));
      expect(platform.calls, contains('startListening'));
    });

    testWidgets('invokes onScreenshotDetected while active', (tester) async {
      var screenshots = 0;
      await tester.pumpWidget(
        _GuardHarness(shield: shield, onScreenshotDetected: (_) => screenshots++, captureOnScreenshot: false),
      );
      await tester.pump();

      platform.controller.add(null);
      await tester.pump();

      expect(screenshots, 1);
    });

    testWidgets('does not invoke onScreenshotDetected while inactive', (tester) async {
      var screenshots = 0;
      await tester.pumpWidget(
        _GuardHarness(shield: shield, onScreenshotDetected: (_) => screenshots++, captureOnScreenshot: false),
      );
      await tester.pump();

      await tester.tap(find.text('toggle'));
      await tester.pump();

      platform.controller.add(null);
      await tester.pump();

      expect(screenshots, 0);
    });

    testWidgets('passes a PNG of the guarded subtree to onScreenshotDetected', (tester) async {
      Uint8List? captured;
      await tester.pumpWidget(_GuardHarness(shield: shield, onScreenshotDetected: (image) => captured = image));
      await tester.pump();

      platform.controller.add(null);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.isNotEmpty, isTrue);
    });

    testWidgets('passes null to onScreenshotDetected when captureOnScreenshot is false', (tester) async {
      Uint8List? captured;
      await tester.pumpWidget(
        _GuardHarness(shield: shield, onScreenshotDetected: (image) => captured = image, captureOnScreenshot: false),
      );
      await tester.pump();

      platform.controller.add(null);
      await tester.pump();

      expect(captured, isNull);
    });

    testWidgets('releases protection and listening when disposed', (tester) async {
      await tester.pumpWidget(_GuardHarness(shield: shield));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(platform.calls, contains('setProtected:false'));
      expect(platform.calls, contains('stopListening'));
    });

    testWidgets('on Android, drops capture prevention so detection can fire when both are requested', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(_GuardHarness(shield: shield));
      await tester.pump();

      expect(platform.calls, contains('startListening'));
      expect(platform.calls, isNot(contains('setProtected:true')));
    });

    testWidgets('on Android, still prevents capture when detection is disabled', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(_GuardHarness(shield: shield, detectScreenshots: false));
      await tester.pump();

      expect(platform.calls, contains('setProtected:true'));
      expect(platform.calls, isNot(contains('startListening')));
    });
  });
}
