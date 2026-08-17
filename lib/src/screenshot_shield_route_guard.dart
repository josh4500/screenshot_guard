import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// A widget that scopes screenshot protection to the route it lives on.
///
/// While the enclosing [ModalRoute] is the top-most route this guard starts
/// listening for screenshots and (optionally) prevents capture. When another
/// route is pushed on top the protection is released and listening stops, and
/// both resume automatically when this route becomes visible again.
///
/// With [captureOnScreenshot] enabled the guarded subtree is wrapped in a
/// [RepaintBoundary], and each detected screenshot is re-rasterized into a PNG
/// that is passed to [onScreenshotDetected]. This captures the app's own
/// content rather than the OS screenshot, so it works even on platforms or
/// screens where the OS frame is blanked or unavailable.
///
/// Only one [ScreenshotShieldRouteGuard] may be mounted per route; mounting a
/// second one on the same route reports an error and is left inactive.
///
/// The [ScreenshotShield] and the [RouteObserver] are read from the nearest
/// [ScreenshotShieldScope]. The scope's [ScreenshotShieldScope.routeObserver]
/// must be registered with the enclosing `Navigator`, e.g. via
/// `MaterialApp(navigatorObservers: [routeObserver])`.
class ScreenshotShieldRouteGuard extends StatefulWidget {
  const ScreenshotShieldRouteGuard({
    super.key,
    required this.child,
    this.preventCapture = true,
    this.detectScreenshots = true,
    this.captureOnScreenshot = true,
    this.onScreenshotDetected,
  });

  /// The subtree guarded while this route is in view.
  final Widget child;

  /// Whether [ScreenshotShield.setProtected] is enabled while the route is in
  /// view. On Android this blanks the captured frame. Defaults to `true`.
  final bool preventCapture;

  /// Whether the guard listens for screenshots while the route is in view.
  /// Defaults to `true`.
  final bool detectScreenshots;

  /// Whether the guarded subtree is re-rasterized into a PNG when a screenshot
  /// is detected. The PNG bytes are passed to [onScreenshotDetected]; set to
  /// `false` to skip the capture overhead. Defaults to `true`.
  final bool captureOnScreenshot;

  /// Invoked each time a screenshot is captured while the route is in view.
  ///
  /// The argument is a PNG-encoded image of the guarded subtree when
  /// [captureOnScreenshot] is enabled, or `null` if the capture was skipped or
  /// failed. Use it to show the user a shareable copy of the screen.
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
  bool _inView = false;

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

  /// Registers this guard on [route], reporting an error and returning `false`
  /// if another guard is already mounted on the same route.
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
    final shield = _shield!;
    if (widget.detectScreenshots) {
      await shield.startListening();
    }
    if (widget.preventCapture) {
      await shield.setProtected(protected: true);
    }
  }

  Future<void> _leaveView() async {
    if (!_inView) return;
    _inView = false;
    final shield = _shield!;
    if (widget.preventCapture) {
      await shield.setProtected(protected: false);
    }
    if (widget.detectScreenshots) {
      await shield.stopListening();
    }
  }
}
