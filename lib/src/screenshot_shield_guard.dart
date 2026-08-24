import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/src/screenshot_shield_guard_config.dart';

/// A widget that guards its subtree against screen capture without relying on
/// route navigation.
///
/// Unlike [ScreenshotShieldRouteGuard], which ties protection to the enclosing
/// route being the top-most route, this guard activates while the widget is
/// mounted and [active] is `true`. Use it for screens that are not managed by
/// a `Navigator` with a [RouteObserver] (for example custom tabs, embedded
/// views, or an overlay), and toggle [active] yourself when the screen is
/// hidden by other means.
///
/// While active the guard starts listening for screenshots and (optionally)
/// prevents capture; both are released when [active] becomes `false` or the
/// widget is disposed.
///
/// The [ScreenshotShield] is read from the nearest [ScreenshotShieldScope].
class ScreenshotShieldGuard extends StatefulWidget {
  const ScreenshotShieldGuard({
    super.key,
    required this.child,
    this.active = true,
    this.preventCapture = true,
    this.detectScreenshots = true,
    this.captureOnScreenshot = true,
    this.onScreenshotDetected,
  });

  /// The subtree guarded while the guard is active.
  final Widget child;

  /// Whether the guard is currently active. When `false`, protection and
  /// screenshot listening are released. Defaults to `true`.
  final bool active;

  /// Whether capture prevention is enabled while the guard is active. On
  /// Android this blanks the captured frame via the secure window flag, but
  /// that flag also suppresses screenshot detection, so on Android detection
  /// wins when [detectScreenshots] is also enabled. Defaults to `true`.
  final bool preventCapture;

  /// Whether the guard listens for screenshots while it is active.
  /// Defaults to `true`.
  final bool detectScreenshots;

  /// Whether the guarded subtree is re-rasterized into a PNG when a screenshot
  /// is detected. The PNG bytes are passed to [onScreenshotDetected]; set to
  /// `false` to skip the capture overhead. Defaults to `true`.
  final bool captureOnScreenshot;

  /// Invoked each time a screenshot is captured while the guard is active.
  ///
  /// The argument is a PNG-encoded image of the guarded subtree when
  /// [captureOnScreenshot] is enabled, or `null` if the capture was skipped or
  /// failed. Use it to show the user a shareable copy of the screen.
  final ValueChanged<Uint8List?>? onScreenshotDetected;

  @override
  State<ScreenshotShieldGuard> createState() => _ScreenshotShieldGuardState();
}

class _ScreenshotShieldGuardState extends State<ScreenshotShieldGuard> {
  ScreenshotShield? _shield;
  StreamSubscription<void>? _screenshotSubscription;
  final GlobalKey _boundaryKey = GlobalKey();
  bool _active = false;

  /// Whether capture prevention should be applied, accounting for the Android
  /// conflict where the secure window flag suppresses screenshot detection.
  bool get _shouldPrevent =>
      shouldPreventCapture(
        preventCapture: widget.preventCapture,
        detectScreenshots: widget.detectScreenshots,
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
        oldWidget.detectScreenshots != widget.detectScreenshots) {
      unawaited(_syncActivation());
    }
  }

  Future<void> _syncActivation() async {
    if (!mounted || _shield == null) {
      return;
    }
    if (widget.active) {
      if (_active) {
        await _resync();
      } else {
        await _enter();
      }
    } else if (_active) {
      await _leave();
    }
  }

  Future<void> _enter() async {
    if (_active) {
      return;
    }
    _active = true;
    final shield = _shield!;
    if (widget.detectScreenshots) {
      await shield.startListening();
    }
    if (_shouldPrevent) {
      await shield.setProtection(preventCapture: true);
    }
  }

  Future<void> _leave() async {
    if (!_active) {
      return;
    }
    _active = false;
    final shield = _shield!;
    if (_shouldPrevent) {
      await shield.setProtection(preventCapture: false);
    }
    if (widget.detectScreenshots) {
      await shield.stopListening();
    }
  }

  Future<void> _resync() async {
    if (!_active) {
      return;
    }
    final shield = _shield!;
    if (widget.detectScreenshots) {
      await shield.startListening();
    } else {
      await shield.stopListening();
    }
    if (_shouldPrevent) {
      await shield.setProtection(preventCapture: true);
    } else {
      await shield.setProtection(preventCapture: false);
    }
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
    unawaited(_leave());
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
