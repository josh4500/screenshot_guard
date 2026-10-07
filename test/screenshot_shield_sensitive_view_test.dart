import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';

class _FakeShieldPlatform extends ScreenshotShieldPlatform {
  final List<String> calls = <String>[];

  @override
  Future<void> setProtected({required bool protected}) async => calls.add('setProtected:$protected');
}

void main() {
  // Capture prevention is process-wide state that mirrors the platform plugin,
  // so every test starts from a known state.
  setUp(() async {
    await ScreenshotShield(platform: _FakeShieldPlatform()).setProtection(preventCapture: false);
  });

  group('ScreenshotShieldSensitiveView', () {
    test('is supported on iOS only', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(ScreenshotShieldSensitiveView.isSupported, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(ScreenshotShieldSensitiveView.isSupported, isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(ScreenshotShieldSensitiveView.isSupported, isFalse);
    });

    testWidgets('builds the child directly where there is no native support', (WidgetTester tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: ScreenshotShieldSensitiveView(child: Text('secret')),
        ),
      );

      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(ColoredBox), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('leaves the child interactive where there is no native support', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ScreenshotShieldSensitiveView(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 100, height: 100),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('on iOS', () {
    late List<MethodCall> viewCalls;
    late bool respondToSnapshots;
    late int? viewId;
    late int createCalls;

    setUp(() {
      viewCalls = <MethodCall>[];
      respondToSnapshots = true;
      viewId = null;
      createCalls = 0;
      final TestDefaultBinaryMessenger messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Kept installed for the whole test (including teardown): disposing the
      // platform view talks to this channel too.
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (MethodCall call) async {
        if (call.method == 'create') {
          createCalls++;
          viewId = (call.arguments as Map<Object?, Object?>)['id'] as int;
          if (respondToSnapshots) {
            // The widget addresses its own platform view on a per-view channel.
            messenger.setMockMethodCallHandler(MethodChannel('screenshot_shield/sensitive_view/$viewId'), (
              MethodCall call,
            ) async {
              viewCalls.add(call);
              return null;
            });
          }
        }
        return null;
      });
    });

    /// Lets the rasterise -> channel round trip complete.
    Future<void> settleSnapshot(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pump();
    }

    Widget region({Color placeholder = const Color(0xFF112233), Widget? child}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ScreenshotShieldSensitiveView(placeholderColor: placeholder, child: child ?? const Text('secret')),
        ),
      );
    }

    testWidgets('does not paint the placeholder before a snapshot exists', (WidgetTester tester) async {
      // The capture cannot succeed, so the region must keep showing the live
      // child instead of an opaque rectangle.
      respondToSnapshots = false;

      await tester.pumpWidget(region());
      await settleSnapshot(tester);

      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);
      // The placeholder stays in the tree (so the platform view is not rebuilt)
      // but must be transparent while there is nothing to cover it.
      final ColoredBox placeholder = tester.widget<ColoredBox>(find.byType(ColoredBox));
      expect(placeholder.color, const Color(0x00000000));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('covers the child with the placeholder once a snapshot exists', (WidgetTester tester) async {
      await tester.pumpWidget(region());
      await settleSnapshot(tester);

      // The subtree stays in the tree (it is what gets rasterised), but it is
      // covered by the opaque placeholder and by the native region.
      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsOneWidget);
      final ColoredBox placeholder = tester.widget<ColoredBox>(find.byType(ColoredBox));
      expect(placeholder.color, const Color(0xFF112233));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('creates the platform view once, not on every snapshot', (WidgetTester tester) async {
      await tester.pumpWidget(region());
      await settleSnapshot(tester);

      expect(find.byType(ColoredBox), findsOneWidget);
      // A placeholder that appeared/disappeared with the snapshot state would
      // rebuild the platform view and loop forever.
      expect(createCalls, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('keeps the child interactive while it is protected', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        region(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 80),
          ),
        ),
      );
      await settleSnapshot(tester);
      // The placeholder is painted, and must still not swallow the tap.
      expect(find.byType(ColoredBox), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();

      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('stands down while whole-window prevention is enabled', (WidgetTester tester) async {
      await ScreenshotShield(platform: _FakeShieldPlatform()).setProtection(preventCapture: true);

      await tester.pumpWidget(region());
      await tester.pump();

      // No platform view, no placeholder, and no rasterising: the window is
      // already excluded from captures.
      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(ColoredBox), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('activates when whole-window prevention is released', (WidgetTester tester) async {
      final ScreenshotShield shield = ScreenshotShield(platform: _FakeShieldPlatform());
      await shield.setProtection(preventCapture: true);

      await tester.pumpWidget(region());
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);

      await shield.setProtection(preventCapture: false);
      await tester.pump();
      expect(find.byType(UiKitView), findsOneWidget);

      await settleSnapshot(tester);
      expect(find.byType(ColoredBox), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('sends the rasterised subtree to its platform view', (WidgetTester tester) async {
      await tester.pumpWidget(region());
      await settleSnapshot(tester);

      expect(viewId, isNotNull);
      expect(viewCalls.map((MethodCall call) => call.method), contains('setSnapshot'));
      final MethodCall snapshot = viewCalls.firstWhere((MethodCall call) => call.method == 'setSnapshot');
      final Uint8List bytes = (snapshot.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
      expect(bytes, isNotEmpty);
      // PNG signature.
      expect(bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
