import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/screenshot_shield_platform_interface.dart';
import 'package:screenshot_shield/src/screenshot_shield_claims.dart';

/// Tracks the host's state the way the native side does: one listening flag and one
/// protection flag, no counting.
class _HostStatePlatform extends ScreenshotShieldPlatform {
  int listeners = 0;
  bool protected = false;
  final calls = <String>[];

  @override
  Stream<void> get onScreenshotDetected => const Stream<void>.empty();

  @override
  Future<void> startListening() async {
    listeners++;
    calls.add('startListening');
  }

  @override
  Future<void> stopListening() async {
    listeners--;
    calls.add('stopListening');
  }

  @override
  Future<void> setProtected({required bool protected}) async {
    this.protected = protected;
    calls.add('setProtected:$protected');
  }

  @override
  Future<void> setBackgroundBlur({required bool blurEnabled}) async {}

  @override
  Future<void> dispose() async {}
}

/// Like the real channel: the first startListening completes only when [releaseStart]
/// is called, so guards can be reconfigured or removed while it is in flight.
class _SlowStartPlatform extends _HostStatePlatform {
  // Created on first use, inside the test's fake-async zone: a completer created in
  // setUp belongs to the real zone, and its continuation would never run while pumping.
  Completer<void>? _start;

  void releaseStart() => (_start ??= Completer<void>()).complete();

  @override
  Future<void> startListening() async {
    await (_start ??= Completer<void>()).future;
    await super.startListening();
  }
}

class _TwoGuards extends StatefulWidget {
  const _TwoGuards({required this.shield});

  final ScreenshotShield shield;

  @override
  State<_TwoGuards> createState() => _TwoGuardsState();
}

class _TwoGuardsState extends State<_TwoGuards> {
  bool firstActive = true;
  bool secondActive = true;
  bool secondDetects = true;
  bool secondPrevents = true;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    return ScreenshotShieldScope(
      shield: widget.shield,
      child: MaterialApp(
        home: Column(
          children: [
            ScreenshotShieldGuard(active: firstActive, forcePreventCapture: true, child: const Text('first')),
            ScreenshotShieldGuard(
              active: secondActive,
              detectScreenshots: secondDetects,
              preventCapture: secondPrevents,
              forcePreventCapture: true,
              child: const Text('second'),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  late _HostStatePlatform platform;
  late ScreenshotShield shield;

  setUp(() {
    ProtectionClaims.reset();
    platform = _HostStatePlatform();
    shield = ScreenshotShield(platform: platform);
  });

  testWidgets('protection stays on until the last guard that needs it leaves', (tester) async {
    await tester.pumpWidget(_TwoGuards(shield: shield));
    await tester.pumpAndSettle();
    expect(platform.protected, isTrue);

    final state = tester.state<_TwoGuardsState>(find.byType(_TwoGuards));
    state.update(() => state.firstActive = false);
    await tester.pumpAndSettle();
    expect(platform.protected, isTrue, reason: 'the second guard still needs protection');

    state.update(() => state.secondActive = false);
    await tester.pumpAndSettle();
    expect(platform.protected, isFalse);
  });

  testWidgets("changing a guard's settings never adds or removes extra listeners", (tester) async {
    await tester.pumpWidget(_TwoGuards(shield: shield));
    await tester.pumpAndSettle();
    expect(platform.listeners, 2, reason: 'one listening slot per guard');

    final state = tester.state<_TwoGuardsState>(find.byType(_TwoGuards));
    // Toggling detection off and back on must give back exactly what was taken.
    state.update(() => state.secondDetects = false);
    await tester.pumpAndSettle();
    expect(platform.listeners, 1, reason: 'turning detection off on one guard keeps the other listening');
    state.update(() => state.secondDetects = true);
    await tester.pumpAndSettle();
    expect(platform.listeners, 2, reason: 'and turning it back on takes exactly one slot again');

    // Changing an unrelated setting must not take another slot.
    state.update(() => state.secondPrevents = false);
    await tester.pumpAndSettle();
    expect(platform.listeners, 2, reason: 'changing preventCapture leaves listening alone');
    expect(platform.protected, isTrue, reason: 'the first guard still protects the window');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(platform.listeners, 0);
    expect(platform.protected, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('while a platform call is in flight', () {
    late _SlowStartPlatform slow;

    setUp(() {
      slow = _SlowStartPlatform();
      shield = ScreenshotShield(platform: slow);
    });

    testWidgets('a guard removed before listening starts leaves nothing protected', (tester) async {
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          child: const ScreenshotShieldGuard(child: SizedBox()),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(ScreenshotShieldScope(shield: shield, child: const SizedBox()));
      slow.releaseStart();
      await tester.pumpAndSettle();

      expect(slow.protected, isFalse);
      expect(ProtectionClaims.count, 0);
      expect(slow.listeners, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a guarded route covered at once by another route is not left protected', (tester) async {
      final observer = RouteObserver<ModalRoute<void>>();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ScreenshotShieldScope(
          shield: shield,
          routeObserver: observer,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [observer],
            home: const ScreenshotShieldRouteGuard(child: Text('guarded')),
          ),
        ),
      );
      // Push over the guarded route before the start reply arrives.
      navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('open')));
      await tester.pump();
      slow.releaseStart();
      await tester.pumpAndSettle();
      expect(slow.protected, isFalse, reason: 'the guarded route is not in view');

      // Removing the guarded route entirely must not leave anything behind either.
      navigatorKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const Text('home')),
        (_) => false,
      );
      await tester.pumpAndSettle();
      expect(slow.protected, isFalse);
      expect(ProtectionClaims.count, 0);
      expect(slow.listeners, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('a guard reconfigured mid-call ends with its latest settings', (tester) async {
      Widget guard({required bool preventCapture}) => ScreenshotShieldScope(
        shield: shield,
        child: ScreenshotShieldGuard(preventCapture: preventCapture, child: const SizedBox()),
      );
      await tester.pumpWidget(guard(preventCapture: false));
      await tester.pump();
      await tester.pumpWidget(guard(preventCapture: true));
      slow.releaseStart();
      await tester.pumpAndSettle();

      expect(slow.protected, isTrue, reason: 'the guard now asks for prevention');
      expect(ProtectionClaims.count, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
