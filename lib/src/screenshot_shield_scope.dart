import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// Provides a [ScreenshotShield] and, optionally, a [RouteObserver] to the
/// subtree via `context`.
///
/// Place this widget above the screens you want to guard, for example wrapping
/// your `MaterialApp`. Descendants read the shield with
/// [ScreenshotShieldScope.of].
///
/// When a [routeObserver] is provided, register the same instance with the
/// enclosing `Navigator`, e.g. via `MaterialApp(navigatorObservers:
/// [routeObserver])`, so that route-aware widgets such as
/// [ScreenshotShieldRouteGuard] can be notified of navigation changes.
class ScreenshotShieldScope extends InheritedWidget {
  const ScreenshotShieldScope({super.key, required super.child, required this.shield, this.routeObserver});

  /// The [ScreenshotShield] made available to the subtree.
  final ScreenshotShield shield;

  /// The route observer shared with route-aware descendants. Must be
  /// registered with the nearest `Navigator`.
  final RouteObserver<ModalRoute<void>>? routeObserver;

  /// Returns the [ScreenshotShield] from the nearest [ScreenshotShieldScope].
  ///
  /// Throws an [AssertionError] in debug mode if no scope is found above
  /// [context].
  static ScreenshotShield of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>();
    assert(scope != null, 'No ScreenshotShieldScope found in context.');
    return scope!.shield;
  }

  /// Returns the [routeObserver] from the nearest [ScreenshotShieldScope], or
  /// `null` if none was provided.
  static RouteObserver<ModalRoute<void>>? routeObserverOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>()?.routeObserver;
  }

  @override
  bool updateShouldNotify(ScreenshotShieldScope oldWidget) =>
      shield != oldWidget.shield || routeObserver != oldWidget.routeObserver;
}
