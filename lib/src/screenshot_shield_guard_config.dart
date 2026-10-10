import 'package:flutter/foundation.dart';

/// Whether capture prevention should be applied. On Android the secure flag
/// suppresses detection, so detection wins when both are requested unless
/// [forcePreventCapture] is set.
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
