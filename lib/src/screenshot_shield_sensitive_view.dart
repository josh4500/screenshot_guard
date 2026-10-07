import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// When [ScreenshotShieldSensitiveView] keeps the region out of captures.
enum SensitiveProtection {
  /// The region is protected while the screen is being recorded or mirrored and
  /// while the app is not in the foreground (which is what keeps it out of the
  /// app-switcher snapshot). This is the default.
  ///
  /// The original widget is what is on screen the rest of the time - nothing is
  /// wrapped, rasterised or overlaid - so a screenshot taken while the app is in
  /// the foreground is **not** covered. Use whole-window protection
  /// ([ScreenshotShield.setProtection] with `preventCapture: true`, or a
  /// [ScreenshotShieldRouteGuard]) on screens where a screenshot must come out
  /// blank.
  whileCaptured,

  /// The region is protected whenever it is mounted, which also blanks
  /// foreground screenshots.
  ///
  /// What the user sees while it is on is a continuously refreshed copy of the
  /// subtree displayed inside the capture-excluded canvas, because that is the
  /// only thing iOS can keep out of a capture (live Flutter pixels are one
  /// surface and cannot be excluded per region). That copy is refreshed whenever
  /// the subtree repaints, but it is still a copy: Flutter overlays that cover
  /// the region (a selection toolbar, a dialog, a tooltip) render behind it, and
  /// rasterising costs a GPU readback per refresh.
  always,
}

/// iOS only: keeps its subtree out of captures while the screen is being
/// recorded or mirrored, and while the app is in the background.
///
/// By default the widget is invisible in the tree: it wraps [child] in a
/// layout-neutral box that paints nothing, creates no platform view and
/// rasterises nothing, and it only takes over while protection is needed
/// ([SensitiveProtection.whileCaptured]):
///
/// * while the screen is being recorded or mirrored
///   ([ScreenshotShield.onScreenRecordingChanged]: `UIScreen.isCaptured` on iOS,
///   which is also `true` while mirroring, and the Android 15 recording
///   callback), and
/// * while the app is not in the foreground, which keeps the region out of the
///   app-switcher snapshot.
///
/// While it is engaged, the guard is a platform view whose layer is nested in its
/// own capture-excluded canvas: a capture gets no pixels from the region and
/// instead shows [captureColor] - black by default - painted behind it, while the
/// user keeps seeing the subtree as a continuously refreshed copy composited over
/// [backdropColor]. The copy tracks the live subtree (typing, carets, animations
/// and size changes) because it is re-rasterised whenever the subtree repaints,
/// at most once per frame, and `refreshInterval` can cap that rate for content
/// that repaints continuously.
///
/// Why a copy at all: iOS excludes a *native view's own layer* from captures, and
/// Flutter renders every widget into one surface. Nesting live Flutter content in
/// the excluded canvas is therefore impossible, so the pixels the user sees while
/// the region is blank in a capture have to come from a native view - a
/// rasterised copy of the subtree. A "shield" that is transparent on screen and
/// black in the capture cannot exist: an excluded layer is *omitted* from the
/// capture, so a transparent shield would simply reveal the live widget to the
/// capture as well.
///
/// What the user is interacting with is always the live subtree: the copy and the
/// capture canvas are transparent to pointers, so taps, drags, focus and text
/// input reach [child] normally. Until the first copy lands nothing opaque is
/// painted, so the region shows the live subtree and is simply not excluded from
/// captures yet.
///
/// Things to know while the region is engaged:
///
/// * It is a native view, so it composites above the rest of the Flutter content:
///   a Flutter overlay that covers the region (a selection toolbar, a dialog, a
///   tooltip) is drawn behind it.
/// * The copy is one frame behind, and rasterising costs a GPU readback per
///   refresh, so content that repaints continuously (video, a large animation)
///   keeps the CPU busy while it is engaged. Use [refreshInterval] to cap it.
/// * [SensitiveProtection.always] keeps all of this on permanently, in exchange
///   for also blanking foreground screenshots.
/// * It derives from the same undocumented UIKit behaviour as the whole-window
///   protection, so it can break on any iOS release, and the exclusion itself can
///   only be confirmed on a real device (`xcrun simctl io screenshot` cannot show
///   it).
///
/// Whole-window protection (`preventCapture: true`, which is what the guards
/// enable) makes the region redundant: it stands down while that is active, and
/// nothing is rasterised. On platforms other than iOS, and when [enabled] is
/// false, the widget builds [child] directly.
///
/// ```dart
/// ScreenshotShieldSensitiveView(
///   child: Text('Account number: 1234'),
/// )
/// ```
class ScreenshotShieldSensitiveView extends StatefulWidget {
  /// Creates a widget that keeps [child] out of captures on iOS.
  const ScreenshotShieldSensitiveView({
    super.key,
    required this.child,
    this.captureColor,
    this.backdropColor,
    this.protection = SensitiveProtection.whileCaptured,
    this.refreshInterval,
    this.enabled = true,
    this.controller,
  });

  /// The subtree to keep out of captures.
  ///
  /// It stays live, laid out and interactive: the user interacts with this, and
  /// it is what gets rasterised into the copy the user sees while the region is
  /// engaged.
  final Widget child;

  /// What a capture shows where the region is. Defaults to black.
  ///
  /// It is painted in Flutter behind the capture-excluded canvas, so the user
  /// never sees it (the canvas covers it with the copy over [backdropColor]); a
  /// capture does, because the excluded canvas contributes nothing to it.
  final Color? captureColor;

  /// What the user sees behind the copy, where [child] is transparent (the gaps
  /// between rounded cells, for example).
  ///
  /// Defaults to the ambient [ThemeData.scaffoldBackgroundColor]. It is painted
  /// *inside* the capture-excluded canvas, so it is visible to the user but not
  /// to a capture.
  final Color? backdropColor;

  /// When the region is kept out of captures. Defaults to
  /// [SensitiveProtection.whileCaptured].
  final SensitiveProtection protection;

  /// The minimum time between two refreshes of the copy, or `null` (the default)
  /// to refresh on every frame in which the subtree repaints.
  ///
  /// Set it when the region contains something that repaints continuously (video,
  /// a large animation) to cap the rasterising cost, at the price of a less
  /// responsive copy.
  final Duration? refreshInterval;

  /// Whether the region may protect at all. When false the widget builds [child]
  /// directly.
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
  /// Does nothing when the region is not engaged.
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

class _ScreenshotShieldSensitiveViewState extends State<ScreenshotShieldSensitiveView> with WidgetsBindingObserver {
  static const String _viewType = 'screenshot_shield/sensitive_view';

  /// How often the first copy is retried until it succeeds. Until then the region
  /// shows the live child rather than an opaque rectangle.
  static const Duration _firstSnapshotRetryInterval = Duration(milliseconds: 250);

  final GlobalKey _boundaryKey = GlobalKey();
  ScreenshotShield? _shield;
  ScreenshotShield? _fallbackShield;
  StreamSubscription<bool>? _recordingSubscription;
  MethodChannel? _channel;
  Timer? _retryTimer;
  Timer? _throttleTimer;
  bool _listening = false;
  bool _recording = false;
  bool _foreground = true;
  bool _capturing = false;
  bool _refreshQueued = false;
  Duration? _lastRefresh;

  /// Whether the native view has received a copy of the subtree yet.
  ///
  /// Nothing opaque is painted before that: the region shows the live subtree and
  /// is simply not excluded from captures yet, rather than going blank.
  bool _snapshotReady = false;

  /// The colour a capture shows in the region.
  Color get _captureColor => widget.captureColor ?? const Color(0xFF000000);

  /// What the user sees behind the copy, inside the capture-excluded canvas.
  Color get _backdropColor => widget.backdropColor ?? Theme.of(context).scaffoldBackgroundColor;

  /// Whether the recording state has to be watched.
  bool get _watchesRecording => widget.protection == SensitiveProtection.whileCaptured;

  /// Whether the region is currently kept out of captures.
  bool get _engaged =>
      ScreenshotShieldSensitiveView.isSupported &&
      widget.enabled &&
      !ScreenshotShield.preventCaptureActive.value &&
      (_watchesRecording ? (_recording || !_foreground) : true);

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    ScreenshotShield.preventCaptureActive.addListener(_handlePreventCaptureChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShield();
  }

  @override
  void didUpdateWidget(ScreenshotShieldSensitiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.protection != widget.protection || oldWidget.enabled != widget.enabled) {
      _syncShield();
    } else {
      _syncEngagement();
    }
    if (oldWidget.refreshInterval != widget.refreshInterval) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      scheduleRefresh();
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    WidgetsBinding.instance.removeObserver(this);
    ScreenshotShield.preventCaptureActive.removeListener(_handlePreventCaptureChanged);
    _recordingSubscription?.cancel();
    if (_listening) {
      unawaited(_shield?.stopListening());
    }
    _retryTimer?.cancel();
    _throttleTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground || !mounted) {
      return;
    }
    setState(() => _foreground = foreground);
    _syncEngagement();
  }

  /// Stops (or resumes) the region when whole-window protection is toggled.
  void _handlePreventCaptureChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _syncEngagement();
  }

  /// Resolves the [ScreenshotShield], reads the current recording state and then
  /// follows it through the stream.
  ///
  /// Reading [ScreenshotShield.isScreenRecording] first is what makes a region that
  /// appears while the screen is *already* being recorded engage immediately: the
  /// stream only delivers changes, and a late listener never sees the change it
  /// missed.
  void _syncShield() {
    final ScreenshotShieldScope? scope = context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>();
    final ScreenshotShield shield = scope?.shield ?? (_fallbackShield ??= ScreenshotShield());
    _recordingSubscription?.cancel();
    _recordingSubscription = null;
    _shield = shield;
    if (_watchesRecording) {
      _recording = shield.isScreenRecording;
      _recordingSubscription = shield.onScreenRecordingChanged.listen(_handleRecordingChanged);
    } else {
      _recording = false;
    }
    _updateListening();
    _syncEngagement();
  }

  void _handleRecordingChanged(bool recording) {
    if (!mounted || recording == _recording) {
      return;
    }
    setState(() => _recording = recording);
    _syncEngagement();
  }

  void _updateListening() {
    final ScreenshotShield? shield = _shield;
    if (shield == null) {
      return;
    }
    if (_watchesRecording && !_listening) {
      _listening = true;
      unawaited(shield.startListening());
    } else if (!_watchesRecording && _listening) {
      _listening = false;
      unawaited(shield.stopListening());
    }
  }

  /// Keeps the Dart-side resources in step with whether the region is engaged.
  ///
  /// The tree itself is rebuilt by the state change that led here (or by
  /// `didUpdateWidget`); this only takes down what the platform view was using, so
  /// a disengaged region costs nothing.
  void _syncEngagement() {
    if (!_engaged) {
      // The platform view is removed by the rebuild; stop talking to it and drop
      // the copy state.
      _channel = null;
      _snapshotReady = false;
      _retryTimer?.cancel();
      _throttleTimer?.cancel();
      return;
    }
    _restartRetryTimer();
  }

  void _handlePlatformViewCreated(int id) {
    _channel = MethodChannel('$_viewType/$id');
    // A fresh native view has no copy, so nothing opaque is painted until the
    // capture below lands (otherwise a rectangle would cover the region).
    if (_snapshotReady && mounted) {
      setState(() => _snapshotReady = false);
    } else {
      _snapshotReady = false;
    }
    unawaited(_setEnabled(true));
    scheduleRefresh();
    // Retry until the first copy lands, so the region does not stay unprotected
    // just because it was first laid out while it could not be rasterised (off
    // screen, or mid-animation).
    _restartRetryTimer();
  }

  /// Called from the render object inside the repaint boundary whenever the
  /// guarded subtree paints, which is what keeps the copy live.
  void _handleSubtreePainted() {
    if (!_engaged) {
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
    if (!mounted || _refreshQueued || !_engaged) {
      return;
    }
    _refreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      unawaited(refresh());
    });
    // Adding a post-frame callback does not ask for a frame, and a refresh can be
    // scheduled from outside one (the throttle timer, a resize, the controller);
    // without this the last state could never reach the native view.
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
    if (!_engaged || _snapshotReady) {
      return;
    }
    _retryTimer = Timer.periodic(_firstSnapshotRetryInterval, (_) => unawaited(refresh()));
  }

  /// Rasterises the guarded subtree and hands the copy to the native view.
  Future<void> refresh() async {
    final MethodChannel? channel = _channel;
    if (channel == null || !mounted || !_engaged) {
      return;
    }
    if (_capturing) {
      // Do not lose the request: capture once more when this one finishes.
      _refreshQueued = true;
      return;
    }
    final RenderObject? renderObject = _boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary || renderObject.debugNeedsPaint || renderObject.size.isEmpty) {
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
          'backdropColor': _backdropColor.toARGB32(),
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

  @override
  Widget build(BuildContext context) {
    if (!ScreenshotShieldSensitiveView.isSupported || !widget.enabled) {
      return widget.child;
    }
    final bool engaged = _engaged;
    return ScreenshotShieldRegionLayout(
      captureColor: engaged && _snapshotReady ? _captureColor : null,
      onSubtreeSizeChanged: scheduleRefresh,
      children: <Widget>[
        // Always at the same position in the element tree, so engaging and
        // disengaging never rebuilds - or loses the state of - the wrapped widget.
        // It is also the source of the copy.
        RepaintBoundary(
          key: _boundaryKey,
          child: _RepaintNotifier(onPaint: _handleSubtreePainted, child: widget.child),
        ),
        // What the user sees while the region is engaged: the rasterised subtree,
        // excluded from captures by the native view. Only in the tree while it is
        // needed, so an unengaged region creates no platform view at all.
        if (engaged)
          UiKitView(
            viewType: _viewType,
            creationParams: <String, dynamic>{'enabled': true},
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: .transparent,
            onPlatformViewCreated: _handlePlatformViewCreated,
          ),
      ],
    );
  }
}

/// Lays out a guarded subtree with an optional capture overlay on top of it.
///
/// This is the region's layout; it is package-internal (not exported by the
/// library) but public so the package's own tests can assert on it:
///
/// * the subtree is laid out with the constraints this widget received,
///   **unchanged**, so wrapping it cannot change its layout;
/// * the region's size is the subtree's size;
/// * the overlay ([RenderScreenshotShieldRegion.captureColor] and the second
///   child) is laid out tight to that size, so it always matches the region;
/// * nothing is clipped, so a child that paints outside its box is not cut;
/// * only the subtree is a pointer target and only the subtree contributes
///   semantics.
class ScreenshotShieldRegionLayout extends MultiChildRenderObjectWidget {
  /// Creates the layout for a guarded region.
  const ScreenshotShieldRegionLayout({
    super.key,
    required this.captureColor,
    required this.onSubtreeSizeChanged,
    super.children,
  });

  /// The colour painted over the subtree while it is excluded from captures, or
  /// `null` while nothing may be painted (before the first copy exists).
  final Color? captureColor;

  /// Called when the subtree is laid out at a new size.
  final VoidCallback onSubtreeSizeChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderScreenshotShieldRegion(captureColor, onSubtreeSizeChanged);

  @override
  void updateRenderObject(BuildContext context, RenderScreenshotShieldRegion renderObject) {
    renderObject
      ..captureColor = captureColor
      ..onSubtreeSizeChanged = onSubtreeSizeChanged;
  }
}

/// The render object behind [ScreenshotShieldRegionLayout].
class RenderScreenshotShieldRegion extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, StackParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, StackParentData> {
  /// Creates the render object.
  RenderScreenshotShieldRegion(this._captureColor, this._onSubtreeSizeChanged);

  /// The first child, which is the guarded subtree.
  RenderBox? get _subtree => firstChild;

  /// The last child, which is the capture overlay (a platform view), if any.
  RenderBox? get _overlay {
    final RenderBox? overlay = lastChild;
    return identical(overlay, firstChild) ? null : overlay;
  }

  Color? _captureColor;

  /// The colour painted over the subtree, or `null` to paint nothing.
  Color? get captureColor => _captureColor;
  set captureColor(Color? value) {
    if (_captureColor == value) {
      return;
    }
    _captureColor = value;
    markNeedsPaint();
  }

  VoidCallback? _onSubtreeSizeChanged;

  /// Called from [performLayout] when the subtree's size changes.
  set onSubtreeSizeChanged(VoidCallback? value) => _onSubtreeSizeChanged = value;

  Size? _lastSubtreeSize;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! StackParentData) {
      child.parentData = StackParentData();
    }
  }

  @override
  void performLayout() {
    final RenderBox? subtree = _subtree;
    if (subtree == null) {
      size = constraints.smallest;
      return;
    }
    // The constraints this render object received are passed on unchanged: the
    // guarded widget has to lay out exactly as it would without the region.
    subtree.layout(constraints, parentUsesSize: true);
    size = subtree.size;
    if (_lastSubtreeSize != size) {
      _lastSubtreeSize = size;
      // Inside layout, so this must not build or paint: it schedules the copy.
      _onSubtreeSizeChanged?.call();
    }
    _overlay?.layout(BoxConstraints.tight(size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? subtree = _subtree;
    if (subtree == null) {
      return;
    }
    context.paintChild(subtree, offset);
    final Color? captureColor = _captureColor;
    if (captureColor != null) {
      // Painted between the subtree and the overlay: this is what a capture sees
      // (the excluded canvas contributes nothing to it), and the user never sees
      // it because the overlay covers the whole region.
      context.canvas.drawRect(offset & size, Paint()..color = captureColor);
    }
    final RenderBox? overlay = _overlay;
    if (overlay != null) {
      context.paintChild(overlay, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Only the subtree is a pointer target: taps, drags, focus and text input
    // must reach the widget, and the overlay must never absorb them.
    final RenderBox? subtree = _subtree;
    return subtree != null && subtree.hitTest(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    // The overlay contributes no semantics; the subtree behaves as it would
    // unwrapped.
    final RenderBox? subtree = _subtree;
    if (subtree != null) {
      visitor(subtree);
    }
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
