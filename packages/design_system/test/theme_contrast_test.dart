import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final role in FcwRole.values) {
    for (final brightness in Brightness.values) {
      test('${role.name} ${brightness.name} text pairs meet WCAG AA', () {
        final theme = brightness == Brightness.dark
            ? ColdWalletTheme.dark(role: role)
            : ColdWalletTheme.light(role: role);
        final c = theme.colorScheme;
        final palette = theme.extension<FcwPalette>()!;
        final pairs = <String, (Color, Color)>{
          'onSurface/surface': (c.onSurface, c.surface),
          'onSurface/scaffold': (c.onSurface, theme.scaffoldBackgroundColor),
          'onSurfaceVariant/surface': (c.onSurfaceVariant, c.surface),
          'onSurfaceVariant/scaffold': (
            c.onSurfaceVariant,
            theme.scaffoldBackgroundColor
          ),
          'onPrimary/primary': (c.onPrimary, c.primary),
          'onPrimaryContainer/primaryContainer': (
            c.onPrimaryContainer,
            c.primaryContainer
          ),
          'primary/surface': (c.primary, c.surface),
          // Text buttons and error text sit directly on the scaffold.
          'primary/scaffold': (c.primary, theme.scaffoldBackgroundColor),
          'error/scaffold': (c.error, theme.scaffoldBackgroundColor),
          // The slide label sits on the track and, mid-drag, on its fill.
          'onSurface/surfaceContainerHighest': (
            c.onSurface,
            c.surfaceContainerHighest
          ),
          'onSurface/primaryContainer': (c.onSurface, c.primaryContainer),
          'onSurface/codeSurface': (c.onSurface, palette.codeSurface),
          for (final tone in FcwTone.values)
            '${tone.name} accent/surface': (palette.of(tone).accent, c.surface),
          for (final tone in FcwTone.values)
            '${tone.name} onContainer/container': (
              palette.of(tone).onContainer,
              palette.of(tone).container
            ),
        };
        for (final entry in pairs.entries) {
          final (fg, bg) = entry.value;
          expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5),
              reason:
                  '${entry.key} is ${_contrast(fg, bg).toStringAsFixed(2)}:1');
        }
      });
    }
  }
}
