import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// Tone and icon for an EVM transaction outcome (see TransactionOutcome.label).
FcwTone outcomeTone(String state) => switch (state) {
      'confirmed' => FcwTone.success,
      'verified' || 'broadcasting' || 'accepted' || 'pending' => FcwTone.info,
      'executionFailed' => FcwTone.danger,
      'unknown' => FcwTone.warning,
      _ => FcwTone.neutral,
    };

IconData outcomeIcon(String state) => switch (state) {
      'awaitingSignature' => Icons.qr_code_2,
      'verified' => Icons.verified_outlined,
      'broadcasting' || 'accepted' || 'pending' => Icons.schedule,
      'confirmed' => Icons.check_circle_outline,
      'executionFailed' => Icons.error_outline,
      'unknown' => Icons.help_outline,
      'cancelled' => Icons.block_outlined,
      _ => Icons.help_outline,
    };
