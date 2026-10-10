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
/// Requests only record the state the guard wants. A single queue then brings what is
/// held in line with the *latest* wanted state, one step at a time: platform calls are
/// asynchronous, so a guard can be reconfigured or disposed while an earlier change is
/// still in flight, and applying each request's own arguments in turn would leak a
/// claim (disposed mid-acquire) or drop one that is still wanted.
class GuardClaims {
  ScreenshotShield? _wantedShield;
  bool _wantListen = false;
  bool _wantProtect = false;

  ScreenshotShield? _shield;
  bool _listening = false;
  bool _protecting = false;

  Future<void> _queue = Future<void>.value();

  /// Asks to hold exactly [listen] and [protect] on [shield].
  Future<void> apply(ScreenshotShield shield, {required bool listen, required bool protect}) {
    _wantedShield = shield;
    _wantListen = listen;
    _wantProtect = protect;
    return _schedule();
  }

  /// Asks to give back everything this guard holds.
  Future<void> release() {
    _wantListen = false;
    _wantProtect = false;
    return _schedule();
  }

  Future<void> _schedule() {
    final Future<void> step = _queue.then((_) => _reconcile());
    // A failed platform call must not stall later steps.
    _queue = step.catchError((Object _) {});
    return step;
  }

  /// Applies the latest wanted state; earlier queued steps may already have done so.
  Future<void> _reconcile() async {
    if (!identical(_wantedShield, _shield)) {
      await _giveBack();
      _shield = _wantedShield;
    }
    final ScreenshotShield? shield = _shield;
    if (shield == null) {
      return;
    }
    if (_wantListen != _listening) {
      _listening = _wantListen;
      await (_listening ? shield.startListening() : shield.stopListening());
    }
    // Re-read: a request may have arrived while listening changed.
    if (_wantProtect != _protecting) {
      _protecting = _wantProtect;
      await (_protecting ? ProtectionClaims.acquire(shield) : ProtectionClaims.release(shield));
    }
    if (_wantListen != _listening || _wantProtect != _protecting) {
      // Something changed while awaiting; converge before this step completes.
      await _reconcile();
    }
  }

  /// Releases what is held on the current shield (used when the shield changes).
  Future<void> _giveBack() async {
    final ScreenshotShield? shield = _shield;
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
