import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// Provides a [ScreenshotShield] and an optional [RouteObserver] to its subtree.
///
/// With a [routeObserver], register the same instance with the `Navigator`.
class ScreenshotShieldScope extends InheritedWidget {
  const ScreenshotShieldScope({super.key, required super.child, required this.shield, this.routeObserver});

  /// The [ScreenshotShield] made available to the subtree.
  final ScreenshotShield shield;

  /// The route observer shared with route-aware descendants. Must be
  /// registered with the nearest `Navigator`.
  final RouteObserver<ModalRoute<void>>? routeObserver;

  /// Returns the [ScreenshotShield] from the nearest [ScreenshotShieldScope],
  /// or throws an [AssertionError] in debug mode if there is none.
  static ScreenshotShield of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>();
    assert(scope != null, 'No ScreenshotShieldScope found in context.');
    return scope!.shield;
  }

  /// Returns the [routeObserver] from the nearest scope, or `null`.
  static RouteObserver<ModalRoute<void>>? routeObserverOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>()?.routeObserver;
  }

  @override
  bool updateShouldNotify(ScreenshotShieldScope oldWidget) =>
      shield != oldWidget.shield || routeObserver != oldWidget.routeObserver;
}
