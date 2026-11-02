import 'package:flutter/services.dart';

/// Haptic feedback helper for tactile confirmation during optical QR exchange.
class HapticHelper {
  static void lightTick() {
    HapticFeedback.selectionClick();
  }

  static void successVibrate() {
    HapticFeedback.mediumImpact();
  }

  static void errorVibrate() {
    HapticFeedback.heavyImpact();
  }
}
