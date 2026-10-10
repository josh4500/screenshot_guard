import 'package:flutter/foundation.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// Whole-window capture prevention requested by guards, counted across the process.
///
/// Prevention belongs to the window, not to a guard, so when one of two active guards
/// leaves it must not switch prevention off for the other. The window is protected while
/// at least one claim is held.
abstract final class ProtectionClaims {
  static int _count = 0;

  /// How many guards currently hold a claim.
  static int get count => _count;

  static Future<void> acquire(ScreenshotShield shield) async {
    _count++;
    if (_count == 1) {
      await shield.setProtection(preventCapture: true);
    }
  }

  static Future<void> release(ScreenshotShield shield) async {
    if (_count == 0) {
      return;
    }
    _count--;
    if (_count == 0) {
      await shield.setProtection(preventCapture: false);
    }
  }

  @visibleForTesting
  static void reset() => _count = 0;
}

/// What one guard currently holds on its [ScreenshotShield]: a listening slot and a
/// prevention claim.
///
/// Every change is applied exactly once, so re-applying the same configuration (a
/// rebuild, a settings change) never adds a second listener or drops a claim the guard
/// never took.
class GuardClaims {
  ScreenshotShield? _shield;
  bool _listening = false;
  bool _protecting = false;

  /// Brings the held claims on [shield] to the requested state.
  Future<void> apply(ScreenshotShield shield, {required bool listen, required bool protect}) async {
    if (!identical(shield, _shield)) {
      await release();
      _shield = shield;
    }
    // Flags flip before awaiting so an overlapping call sees the new state.
    if (listen != _listening) {
      _listening = listen;
      await (listen ? shield.startListening() : shield.stopListening());
    }
    if (protect != _protecting) {
      _protecting = protect;
      await (protect ? ProtectionClaims.acquire(shield) : ProtectionClaims.release(shield));
    }
  }

  /// Gives back everything this guard holds.
  Future<void> release() async {
    final shield = _shield;
    if (shield == null) {
      return;
    }
    if (_protecting) {
      _protecting = false;
      await ProtectionClaims.release(shield);
    }
    if (_listening) {
      _listening = false;
      await shield.stopListening();
    }
  }
}
