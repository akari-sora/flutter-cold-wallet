import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:public_models/src/ffi/ur_decoder.dart';
import 'fountain_progress.dart';

class UrTypeMismatchException implements Exception {
  final String expected;
  final String actual;
  UrTypeMismatchException({required this.expected, required this.actual});
  @override
  String toString() => 'UR 類型不符：預期 $expected，收到 $actual';
}

class UrInconsistentSessionException implements Exception {
  final String message;
  UrInconsistentSessionException(this.message);
  @override
  String toString() => message;
}

typedef UrFrameDecode = Map<String, dynamic> Function(
    String expectedType, List<String> frames);

Map<String, dynamic> _decodeIncrementalFrame((int, String) input) =>
    NativeUrDecoder.receiveFrame(input.$1, input.$2);

/// Bounded transport session. Only the native fountain decoder can complete it.
class UrFountainDecoder {
  static const maxFrameCharacters = 8192;
  static const maxFrames = 512;
  static const maxSessionCharacters = 2097152;
  static const maxPayloadBytes = 131072;

  final String expectedType;
  final UrFrameDecode? _decode;
  int? _nativeSession;
  bool _receiving = false;
  late final Set<String> _allowedTypes;
  final _progressController = StreamController<FountainProgress>.broadcast();
  final Map<int, String> _frames = {};
  String? _activeType;
  int _totalFragments = 0;
  int _sessionCharacters = 0;
  bool _isComplete = false;
  bool _disposed = false;
  int _generation = 0;
  List<int>? _completedPayload;
  String? _completedUrOrFramesJson;

  UrFountainDecoder({required this.expectedType, UrFrameDecode? decode})
      : _decode = decode {
    _allowedTypes = expectedType
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (_allowedTypes.isEmpty) throw ArgumentError('必須指定 QR 類型');
  }

  Stream<FountainProgress> get progressStream => _progressController.stream;
  bool get isComplete => _isComplete;
  List<int>? get completedPayload => _completedPayload == null
      ? null
      : List<int>.unmodifiable(_completedPayload!);
  String? get completedUrOrFramesJson => _completedUrOrFramesJson;
  String? get activeType => _activeType;
  List<String> get orderedFrames {
    final keys = _frames.keys.toList()..sort();
    return keys.map((key) => _frames[key]!).toList(growable: false);
  }

  Future<List<int>?> receiveFrame(String rawUr) async {
    if (_disposed) throw StateError('掃描已結束');
    if (_isComplete) return completedPayload;
    if (_receiving) throw StateError('QR 核心仍在處理上一幀');
    if (rawUr.length > maxFrameCharacters) {
      throw const FormatException('QR 單幀超過大小限制');
    }
    final clean = rawUr.trim().toLowerCase();
    final segments =
        clean.startsWith('ur:') ? clean.substring(3).split('/') : <String>[];
    if (segments.length < 2 ||
        segments.length > 3 ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(segments[0])) {
      throw const FormatException('無效的 UR 格式');
    }
    final type = segments[0];
    if ((!_allowedTypes.contains('*') && !_allowedTypes.contains(type)) ||
        (_activeType != null && _activeType != type)) {
      throw UrTypeMismatchException(
          expected: _activeType ?? expectedType, actual: type);
    }
    var sequence = 1;
    var count = 1;
    if (segments.length == 3) {
      final match = RegExp(r'^([0-9]+)-([0-9]+)$').firstMatch(segments[1]);
      sequence = match == null ? 0 : int.tryParse(match[1]!) ?? 0;
      count = match == null ? 0 : int.tryParse(match[2]!) ?? 0;
      if (sequence <= 0 ||
          sequence > 0xffffffff ||
          count <= 0 ||
          count > maxFrames) {
        throw const FormatException('QR 幀序號超過限制');
      }
    }
    if (_totalFragments != 0 && _totalFragments != count) {
      throw UrInconsistentSessionException('QR 幀數不符，請重設後掃描同一筆請求');
    }
    final previous = _frames[sequence];
    if (previous == clean) return null;
    if (previous != null) {
      throw UrInconsistentSessionException('同一 QR 序號內容不符，請重設掃描');
    }
    if (_frames.length >= maxFrames ||
        _sessionCharacters + clean.length > maxSessionCharacters) {
      throw const FormatException('QR 掃描會話超過限制，請重設');
    }
    final generation = _generation;
    _receiving = true;
    final Map<String, dynamic> result;
    try {
      final injected = _decode;
      if (injected != null) {
        // Compatibility seam for deterministic public-only test decoders.
        final candidate = {..._frames, sequence: clean};
        final keys = candidate.keys.toList()..sort();
        result = injected(
            type, keys.map((key) => candidate[key]!).toList(growable: false));
      } else {
        final session = _nativeSession ??= NativeUrDecoder.startSession(type);
        // Only the new frame crosses FFI. Native preserves the bounded session;
        // decoding runs in a worker isolate instead of the Flutter UI thread.
        result = await compute(_decodeIncrementalFrame, (session, clean),
            debugLabel: 'FCW QR decode');
      }
    } finally {
      // A reset during the worker call already released this receive slot.
      if (generation == _generation) _receiving = false;
    }
    if (_disposed || generation != _generation) return null;
    // Invalid input never becomes active Dart session state; native rolls back
    // a rejected receive without discarding previously accepted frames.
    final status = result['status'];
    if (status == 'error') {
      final code = result['error_code'];
      if (code == 'ERR_UR_SESSION_RECOVERY' ||
          code == 'ERR_UR_SESSION_NOT_FOUND') {
        // Native dropped the session; Dart progress can no longer be trusted.
        _nativeSession = null;
        reset();
        throw UrInconsistentSessionException('QR 解碼會話已失效，已清除進度，請重新掃描');
      }
      // A rejected first frame must not pin one of the allowed UR types.
      // Accepted multipart state still stays intact via native rollback.
      if (_frames.isEmpty) _closeNativeSession();
      throw FormatException(result['error'] as String? ?? 'QR 解碼失敗');
    }
    if (status != 'complete' && status != 'incomplete') {
      _discardDesynchronizedSession(false);
      throw StateError('QR 核心結果無效');
    }
    final total = result['total_fragments'];
    final resolved = result['resolved_fragments'];
    if (total is! int ||
        resolved is! int ||
        total != count ||
        resolved < 0 ||
        resolved > total) {
      _discardDesynchronizedSession(status == 'complete');
      throw StateError('QR 核心進度無效');
    }
    List<int>? payload;
    if (status == 'complete') {
      final hex = result['payload_hex'];
      if (hex is! String ||
          hex.isEmpty ||
          hex.length > maxPayloadBytes * 2 ||
          hex.length.isOdd ||
          !RegExp(r'^[0-9a-f]+$').hasMatch(hex) ||
          resolved != total) {
        _discardDesynchronizedSession(true);
        throw StateError('QR 核心資料無效');
      }
      payload = List<int>.generate(hex.length ~/ 2,
          (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
    }
    _frames[sequence] = clean;
    _sessionCharacters += clean.length;
    _activeType = type;
    _totalFragments = count;
    _isComplete = payload != null;
    _completedPayload = payload;
    if (_isComplete) {
      final frames = orderedFrames;
      _completedUrOrFramesJson =
          frames.length == 1 ? frames.single : jsonEncode(frames);
      _nativeSession = null; // Native removes completed sessions.
    }
    _progressController.add(FountainProgress(
        totalFragments: total,
        resolvedFragments: resolved,
        currentSeqNum: sequence,
        isComplete: _isComplete));
    return completedPayload;
  }

  Future<List<int>?> receiveBatchInput(String input) async {
    if (input.length > maxSessionCharacters + 16384)
      throw const FormatException('QR 輸入超過限制');
    final text = input.trim();
    if (text.isEmpty) throw const FormatException('QR 輸入不可為空');
    final List<String> frames;
    if (text.startsWith('[')) {
      final decoded = jsonDecode(text);
      if (decoded is! List || decoded.any((frame) => frame is! String)) {
        throw const FormatException('QR 清單只接受字串');
      }
      frames = decoded.cast<String>();
    } else {
      frames = text
          .split(RegExp(r'[\r\n]+'))
          .where((frame) => frame.trim().isNotEmpty)
          .toList();
    }
    if (frames.isEmpty || frames.length > maxFrames)
      throw const FormatException('QR 幀數超過限制或空白');
    final generation = _generation;
    final hadProgress = _frames.isNotEmpty;
    for (final frame in frames) {
      if (_disposed || generation != _generation) return null;
      final List<int>? result;
      try {
        result = await receiveFrame(frame);
      } catch (e) {
        // Manual input is all-or-nothing: a partly accepted list must not
        // leave frames that make a corrected retry look inconsistent.
        if (!_disposed && generation == _generation) reset();
        if (hadProgress) {
          throw UrInconsistentSessionException(
              '$e（已一併清除先前的掃描進度，請重新掃描或貼上完整內容）');
        }
        rethrow;
      }
      if (_disposed || generation != _generation) return null;
      if (result != null) return result;
    }
    return null;
  }

  /// The native result was accepted by FFI but rejected here, so the native
  /// session no longer matches Dart state. A completed session is already
  /// removed natively; anything else is closed explicitly.
  void _discardDesynchronizedSession(bool nativeCompleted) {
    if (nativeCompleted) _nativeSession = null;
    reset();
  }

  void reset() {
    if (_disposed) return;
    _generation++;
    _receiving = false;
    _closeNativeSession();
    _activeType = null;
    _totalFragments = 0;
    _sessionCharacters = 0;
    _frames.clear();
    _isComplete = false;
    _completedPayload = null;
    _completedUrOrFramesJson = null;
    _progressController.add(const FountainProgress.initial());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _closeNativeSession();
    _frames.clear();
    _progressController.close();
  }

  void _closeNativeSession() {
    final session = _nativeSession;
    _nativeSession = null;
    if (session != null) NativeUrDecoder.closeSession(session);
  }
}
