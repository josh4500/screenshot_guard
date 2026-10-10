import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';
import 'package:screenshot_shield/src/screenshot_shield_claims.dart';
import 'package:screenshot_shield/src/screenshot_shield_guard_config.dart';

/// Scopes screenshot protection to the route it lives on.
///
/// Active while this route is top-most; one guard per route.
class ScreenshotShieldRouteGuard extends StatefulWidget {
  const ScreenshotShieldRouteGuard({
    super.key,
    required this.child,
    this.preventCapture = true,
    this.detectScreenshots = true,
    this.forcePreventCapture = false,
    this.captureOnScreenshot = true,
    this.onScreenshotDetected,
  });

  /// The subtree guarded while this route is in view.
  final Widget child;

  /// Whether capture prevention is enabled while the route is in view. On
  /// Android the secure flag also suppresses detection, so detection wins when
  /// [detectScreenshots] is enabled too. Defaults to `true`.
  final bool preventCapture;

  /// Whether the guard listens for screenshots while the route is in view.
  /// Defaults to `true`.
  final bool detectScreenshots;

  /// Whether capture prevention wins over detection on Android. Forcing it
  /// means [onScreenshotDetected] will not fire while the route is in view.
  /// Defaults to `false`.
  final bool forcePreventCapture;

  /// Whether the guarded subtree is re-rasterized into a PNG on detection, at
  /// extra cost. The bytes go to [onScreenshotDetected]. Defaults to `true`.
  final bool captureOnScreenshot;

  /// Called with a PNG of the guarded subtree, or `null` if capture was
  /// skipped or failed. Fires each time a screenshot is captured.
  final ValueChanged<Uint8List?>? onScreenshotDetected;

  @override
  State<ScreenshotShieldRouteGuard> createState() => _ScreenshotShieldRouteGuardState();
}

class _ScreenshotShieldRouteGuardState extends State<ScreenshotShieldRouteGuard> with RouteAware {
  static final Set<Route<dynamic>> _guardedRoutes = <Route<dynamic>>{};

  ScreenshotShield? _shield;
  StreamSubscription<void>? _screenshotSubscription;
  RouteObserver<ModalRoute<void>>? _routeObserver;
  Route<dynamic>? _registeredRoute;
  final GlobalKey _boundaryKey = GlobalKey();
  final GuardClaims _claims = GuardClaims();
  bool _inView = false;

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
    final routeObserver = ScreenshotShieldScope.routeObserverOf(context);
    assert(
      routeObserver != null,
      'ScreenshotShieldRouteGuard requires a RouteObserver. Provide one via '
      'ScreenshotShieldScope(routeObserver: ...) and register it with '
      'MaterialApp.navigatorObservers.',
    );
    if (routeObserver != _routeObserver) {
      _routeObserver?.unsubscribe(this);
      _routeObserver = routeObserver;
    }
    final route = ModalRoute.of(context);
    if (route != null && !_registerRoute(route)) {
      return;
    }
    if (route != null && _routeObserver != null) {
      _routeObserver!.subscribe(this, route);
    }
  }

  /// Registers this guard on [route]; reports an error if it is already guarded.
  bool _registerRoute(Route<dynamic> route) {
    if (route == _registeredRoute) {
      return true;
    }
    _unregister();
    if (_guardedRoutes.contains(route)) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: AssertionError(
            'Only one ScreenshotShieldRouteGuard can be used per route. '
            'A ScreenshotShieldRouteGuard is already mounted on this route; '
            'place a single guard around the screen you want to protect.',
          ),
          library: 'screenshot_shield',
          context: ErrorDescription('while mounting ScreenshotShieldRouteGuard'),
        ),
      );
      return false;
    }
    _guardedRoutes.add(route);
    _registeredRoute = route;
    return true;
  }

  void _unregister() {
    final route = _registeredRoute;
    if (route != null) {
      _guardedRoutes.remove(route);
      _registeredRoute = null;
    }
  }

  void _syncShield() {
    final shield = ScreenshotShieldScope.of(context);
    if (shield == _shield) {
      return;
    }
    _shield = shield;
    _screenshotSubscription?.cancel();
    _screenshotSubscription = shield.onScreenshotDetected.listen((_) async {
      if (!_inView) {
        return;
      }
      final image = widget.captureOnScreenshot ? await _captureChild() : null;
      widget.onScreenshotDetected?.call(image);
    });
  }

  @override
  void didUpdateWidget(ScreenshotShieldRouteGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preventCapture != widget.preventCapture ||
        oldWidget.detectScreenshots != widget.detectScreenshots ||
        oldWidget.forcePreventCapture != widget.forcePreventCapture) {
      if (_inView) {
        unawaited(_sync());
      }
    }
  }

  /// Applies the current configuration to the claims this guard holds.
  Future<void> _sync() async {
    final shield = _shield;
    if (!_inView || shield == null) return;
    await _claims.apply(shield, listen: widget.detectScreenshots, protect: _shouldPrevent);
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
  void didPush() {
    super.didPush();
    unawaited(_enterView());
  }

  @override
  void didPopNext() {
    super.didPopNext();
    unawaited(_enterView());
  }

  @override
  void didPushNext() {
    super.didPushNext();
    unawaited(_leaveView());
  }

  @override
  void didPop() {
    super.didPop();
    _routeObserver?.unsubscribe(this);
    _unregister();
    unawaited(_leaveView());
  }

  @override
  void dispose() {
    _routeObserver?.unsubscribe(this);
    _unregister();
    unawaited(_leaveView());
    _screenshotSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.captureOnScreenshot) {
      return widget.child;
    }
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }

  Future<void> _enterView() async {
    if (_inView) return;
    _inView = true;
    await _sync();
  }

  Future<void> _leaveView() async {
    if (!_inView) return;
    _inView = false;
    await _claims.release();
  }
}
