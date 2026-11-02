import 'package:flutter/material.dart';

/// Covers revoked authorization UI while preserving the mounted child.
class SecurityOverlay extends StatelessWidget {
  final bool isLocked;
  final VoidCallback? onUnlock;
  final Widget child;

  const SecurityOverlay({
    super.key,
    required this.isLocked,
    this.onUnlock,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLocked) return child;

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Stack(
      children: [
        ExcludeSemantics(child: ExcludeFocus(child: child)),
        Positioned.fill(
          child: Material(
            color: colors.surface,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline,
                          color: colors.onSurfaceVariant, size: 40),
                      const SizedBox(height: 20),
                      Text('金庫已鎖定',
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      Text(
                        '待簽授權已作廢。解鎖後請重新掃描交易。',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (onUnlock != null) ...[
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.lock_open_outlined),
                          label: const Text('解鎖並重新掃描'),
                          onPressed: onUnlock,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
