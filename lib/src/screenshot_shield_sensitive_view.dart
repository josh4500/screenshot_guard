import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// When [ScreenshotShieldSensitiveView] keeps the region out of captures.
enum SensitiveProtection {
  /// Only while the screen is recorded or mirrored. The app-switcher snapshot and
  /// foreground screenshots are not covered.
  whileRecording,

  /// While recording or mirrored, and while the app is not in the foreground, which
  /// keeps the region out of the app-switcher snapshot. The default.
  whileCaptured,

  /// Whenever the region is mounted, which also blanks foreground screenshots. The user
  /// sees a live copy of the subtree; overlays that cover the region render behind it,
  /// and rasterising costs a GPU readback per refresh.
  always,
}

/// iOS only: keeps its subtree out of captures while the screen is recorded, mirrored,
/// or the app is in the background.
///
/// Invisible in the tree by default: it wraps [child] in a layout-neutral box that paints
/// nothing, creates no platform view and rasterises nothing until protection is needed.
/// Engaged, it is a platform view whose layer sits in a capture-excluded canvas, so a
/// capture gets no pixels from the region and shows [captureColor] instead, while the user
/// sees a continuously refreshed copy of the subtree over [backdropColor].
///
/// [protection] selects when that happens, and [refreshInterval] bounds the cost.
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

  /// What the user sees behind the copy where [child] is transparent, while the region
  /// is engaged. Defaults to transparent.
  ///
  /// The copy sits over [captureColor], so with a transparent backdrop any see-through
  /// part of [child] - rounded corners, gaps between cells - shows [captureColor] on
  /// screen while engaged. For such content, set this to the colour behind the region
  /// (for example `Theme.of(context).colorScheme.surface`). Opaque, rectangular content
  /// needs nothing.
  final Color? backdropColor;

  /// When the region is kept out of captures. Defaults to
  /// [SensitiveProtection.whileCaptured].
  final SensitiveProtection protection;

  /// Minimum time between refreshes of the copy while the region is engaged.
  ///
  /// Each refresh rasterises the subtree and reads it back from the GPU, so this caps
  /// the cost of regions that repaint often (a blinking caret, an animation). Defaults
  /// to [defaultRefreshInterval] (about 30 refreshes a second); pass [Duration.zero] to
  /// refresh on every frame in which the subtree repaints.
  final Duration? refreshInterval;

  /// The [refreshInterval] used when none is given.
  static const Duration defaultRefreshInterval = Duration(milliseconds: 33);

  /// The highest pixel ratio the copy is rasterised at. Above it (3x phones) the copy
  /// is upscaled on screen, which is barely visible and less than half the readback.
  static const double maxCopyPixelRatio = 2.0;

  /// Whether the region may protect at all; `false` builds [child] untouched.
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

  /// How often the first copy is retried. The region stays unprotected until it lands.
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
  Color get _backdropColor => widget.backdropColor ?? const Color(0x00000000);

  /// Whether the recording state has to be watched.
  bool get _watchesRecording => widget.protection != SensitiveProtection.always;

  /// Whether the region is currently kept out of captures.
  bool get _engaged {
    if (!ScreenshotShieldSensitiveView.isSupported || !widget.enabled || ScreenshotShield.preventCaptureActive.value) {
      return false;
    }
    return switch (widget.protection) {
      SensitiveProtection.whileRecording => _recording,
      SensitiveProtection.whileCaptured => _recording || !_foreground,
      SensitiveProtection.always => true,
    };
  }

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

  /// Resolves the [ScreenshotShield], reads the current recording state, then follows it
  /// through the stream: the stream only delivers changes, so a region that appears
  /// mid-recording would otherwise wait for a change it has already missed.
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
      // The rebuild removes the platform view: stop talking to it and drop its copy.
      _channel = null;
      _snapshotReady = false;
      _retryTimer?.cancel();
      _throttleTimer?.cancel();
      // Cleared, not just cancelled: a leftover timer reads as "a refresh is due", and
      // a re-engaged region would then never refresh its copy again.
      _throttleTimer = null;
      return;
    }
    _restartRetryTimer();
  }

  void _handlePlatformViewCreated(int id) {
    _channel = MethodChannel('$_viewType/$id');
    // A fresh native view has no copy, so the region stays transparent until one lands.
    if (_snapshotReady && mounted) {
      setState(() => _snapshotReady = false);
    } else {
      _snapshotReady = false;
    }
    unawaited(_setEnabled(true));
    scheduleRefresh();
    // Retry until the first copy lands, so the region is not left unprotected.
    _restartRetryTimer();
  }

  /// Called from the render object inside the repaint boundary whenever the
  /// guarded subtree paints, which is what keeps the copy live.
  void _handleSubtreePainted() {
    if (!_engaged) {
      return;
    }
    final Duration interval = widget.refreshInterval ?? ScreenshotShieldSensitiveView.defaultRefreshInterval;
    if (interval <= Duration.zero) {
      scheduleRefresh();
      return;
    }
    if (_throttleTimer?.isActive ?? false) {
      // A refresh is already due at the end of the window; it captures the latest
      // paint, so this one needs nothing of its own. (Refreshing here instead would
      // refresh on every frame of a continuous animation.)
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
    // A post-frame callback does not request a frame, so ask for one when refreshing.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _setEnabled(bool enabled) async {
    try {
      await _channel?.invokeMethod<void>('setEnabled', enabled);
    } catch (error) {
      // Best effort: the platform view may be gone, or not ready for a call, yet.
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
      final double pixelRatio = math.min(
        MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        ScreenshotShieldSensitiveView.maxCopyPixelRatio,
      );
      final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
      try {
        // Raw RGBA: the copy is refreshed continuously, so encoding would cost more.
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
      // Best effort: the live child stays visible until a capture succeeds.
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
      // Nothing covers the live subtree until the first copy lands, so the region never
      // flashes on screen. A capture can see it for that frame or two - on top of the
      // delay before iOS reports a recording at all; `SensitiveProtection.always` keeps
      // the copy in place permanently for regions that cannot afford either.
      captureColor: engaged && _snapshotReady ? _captureColor : null,
      onSubtreeSizeChanged: scheduleRefresh,
      children: <Widget>[
        // Same position in the element tree whether or not the region is engaged.
        RepaintBoundary(
          key: _boundaryKey,
          child: _RepaintNotifier(onPaint: _handleSubtreePainted, child: widget.child),
        ),
        // What the user sees while engaged: the copy painted over the backdrop.
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

  /// Colour painted over the subtree while it is excluded from captures, if any.
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
    // Constraints pass through unchanged, so the region cannot affect the layout.
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
      // Painted between the subtree and the overlay: what a capture sees.
      context.canvas.drawRect(offset & size, Paint()..color = captureColor);
    }
    final RenderBox? overlay = _overlay;
    if (overlay != null) {
      context.paintChild(overlay, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Only the subtree takes pointers: taps, drags, focus and text input.
    final RenderBox? subtree = _subtree;
    return subtree != null && subtree.hitTest(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    // The overlay contributes no semantics.
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
    // Schedules a post-frame callback; never builds or marks paint during paint.
    onPaint();
    super.paint(context, offset);
  }
}
