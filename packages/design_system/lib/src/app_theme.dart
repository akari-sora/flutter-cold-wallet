import 'package:flutter/material.dart';

import 'tokens.dart';

/// Shared, offline typography and surfaces for Wallet and Vault.
class ColdWalletTheme {
  const ColdWalletTheme._();

  // The role is required: a Vault dressed in Wallet colors defeats the point.
  static ThemeData light({required FcwRole role}) =>
      _build(Brightness.light, role);
  static ThemeData dark({required FcwRole role}) =>
      _build(Brightness.dark, role);

  static const _walletSeed = Color(0xFF2456C9);
  static const _vaultSeed = Color(0xFF1F8A66);

  static ThemeData _build(Brightness brightness, FcwRole role) {
    final dark = brightness == Brightness.dark;
    final vault = role == FcwRole.vault;
    final scaffold = switch ((vault, dark)) {
      (false, false) => const Color(0xFFF3F5F9),
      (false, true) => const Color(0xFF0E1116),
      (true, false) => const Color(0xFFF2F4F2),
      (true, true) => const Color(0xFF0B0F0D),
    };
    final surface = switch ((vault, dark)) {
      (false, false) => const Color(0xFFFFFFFF),
      (false, true) => const Color(0xFF161B22),
      (true, false) => const Color(0xFFFFFFFF),
      (true, true) => const Color(0xFF141A17),
    };
    final seeded = ColorScheme.fromSeed(
      seedColor: vault ? _vaultSeed : _walletSeed,
      brightness: brightness,
      // Fidelity keeps the seed's chroma; the default tonal spot washes the
      // brand colors out to grey-violet.
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    // Containers are a light wash of the brand color, not a second saturated
    // block competing with filled buttons.
    final tint = Color.alphaBlend(
        seeded.primary.withValues(alpha: dark ? 0.22 : 0.10), surface);
    final colors = seeded.copyWith(
      primaryContainer: tint,
      onPrimaryContainer: seeded.primary,
      surface: surface,
      onSurface: dark ? const Color(0xFFE6EAE8) : const Color(0xFF111827),
      onSurfaceVariant:
          dark ? const Color(0xFFA9B3AE) : const Color(0xFF4B5563),
      surfaceContainerLowest: surface,
      outlineVariant: dark ? const Color(0xFF2A332F) : const Color(0xFFDDE2E8),
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      fontFamily: 'sans-serif',
      fontFamilyFallback: const ['Noto Sans CJK TC', 'Noto Sans TC', 'Roboto'],
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
    final text = base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge
          ?.copyWith(fontSize: 34, height: 1.2, fontWeight: FontWeight.w700),
      headlineMedium: base.textTheme.headlineMedium
          ?.copyWith(fontSize: 28, height: 1.25, fontWeight: FontWeight.w700),
      headlineSmall: base.textTheme.headlineSmall
          ?.copyWith(fontSize: 24, height: 1.3, fontWeight: FontWeight.w700),
      titleLarge: base.textTheme.titleLarge
          ?.copyWith(fontSize: 21, height: 1.35, fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium
          ?.copyWith(fontSize: 17, height: 1.4, fontWeight: FontWeight.w600),
      titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 14,
          height: 1.4,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
      bodyMedium:
          base.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.5),
      labelLarge: base.textTheme.labelLarge
          ?.copyWith(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600),
      labelMedium: base.textTheme.labelMedium
          ?.copyWith(fontSize: 13, height: 1.3, fontWeight: FontWeight.w600),
    );
    const pill = StadiumBorder();
    final inputRadius = BorderRadius.circular(FcwRadius.input);
    final cardShape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FcwRadius.card),
        side: BorderSide(color: colors.outlineVariant));
    final button = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(52, 52)),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
      shape: const WidgetStatePropertyAll(pill),
      textStyle: WidgetStatePropertyAll(text.labelLarge),
      elevation: const WidgetStatePropertyAll(0),
    );
    final disabledBg = colors.onSurface.withValues(alpha: 0.12);
    final disabledFg = colors.onSurface.withValues(alpha: 0.38);
    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: scaffold,
      extensions: [FcwPalette.forScheme(colors)],
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: scaffold,
        foregroundColor: colors.onSurface,
        titleTextStyle: text.titleLarge?.copyWith(color: colors.onSurface),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
      ),
      dividerTheme: DividerThemeData(
          color: colors.outlineVariant, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        errorMaxLines: 6,
        helperMaxLines: 4,
        floatingLabelStyle: TextStyle(color: colors.primary),
        border: OutlineInputBorder(
            borderRadius: inputRadius,
            borderSide: BorderSide(color: colors.outlineVariant)),
        enabledBorder: OutlineInputBorder(
            borderRadius: inputRadius,
            borderSide: BorderSide(color: colors.outlineVariant)),
        focusedBorder: OutlineInputBorder(
            borderRadius: inputRadius,
            borderSide: BorderSide(color: colors.primary, width: 2)),
        errorBorder: OutlineInputBorder(
            borderRadius: inputRadius,
            borderSide: BorderSide(color: colors.error)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: inputRadius,
            borderSide: BorderSide(color: colors.error, width: 2)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: button.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled)
                  ? disabledBg
                  : colors.primary),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.disabled)
                  ? disabledFg
                  : colors.onPrimary),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: button.copyWith(
          side: WidgetStateProperty.resolveWith((states) => BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? colors.onSurface.withValues(alpha: 0.12)
                  : colors.outline)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: button.copyWith(
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
          style:
              ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48)))),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? tint : surface),
          foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? disabledFg
                  : states.contains(WidgetState.selected)
                      ? seeded.primary
                      : colors.onSurface),
          side: WidgetStatePropertyAll(BorderSide(color: colors.outline)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: colors.outlineVariant),
        labelStyle: text.labelMedium?.copyWith(color: colors.onSurface),
        secondaryLabelStyle: text.labelMedium?.copyWith(color: seeded.primary),
        backgroundColor: surface,
        selectedColor: tint,
        checkmarkColor: seeded.primary,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minVerticalPadding: 12,
        iconColor: colors.onSurfaceVariant,
        titleTextStyle: text.titleMedium?.copyWith(color: colors.onSurface),
        subtitleTextStyle:
            text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FcwRadius.input)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FcwRadius.input)),
        contentTextStyle: text.bodyMedium?.copyWith(
            color: colors.onInverseSurface, fontWeight: FontWeight.w500),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primary,
        linearTrackColor: colors.surfaceContainerHighest,
        linearMinHeight: 6,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      dialogTheme: DialogThemeData(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: text.titleLarge?.copyWith(color: colors.onSurface),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(FcwRadius.sheet))),
      bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(FcwRadius.sheet)))),
      expansionTileTheme: ExpansionTileThemeData(
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          // Top room for the floating label of a first input, which the
          // expanding area would otherwise clip (it overhangs more at 2x text).
          childrenPadding:
              const EdgeInsets.only(top: FcwSpace.lg, bottom: FcwSpace.lg),
          shape: const Border(),
          collapsedShape: const Border(),
          textColor: colors.onSurface,
          collapsedTextColor: colors.onSurface,
          iconColor: colors.onSurfaceVariant,
          collapsedIconColor: colors.onSurfaceVariant),
    );
  }
}
