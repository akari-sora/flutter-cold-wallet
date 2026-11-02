import 'package:flutter/material.dart';

/// Which app a theme dresses. The two apps run on different devices and must
/// never be mistaken for each other: the online Wallet is cool blue, the
/// offline Vault signer is deep green.
enum FcwRole { wallet, vault }

/// Spacing scale shared by both apps (4-point grid).
class FcwSpace {
  const FcwSpace._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter.
  static const double page = 16;
}

/// Corner radii. Rule: buttons are full pill, inputs 14, cards and banners 20,
/// sheets and dialogs 28. Nothing else gets its own radius.
class FcwRadius {
  const FcwRadius._();
  static const double input = 14;
  static const double card = 20;
  static const double sheet = 28;
}

/// Semantic tones for status, banners and pills. Color is never the only
/// signal: every tone is shown with an icon and text.
enum FcwTone { neutral, info, success, warning, danger }

@immutable
class FcwToneColors {
  final Color container;
  final Color onContainer;
  final Color accent;

  const FcwToneColors(this.container, this.onContainer, this.accent);

  static FcwToneColors lerp(FcwToneColors a, FcwToneColors b, double t) =>
      FcwToneColors(
        Color.lerp(a.container, b.container, t)!,
        Color.lerp(a.onContainer, b.onContainer, t)!,
        Color.lerp(a.accent, b.accent, t)!,
      );
}

/// Tone colors for both brightness modes, tuned for at least 4.5:1 text
/// contrast on their containers.
@immutable
class FcwPalette extends ThemeExtension<FcwPalette> {
  final FcwToneColors neutral;
  final FcwToneColors info;
  final FcwToneColors success;
  final FcwToneColors warning;
  final FcwToneColors danger;

  /// Tinted background for addresses, hashes and other verbatim values.
  final Color codeSurface;
  final Color codeBorder;

  const FcwPalette({
    required this.neutral,
    required this.info,
    required this.success,
    required this.warning,
    required this.danger,
    required this.codeSurface,
    required this.codeBorder,
  });

  FcwToneColors of(FcwTone tone) => switch (tone) {
        FcwTone.neutral => neutral,
        FcwTone.info => info,
        FcwTone.success => success,
        FcwTone.warning => warning,
        FcwTone.danger => danger,
      };

  static FcwPalette resolve(BuildContext context) =>
      Theme.of(context).extension<FcwPalette>() ??
      FcwPalette.forScheme(Theme.of(context).colorScheme);

  factory FcwPalette.forScheme(ColorScheme colors) {
    final dark = colors.brightness == Brightness.dark;
    return FcwPalette(
      neutral: FcwToneColors(colors.surfaceContainerHighest, colors.onSurface,
          colors.onSurfaceVariant),
      info: dark
          ? const FcwToneColors(
              Color(0xFF16284A), Color(0xFFC3D5FF), Color(0xFF8FB2FF))
          : const FcwToneColors(
              Color(0xFFE4ECFD), Color(0xFF163A86), Color(0xFF2456C9)),
      success: dark
          ? const FcwToneColors(
              Color(0xFF113526), Color(0xFFA8EBC8), Color(0xFF5ED3A0))
          : const FcwToneColors(
              Color(0xFFDDF2E6), Color(0xFF0E4D30), Color(0xFF1C7A4D)),
      warning: dark
          ? const FcwToneColors(
              Color(0xFF3A2C0B), Color(0xFFFFDB8E), Color(0xFFF2B53C))
          : const FcwToneColors(
              Color(0xFFFFF0D2), Color(0xFF5E3D00), Color(0xFF9A6400)),
      danger: FcwToneColors(
          colors.errorContainer, colors.onErrorContainer, colors.error),
      codeSurface: dark ? const Color(0xFF0F1412) : const Color(0xFFF1F3F6),
      codeBorder: colors.outlineVariant,
    );
  }

  @override
  FcwPalette copyWith({
    FcwToneColors? neutral,
    FcwToneColors? info,
    FcwToneColors? success,
    FcwToneColors? warning,
    FcwToneColors? danger,
    Color? codeSurface,
    Color? codeBorder,
  }) =>
      FcwPalette(
        neutral: neutral ?? this.neutral,
        info: info ?? this.info,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        danger: danger ?? this.danger,
        codeSurface: codeSurface ?? this.codeSurface,
        codeBorder: codeBorder ?? this.codeBorder,
      );

  @override
  FcwPalette lerp(ThemeExtension<FcwPalette>? other, double t) {
    if (other is! FcwPalette) return this;
    return FcwPalette(
      neutral: FcwToneColors.lerp(neutral, other.neutral, t),
      info: FcwToneColors.lerp(info, other.info, t),
      success: FcwToneColors.lerp(success, other.success, t),
      warning: FcwToneColors.lerp(warning, other.warning, t),
      danger: FcwToneColors.lerp(danger, other.danger, t),
      codeSurface: Color.lerp(codeSurface, other.codeSurface, t)!,
      codeBorder: Color.lerp(codeBorder, other.codeBorder, t)!,
    );
  }
}

/// Monospace style for verbatim values (addresses, hashes, request IDs).
/// System fonts only: the Vault is offline and never fetches fonts.
TextStyle fcwMono(TextStyle? base) => (base ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Roboto Mono', 'Menlo', 'Courier New'],
      letterSpacing: 0.2,
      height: 1.55,
    );

/// Tabular figures so amounts do not jitter as digits change.
TextStyle fcwFigures(TextStyle? base) => (base ?? const TextStyle())
    .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
