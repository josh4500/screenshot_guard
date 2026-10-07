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

    group('on iOS', () {
      late int? viewId;
      late List<MethodCall> viewCalls;

      void mockPlatformViews() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          (MethodCall call) async {
            if (call.method == 'create') {
              viewId = (call.arguments as Map<Object?, Object?>)['id'] as int;
              // The widget addresses its own platform view on a per-view
              // channel; answer it before Flutter reports the view as created.
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
                MethodChannel('screenshot_shield/sensitive_view/$viewId'),
                (MethodCall call) async {
                  viewCalls.add(call);
                  return null;
                },
              );
            }
            return null;
          },
        );
      }

      setUp(() {
        viewId = null;
        viewCalls = <MethodCall>[];
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        );
        if (viewId != null) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel('screenshot_shield/sensitive_view/$viewId'),
            null,
          );
        }
      });

      testWidgets('covers the child with the placeholder and a native region', (WidgetTester tester) async {
        mockPlatformViews();
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: ScreenshotShieldSensitiveView(placeholderColor: Color(0xFF112233), child: Text('secret')),
            ),
          ),
        );
        await tester.pump();

        // The subtree stays in the tree (it is what gets rasterised), but it is
        // covered by the opaque placeholder and by the native region.
        expect(find.text('secret'), findsOneWidget);
        expect(find.byType(UiKitView), findsOneWidget);
        final ColoredBox placeholder = tester.widget<ColoredBox>(find.byType(ColoredBox));
        expect(placeholder.color, const Color(0xFF112233));
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('stands down while whole-window prevention is enabled', (WidgetTester tester) async {
        mockPlatformViews();
        await ScreenshotShield(platform: _FakeShieldPlatform()).setProtection(preventCapture: true);

        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: ScreenshotShieldSensitiveView(child: Text('secret'))),
          ),
        );
        await tester.pump();

        // No platform view, no placeholder, and no rasterising: the window is
        // already excluded from captures.
        expect(find.text('secret'), findsOneWidget);
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(ColoredBox), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('activates when whole-window prevention is released', (WidgetTester tester) async {
        mockPlatformViews();
        final ScreenshotShield shield = ScreenshotShield(platform: _FakeShieldPlatform());
        await shield.setProtection(preventCapture: true);

        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: ScreenshotShieldSensitiveView(child: Text('secret'))),
          ),
        );
        await tester.pump();
        expect(find.byType(UiKitView), findsNothing);

        await shield.setProtection(preventCapture: false);
        await tester.pump();

        expect(find.byType(UiKitView), findsOneWidget);
        expect(find.byType(ColoredBox), findsOneWidget);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

      testWidgets('sends the rasterised subtree to its platform view', (WidgetTester tester) async {
        mockPlatformViews();
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: ScreenshotShieldSensitiveView(child: Text('secret'))),
          ),
        );
        await tester.pump();

        for (var i = 0; i < 4; i++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        }
        await tester.pump();

        expect(viewId, isNotNull);
        expect(viewCalls.map((MethodCall call) => call.method), contains('setSnapshot'));
        final MethodCall snapshot = viewCalls.firstWhere((MethodCall call) => call.method == 'setSnapshot');
        final Uint8List bytes = (snapshot.arguments as Map<Object?, Object?>)['bytes']! as Uint8List;
        expect(bytes, isNotEmpty);
        // PNG signature.
        expect(bytes.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    });
  });
}
