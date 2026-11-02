import 'package:flutter/material.dart';

/// Prevents accidental confirmation through a physical sliding gesture.
class SlideToConfirm extends StatefulWidget {
  final VoidCallback onConfirmed;
  final bool enabled;
  final String label;

  const SlideToConfirm({
    super.key,
    required this.onConfirmed,
    this.enabled = true,
    this.label = '滑動以確認簽署',
  });

  @override
  State<SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<SlideToConfirm> {
  double _position = 0.0;
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    const thumbSize = 56.0;
    // The thumb and its fill sit this far inside the track border.
    const inset = 4.0;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = _confirmed ? '已確認授權' : widget.label;

    return LayoutBuilder(builder: (context, constraints) {
      final maxSlide = (constraints.maxWidth - inset * 2 - thumbSize)
          .clamp(0.0, double.infinity);
      return Semantics(
        container: true,
        slider: true,
        enabled: widget.enabled && !_confirmed,
        label: label,
        hint: widget.enabled && !_confirmed ? '將左側箭頭向右滑至終點以確認' : null,
        value: _confirmed ? '已確認' : null,
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: thumbSize + inset * 2),
            padding: const EdgeInsets.all(inset),
            clipBehavior: Clip.antiAlias,
            decoration: ShapeDecoration(
              color: colors.surfaceContainerHighest,
              shape: StadiumBorder(
                side: BorderSide(
                  color:
                      widget.enabled ? colors.primary : colors.outlineVariant,
                ),
              ),
            ),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Fill that trails the thumb at its height, so progress shows
                // mid-drag and nothing shows around the thumb at rest.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _position + thumbSize,
                  child: Center(
                    child: Container(
                      key: const Key('slide_to_confirm_fill'),
                      height: thumbSize,
                      decoration: ShapeDecoration(
                        color: widget.enabled
                            ? colors.primaryContainer
                            : Colors.transparent,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(60, 16, 12, 16),
                  child: Center(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: widget.enabled
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: _position,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: GestureDetector(
                      onHorizontalDragUpdate: widget.enabled && !_confirmed
                          ? (details) {
                              setState(() {
                                _position =
                                    (_position + details.delta.dx).clamp(
                                  0.0,
                                  maxSlide,
                                );
                              });
                            }
                          : null,
                      onHorizontalDragEnd: widget.enabled && !_confirmed
                          ? (details) {
                              if (maxSlide > 0 && _position >= maxSlide * 0.9) {
                                setState(() {
                                  _position = maxSlide;
                                  _confirmed = true;
                                });
                                widget.onConfirmed();
                              } else {
                                setState(() {
                                  _position = 0.0;
                                });
                              }
                            }
                          : null,
                      child: Container(
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.enabled
                              ? colors.primary
                              : colors.surfaceContainerLow,
                        ),
                        child: Icon(
                          _confirmed ? Icons.check : Icons.arrow_forward_ios,
                          color: widget.enabled
                              ? colors.onPrimary
                              : colors.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
