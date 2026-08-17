import 'dart:async';
import 'dart:typed_data';

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
  Future<void> dispose() async {}
}

class _SecondScreen extends StatelessWidget {
  const _SecondScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('pop')),
      ),
    );
  }
}

class _ScopeReader extends StatelessWidget {
  const _ScopeReader({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

Widget _buildApp({
  required ScreenshotShield shield,
  required RouteObserver<ModalRoute<void>> routeObserver,
  required ValueChanged<Uint8List?>? onScreenshotDetected,
  bool preventCapture = true,
  bool detectScreenshots = true,
  bool captureOnScreenshot = true,
}) {
  return ScreenshotShieldScope(
    shield: shield,
    routeObserver: routeObserver,
    child: MaterialApp(
      navigatorObservers: [routeObserver],
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              ScreenshotShieldRouteGuard(
                onScreenshotDetected: onScreenshotDetected,
                preventCapture: preventCapture,
                detectScreenshots: detectScreenshots,
                captureOnScreenshot: captureOnScreenshot,
                child: const Text('home'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _SecondScreen())),
                child: const Text('push'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _FakeScreenshotShieldPlatform platform;
  late ScreenshotShield shield;
  late RouteObserver<ModalRoute<void>> routeObserver;

  setUp(() {
    platform = _FakeScreenshotShieldPlatform();
    ScreenshotShieldPlatform.instance = platform;
    shield = ScreenshotShield();
    routeObserver = RouteObserver<ModalRoute<void>>();
  });

  group('ScreenshotShieldScope', () {
    testWidgets('exposes the shield via context', (tester) async {
      ScreenshotShield? fromContext;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: _ScopeReader(
            builder: (context) {
              fromContext = ScreenshotShieldScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(fromContext, same(shield));
    });
  });

  group('ScreenshotShieldRouteGuard', () {
    testWidgets('activates protection and listening while the route is in view', (tester) async {
      await tester.pumpWidget(_buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: null));
      await tester.pump();

      expect(platform.calls, contains('startListening'));
      expect(platform.calls, contains('setProtected:true'));
    });

    testWidgets('releases protection and listening when covered by another route', (tester) async {
      await tester.pumpWidget(_buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: null));

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();

      expect(platform.calls, contains('setProtected:false'));
      expect(platform.calls, contains('stopListening'));
    });

    testWidgets('re-activates protection and listening when it becomes visible again', (tester) async {
      await tester.pumpWidget(_buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: null));

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('pop'));
      await tester.pumpAndSettle();

      expect(platform.calls, contains('setProtected:true'));
      expect(platform.calls, contains('startListening'));
    });

    testWidgets('invokes onScreenshotDetected while in view', (tester) async {
      var screenshots = 0;
      await tester.pumpWidget(
        _buildApp(
          shield: shield,
          routeObserver: routeObserver,
          onScreenshotDetected: (_) => screenshots++,
          captureOnScreenshot: false,
        ),
      );
      await tester.pump();

      platform.controller.add(null);
      await tester.pump();

      expect(screenshots, 1);
    });

    testWidgets('passes a PNG of the guarded subtree to onScreenshotDetected', (tester) async {
      Uint8List? captured;
      await tester.pumpWidget(
        _buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: (image) => captured = image),
      );
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
        _buildApp(
          shield: shield,
          routeObserver: routeObserver,
          onScreenshotDetected: (image) => captured = image,
          captureOnScreenshot: false,
        ),
      );
      await tester.pump();

      platform.controller.add(null);
      await tester.pump();

      expect(captured, isNull);
    });

    testWidgets('does not invoke onScreenshotDetected while covered', (tester) async {
      var screenshots = 0;
      await tester.pumpWidget(
        _buildApp(
          shield: shield,
          routeObserver: routeObserver,
          onScreenshotDetected: (_) => screenshots++,
          captureOnScreenshot: false,
        ),
      );

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();

      platform.controller.add(null);
      await tester.pump();

      expect(screenshots, 0);
    });

    testWidgets('skips setProtected when preventCapture is false', (tester) async {
      await tester.pumpWidget(
        _buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: null, preventCapture: false),
      );
      await tester.pump();

      expect(platform.calls, contains('startListening'));
      expect(platform.calls, isNot(contains('setProtected:true')));
      expect(platform.calls, isNot(contains('setProtected:false')));
    });

    testWidgets('skips listening when detectScreenshots is false', (tester) async {
      await tester.pumpWidget(
        _buildApp(shield: shield, routeObserver: routeObserver, onScreenshotDetected: null, detectScreenshots: false),
      );
      await tester.pump();

      expect(platform.calls, contains('setProtected:true'));
      expect(platform.calls, isNot(contains('startListening')));
      expect(platform.calls, isNot(contains('stopListening')));
    });

    testWidgets('asserts when used more than once on the same route', (tester) async {
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          routeObserver: routeObserver,
          child: MaterialApp(
            navigatorObservers: [routeObserver],
            home: Scaffold(
              body: Column(
                children: [
                  const ScreenshotShieldRouteGuard(child: Text('first')),
                  const ScreenshotShieldRouteGuard(child: Text('second')),
                ],
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });
  });
}
