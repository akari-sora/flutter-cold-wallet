import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:public_models/public_models.dart';

typedef _JsonC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _JsonDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class BitcoinFfiService {
  late final _JsonDart _build;
  late final _JsonDart _verify;
  late final _FreeDart _free;
  late final _JsonDart _describe;
  BitcoinFfiService([DynamicLibrary? library]) {
    final lib = library ?? NativeLibraryLoader.loadWalletLib();
    _build =
        lib.lookupFunction<_JsonC, _JsonDart>('wallet_build_regtest_psbt_json');
    _verify = lib.lookupFunction<_JsonC, _JsonDart>(
        'wallet_verify_regtest_psbt_response_json');
    _free = lib.lookupFunction<_FreeC, _FreeDart>('wallet_free_string');
    _describe = lib.lookupFunction<_JsonC, _JsonDart>(
        'wallet_verify_regtest_account_json');
  }
  Map<String, dynamic> _invoke(_JsonDart fn, Map<String, dynamic> request) {
    final input = jsonEncode(request).toNativeUtf8();
    try {
      final output = fn(input);
      if (output == nullptr) throw StateError('Bitcoin 原生核心未回應');
      try {
        return Map<String, dynamic>.from(
            jsonDecode(output.toDartString()) as Map);
      } finally {
        _free(output);
      }
    } finally {
      calloc.free(input);
    }
  }

  Map<String, dynamic> describe(Map<String, dynamic> request) =>
      _invoke(_describe, request);
  Map<String, dynamic> build(Map<String, dynamic> request) =>
      _invoke(_build, request);
  Map<String, dynamic> verify(Map<String, dynamic> request) =>
      _invoke(_verify, request);
}

/// Re-derive all displayed Bitcoin receive/change metadata from the public tpub.
/// A master fingerprint is origin metadata, not proof of device identity.
void validateBitcoinPublicAccount(
    BitcoinFfiService native, AccountDescriptor account) {
  final canonical = native.describe({
    'account_xpub': account.extendedPublicKey,
    'master_fingerprint': account.masterFingerprint
  });
  if (canonical['status'] != 'SUCCESS' ||
      canonical['address'] != account.address ||
      canonical['receive_address_regtest'] !=
          account.btcReceiveAddressRegtest ||
      canonical['change_address'] != account.btcChangeAddress ||
      canonical['descriptor'] != account.btcDescriptor ||
      canonical['derivation_path'] != account.derivationPath ||
      (account.compressedPublicKeyHex != null &&
          canonical['compressed_pubkey_hex'] !=
              account.compressedPublicKeyHex)) {
    throw const FormatException('Bitcoin 公開描述、地址或找零資料與 tpub 不符');
  }
}
