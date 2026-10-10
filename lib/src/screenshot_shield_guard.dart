import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/src/screenshot_shield_claims.dart';
import 'package:screenshot_shield/src/screenshot_shield_guard_config.dart';

/// Guards its subtree against screen capture while [active] is `true`.
///
/// Unlike [ScreenshotShieldRouteGuard], it is not tied to a route.
class ScreenshotShieldGuard extends StatefulWidget {
  const ScreenshotShieldGuard({
    super.key,
    required this.child,
    this.active = true,
    this.preventCapture = true,
    this.detectScreenshots = true,
    this.forcePreventCapture = false,
    this.captureOnScreenshot = true,
    this.onScreenshotDetected,
  });

  /// The subtree guarded while the guard is active.
  final Widget child;

  /// Whether the guard is active. When `false`, protection and listening stop.
  /// Defaults to `true`.
  final bool active;

  /// Whether capture prevention is enabled while active. On Android the secure
  /// flag also suppresses detection, so detection wins when [detectScreenshots]
  /// is enabled too. Defaults to `true`.
  final bool preventCapture;

  /// Whether the guard listens for screenshots while active. Defaults to `true`.
  final bool detectScreenshots;

  /// Whether capture prevention wins over detection on Android. Forcing it
  /// means [onScreenshotDetected] will not fire while the guard is active.
  /// Defaults to `false`.
  final bool forcePreventCapture;

  /// Whether the guarded subtree is re-rasterized into a PNG on detection, at
  /// extra cost. The bytes go to [onScreenshotDetected]. Defaults to `true`.
  final bool captureOnScreenshot;

  /// Called with a PNG of the guarded subtree, or `null` if capture was
  /// skipped or failed. Fires each time a screenshot is captured.
  final ValueChanged<Uint8List?>? onScreenshotDetected;

  @override
  State<ScreenshotShieldGuard> createState() => _ScreenshotShieldGuardState();
}

class _ScreenshotShieldGuardState extends State<ScreenshotShieldGuard> {
  ScreenshotShield? _shield;
  StreamSubscription<void>? _screenshotSubscription;
  final GlobalKey _boundaryKey = GlobalKey();
  final GuardClaims _claims = GuardClaims();
  bool _active = false;

  /// Whether prevention applies; see [preventCapture] for the Android conflict.
  bool get _shouldPrevent => shouldPreventCapture(
    preventCapture: widget.preventCapture,
    detectScreenshots: widget.detectScreenshots,
    forcePreventCapture: widget.forcePreventCapture,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShield();
    unawaited(_syncActivation());
  }

  void _syncShield() {
    final shield = ScreenshotShieldScope.of(context);
    if (shield == _shield) {
      return;
    }
    _shield = shield;
    _screenshotSubscription?.cancel();
    _screenshotSubscription = shield.onScreenshotDetected.listen((_) async {
      if (!_active) {
        return;
      }
      final image = widget.captureOnScreenshot ? await _captureChild() : null;
      widget.onScreenshotDetected?.call(image);
    });
  }

  @override
  void didUpdateWidget(ScreenshotShieldGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.preventCapture != widget.preventCapture ||
        oldWidget.detectScreenshots != widget.detectScreenshots ||
        oldWidget.forcePreventCapture != widget.forcePreventCapture) {
      unawaited(_syncActivation());
    }
  }

  Future<void> _syncActivation() async {
    final shield = _shield;
    if (!mounted || shield == null) {
      return;
    }
    _active = widget.active;
    await _claims.apply(shield, listen: _active && widget.detectScreenshots, protect: _active && _shouldPrevent);
  }

  Future<Uint8List?> _captureChild() async {
    final renderObject = _boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      return null;
    }
    try {
      final image = await renderObject.toImage(pixelRatio: MediaQuery.of(context).devicePixelRatio);
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _screenshotSubscription?.cancel();
    _active = false;
    unawaited(_claims.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.captureOnScreenshot) {
      return widget.child;
    }
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }
}
