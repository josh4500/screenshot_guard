import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:screenshot_shield/screenshot_shield.dart';

/// Shields its subtree while the screen is being recorded or mirrored, and while
/// the app is not in the foreground.
///
/// This is the cross-platform counterpart to whole-window capture prevention:
/// instead of blanking the whole screen (see [ScreenshotShieldRouteGuard]), only
/// the region is hidden, and the subtree itself is never rasterised - it stays
/// live, so it renders correctly through layout changes, animations, text input
/// and anything Flutter draws on top of it.
///
/// The shield is applied while:
///
/// * the screen is being recorded or mirrored, when [shieldWhileRecording] is
///   `true` (the default). Reported by
///   [ScreenshotShield.onScreenRecordingChanged]: `UIScreen.isCaptured` on iOS
///   (which is also `true` while mirroring, for example via AirPlay) and the
///   Android 15 (API 35) recording callback on Android. Older Android versions
///   never report it, so the region is not shielded there; rely on
///   `preventCapture` on those versions.
/// * the app is not in the foreground, when [shieldInBackground] is `true` (the
///   default), which keeps the region out of the app-switcher snapshot on every
///   platform.
///
/// While shielded the child is covered by [shield] - or by an opaque
/// [shieldColor], defaulting to the ambient
/// [ThemeData.scaffoldBackgroundColor] - or, when [blur] is set, blurred with
/// [ImageFiltered] instead. The child keeps its layout either way, so shielding
/// never changes the size or position of anything around it. While it is
/// covered, the child also stops receiving pointers and is removed from the
/// semantics tree, so a hidden field cannot be typed into or read by assistive
/// technology.
///
/// This widget does **not** protect against screenshots taken while the app is
/// in the foreground: iOS only excludes native views' own layers from captures,
/// and live Flutter pixels are not a native view. Use
/// [ScreenshotShield.setProtection] with `preventCapture: true` (or a
/// [ScreenshotShieldRouteGuard]) on screens where a screenshot has to come out
/// blank.
///
/// The [ScreenshotShield] is read from the nearest [ScreenshotShieldScope], or
/// an internal one is used when there is no scope above the widget.
///
/// ```dart
/// ScreenshotShieldSensitiveRegion(
///   child: Text('Account number: 1234'),
/// )
/// ```
class ScreenshotShieldSensitiveRegion extends StatefulWidget {
  /// Creates a widget that hides [child] while the screen is captured or the app
  /// is in the background.
  const ScreenshotShieldSensitiveRegion({
    super.key,
    required this.child,
    this.shield,
    this.shieldColor,
    this.blur,
    this.shieldWhileRecording = true,
    this.shieldInBackground = true,
    this.shielded,
  });

  /// The subtree to hide while shielded. It stays live and laid out.
  final Widget child;

  /// What is shown in place of [child] while shielded.
  ///
  /// Defaults to an opaque box painted with [shieldColor] (or the ambient
  /// scaffold background). Ignored when [blur] is set.
  final Widget? shield;

  /// The colour of the default shield.
  ///
  /// Defaults to [ThemeData.scaffoldBackgroundColor], so the region looks like
  /// whatever it sits on. Set it when the region sits on a gradient, an image or
  /// a card.
  final Color? shieldColor;

  /// Blurs the live child while shielded instead of covering it.
  ///
  /// The blur is applied to the child itself, so the region keeps rendering
  /// normally and stays interactive; use it when the app remains usable while
  /// recording.
  final double? blur;

  /// Whether to shield while the screen is being recorded or mirrored.
  /// Defaults to `true`.
  final bool shieldWhileRecording;

  /// Whether to shield while the app is not in the foreground - which is what
  /// keeps the region out of the app-switcher snapshot. Defaults to `true`.
  final bool shieldInBackground;

  /// Overrides the automatic triggers when it is not `null`.
  ///
  /// Useful for app-driven rules (shield while a session is active) and for
  /// previewing or testing the shield.
  final bool? shielded;

  @override
  State<ScreenshotShieldSensitiveRegion> createState() => _ScreenshotShieldSensitiveRegionState();
}

class _ScreenshotShieldSensitiveRegionState extends State<ScreenshotShieldSensitiveRegion> with WidgetsBindingObserver {
  ScreenshotShield? _shield;
  ScreenshotShield? _fallbackShield;
  StreamSubscription<bool>? _recordingSubscription;
  bool _listening = false;
  bool _recording = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShield();
  }

  @override
  void didUpdateWidget(ScreenshotShieldSensitiveRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shieldWhileRecording != widget.shieldWhileRecording) {
      _syncShield();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingSubscription?.cancel();
    if (_listening) {
      unawaited(_shield?.stopListening());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground || !mounted) {
      return;
    }
    setState(() => _foreground = foreground);
  }

  /// Subscribes to the recording state before asking for listening, so the
  /// current state that the host reports when listening starts is not missed.
  void _syncShield() {
    final scope = context.dependOnInheritedWidgetOfExactType<ScreenshotShieldScope>();
    final shield = scope?.shield ?? (_fallbackShield ??= ScreenshotShield());
    _recordingSubscription?.cancel();
    _recordingSubscription = null;
    _shield = shield;
    if (widget.shieldWhileRecording) {
      _recordingSubscription = shield.onScreenRecordingChanged.listen((recording) {
        if (mounted && recording != _recording) {
          setState(() => _recording = recording);
        }
      });
    } else {
      _recording = false;
    }
    _updateListening();
  }

  void _updateListening() {
    final shield = _shield;
    if (shield == null) {
      return;
    }
    if (widget.shieldWhileRecording && !_listening) {
      _listening = true;
      unawaited(shield.startListening());
    } else if (!widget.shieldWhileRecording && _listening) {
      _listening = false;
      unawaited(shield.stopListening());
    }
  }

  bool get _isShielded {
    final override = widget.shielded;
    if (override != null) {
      return override;
    }
    if (widget.shieldWhileRecording && _recording) {
      return true;
    }
    if (widget.shieldInBackground && !_foreground) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final shielded = _isShielded;
    final blur = widget.blur;
    final covered = shielded && blur == null;

    Widget child = widget.child;
    if (shielded && blur != null) {
      child = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: child,
      );
    }
    if (covered) {
      // Nothing to interact with while it is hidden, and no semantics to leak.
      child = IgnorePointer(child: child);
    }
    child = ExcludeSemantics(excluding: shielded, child: child);

    return Stack(
      children: <Widget>[
        // Always laid out, so shielding never shifts the layout around it.
        child,
        if (covered) Positioned.fill(child: _buildShield(context)),
      ],
    );
  }

  Widget _buildShield(BuildContext context) {
    final shield = widget.shield;
    if (shield != null) {
      return shield;
    }
    return ColoredBox(color: widget.shieldColor ?? Theme.of(context).scaffoldBackgroundColor);
  }
}
