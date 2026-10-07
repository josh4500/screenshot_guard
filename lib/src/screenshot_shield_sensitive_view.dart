import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// iOS only: keeps its subtree out of screenshots, screen recordings and the
/// app-switcher snapshot, while the rest of the app stays capturable.
///
/// `ScreenshotShield.setProtection(preventCapture: true)` blanks the whole
/// window; this widget protects a single region. Flutter renders every widget
/// into one surface and iOS only excludes a *native view's own layer* from a
/// capture, so a region can only be excluded by giving it a native view: the
/// subtree is rasterised in Flutter and the result is displayed by a platform
/// view whose layer is nested in its own capture-excluded canvas. What the user
/// sees is therefore a copy of the subtree - but a copy that is refreshed
/// **whenever the subtree repaints**, at most once per frame, so typing, a
/// blinking caret, animations and layout or size changes all show up (unlike a
/// one-shot snapshot, which freezes the region and stretches it when it
/// resizes). A capture of the region gets no pixels at all.
///
/// What a capture sees instead is [ScreenshotShieldSensitiveView.placeholderColor],
/// which is also what shows through any transparent part of the subtree on
/// screen, so it defaults to the ambient [ThemeData.scaffoldBackgroundColor] and
/// should be set when the region sits on a gradient, an image or a card.
///
/// The subtree stays laid out and stays live: the platform view and the
/// placeholder are transparent to pointers, so taps, drags, focus and text input
/// reach [child] as usual - the copy is what the user sees, [child] is what the
/// user is interacting with. Until the first copy lands the placeholder is not
/// painted at all, so the region shows the live subtree and is simply not
/// excluded from captures yet.
///
/// Things to know before relying on it:
///
/// * The region is a native view, so it composites above the rest of the Flutter
///   content: a Flutter overlay that covers the region (a selection toolbar, a
///   dialog, a tooltip) is drawn behind it. Keep overlays out of the region, or
///   put the region on a screen that uses whole-window protection instead.
/// * Rasterising costs a GPU readback per refresh, so a region containing
///   something that repaints continuously (video, a large animation) keeps the
///   CPU busy. Use [refreshInterval] to cap how often the copy is refreshed, or
///   use whole-window protection for content like that.
/// * The copy is one frame behind, and it is still a copy: hit-testing, focus and
///   text input happen in the live subtree underneath.
/// * It derives from the same undocumented UIKit behaviour as the whole-window
///   protection, so it can break on any iOS release, and the exclusion itself can
///   only be confirmed on a real device (`xcrun simctl io screenshot` cannot show
///   it).
///
/// On every other platform (and in tests) the widget is a no-op and builds
/// [child] directly. It also stands down while whole-window prevention is active
/// (`ScreenshotShield.setProtection(preventCapture: true)`, which is what the
/// guards enable), because the window is excluded from captures anyway: no
/// platform view is created and nothing is rasterised.
///
/// ```dart
/// ScreenshotShieldSensitiveView(
///   // Defaults to the scaffold background; set it when the region sits on
///   // something else, because it also shows through transparent parts of the
///   // child.
///   placeholderColor: Color(0xFFF4F1EC),
///   child: Text('Account number: 1234'),
/// )
/// ```
class ScreenshotShieldSensitiveView extends StatefulWidget {
  /// Creates a widget that keeps [child] out of captures on iOS.
  const ScreenshotShieldSensitiveView({
    super.key,
    required this.child,
    this.placeholderColor,
    this.refreshInterval,
    this.enabled = true,
    this.controller,
  });

  /// The subtree to keep out of captures. It stays live, laid out and
  /// interactive; the user sees a continuously refreshed copy of it.
  final Widget child;

  /// What a capture shows in place of [child], and what shows through any part
  /// of [child] that is transparent - which is why it has to match what is
  /// behind the region.
  ///
  /// Defaults to the ambient [ThemeData.scaffoldBackgroundColor], which is what
  /// most regions sit on. Set it explicitly when the region sits on something
  /// else (a gradient, an image, a card), otherwise those transparent parts show
  /// this colour on screen. It must stay opaque: it is the only thing standing
  /// between a capture and the rasterised subtree.
  final Color? placeholderColor;

  /// The minimum time between two refreshes of the copy, or `null` (the default)
  /// to refresh on every frame in which the subtree repaints.
  ///
  /// Set it when the region contains something that repaints continuously (video,
  /// a large animation) to cap the rasterising cost, at the price of a less
  /// responsive copy.
  final Duration? refreshInterval;

  /// Whether the region is currently excluded from captures.
  final bool enabled;

  /// Optional handle for refreshing the copy on demand.
  final ScreenshotShieldSensitiveViewController? controller;

  /// Whether the current platform can exclude a region from captures.
  ///
  /// Only iOS is implemented; every other platform builds [child] directly.
  static bool get isSupported => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  State<ScreenshotShieldSensitiveView> createState() => _ScreenshotShieldSensitiveViewState();
}

/// Handle for refreshing a [ScreenshotShieldSensitiveView] on demand.
///
/// The copy refreshes by itself whenever the subtree repaints, so this is only
/// needed when the subtree changes in a way that does not repaint it - a platform
/// view inside the region, for example.
class ScreenshotShieldSensitiveViewController {
  _ScreenshotShieldSensitiveViewState? _state;

  /// Re-rasterises the guarded subtree into the native view.
  ///
  /// The capture happens after the next frame. Requests that arrive while a
  /// capture is in flight are coalesced into one more capture rather than
  /// dropped.
  ///
  /// Does nothing when the widget is not using a platform view.
  void refresh() {
    _state?.scheduleRefresh();
  }

  void _attach(_ScreenshotShieldSensitiveViewState state) {
    _state = state;
  }

  void _detach(_ScreenshotShieldSensitiveViewState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

class _ScreenshotShieldSensitiveViewState extends State<ScreenshotShieldSensitiveView> {
  static const String _viewType = 'screenshot_shield/sensitive_view';

  /// How often the first copy is retried until it succeeds. Until then the region
  /// shows the live child rather than the capture placeholder.
  static const Duration _firstSnapshotRetryInterval = Duration(milliseconds: 250);

  final GlobalKey _boundaryKey = GlobalKey();
  MethodChannel? _channel;
  Timer? _retryTimer;
  Timer? _throttleTimer;
  bool _capturing = false;
  bool _refreshQueued = false;
  Duration? _lastRefresh;

  /// Whether the native view has received a copy of the subtree yet.
  ///
  /// The placeholder is what a *capture* should see, so it is only painted once
  /// there is a copy covering it; before that the live child is shown instead of
  /// an opaque rectangle, and a region whose copy cannot be taken stays visible
  /// rather than going blank.
  bool _snapshotReady = false;

  /// Whether this region needs its own native protection.
  ///
  /// It does not when the whole window is already excluded from captures by
  /// `ScreenshotShield.setProtection(preventCapture: true)`: the region would be
  /// blanked anyway, so the platform view, the rasterising and the placeholder
  /// are all skipped.
  bool get _usesPlatformView =>
      ScreenshotShieldSensitiveView.isSupported && widget.enabled && !ScreenshotShield.preventCaptureActive.value;

  /// The colour a capture shows in the region, and what shows through the
  /// transparent parts of [ScreenshotShieldSensitiveView.child] on screen.
  Color get _placeholderColor => widget.placeholderColor ?? Theme.of(context).scaffoldBackgroundColor;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    ScreenshotShield.preventCaptureActive.addListener(_handlePreventCaptureChanged);
  }

  /// Stops (or resumes) the region when whole-window protection is toggled. The
  /// rebuild itself is driven by the [ValueListenableBuilder] in [build].
  void _handlePreventCaptureChanged() {
    if (ScreenshotShield.preventCaptureActive.value) {
      // The native view is being torn down with the rebuild; stop talking to it.
      _channel = null;
      _snapshotReady = false;
      _retryTimer?.cancel();
      _throttleTimer?.cancel();
    } else {
      _restartRetryTimer();
    }
  }

  @override
  void didUpdateWidget(ScreenshotShieldSensitiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.refreshInterval != widget.refreshInterval) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      scheduleRefresh();
    }
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        unawaited(_setEnabled(true));
        _restartRetryTimer();
      } else {
        _retryTimer?.cancel();
        unawaited(_setEnabled(false));
      }
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    ScreenshotShield.preventCaptureActive.removeListener(_handlePreventCaptureChanged);
    _retryTimer?.cancel();
    _throttleTimer?.cancel();
    super.dispose();
  }

  void _handlePlatformViewCreated(int id) {
    _channel = MethodChannel('$_viewType/$id');
    // A fresh native view has no copy, so drop the placeholder until the capture
    // below lands (otherwise an opaque rectangle covers the region).
    if (_snapshotReady && mounted) {
      setState(() => _snapshotReady = false);
    } else {
      _snapshotReady = false;
    }
    unawaited(_setEnabled(widget.enabled));
    scheduleRefresh();
    // Retry until the first copy lands, so the region does not stay unprotected
    // just because it was first laid out while it could not be rasterised (off
    // screen, or mid-animation).
    _restartRetryTimer();
  }

  /// Called from the render object inside the repaint boundary whenever the
  /// guarded subtree paints, which is what keeps the copy live.
  void _handleSubtreePainted() {
    if (!_usesPlatformView) {
      return;
    }
    final Duration? interval = widget.refreshInterval;
    if (interval == null || _throttleTimer != null) {
      scheduleRefresh();
      return;
    }
    final Duration? last = _lastRefresh;
    final Duration since = last == null ? interval : WidgetsBinding.instance.currentFrameTimeStamp - last;
    if (since >= interval) {
      scheduleRefresh();
      return;
    }
    // Refresh once the throttle window has passed, so the last state of the
    // subtree still reaches the native view.
    _throttleTimer = Timer(interval - since, () {
      _throttleTimer = null;
      scheduleRefresh();
    });
  }

  /// Schedules a capture after the next frame, coalescing bursts of requests.
  void scheduleRefresh() {
    if (!mounted || _refreshQueued) {
      return;
    }
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      unawaited(refresh());
    });
    // Adding a post-frame callback does not ask for a frame, and a refresh can be
    // scheduled from outside one (the throttle timer, a resize notification, the
    // controller); without this the last state could never reach the native view.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await _channel?.invokeMethod<void>('setEnabled', enabled);
    } catch (error) {
      // Toggling is best effort: the platform view may already be gone, or may
      // not exist at all (in tests, or on a platform without native support).
      debugPrint('ScreenshotShield: could not toggle the sensitive view: $error');
    }
  }

  void _restartRetryTimer() {
    _retryTimer?.cancel();
    if (!_usesPlatformView || _snapshotReady) {
      return;
    }
    _retryTimer = Timer.periodic(_firstSnapshotRetryInterval, (_) => unawaited(refresh()));
  }

  /// Rasterises the guarded subtree and hands the copy to the native view.
  Future<void> refresh() async {
    final MethodChannel? channel = _channel;
    if (channel == null || !mounted) {
      return;
    }
    if (_capturing) {
      // Do not lose the request: capture once more when this one finishes.
      _refreshQueued = true;
      return;
    }
    final RenderObject? renderObject = _boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary || renderObject.debugNeedsPaint || renderObject.size.isEmpty) {
      debugPrint(
        'T refresh bail renderObject=$renderObject needsPaint=${renderObject is RenderRepaintBoundary ? renderObject.debugNeedsPaint : null} size=${renderObject?.paintBounds.size}',
      );
      return;
    }
    _capturing = true;
    _lastRefresh = WidgetsBinding.instance.currentFrameTimeStamp;
    try {
      final ui.Image image = await renderObject.toImage(pixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
      try {
        // Raw RGBA rather than an encoded image: the copy is refreshed as the
        // subtree repaints, so encoding every frame would dominate the cost.
        final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) {
          return;
        }
        await channel.invokeMethod<void>('setSnapshot', <String, dynamic>{
          'bytes': data.buffer.asUint8List(),
          'width': image.width,
          'height': image.height,
        });
        if (mounted && !_snapshotReady) {
          setState(() => _snapshotReady = true);
          // The first copy is in; the retry timer has done its job.
          _retryTimer?.cancel();
        }
      } finally {
        image.dispose();
      }
    } catch (error) {
      // Rasterising is best effort: the live child stays visible until a capture
      // succeeds.
      debugPrint('ScreenshotShield: could not rasterise the sensitive view: $error');
    } finally {
      _capturing = false;
      if (_refreshQueued) {
        _refreshQueued = false;
        scheduleRefresh();
      }
    }
  }

  /// Re-rasterises when the region is laid out at a new size, so a resized region
  /// is never stretched from a stale copy.
  bool _handleSizeChanged(SizeChangedLayoutNotification notification) {
    scheduleRefresh();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!ScreenshotShieldSensitiveView.isSupported || !widget.enabled) {
      return widget.child;
    }
    return ValueListenableBuilder<bool>(
      valueListenable: ScreenshotShield.preventCaptureActive,
      builder: (BuildContext context, bool preventCaptureActive, Widget? _) {
        if (preventCaptureActive) {
          // The whole window is already excluded from captures.
          return widget.child;
        }
        return _buildProtectedRegion();
      },
    );
  }

  Widget _buildProtectedRegion() {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: _handleSizeChanged,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          // Rasterised into the native view, and the live, interactive widget:
          // the platform view and the placeholder are transparent to pointers,
          // so taps, drags and focus reach this subtree.
          SizeChangedLayoutNotifier(
            child: RepaintBoundary(
              key: _boundaryKey,
              // Repainting the subtree is what schedules the next copy, so the
              // region tracks typing, carets, animations and resizes.
              child: _RepaintNotifier(onPaint: _handleSubtreePainted, child: widget.child),
            ),
          ),
          // What a capture sees in place of the subtree above, and never a
          // pointer target. It stays in the tree and only changes colour: adding
          // or removing it would shift the Stack's children, rebuild the
          // UiKitView below and reset its copy, which loops.
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: _snapshotReady ? _placeholderColor : const Color(0x00000000)),
            ),
          ),
          // What the user sees: the rasterised subtree, excluded from captures.
          Positioned.fill(
            child: UiKitView(
              viewType: _viewType,
              creationParams: <String, dynamic>{'enabled': widget.enabled},
              creationParamsCodec: const StandardMessageCodec(),
              hitTestBehavior: .transparent,
              onPlatformViewCreated: _handlePlatformViewCreated,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reports every paint of the subtree it wraps.
///
/// It sits inside the repaint boundary, so it is painted whenever anything in
/// the guarded subtree repaints - which is the signal used to refresh the copy
/// the user sees.
class _RepaintNotifier extends SingleChildRenderObjectWidget {
  const _RepaintNotifier({required Widget super.child, required this.onPaint});

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderRepaintNotifier(onPaint);

  @override
  void updateRenderObject(BuildContext context, _RenderRepaintNotifier renderObject) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderRepaintNotifier extends RenderProxyBox {
  _RenderRepaintNotifier(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Only schedules work (a post-frame callback); it must not build or mark
    // anything dirty while the frame is being painted.
    onPaint();
    super.paint(context, offset);
  }
}
