import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:public_models/public_models.dart';

typedef _WalletCancelC = Int32 Function(Pointer<Utf8> sessionId);
typedef _WalletCancelDart = int Function(Pointer<Utf8> sessionId);

typedef _WalletInitC = Int32 Function();
typedef _WalletInitDart = int Function();

typedef _WalletVerifyPubkeyAddressC = Int32 Function(
  Pointer<Utf8> compressedPubkeyHex,
  Pointer<Utf8> expectedAddress,
);
typedef _WalletVerifyPubkeyAddressDart = int Function(
  Pointer<Utf8> compressedPubkeyHex,
  Pointer<Utf8> expectedAddress,
);

typedef _WalletDecodeMultiAccountsUrC = Pointer<Utf8> Function(
  Pointer<Utf8> urOrFrames,
  Uint64 defaultChainId,
);
typedef _WalletDecodeMultiAccountsUrDart = Pointer<Utf8> Function(
  Pointer<Utf8> urOrFrames,
  int defaultChainId,
);

typedef _WalletBuildEthSignRequestUrC = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestIdHex,
  Pointer<Utf8> rawTxHex,
  Uint64 chainId,
  Pointer<Utf8> derivationPath,
  Pointer<Utf8> masterFingerprintHex,
  Pointer<Utf8> expectedAddress,
  Uint32 maxFragmentLen,
);
typedef _WalletBuildEthSignRequestUrDart = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestIdHex,
  Pointer<Utf8> rawTxHex,
  int chainId,
  Pointer<Utf8> derivationPath,
  Pointer<Utf8> masterFingerprintHex,
  Pointer<Utf8> expectedAddress,
  int maxFragmentLen,
);

typedef _WalletVerifyAndAssembleEthSigUrC = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> expectedRequestIdHex,
  Pointer<Utf8> urOrFrames,
);
typedef _WalletVerifyAndAssembleEthSigUrDart = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> expectedRequestIdHex,
  Pointer<Utf8> urOrFrames,
);

typedef _WalletEncodePsbtUrC = Pointer<Utf8> Function(
  Pointer<Utf8> psbtHex,
  Uint32 maxFragmentLen,
);
typedef _WalletEncodePsbtUrDart = Pointer<Utf8> Function(
  Pointer<Utf8> psbtHex,
  int maxFragmentLen,
);

typedef _WalletFinalizePsbtJsonC = Pointer<Utf8> Function(
  Pointer<Utf8> psbtUrOrHex,
);
typedef _WalletFinalizePsbtJsonDart = Pointer<Utf8> Function(
  Pointer<Utf8> psbtUrOrHex,
);

typedef _WalletVerifySigC = Int32 Function(
  Pointer<Utf8> digestHex,
  Pointer<Utf8> sigRHex,
  Pointer<Utf8> sigSHex,
  Uint8 sigV,
  Pointer<Utf8> expectedAddress,
);
typedef _WalletVerifySigDart = int Function(
  Pointer<Utf8> digestHex,
  Pointer<Utf8> sigRHex,
  Pointer<Utf8> sigSHex,
  int sigV,
  Pointer<Utf8> expectedAddress,
);

typedef _WalletDecodeIntentC = Pointer<Utf8> Function(
  Pointer<Utf8> rawRlpHex,
  Uint64 declaredChainId,
);
typedef _WalletDecodeIntentDart = Pointer<Utf8> Function(
  Pointer<Utf8> rawRlpHex,
  int declaredChainId,
);

typedef _WalletFreeStringC = Void Function(Pointer<Utf8> s);
typedef _WalletFreeStringDart = void Function(Pointer<Utf8> s);

/// FFI Bridge for watch-only wallet.
/// Strictly uses wallet_ffi: zero private key APIs, zero signing logic.
class WalletFfiService {
  late final DynamicLibrary _lib;
  late final _WalletInitDart _init;
  late final _WalletCancelDart _cancel;
  late final _WalletVerifyPubkeyAddressDart _verifyPubkeyAddress;
  late final _WalletDecodeMultiAccountsUrDart _decodeMultiAccountsUr;
  late final _WalletBuildEthSignRequestUrDart _buildEthSignRequestUr;
  late final _WalletVerifyAndAssembleEthSigUrDart _verifyAndAssembleEthSigUr;
  late final _WalletEncodePsbtUrDart _encodePsbtUr;
  late final _WalletFinalizePsbtJsonDart _finalizePsbtJson;
  late final _WalletVerifySigDart _verifySig;
  late final _WalletDecodeIntentDart _decodeIntent;
  late final _WalletFreeStringDart _freeString;

  WalletFfiService([DynamicLibrary? lib]) {
    _lib = lib ?? NativeLibraryLoader.loadWalletLib();
    _init = _lib
        .lookup<NativeFunction<_WalletInitC>>('wallet_init')
        .asFunction<_WalletInitDart>();
    _cancel = _lib.lookupFunction<_WalletCancelC, _WalletCancelDart>(
        'wallet_cancel_pending_session');
    _verifyPubkeyAddress = _lib
        .lookup<NativeFunction<_WalletVerifyPubkeyAddressC>>(
          'wallet_verify_pubkey_address',
        )
        .asFunction<_WalletVerifyPubkeyAddressDart>();
    _decodeMultiAccountsUr = _lib
        .lookup<NativeFunction<_WalletDecodeMultiAccountsUrC>>(
          'wallet_decode_and_verify_multi_accounts_ur',
        )
        .asFunction<_WalletDecodeMultiAccountsUrDart>();
    _buildEthSignRequestUr = _lib
        .lookup<NativeFunction<_WalletBuildEthSignRequestUrC>>(
          'wallet_build_eth_sign_request_ur',
        )
        .asFunction<_WalletBuildEthSignRequestUrDart>();
    _verifyAndAssembleEthSigUr = _lib
        .lookup<NativeFunction<_WalletVerifyAndAssembleEthSigUrC>>(
          'wallet_verify_and_assemble_eth_signature_ur',
        )
        .asFunction<_WalletVerifyAndAssembleEthSigUrDart>();
    _encodePsbtUr = _lib
        .lookup<NativeFunction<_WalletEncodePsbtUrC>>('wallet_encode_psbt_ur')
        .asFunction<_WalletEncodePsbtUrDart>();
    _finalizePsbtJson = _lib
        .lookup<NativeFunction<_WalletFinalizePsbtJsonC>>(
          'wallet_finalize_and_extract_psbt',
        )
        .asFunction<_WalletFinalizePsbtJsonDart>();
    _verifySig = _lib
        .lookup<NativeFunction<_WalletVerifySigC>>('wallet_verify_signature')
        .asFunction<_WalletVerifySigDart>();
    _decodeIntent = _lib
        .lookup<NativeFunction<_WalletDecodeIntentC>>(
          'wallet_decode_intent_json',
        )
        .asFunction<_WalletDecodeIntentDart>();
    _freeString = _lib
        .lookup<NativeFunction<_WalletFreeStringC>>('wallet_free_string')
        .asFunction<_WalletFreeStringDart>();
  }

  Map<String, dynamic> _readAndFreeJson(Pointer<Utf8> ptr, String fallbackErr) {
    if (ptr == nullptr) {
      return {'status': 'ERROR', 'error': fallbackErr};
    }
    try {
      final str = ptr.toDartString();
      return jsonDecode(str) as Map<String, dynamic>;
    } finally {
      _freeString(ptr);
    }
  }

  int init() => _init();

  void cancelPendingSession(String sessionId) {
    final ptr = sessionId.toNativeUtf8();
    try {
      if (_cancel(ptr) != 0) throw StateError('無法撤銷待簽請求');
    } finally {
      calloc.free(ptr);
    }
  }

  /// Verifies that a 33-byte compressed secp256k1 public key derives [expectedAddress].
  bool verifyPubkeyAddress({
    required String compressedPubkeyHex,
    required String expectedAddress,
  }) {
    final pkPtr = compressedPubkeyHex.toNativeUtf8();
    final addrPtr = expectedAddress.toNativeUtf8();
    try {
      return _verifyPubkeyAddress(pkPtr, addrPtr) == 1;
    } finally {
      calloc.free(pkPtr);
      calloc.free(addrPtr);
    }
  }

  /// Decodes a `ur:crypto-multi-accounts/...` (single UR or JSON array of fountain frames),
  /// cryptographically verifies each public key and fingerprint, and returns derived EVM & BTC accounts.
  Map<String, dynamic> decodeAndVerifyMultiAccountsUr(
    String urOrFrames, {
    int defaultChainId = 11155111,
  }) {
    final uPtr = urOrFrames.toNativeUtf8();
    try {
      final resPtr = _decodeMultiAccountsUr(uPtr, defaultChainId);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from wallet_decode_and_verify_multi_accounts_ur',
      );
    } finally {
      calloc.free(uPtr);
    }
  }

  /// Validates an unsigned Legacy or EIP-1559 transaction against watch-only policy,
  /// registers it as a pending transaction bound to [sessionId] & [requestIdHex],
  /// and encodes it into CBOR Tag 401 `ur:eth-sign-request/...` single UR and fountain frames.
  /// Zero [maxFragmentLen] lets the core choose a bounded displayable session.
  Map<String, dynamic> buildEthSignRequestUr({
    required String sessionId,
    required String requestIdHex,
    required String rawTxHex,
    required int chainId,
    required String derivationPath,
    required String masterFingerprintHex,
    required String expectedAddress,
    int maxFragmentLen = 0,
  }) {
    final sPtr = sessionId.toNativeUtf8();
    final rPtr = requestIdHex.toNativeUtf8();
    final txPtr = rawTxHex.toNativeUtf8();
    final pathPtr = derivationPath.toNativeUtf8();
    final fpPtr = masterFingerprintHex.toNativeUtf8();
    final addrPtr = expectedAddress.toNativeUtf8();
    try {
      final resPtr = _buildEthSignRequestUr(
        sPtr,
        rPtr,
        txPtr,
        chainId,
        pathPtr,
        fpPtr,
        addrPtr,
        maxFragmentLen,
      );
      return _readAndFreeJson(
        resPtr,
        'Null pointer from wallet_build_eth_sign_request_ur',
      );
    } finally {
      calloc.free(sPtr);
      calloc.free(rPtr);
      calloc.free(txPtr);
      calloc.free(pathPtr);
      calloc.free(fpPtr);
      calloc.free(addrPtr);
    }
  }

  /// Decodes CBOR Tag 402 `ur:eth-signature/...`, verifies `request_id` and ECDSA recovery against
  /// the registered pending transaction, and assembles the canonical signed raw transaction RLP.
  Map<String, dynamic> verifyAndAssembleEthSignatureUr({
    required String sessionId,
    required String expectedRequestIdHex,
    required String urOrFrames,
  }) {
    final sPtr = sessionId.toNativeUtf8();
    final rPtr = expectedRequestIdHex.toNativeUtf8();
    final uPtr = urOrFrames.toNativeUtf8();
    try {
      final resPtr = _verifyAndAssembleEthSigUr(sPtr, rPtr, uPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from wallet_verify_and_assemble_eth_signature_ur',
      );
    } finally {
      calloc.free(sPtr);
      calloc.free(rPtr);
      calloc.free(uPtr);
    }
  }

  /// Encodes an unsigned Bitcoin PSBT hex into CBOR Tag 310 `ur:crypto-psbt/...` single UR and fountain frames.
  /// Zero [maxFragmentLen] lets the core choose a bounded displayable session.
  Map<String, dynamic> encodePsbtUr(
    String psbtHex, {
    int maxFragmentLen = 0,
  }) {
    final pPtr = psbtHex.toNativeUtf8();
    try {
      final resPtr = _encodePsbtUr(pPtr, maxFragmentLen);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from wallet_encode_psbt_ur',
      );
    } finally {
      calloc.free(pPtr);
    }
  }

  /// Finalizes a signed Bitcoin PSBT (`ur:crypto-psbt/...` or hex) and extracts raw broadcastable tx hex & txid.
  Map<String, dynamic> finalizePsbt(String psbtUrOrHex) {
    final pPtr = psbtUrOrHex.toNativeUtf8();
    try {
      final resPtr = _finalizePsbtJson(pPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from wallet_finalize_psbt_json',
      );
    } finally {
      calloc.free(pPtr);
    }
  }

  /// Verifies that a 65-byte ECDSA signature over digestHex recovers expectedAddress.
  /// Returns true only if recovered address matches expectedAddress byte-for-byte.
  bool verifySignature({
    required String digestHex,
    required String rHex,
    required String sHex,
    required int v,
    required String expectedAddress,
  }) {
    final dPtr = digestHex.toNativeUtf8();
    final rPtr = rHex.toNativeUtf8();
    final sPtr = sHex.toNativeUtf8();
    final ePtr = expectedAddress.toNativeUtf8();
    try {
      final res = _verifySig(dPtr, rPtr, sPtr, v, ePtr);
      return res == 1;
    } finally {
      calloc.free(dPtr);
      calloc.free(rPtr);
      calloc.free(sPtr);
      calloc.free(ePtr);
    }
  }

  /// Decodes unsigned RLP transaction and returns verified structured intent.
  Map<String, dynamic>? decodeIntentJson({
    required String rawRlpHex,
    required int declaredChainId,
  }) {
    final rlpPtr = rawRlpHex.toNativeUtf8();
    try {
      final resPtr = _decodeIntent(rlpPtr, declaredChainId);
      if (resPtr == nullptr) return null;
      try {
        final str = resPtr.toDartString();
        return jsonDecode(str) as Map<String, dynamic>;
      } finally {
        _freeString(resPtr);
      }
    } finally {
      calloc.free(rlpPtr);
    }
  }
}
