import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/screenshot_shield_sensitive_view.dart';

class _FakeShieldPlatform extends ScreenshotShieldPlatform {
  final StreamController<bool> recording = StreamController<bool>.broadcast();
  final List<String> calls = <String>[];
  StreamSubscription<bool>? _subscription;

  @override
  Stream<bool> get onScreenRecordingChanged => recording.stream;

  @override
  Future<void> startListening() async {
    calls.add('startListening');
    // Mirror PigeonScreenshotShield: cache the state so later widgets can read it.
    _subscription ??= recording.stream.listen(reportScreenRecordingState, onError: (Object _) {});
  }

  @override
  Future<void> stopListening() async => calls.add('stopListening');

  @override
  Future<void> setProtected({required bool protected}) async => calls.add('setProtected:$protected');
}

void main() {
  // Prevention is process-wide, so each test starts from a known state.
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
      expect(find.byType(ScreenshotShieldRegionLayout), findsNothing);
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
    late _FakeShieldPlatform platform;
    late ScreenshotShield shield;
    late List<MethodCall> viewCalls;
    late bool respondToSnapshots;
    late int createCalls;

    setUp(() {
      platform = _FakeShieldPlatform();
      shield = ScreenshotShield(platform: platform);
      viewCalls = <MethodCall>[];
      respondToSnapshots = true;
      createCalls = 0;
      final TestDefaultBinaryMessenger messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Stays installed through teardown: disposal also talks to this channel.
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (MethodCall call) async {
        if (call.method == 'create') {
          createCalls++;
          final int viewId = (call.arguments as Map<Object?, Object?>)['id'] as int;
          if (respondToSnapshots) {
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

    tearDown(() async {
      await platform.recording.close();
    });

    /// Lets the rasterise -> channel round trip complete.
    Future<void> settleSnapshot(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pump();
    }

    /// Broadcast delivery can land after the frame `pump` started, so pump twice.
    Future<void> emitRecording(WidgetTester tester, bool recording) async {
      platform.recording.add(recording);
      await tester.pump();
      await tester.pump();
    }

    int snapshotCount() => viewCalls.where((MethodCall call) => call.method == 'setSnapshot').length;

    Widget region({
      Widget? child,
      SensitiveProtection protection = SensitiveProtection.whileCaptured,
      bool enabled = true,
      Duration? refreshInterval,
      Color? captureColor,
      Color? backdropColor,
    }) {
      return ScreenshotShieldScope(
        shield: shield,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ScreenshotShieldSensitiveView(
              protection: protection,
              enabled: enabled,
              refreshInterval: refreshInterval,
              captureColor: captureColor,
              backdropColor: backdropColor,
              child: child ?? const SizedBox(width: 200, height: 80, child: Text('secret')),
            ),
          ),
        ),
      );
    }

    RenderScreenshotShieldRegion renderRegion(WidgetTester tester) =>
        tester.renderObject<RenderScreenshotShieldRegion>(find.byType(ScreenshotShieldRegionLayout));

    testWidgets('lays out exactly like the bare child while idle', (WidgetTester tester) async {
      const Key childKey = Key('child');
      await tester.pumpWidget(region(child: const SizedBox(key: childKey, width: 120, height: 40)));
      final Rect regionRect = tester.getRect(find.byKey(childKey));
      expect(find.byType(UiKitView), findsNothing);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(key: childKey, width: 120, height: 40)),
        ),
      );
      final Rect bareRect = tester.getRect(find.byKey(childKey));

      expect(regionRect, bareRect);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('paints nothing over the subtree until a copy exists', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.always));

      expect(find.byType(UiKitView), findsOneWidget);
      expect(renderRegion(tester).captureColor, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('engages while the screen is being recorded', (WidgetTester tester) async {
      await tester.pumpWidget(region());
      expect(find.byType(UiKitView), findsNothing);

      await emitRecording(tester, true);
      expect(find.byType(UiKitView), findsOneWidget);
      await settleSnapshot(tester);
      expect(renderRegion(tester).captureColor, isNotNull);

      await emitRecording(tester, false);
      expect(find.byType(UiKitView), findsNothing);
      expect(renderRegion(tester).captureColor, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('engages when it appears while the screen is already being recorded', (WidgetTester tester) async {
      // The change event fired before this region existed and is not replayed.
      await tester.pumpWidget(const SizedBox());
      await shield.startListening();
      await emitRecording(tester, true);

      await tester.pumpWidget(region());

      expect(find.byType(UiKitView), findsOneWidget);
      await settleSnapshot(tester);
      expect(renderRegion(tester).captureColor, isNotNull);

      await emitRecording(tester, false);
      expect(find.byType(UiKitView), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('whileRecording ignores the app lifecycle entirely', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.whileRecording));
      expect(find.byType(UiKitView), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);

      await emitRecording(tester, true);
      expect(find.byType(UiKitView), findsOneWidget);
      await settleSnapshot(tester);
      expect(renderRegion(tester).captureColor, isNotNull);

      await emitRecording(tester, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);
      await emitRecording(tester, true);
      expect(find.byType(UiKitView), findsOneWidget);

      await emitRecording(tester, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('engages while the app is not in the foreground', (WidgetTester tester) async {
      await tester.pumpWidget(region());

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(UiKitView), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('always protection engages without recording', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.always));

      expect(find.byType(UiKitView), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('renders the child directly when disabled', (WidgetTester tester) async {
      await tester.pumpWidget(region(enabled: false, protection: SensitiveProtection.always));

      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(ScreenshotShieldRegionLayout), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('stands down while whole-window prevention is active', (WidgetTester tester) async {
      await ScreenshotShield(platform: _FakeShieldPlatform()).setProtection(preventCapture: true);

      await tester.pumpWidget(region(protection: SensitiveProtection.always));
      await tester.pump();

      expect(find.text('secret'), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      expect(renderRegion(tester).captureColor, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('engages when whole-window prevention is released', (WidgetTester tester) async {
      final ScreenshotShield other = ScreenshotShield(platform: _FakeShieldPlatform());
      await other.setProtection(preventCapture: true);

      await tester.pumpWidget(region(protection: SensitiveProtection.always));
      expect(find.byType(UiKitView), findsNothing);

      await other.setProtection(preventCapture: false);
      await tester.pump();
      expect(find.byType(UiKitView), findsOneWidget);

      await settleSnapshot(tester);
      expect(find.byType(UiKitView), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('sends raw RGBA pixels, their size and the backdrop colour', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.always, backdropColor: const Color(0xFF445566)));
      await settleSnapshot(tester);

      expect(snapshotCount(), greaterThanOrEqualTo(1));
      final MethodCall snapshot = viewCalls.firstWhere((MethodCall call) => call.method == 'setSnapshot');
      final Map<Object?, Object?> arguments = snapshot.arguments as Map<Object?, Object?>;
      final Uint8List bytes = arguments['bytes']! as Uint8List;
      final int width = arguments['width']! as int;
      final int height = arguments['height']! as int;

      expect(bytes.length, width * height * 4);
      expect(arguments['backdropColor'], const Color(0xFF445566).toARGB32());
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('gives the subtree the constraints it received, unchanged', (WidgetTester tester) async {
      BoxConstraints? seen;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 200,
                height: 100,
                child: ScreenshotShieldSensitiveView(
                  protection: SensitiveProtection.always,
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      seen = constraints;
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // The tight 200x100 constraints must reach the subtree untouched.
      expect(seen!.minWidth, 200);
      expect(seen!.minHeight, 100);
      expect(seen!.maxHeight, 100);
      expect(tester.getSize(find.byType(ScreenshotShieldRegionLayout)), const Size(200, 100));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('sizes the overlay exactly like the region', (WidgetTester tester) async {
      const Key childKey = Key('child');
      await tester.pumpWidget(
        region(
          protection: SensitiveProtection.always,
          child: const SizedBox(key: childKey, width: 120, height: 40),
        ),
      );
      await settleSnapshot(tester);

      expect(tester.getSize(find.byType(UiKitView)), tester.getSize(find.byKey(childKey)));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('keeps the child interactive while it is engaged', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        region(
          protection: SensitiveProtection.always,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 80),
          ),
        ),
      );
      await settleSnapshot(tester);

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();

      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('refreshes the copy when the subtree repaints', (WidgetTester tester) async {
      var value = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return ScreenshotShieldSensitiveView(
                    protection: SensitiveProtection.always,
                    child: SizedBox(width: 200, height: 80, child: Text('value $value')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await settleSnapshot(tester);
      final int afterFirstCopy = snapshotCount();

      rebuild(() => value++);
      await tester.pump();
      await settleSnapshot(tester);

      expect(find.text('value 1'), findsOneWidget);
      expect(snapshotCount(), greaterThan(afterFirstCopy));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('does not refresh while nothing repaints', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.always));
      await settleSnapshot(tester);
      final int afterFirstCopy = snapshotCount();

      await tester.pump();
      await tester.pump();
      await settleSnapshot(tester);

      expect(snapshotCount(), afterFirstCopy);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('refreshes the copy after the region is resized', (WidgetTester tester) async {
      var width = 200.0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return ScreenshotShieldSensitiveView(
                    protection: SensitiveProtection.always,
                    child: SizedBox(width: width, height: 80, child: const Text('secret')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await settleSnapshot(tester);
      final int afterFirstCopy = snapshotCount();

      rebuild(() => width = 320);
      await tester.pump();
      await settleSnapshot(tester);

      expect(tester.getSize(find.byType(UiKitView)).width, 320);
      expect(snapshotCount(), greaterThan(afterFirstCopy));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('throttles refreshes to refreshInterval', (WidgetTester tester) async {
      var value = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return ScreenshotShieldSensitiveView(
                    protection: SensitiveProtection.always,
                    refreshInterval: const Duration(seconds: 2),
                    child: SizedBox(width: 200, height: 80, child: Text('value $value')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await settleSnapshot(tester);
      final int afterFirstCopy = snapshotCount();

      rebuild(() => value++);
      await tester.pump();
      await settleSnapshot(tester);
      expect(snapshotCount(), afterFirstCopy);

      await tester.pump(const Duration(seconds: 2));
      await settleSnapshot(tester);
      expect(snapshotCount(), greaterThan(afterFirstCopy));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('creates the platform view once, not on every refresh', (WidgetTester tester) async {
      var value = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return ScreenshotShieldSensitiveView(
                    protection: SensitiveProtection.always,
                    child: SizedBox(width: 200, height: 80, child: Text('value $value')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await settleSnapshot(tester);

      rebuild(() => value++);
      await tester.pump();
      await settleSnapshot(tester);

      expect(createCalls, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('listens for recordings while watching, and stops on dispose', (WidgetTester tester) async {
      await tester.pumpWidget(region());
      expect(platform.calls, contains('startListening'));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(platform.calls, contains('stopListening'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('does not listen when it never watches for recordings', (WidgetTester tester) async {
      await tester.pumpWidget(region(protection: SensitiveProtection.always));

      expect(platform.calls, isNot(contains('startListening')));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
