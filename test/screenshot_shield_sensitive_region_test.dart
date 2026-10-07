import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

class _FakePlatform extends ScreenshotShieldPlatform {
  final StreamController<bool> recording = StreamController<bool>.broadcast();
  final List<String> calls = <String>[];

  @override
  Stream<bool> get onScreenRecordingChanged => recording.stream;

  @override
  Future<void> startListening() async => calls.add('startListening');

  @override
  Future<void> stopListening() async => calls.add('stopListening');
}

const Key _coverKey = Key('cover');
const Key _childKey = Key('child');

Widget _harness({
  required ScreenshotShield shield,
  bool? shielded,
  bool shieldWhileRecording = true,
  bool shieldInBackground = true,
  double? blur,
  Widget? shieldWidget,
  VoidCallback? onTap,
}) {
  return ScreenshotShieldScope(
    shield: shield,
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 20, child: Text('sibling', key: Key('sibling'))),
              SizedBox(
                width: 200,
                height: 60,
                child: ScreenshotShieldSensitiveRegion(
                  shielded: shielded,
                  shieldWhileRecording: shieldWhileRecording,
                  shieldInBackground: shieldInBackground,
                  blur: blur,
                  shield: shieldWidget ?? const ColoredBox(key: _coverKey, color: Colors.red),
                  child: GestureDetector(
                    key: _childKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap ?? () {},
                    child: const ColoredBox(color: Colors.deepOrange, child: Text('secret')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  late _FakePlatform platform;
  late ScreenshotShield shield;

  setUp(() {
    platform = _FakePlatform();
    shield = ScreenshotShield(platform: platform);
  });

  tearDown(() async {
    await platform.recording.close();
  });

  Finder cover() => find.byKey(_coverKey);

  /// Broadcast events are delivered in a microtask, which can land after the
  /// frame `pump` started, so rebuild once more.
  Future<void> emit(WidgetTester tester, bool recording) async {
    platform.recording.add(recording);
    await tester.pump();
    await tester.pump();
  }

  group('ScreenshotShieldSensitiveRegion', () {
    testWidgets('does not shield a foregrounded app that is not being recorded', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield));

      expect(cover(), findsNothing);
      expect(find.text('secret'), findsOneWidget);
      // It took responsibility for the recording state.
      expect(platform.calls, contains('startListening'));
    });

    testWidgets('shields while the screen is being recorded', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield));

      await emit(tester, true);
      expect(cover(), findsOneWidget);

      await emit(tester, false);
      expect(cover(), findsNothing);
    });

    testWidgets('shields while the app is not in the foreground', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(cover(), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(cover(), findsNothing);
    });

    testWidgets('stops listening and releases it when disposed', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(platform.calls, ['startListening', 'stopListening']);
    });

    testWidgets('does not shield or listen when recording shielding is disabled', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield, shieldWhileRecording: false));

      await emit(tester, true);

      expect(cover(), findsNothing);
      expect(platform.calls, isEmpty);
    });

    testWidgets('does not shield for the background when that is disabled', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield, shieldInBackground: false));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(cover(), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    });

    testWidgets('the shielded override wins over the automatic triggers', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield, shielded: true));
      expect(cover(), findsOneWidget);

      await tester.pumpWidget(_harness(shield: shield, shielded: false));
      await emit(tester, true);
      expect(cover(), findsNothing);
    });

    testWidgets('keeps the layout unchanged while shielded', (WidgetTester tester) async {
      await tester.pumpWidget(_harness(shield: shield));
      final Rect before = tester.getRect(find.byKey(_childKey));
      final Rect siblingBefore = tester.getRect(find.byKey(const Key('sibling')));

      await emit(tester, true);

      expect(tester.getRect(find.byKey(_childKey)), before);
      expect(tester.getRect(find.byKey(const Key('sibling'))), siblingBefore);
    });

    testWidgets('while covered the child takes no pointers and no semantics', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(shield: shield, onTap: () => taps++));

      await emit(tester, true);

      await tester.tap(find.byKey(_coverKey), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);

      final ExcludeSemantics semantics = tester.widget<ExcludeSemantics>(
        find.ancestor(of: find.byKey(_childKey), matching: find.byType(ExcludeSemantics)).first,
      );
      expect(semantics.excluding, isTrue);
    });

    testWidgets('blurs the live child instead of covering it', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(shield: shield, blur: 8, onTap: () => taps++));

      await emit(tester, true);

      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(cover(), findsNothing);

      // Blurred content stays interactive.
      await tester.tap(find.byKey(_childKey));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('defaults the cover to the ambient scaffold background', (WidgetTester tester) async {
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Theme(
            data: ThemeData(scaffoldBackgroundColor: const Color(0xFF445566)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: ScreenshotShieldSensitiveRegion(shielded: true, child: const SizedBox(width: 100, height: 40)),
              ),
            ),
          ),
        ),
      );

      final ColoredBox coverBox = tester.widget<ColoredBox>(find.byType(ColoredBox));
      expect(coverBox.color, const Color(0xFF445566));
    });
  });
}
