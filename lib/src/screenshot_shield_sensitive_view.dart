import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// EXPERIMENTAL, iOS only: hides its subtree from screenshots and screen
/// recordings while leaving the rest of the app capturable.
///
/// Unlike `ScreenshotShield.setProtection(preventCapture: true)`, which blanks
/// the whole window, this widget protects a single region. It works by hosting
/// the subtree in a native platform view whose layer is nested in a capture
/// excluded canvas, so a capture shows [placeholderColor] where the widget is
/// and keeps everything else.
///
/// How it works, and why it is a prototype:
///
/// * Flutter renders the whole widget tree into one surface, so a region can
///   only be excluded if it owns a native view. The subtree is therefore
///   rasterised with [RenderRepaintBoundary.toImage] and the resulting PNG is
///   displayed by the platform view - this is a snapshot, not a live widget.
/// * The subtree is still laid out and painted underneath, but it is covered by
///   an opaque placeholder, which is what a capture sees. Touches pass through
///   the platform view to that subtree, so interaction keeps working, but visual
///   feedback (ripples, text carets, animations) is only as fresh as the last
///   snapshot. Set [refreshInterval] to refresh periodically, or call
///   [ScreenshotShieldSensitiveViewController.refresh] when the content changes.
/// * The widget derives from the same undocumented UIKit behaviour as the
///   whole-window protection, so it can break on any iOS release, and the
///   exclusion itself can only be confirmed on a real device. The region is
///   drawn above the rest of the Flutter content, so it also covers anything
///   that would otherwise be shown on top of it (a dialog, for example).
///
/// On platforms other than iOS (and in tests) the widget is a no-op and simply
/// builds [child].
///
/// It also stands down while whole-window prevention is active
/// (`ScreenshotShield.setProtection(preventCapture: true)`, which is what the
/// guards enable): the region is blanked by the window anyway, so no platform
/// view is created and nothing is rasterised. It activates again as soon as that
/// protection is released.
///
/// ```dart
/// ScreenshotShieldSensitiveView(
///   placeholderColor: Colors.black,
///   child: Text('Account number: 1234'),
/// )
/// ```
class ScreenshotShieldSensitiveView extends StatefulWidget {
  /// Creates a widget that hides [child] from screen capture on iOS.
  const ScreenshotShieldSensitiveView({
    super.key,
    required this.child,
    this.placeholderColor = const Color(0xFF000000),
    this.refreshInterval,
    this.enabled = true,
    this.controller,
  });

  /// The subtree to hide from captures.
  final Widget child;

  /// What a capture shows in place of [child]. Must be opaque: it is the only
  /// thing standing between a screenshot and the rasterised subtree.
  final Color placeholderColor;

  /// How often the native snapshot is refreshed while mounted, or `null` (the
  /// default) to only snapshot after the first frame and on resize. Frequent
  /// refreshes are expensive: every refresh reads the rasterised subtree back
  /// from the GPU.
  final Duration? refreshInterval;

  /// Whether the region is currently excluded from captures.
  final bool enabled;

  /// Optional handle for refreshing the snapshot on demand.
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
/// Use it when [ScreenshotShieldSensitiveView.refreshInterval] is `null` and the
/// guarded subtree changes, for example after a scroll or a video frame.
class ScreenshotShieldSensitiveViewController {
  _ScreenshotShieldSensitiveViewState? _state;

  /// Re-rasterises the guarded subtree into the native view.
  ///
  /// Does nothing when the widget is not using a platform view, or when a
  /// refresh is already in flight.
  Future<void> refresh() async {
    await _state?.refresh();
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

  final GlobalKey _boundaryKey = GlobalKey();
  MethodChannel? _channel;
  Timer? _timer;
  bool _capturing = false;

  /// Whether this region needs its own native protection.
  ///
  /// It does not when the whole window is already excluded from captures by
  /// `ScreenshotShield.setProtection(preventCapture: true)`: the region would be
  /// blanked anyway, so the platform view, the rasterising and the placeholder
  /// are all skipped.
  bool get _usesPlatformView =>
      ScreenshotShieldSensitiveView.isSupported && widget.enabled && !ScreenshotShield.preventCaptureActive.value;

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
      _timer?.cancel();
    } else {
      _restartTimer();
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
      _restartTimer();
    }
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        unawaited(_setEnabled(true));
        _restartTimer();
      } else {
        _timer?.cancel();
        unawaited(_setEnabled(false));
      }
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    ScreenshotShield.preventCaptureActive.removeListener(_handlePreventCaptureChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _handlePlatformViewCreated(int id) {
    _channel = MethodChannel('$_viewType/$id');
    unawaited(_setEnabled(widget.enabled));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(refresh()));
    _restartTimer();
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

  void _restartTimer() {
    _timer?.cancel();
    final Duration? interval = widget.refreshInterval;
    if (interval == null || !_usesPlatformView) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// Rasterises the guarded subtree and hands it to the native view.
  Future<void> refresh() async {
    final MethodChannel? channel = _channel;
    if (channel == null || _capturing || !mounted) {
      return;
    }
    final RenderObject? renderObject = _boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary || renderObject.debugNeedsPaint || renderObject.size.isEmpty) {
      return;
    }
    _capturing = true;
    try {
      final ui.Image image = await renderObject.toImage(pixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1);
      try {
        final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) {
          return;
        }
        await channel.invokeMethod<void>('setSnapshot', <String, dynamic>{'bytes': data.buffer.asUint8List()});
      } finally {
        image.dispose();
      }
    } catch (error) {
      // Snapshotting is best effort: the placeholder is still what a capture
      // sees, the region just renders stale content on screen.
      debugPrint('ScreenshotShield: could not snapshot sensitive view: $error');
    } finally {
      _capturing = false;
    }
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
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        // Rasterised into the native view. Painted but always covered, so it
        // never reaches a capture.
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        // What a capture sees in place of the subtree above.
        Positioned.fill(child: ColoredBox(color: widget.placeholderColor)),
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
    );
  }
}
