import 'package:flutter/foundation.dart';

/// Decides whether capture prevention should be applied for a guarded screen.
///
/// On Android, the secure window flag used to blank screen captures also
/// suppresses screenshot detection: on Android 14+ the system does not invoke
/// the screen capture callback for a window with `FLAG_SECURE`, and on older
/// versions the blanked frame is never saved to the media store. Because the
/// two cannot coexist, when both [preventCapture] and [detectScreenshots] are
/// requested on Android this returns `false` so that
/// [ScreenshotShield.onScreenshotDetected] still fires and the guarded screen
/// can be re-rasterized into a shareable image. Set [forcePreventCapture] to
/// `true` to make prevention win on Android instead, accepting that no
/// detection events will fire. On every other platform the two coexist and
/// prevention is applied as requested.
bool shouldPreventCapture({
  required bool preventCapture,
  required bool detectScreenshots,
  TargetPlatform? platform,
  bool forcePreventCapture = false,
}) {
  final target = platform ?? defaultTargetPlatform;
  if (!preventCapture) return false;
  if (target == TargetPlatform.android && detectScreenshots && !forcePreventCapture) return false;
  return true;
}
