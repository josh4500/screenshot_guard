import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screenshot_shield/src/screenshot_shield_guard_config.dart';

void main() {
  group('shouldPreventCapture', () {
    test('is false when preventCapture is false', () {
      expect(
        shouldPreventCapture(preventCapture: false, detectScreenshots: true, platform: TargetPlatform.android),
        isFalse,
      );
    });

    test('applies prevention on iOS even when detection is enabled', () {
      expect(
        shouldPreventCapture(preventCapture: true, detectScreenshots: true, platform: TargetPlatform.iOS),
        isTrue,
      );
    });

    test('drops prevention on Android so detection can fire', () {
      expect(
        shouldPreventCapture(preventCapture: true, detectScreenshots: true, platform: TargetPlatform.android),
        isFalse,
      );
    });

    test('forces prevention on Android when forcePreventCapture is true', () {
      expect(
        shouldPreventCapture(
          preventCapture: true,
          detectScreenshots: true,
          platform: TargetPlatform.android,
          forcePreventCapture: true,
        ),
        isTrue,
      );
    });

    test('applies prevention on Android when detection is disabled', () {
      expect(
        shouldPreventCapture(preventCapture: true, detectScreenshots: false, platform: TargetPlatform.android),
        isTrue,
      );
    });

    test('applies prevention on other platforms when detection is enabled', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          shouldPreventCapture(preventCapture: true, detectScreenshots: true, platform: platform),
          isTrue,
        );
      }
    });
  });
}
