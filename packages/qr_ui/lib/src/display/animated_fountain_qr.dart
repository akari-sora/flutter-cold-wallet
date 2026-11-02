import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'ur_qr_payload.dart';

/// Animated Fountain QR code display widget.
/// Cycles through multi-part or single-part UR frames at a calibrated frame rate
/// with high-contrast optical ergonomics and manual frame stepping.
class AnimatedFountainQr extends StatefulWidget {
  final List<String> frames;
  final double initialFps;
  final double qrSize;
  final String title;
  final String subtitle;
  final bool startPaused;

  const AnimatedFountainQr({
    super.key,
    required this.frames,
    this.initialFps = 6.0,
    this.qrSize = 280.0,
    this.title = '掃描二維碼',
    this.subtitle = '使用另一台裝置掃描；多張二維碼可連續播放。',
    this.startPaused = false,
  });

  @override
  State<AnimatedFountainQr> createState() => _AnimatedFountainQrState();
}

class _AnimatedFountainQrState extends State<AnimatedFountainQr> {
  late double _fps;
  int _currentIndex = 0;
  late bool _isPlaying;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fps = widget.initialFps.clamp(3.0, 8.0);
    _isPlaying = !widget.startPaused;
    try {
      WakelockPlus.enable();
    } catch (_) {}
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant AnimatedFountainQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.frames, widget.frames)) _currentIndex = 0;
    if (oldWidget.startPaused != widget.startPaused) {
      _isPlaying = !widget.startPaused;
    }
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (!_isPlaying || widget.frames.length < 2) return;
    final intervalMs = (1000 / _fps).round().clamp(100, 1000);
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (mounted && widget.frames.isNotEmpty) {
        setState(() {
          _currentIndex = (_currentIndex + 1) % widget.frames.length;
        });
      }
    });
  }

  void _togglePlayPause() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _startTimer();
      } else {
        _timer?.cancel();
      }
    });
  }

  void _stepFrame(int delta) {
    if (widget.frames.isEmpty) return;
    setState(() {
      _isPlaying = false;
      _timer?.cancel();
      _currentIndex =
          (_currentIndex + delta + widget.frames.length) % widget.frames.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentData =
        widget.frames.isNotEmpty ? widget.frames[_currentIndex] : '';

    return LayoutBuilder(builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;
      final availableWidth =
          constraints.maxWidth.isFinite ? constraints.maxWidth : widget.qrSize;
      final qrSize = math.min(widget.qrSize, availableWidth);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(color: colors.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            widget.subtitle,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          // High contrast pure white card with pure black QR modules (Level M ECC)
          Container(
            width: qrSize,
            height: qrSize,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              // FcwRadius.card; qr_ui does not depend on design_system.
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: UrQrPayload.isDisplayableQrData(currentData)
                ? QrImageView(
                    data: currentData,
                    version: QrVersions.auto,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    padding: const EdgeInsets.all(4),
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  )
                : const Center(
                    child: Text(
                      '無可用 QR 資料',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
          ),

          if (widget.frames.length > 1) ...[
            const SizedBox(height: 12),
            // Shows the sequence is animated and where it is in the loop.
            SizedBox(
              width: qrSize,
              child: LinearProgressIndicator(
                value: (_currentIndex + 1) / widget.frames.length,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),

            // Frame status & rate indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(
                    '幀 ${_currentIndex + 1} / ${widget.frames.length}',
                    style: text.bodySmall?.copyWith(
                        color: colors.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                  Text(
                    '每秒 ${_fps.toStringAsFixed(1)} 張',
                    style: text.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Stepping and Play/Pause controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () => _stepFrame(-1),
                  tooltip: '上一幀 (步進)',
                ),
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause_circle : Icons.play_circle,
                    color: colors.primary,
                  ),
                  iconSize: 42,
                  constraints:
                      const BoxConstraints(minWidth: 56, minHeight: 56),
                  onPressed: _togglePlayPause,
                  tooltip: _isPlaying ? '暫停' : '播放',
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () => _stepFrame(1),
                  tooltip: '下一幀 (步進)',
                ),
              ],
            ),

            // FPS adjustment slider
            SizedBox(
              width: math.min(260, availableWidth),
              child: Slider(
                value: _fps,
                min: 3.0,
                max: 8.0,
                divisions: 10,
                label: '${_fps.toStringAsFixed(1)} FPS',
                onChanged: (val) {
                  setState(() {
                    _fps = val;
                    if (_isPlaying) _startTimer();
                  });
                },
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// Type alias for AnimatedFountainQrView
typedef AnimatedFountainQrView = AnimatedFountainQr;
