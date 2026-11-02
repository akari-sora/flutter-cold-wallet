import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';

typedef _EncodeC = Pointer<Utf8> Function(Pointer<Utf8>, Uint32);
typedef _EncodeDart = Pointer<Utf8> Function(Pointer<Utf8>, int);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

List<int> compact(int n) => n < 253
    ? [n]
    : n <= 65535
        ? [253, n & 255, (n >> 8) & 255]
        : [254, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255];

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// Only public unsigned PSBT bytes and an unknown metadata field. No account,
// mnemonic, derivation, signature, RPC, or transaction dispatch is involved.
List<int> publicPsbt(int metadataLength) {
  final tx = [
    2,
    0,
    0,
    0,
    1,
    ...List.filled(32, 0x11),
    0,
    0,
    0,
    0,
    0,
    0xfd,
    0xff,
    0xff,
    0xff,
    1,
    0xe8,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    22,
    0,
    20,
    ...List.filled(20, 0x22),
    0,
    0,
    0,
    0
  ];
  return [
    0x70,
    0x73,
    0x62,
    0x74,
    0xff,
    1,
    0,
    ...compact(tx.length),
    ...tx,
    1,
    0x50,
    ...compact(metadataLength),
    ...List.filled(metadataLength, 0x55),
    0,
    0,
    0
  ];
}

void main() {
  test('maximum public PSBT crosses actual incremental worker isolates',
      () async {
    const target = UrFountainDecoder.maxPayloadBytes - 8;
    final bytes = publicPsbt(target - publicPsbt(0).length - 4);
    expect(bytes, hasLength(target));
    final library = NativeLibraryLoader.loadWalletLib();
    final encode =
        library.lookupFunction<_EncodeC, _EncodeDart>('wallet_encode_psbt_ur');
    final free =
        library.lookupFunction<_FreeC, _FreeDart>('wallet_free_string');
    final input = hex(bytes).toNativeUtf8();
    Pointer<Utf8> output = nullptr;
    late Map<String, dynamic> encoded;
    try {
      output = encode(input, 0);
      expect(output, isNot(nullptr));
      encoded = jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      calloc.free(input);
      if (output != nullptr) free(output);
    }
    expect(encoded['status'], 'SUCCESS');
    final frames = (encoded['fountain_frames'] as List).cast<String>();
    expect(frames, hasLength(512));
    expect((encoded['cbor_hex'] as String).length,
        UrFountainDecoder.maxPayloadBytes * 2);
    final decoder = UrFountainDecoder(expectedType: 'crypto-psbt');
    addTearDown(decoder.dispose);
    var eventTicks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => eventTicks++);
    addTearDown(timer.cancel);
    final clock = Stopwatch()..start();
    final result = await decoder.receiveBatchInput(jsonEncode(frames));
    clock.stop();
    timer.cancel();
    expect(hex(result!), encoded['cbor_hex']);
    expect(decoder.isComplete, isTrue);
    expect(eventTicks, greaterThan(0),
        reason: 'The UI event loop must yield while native work runs.');
    debugPrint(
        'Public 128KiB/512-frame worker roundtrip: ${clock.elapsedMilliseconds}ms; event ticks=$eventTicks');
  });
}
