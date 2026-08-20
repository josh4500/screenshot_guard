import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield_example/main.dart';

class _FakePlatform extends ScreenshotShieldPlatform {
  final controller = StreamController<void>.broadcast();

  @override
  Stream<void> get onScreenshotDetected => controller.stream;

  @override
  Future<void> startListening() async {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> setProtected({required bool protected}) async {}

  @override
  Future<void> setBackgroundBlur({required bool blurEnabled}) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('home screen renders guarded content', (tester) async {
    ScreenshotShieldPlatform.instance = _FakePlatform();
    await tester.pumpWidget(
      ScreenshotShieldScope(
        shield: ScreenshotShield(),
        routeObserver: routeObserver,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('This screen is protected.\nTry taking a screenshot.'), findsOneWidget);
    expect(find.text('No screenshot detected yet.'), findsOneWidget);
  });
}
