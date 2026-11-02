import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart'
    show MethodChannelMobileScanner;
import '../fountain/fountain_progress.dart';
import '../fountain/ur_fountain_decoder.dart';
import '../utils/haptic_helper.dart';

/// Continuous optical air-gap camera scanner widget.
/// Bundles ML Kit offline model capability for zero-network first-launch scanning (OFF-03)
/// and provides manual UR frame input for deterministic testing & accessibility.
class AirGapScanner extends StatefulWidget {
  final String expectedType;
  final String title;
  final ValueChanged<List<int>> onPayloadComplete;
  final ValueChanged<String>? onRawUrComplete;
  final VoidCallback? onCancel;

  /// Opens this app's page in the system settings. When provided, a denied
  /// camera permission explains how to re-enable it and offers this action,
  /// since a permanently denied request no longer shows a system prompt.
  /// A thrown error is shown in the scanner.
  final AsyncCallback? onOpenAppSettings;

  /// Replaces the denied-camera guidance shown with [onOpenAppSettings] for
  /// an entry whose scan does not survive leaving the app.
  final String? deniedPermissionHint;

  /// Called with true when this scanner asks for the camera permission, and
  /// with false once the request is answered. The request puts a system
  /// activity over the app (the dialog, or a transparent one when Android
  /// answers by itself), which makes the app inactive without the user
  /// leaving it. Neither the permission check before it nor the camera start
  /// after the answer is reported, nor a start whose permission is already
  /// granted or one still waiting for another scanner.
  final ValueChanged<bool>? onPermissionRequest;

  const AirGapScanner({
    super.key,
    required this.expectedType,
    this.title = '掃描氣隙二維碼 (Air-Gap Scanner)',
    required this.onPayloadComplete,
    this.onRawUrComplete,
    this.onCancel,
    this.onOpenAppSettings,
    this.deniedPermissionHint,
    this.onPermissionRequest,
  });

  @override
  State<AirGapScanner> createState() => _AirGapScannerState();
}

class _AirGapScannerState extends State<AirGapScanner>
    with WidgetsBindingObserver {
  late final MobileScannerController _scannerController;
  late final UrFountainDecoder _fountainDecoder;
  final _cameraErrorScroll = ScrollController();
  String? _lastScannedText;
  FountainProgress _progress = const FountainProgress.initial();
  String? _errorMessage;
  StreamSubscription<FountainProgress>? _progressSubscription;
  bool _busy = false;
  bool _cancelled = false;
  bool _manualInputOpen = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _generation = 0;

  /// Whether the app was hidden since the last resume, e.g. while the system
  /// settings were open. A permission dialog only makes the app inactive.
  bool _hiddenSinceResume = false;

  /// mobile_scanner has one platform instance for every controller. Starts,
  /// stops and disposals of all scanners run one at a time, in order, so a
  /// scanner still being cleaned up cannot stop a newer scanner's camera.
  static Future<void> _cameraQueue = Future<void>.value();
  static bool _cameraIdle = true;

  /// The scanner whose controller last started the shared camera. Disposing
  /// a controller disposes the shared platform, which stops whatever camera
  /// runs, so only this owner may dispose its controller there.
  static int? _cameraOwner;
  static int _lastScannerId = 0;
  final int _scannerId = ++_lastScannerId;

  static Future<void> _queued(Future<void> Function() operation) {
    // When idle, run at once instead of chaining onto a settled future,
    // which may belong to a zone that no longer runs (e.g. a finished test).
    final run =
        _cameraIdle ? operation() : _cameraQueue.then((_) => operation());
    _cameraIdle = false;
    late final Future<void> queue;
    queue = _cameraQueue = run.catchError((Object _) {}).whenComplete(() {
      if (identical(_cameraQueue, queue)) _cameraIdle = true;
    });
    return run;
  }

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _scannerController = MobileScannerController(
      // Started here instead, after MobileScanner's own setup, so that
      // dispose knows about a start still waiting for the permission dialog.
      autoStart: false,
      detectionSpeed: DetectionSpeed.unrestricted,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_cancelled) return;
      unawaited(_startCamera().catchError((Object error) {
        if (mounted && !_cancelled) {
          setState(() => _errorMessage = '相機啟動失敗：$error');
        }
      }));
    });
    _fountainDecoder = UrFountainDecoder(expectedType: widget.expectedType);
    _progressSubscription = _fountainDecoder.progressStream.listen((p) {
      if (mounted) {
        setState(() => _progress = p);
      }
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _progressSubscription?.cancel();
    // Queued behind this scanner's own start: one still waiting for the
    // permission dialog (e.g. this scanner was revoked while it was open)
    // would otherwise start the camera after this controller is disposed and
    // leave it running, and the next scanner's start would fail with
    // controllerAlreadyInitialized. A newer scanner's start queues behind it.
    final controller = _scannerController;
    final id = _scannerId;
    unawaited(_queued(() async {
      // A newer scanner owns the camera, e.g. it started while this route was
      // still animating out after 取消掃描 had stopped this one. Disposing
      // this controller would stop that camera, so it is left to the garbage
      // collector instead.
      if (_cameraOwner != null && _cameraOwner != id) return;
      _cameraOwner = null;
      await controller.stop().catchError((Object _) {});
      await controller.dispose();
    }));
    _fountainDecoder.dispose();
    _cameraErrorScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (_cancelled) return;
    if (state == AppLifecycleState.resumed) {
      final wasHidden = _hiddenSinceResume;
      _hiddenSinceResume = false;
      // A popped route stays mounted during its reverse animation. It must not
      // restart a camera after the Vault lifecycle guard has already locked.
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (!_scannerController.value.isInitialized) return;
      // A restart requests the permission again, and that request returns
      // here through `inactive`. After a denial only a return from elsewhere
      // (e.g. the system settings) may have changed it; otherwise a request
      // Android denies by itself would repeat until it removes the task.
      // 清除並重新掃描 still asks again on purpose.
      if (_permissionDenied && !wasHidden) return;
      // Frames from before the pause were discarded, so a camera that works
      // again (e.g. enabled by hand in the settings) retires the old message.
      unawaited(_restartCameraIfAllowed(clearError: true));
    } else {
      if (state != AppLifecycleState.inactive) _hiddenSinceResume = true;
      _generation++;
      _fountainDecoder.reset();
      _lastScannedText = null;
      if (mounted) setState(() => _progress = const FountainProgress.initial());
      // A start still pending (e.g. the permission dialog made the app
      // inactive) is left alone, as stop() would have ignored it.
      if (_scannerController.value.isRunning) unawaited(_stopCamera());
    }
  }

  bool get _permissionDenied =>
      _scannerController.value.error?.errorCode ==
      MobileScannerErrorCode.permissionDenied;

  bool _offersAppSettings(MobileScannerException? error) =>
      widget.onOpenAppSettings != null &&
      error?.errorCode == MobileScannerErrorCode.permissionDenied;

  Future<void> _openAppSettings() async {
    try {
      await widget.onOpenAppSettings!();
    } catch (_) {
      if (mounted && !_cancelled) {
        setState(() => _errorMessage =
            '無法開啟系統設定。請手動前往系統設定的應用程式頁面，允許本 App 使用相機。');
      }
    }
  }

  bool get _canRunCamera =>
      mounted &&
      !_cancelled &&
      !_manualInputOpen &&
      !_fountainDecoder.isComplete &&
      _lifecycleState == AppLifecycleState.resumed &&
      ModalRoute.of(context)?.isCurrent == true;

  // mobile_scanner 7.4.2's method-channel platform requests the camera
  // from start() unless this channel reports it as authorized; the plugin
  // exports neither the channel nor a permission query.
  static const _scannerChannel =
      MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

  /// The camera permission as the plugin's channel reports it. Unknown
  /// (another platform implementation, an error) is null.
  static Future<MobileScannerAuthorizationState?> _cameraAuthorization() async {
    if (kIsWeb ||
        MobileScannerPlatform.instance is! MethodChannelMobileScanner) {
      return null;
    }
    try {
      final raw = await _scannerChannel.invokeMethod<int>('state');
      return raw == null
          ? null
          : MobileScannerAuthorizationState.fromRawValue(raw);
    } catch (_) {
      return null;
    }
  }

  /// What the controller records when start() is refused the camera, set
  /// here because start() would ask again.
  void _recordPermissionDenied() {
    _scannerController.value = _scannerController.value.copyWith(
      cameraDirection: _scannerController.facing,
      isInitialized: true,
      isRunning: false,
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied),
      size: Size.zero,
      torchState: TorchState.unavailable,
      zoomScale: 1.0,
    );
  }

  Future<void> _startCamera() {
    final notify = widget.onPermissionRequest;
    return _queued(() async {
      // A scanner gone while waiting in line must not ask for the camera.
      if (_cancelled) return;
      // Checked when this start actually runs, not while it waits in line.
      final authorization = await _cameraAuthorization();
      if (_cancelled) return;
      if (authorization != null &&
          authorization != MobileScannerAuthorizationState.authorized) {
        // Asked here rather than by start(), so that only the request itself
        // is reported: neither the check before it nor the camera start after
        // the answer. start() then finds the camera granted and asks nothing.
        bool? granted;
        notify?.call(true);
        try {
          granted =
              await _scannerChannel.invokeMethod<bool>('request') ?? false;
        } catch (_) {
          // Left to start(), which asks again and reports the platform error.
        } finally {
          notify?.call(false);
        }
        // Removed while the dialog was open: the answer starts nothing.
        if (_cancelled) return;
        if (granted == false) {
          _recordPermissionDenied();
          return;
        }
      }
      await _scannerController.start();
      if (_scannerController.value.isRunning) _cameraOwner = _scannerId;
    });
  }

  Future<void> _stopCamera() =>
      _queued(_scannerController.stop).catchError((Object _) {});

  Future<void> _restartCameraIfAllowed({bool clearError = false}) async {
    if (!_canRunCamera) return;
    try {
      await _startCamera();
      if (!_canRunCamera) {
        await _stopCamera();
      } else if (clearError && _scannerController.value.isRunning) {
        setState(() => _errorMessage = null);
      }
    } catch (error) {
      if (_canRunCamera) {
        setState(() => _errorMessage = '相機啟動失敗：$error');
      }
    }
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _generation++;
    _fountainDecoder.reset();
    unawaited(_stopCamera());
    if (widget.onCancel != null) {
      widget.onCancel!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _reset() {
    if (_busy || _cancelled || _manualInputOpen) return;
    _generation++;
    _fountainDecoder.reset();
    setState(() {
      _errorMessage = null;
      _lastScannedText = null;
      _progress = const FountainProgress.initial();
    });
    unawaited(_restartCameraIfAllowed());
  }

  Future<bool> _ingestRawFrameOrBatch(String rawInput,
      {bool isBatch = false, bool deferCompletion = false}) async {
    if (!mounted || _busy || _cancelled || _fountainDecoder.isComplete)
      return false;
    _busy = true;
    final generation = _generation;
    try {
      setState(() => _errorMessage = null);
      final result = isBatch
          ? await _fountainDecoder.receiveBatchInput(rawInput)
          : await _fountainDecoder.receiveFrame(rawInput);
      if (!mounted || _cancelled || generation != _generation) return false;
      try {
        HapticHelper.lightTick();
      } catch (_) {}

      if (result != null && !deferCompletion)
        await _publishCompleted(generation);
      return true;
    } catch (e) {
      if (mounted && !_cancelled && generation == _generation) {
        setState(() => _errorMessage = e.toString());
      }
      return false;
    } finally {
      if (mounted)
        setState(() => _busy = false);
      else
        _busy = false;
    }
  }

  Future<void> _publishCompleted(int generation) async {
    final payload = _fountainDecoder.completedPayload;
    final raw = _fountainDecoder.completedUrOrFramesJson;
    if (payload == null || raw == null) return;
    await _stopCamera();
    if (!mounted ||
        _cancelled ||
        generation != _generation ||
        _lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true) return;
    try {
      HapticHelper.successVibrate();
    } catch (_) {}
    widget.onPayloadComplete(payload);
    widget.onRawUrComplete?.call(raw);
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (_busy || !_canRunCamera) return;
    final generation = _generation;

    for (final barcode in capture.barcodes) {
      if (!_canRunCamera || generation != _generation) break;
      final rawValue = barcode.rawValue;
      if (rawValue == null || rawValue.isEmpty) continue;

      if (!rawValue.toLowerCase().startsWith('ur:')) continue;

      if (rawValue == _lastScannedText) continue;
      _lastScannedText = rawValue;

      await _ingestRawFrameOrBatch(rawValue);
      if (_fountainDecoder.isComplete) break;
    }
  }

  Future<void> _showManualUrInputDialog() async {
    if (_busy || !_canRunCamera) return;
    _manualInputOpen = true;
    try {
      // Manual input owns the session even if a camera callback was queued
      // before stop completed. A camera failure must not remove this fallback.
      await _stopCamera();
      if (!mounted ||
          _cancelled ||
          _lifecycleState != AppLifecycleState.resumed ||
          ModalRoute.of(context)?.isCurrent != true) return;
      final generation = _generation;
      final submitted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ManualUrInputDialog(
          expectedType: widget.expectedType,
          onSubmit: (text) async {
            if (!mounted ||
                _cancelled ||
                generation != _generation ||
                _lifecycleState != AppLifecycleState.resumed) {
              return '掃描已暫停，請取消後重新開啟輸入。';
            }
            final accepted = await _ingestRawFrameOrBatch(text,
                isBatch: true, deferCompletion: true);
            return accepted ? null : _errorMessage ?? '掃描已暫停，請取消後重試。';
          },
        ),
      );
      if (mounted &&
          !_cancelled &&
          _lifecycleState == AppLifecycleState.resumed &&
          submitted == true &&
          generation == _generation &&
          _fountainDecoder.isComplete) {
        // Pop the editor before a completion callback navigates away.
        await _publishCompleted(generation);
      }
    } finally {
      _manualInputOpen = false;
      // A denied camera was not running; restarting it would only ask for
      // the permission again.
      if (!_permissionDenied) await _restartCameraIfAllowed();
    }
  }

  // Scrolls, with a visible thumb, when long, e.g. an entry hint at a large
  // text scale.
  Widget _cameraErrorMessage() => ValueListenableBuilder<MobileScannerState>(
        valueListenable: _scannerController,
        builder: (context, camera, _) {
          final error = camera.error;
          if (error == null) return const SizedBox.shrink();
          return Center(
            child: Scrollbar(
              controller: _cameraErrorScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _cameraErrorScroll,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Text(
                    _offersAppSettings(error)
                        ? widget.deniedPermissionHint ??
                            '相機權限未允許。若系統不再詢問，請到系統設定的「權限」開啟相機，返回後即可掃描；也可以使用手動輸入。'
                        : '無法使用相機：${error.errorCode.name}。請檢查相機權限，或使用手動輸入。',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center),
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera viewfinder layer
          MobileScanner(
            controller: _scannerController,
            onDetect: _handleBarcode,
            // The message is laid out between the controls below instead.
            errorBuilder: (context, error) => const SizedBox.expand(),
          ),

          // Viewfinder: dimmed surroundings with a clear window and corner marks,
          // painted under the controls so they keep full contrast.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _ViewfinderPainter(
                  side: (MediaQuery.sizeOf(context).width - 64)
                      .clamp(0, 260)
                      .toDouble(),
                  accent: Theme.of(context).colorScheme.inversePrimary,
                ),
              ),
            ),
          ),

          // The camera error gets the space between the top controls and the
          // status panel, so neither covers it.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: CustomMultiChildLayout(
                delegate: _ScannerLayout(),
                children: [
                  LayoutId(
                      id: _ScannerSlot.message, child: _cameraErrorMessage()),
                  // Top navigation & torch controls
                  LayoutId(
                    id: _ScannerSlot.top,
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        children: [
                          Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white),
                                  tooltip: '取消掃描',
                                  constraints:
                                      const BoxConstraints(minWidth: 48, minHeight: 48),
                                  onPressed: _cancel,
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      key: const Key('manual_ur_dialog_btn'),
                                      icon: const Icon(Icons.keyboard,
                                          color: Colors.white),
                                      tooltip: '手動貼上 UR',
                                      constraints: const BoxConstraints(
                                          minWidth: 48, minHeight: 48),
                                      onPressed: _showManualUrInputDialog,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.flash_on,
                                          color: Colors.white),
                                      tooltip: '手電筒',
                                      constraints: const BoxConstraints(
                                          minWidth: 48, minHeight: 48),
                                      onPressed: () => _scannerController.toggleTorch(),
                                    ),
                                  ],
                                ),
                              ]),
                          Text(widget.title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                  // Bottom progress and status HUD
                  LayoutId(
                    id: _ScannerSlot.bottom,
                    child: Container(
                      key: const Key('scanner_status_panel'),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        // FcwRadius.card; qr_ui does not depend on design_system.
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                            value: _progress.percentage,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.inversePrimary),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              Text(
                                _progress.totalFragments > 0
                                    ? '已讀取 ${_progress.resolvedFragments} / ${_progress.totalFragments} 張'
                                    : '請將二維碼放入框內',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${(_progress.percentage * 100).toInt()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                          ],
                          // Kept in this top-most panel so large text cannot cover it.
                          ValueListenableBuilder<MobileScannerState>(
                            valueListenable: _scannerController,
                            builder: (context, camera, _) {
                              if (!_offersAppSettings(camera.error)) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: FilledButton.icon(
                                  key: const Key('scanner_open_app_settings_btn'),
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(48, 48)),
                                  onPressed: _openAppSettings,
                                  icon: const Icon(Icons.settings, size: 18),
                                  label: const Text('開啟系統設定'),
                                ),
                              );
                            },
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                minimumSize: const Size(48, 48)),
                            onPressed: _reset,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('清除並重新掃描'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualUrInputDialog extends StatefulWidget {
  const _ManualUrInputDialog(
      {required this.expectedType, required this.onSubmit});

  final String expectedType;
  final Future<String?> Function(String text) onSubmit;

  @override
  State<_ManualUrInputDialog> createState() => _ManualUrInputDialogState();
}

class _ManualUrInputDialogState extends State<_ManualUrInputDialog> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_submitting) return;
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = '請輸入或貼上 UR 字串／多幀清單。');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final error = await widget.onSubmit(_controller.text);
      if (!mounted) return;
      if (error == null) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    // showDialog's result completes before its exit animation unmounts the
    // TextField. Keep its controller alive for the dialog's entire lifetime.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        scrollable: true,
        title: const Text('輸入或貼上 UR 字串 / 多幀清單'),
        content: TextField(
          key: const Key('manual_ur_input_field'),
          controller: _controller,
          enabled: !_submitting,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: 'ur:${widget.expectedType.split(',').first}/...',
            border: const OutlineInputBorder(),
            errorText: _error,
            errorMaxLines: 6,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            key: const Key('manual_ur_submit_btn'),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, semanticsLabel: '正在解析 UR'))
                : const Text('解析 UR'),
          ),
        ],
      ));
}

/// Type alias for AirGapScannerView
typedef AirGapScannerView = AirGapScanner;

enum _ScannerSlot { message, top, bottom }

/// Keeps the top controls and the bottom panel where they were as overlays;
/// the camera error message gets the height left between them (none when
/// they meet, where the panel stays painted on top as before).
class _ScannerLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    // Full width and unbounded height, as for the former Positioned overlays.
    final fullWidth = BoxConstraints.tightFor(width: size.width);
    final top = layoutChild(_ScannerSlot.top, fullWidth);
    final bottom = layoutChild(_ScannerSlot.bottom, fullWidth);
    final between =
        (size.height - top.height - bottom.height).clamp(0, size.height);
    layoutChild(_ScannerSlot.message,
        BoxConstraints.tightFor(width: size.width, height: between.toDouble()));
    positionChild(_ScannerSlot.message, Offset(0, top.height));
    positionChild(_ScannerSlot.top, Offset.zero);
    positionChild(_ScannerSlot.bottom, Offset(0, size.height - bottom.height));
  }

  @override
  bool shouldRelayout(_ScannerLayout oldDelegate) => false;
}

class _ViewfinderPainter extends CustomPainter {
  final double side;
  final Color accent;

  const _ViewfinderPainter({required this.side, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final window = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: size.center(Offset.zero), width: side, height: side),
        const Radius.circular(20)); // FcwRadius.card
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(window);
    canvas.drawPath(
        scrim, Paint()..color = Colors.black.withValues(alpha: 0.45));
    final mark = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final r = window.outerRect;
    const len = 28.0;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner.translate(dx * len, 0), mark);
      canvas.drawLine(corner, corner.translate(0, dy * len), mark);
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) =>
      old.side != side || old.accent != accent;
}
