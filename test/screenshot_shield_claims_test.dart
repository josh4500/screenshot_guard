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
}
