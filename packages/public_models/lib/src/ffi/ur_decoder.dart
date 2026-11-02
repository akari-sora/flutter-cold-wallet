import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_library_loader.dart';

typedef _DecodeNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DecodeDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Public transport decoding only. Completeness and checksums come from Rust UR.
class NativeUrDecoder {
  static NativeUrDecoder? _instance;
  final _DecodeDart _decode;
  final _FreeDart _free;

  NativeUrDecoder._(DynamicLibrary library)
      : _decode = library
            .lookupFunction<_DecodeNative, _DecodeDart>('fcw_decode_ur_frames'),
        _free = library
            .lookupFunction<_FreeNative, _FreeDart>('fcw_free_ur_result');

  static NativeUrDecoder _load() {
    final failures = <Object>[];
    for (final loader in [
      NativeLibraryLoader.loadWalletLib,
      NativeLibraryLoader.loadVaultLib,
    ]) {
      try {
        return NativeUrDecoder._(loader());
      } catch (error) {
        failures.add(error);
      }
    }
    throw StateError('無法載入 QR 解碼核心，請安裝完整版本：${failures.join('; ')}');
  }

  static Map<String, dynamic> decode(String type, List<String> frames) {
    return _request({'expected_type': type, 'frames': frames});
  }

  /// Opens one of the bounded native sessions shared by Dart isolates.
  static int startSession(String type) {
    final result = _request({'op': 'start', 'expected_type': type});
    final id = result['session_id'];
    if (result['status'] != 'started' || id is! int || id <= 0) {
      throw StateError(result['error']?.toString() ?? 'QR 解碼工作階段建立失敗');
    }
    return id;
  }

  /// Feeds only the newly scanned frame. Completion releases native state.
  static Map<String, dynamic> receiveFrame(int sessionId, String frame) {
    if (sessionId <= 0) throw ArgumentError.value(sessionId, 'sessionId');
    return _request({'op': 'receive', 'session_id': sessionId, 'frame': frame});
  }

  /// Safe to call repeatedly, including after native completion.
  static void closeSession(int sessionId) {
    if (sessionId <= 0) throw ArgumentError.value(sessionId, 'sessionId');
    final result = _request({'op': 'close', 'session_id': sessionId});
    if (result['status'] != 'closed') {
      throw StateError(result['error']?.toString() ?? 'QR 解碼工作階段關閉失敗');
    }
  }

  static Map<String, dynamic> _request(Map<String, dynamic> request) {
    final decoder = _instance ??= _load();
    final input = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    try {
      output = decoder._decode(input);
      if (output == nullptr) throw StateError('QR 解碼核心未回傳結果');
      return jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      calloc.free(input);
      if (output != nullptr) decoder._free(output);
    }
  }
}
