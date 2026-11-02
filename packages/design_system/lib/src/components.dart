import 'package:flutter/material.dart';

import 'tokens.dart';

IconData _toneIcon(FcwTone tone) => switch (tone) {
      FcwTone.neutral => Icons.info_outline,
      FcwTone.info => Icons.info_outline,
      FcwTone.success => Icons.check_circle_outline,
      FcwTone.warning => Icons.warning_amber_rounded,
      FcwTone.danger => Icons.error_outline,
    };

/// Bordered surface that groups related content.
class FcwPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const FcwPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(FcwSpace.lg),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A Material, not a colored box: list tiles inside draw their ink and
    // focus highlight on the nearest Material, which a painted background
    // would cover.
    return Material(
      color: color ?? colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FcwRadius.card),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Tinted monospace-friendly block for verbatim values (addresses, words).
class FcwCodeBlock extends StatelessWidget {
  final Widget child;

  const FcwCodeBlock({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = FcwPalette.resolve(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.codeSurface,
        borderRadius: BorderRadius.circular(FcwRadius.input),
        border: Border.all(color: palette.codeBorder),
      ),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: FcwSpace.md, vertical: 10),
        child: child,
      ),
    );
  }
}

/// Status chip: icon + text on a tone container (never color alone).
class FcwStatusPill extends StatelessWidget {
  final String label;
  final FcwTone tone;
  final IconData? icon;

  const FcwStatusPill(this.label,
      {super.key, this.tone = FcwTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) {
    final t = FcwPalette.resolve(context).of(tone);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration:
          ShapeDecoration(color: t.container, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon ?? _toneIcon(tone), size: 18, color: t.onContainer),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: t.onContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline message block for warnings, errors and guidance.
class FcwBanner extends StatelessWidget {
  final FcwTone tone;
  final String? title;
  final Widget? content;
  final String? message;
  final IconData? icon;

  const FcwBanner({
    super.key,
    this.tone = FcwTone.info,
    this.title,
    this.message,
    this.content,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = FcwPalette.resolve(context).of(tone);
    final theme = Theme.of(context);
    final textStyle =
        theme.textTheme.bodyMedium?.copyWith(color: t.onContainer);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.container,
        borderRadius: BorderRadius.circular(FcwRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FcwSpace.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon ?? _toneIcon(tone), size: 22, color: t.onContainer),
            const SizedBox(width: FcwSpace.md),
            Expanded(
              child: DefaultTextStyle.merge(
                style: textStyle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: FcwSpace.xs),
                        child: Text(title!,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(color: t.onContainer)),
                      ),
                    if (message != null) Text(message!, style: textStyle),
                    if (content != null) content!,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Labelled verbatim value. Addresses and hashes render in monospace on a
/// tinted block; the full value stays selectable and is its own semantics label.
class FcwField extends StatelessWidget {
  final String label;
  final String value;
  final Key? valueKey;
  final bool mono;

  const FcwField({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge;
    final valueText = SelectableText(
      value,
      key: valueKey,
      semanticsLabel: value,
      style: mono ? fcwMono(base) : base?.copyWith(height: 1.5),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: FcwSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          if (mono) FcwCodeBlock(child: valueText) else valueText,
        ],
      ),
    );
  }
}

/// Large amount with tabular figures and a caption above it.
class FcwAmountHero extends StatelessWidget {
  final String caption;
  final String amount;
  final Key? amountKey;

  const FcwAmountHero(
      {super.key, required this.caption, required this.amount, this.amountKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SelectableText(
          amount,
          key: amountKey,
          semanticsLabel: amount,
          style: fcwFigures(theme.textTheme.headlineMedium)
              .copyWith(height: 1.2, color: theme.colorScheme.onSurface),
        ),
      ],
    );
  }
}

/// Persistent marker telling which device the user is holding.
class FcwRoleBadge extends StatelessWidget {
  final FcwRole role;

  const FcwRoleBadge(this.role, {super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final vault = role == FcwRole.vault;
    // Its own node: inside an AppBar title it must not merge into, and rename,
    // the title.
    return Semantics(
      container: true,
      label: vault ? '離線簽章裝置' : '連網觀察裝置',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.primaryContainer,
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Icon(
            vault ? Icons.shield_outlined : Icons.visibility_outlined,
            size: 18,
            color: colors.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
