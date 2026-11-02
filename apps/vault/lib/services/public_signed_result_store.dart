import 'dart:convert';
import 'dart:io';

import 'package:public_models/public_models.dart';

/// Public identity only. The key is the actual EVM account-0 public key, not
/// the short fingerprint alone. No method in this file unlocks or signs.
class PublicVaultIdentity {
  final String fingerprint;
  final String compressedPublicKey;
  const PublicVaultIdentity(this.fingerprint, this.compressedPublicKey);

  String get key => '$fingerprint:$compressedPublicKey';

  factory PublicVaultIdentity.fromAccounts(
      String fingerprint, Map<String, dynamic> accounts) {
    final evm = accounts['evm_accounts'];
    if (evm is! List || evm.isEmpty || evm.first is! Map) {
      throw const FormatException('缺少金庫公開身分');
    }
    final account = evm.first as Map;
    if (account['account_index'] != 0 ||
        account['derivation_path'] != "m/44'/60'/0'/0/0") {
      throw const FormatException('無法核對金庫公開帳戶');
    }
    return PublicVaultIdentity.fromJson({
      'fingerprint': fingerprint,
      'compressed_public_key': account['compressed_pubkey_hex'],
    });
  }

  factory PublicVaultIdentity.fromJson(Map<String, dynamic> json) {
    final fp = json['fingerprint'];
    final pk = json['compressed_public_key'];
    if (fp is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(fp) ||
        pk is! String ||
        !RegExp(r'^0[23][0-9a-fA-F]{64}$').hasMatch(pk)) {
      throw const FormatException('金庫公開身分格式無效');
    }
    return PublicVaultIdentity(fp.toLowerCase(), pk.toLowerCase());
  }

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'compressed_public_key': compressedPublicKey,
      };
}

enum PublicResultLookupKind { newRequest, available, unavailable, blocked }

class PublicResultLookup {
  final PublicResultLookupKind kind;
  final SignatureResultDto? result;
  final String? error;
  const PublicResultLookup(this.kind, {this.result, this.error});
}

class PublicSignedResultMetadata {
  final String requestId;
  final String signingDigest;
  final int chainId;
  const PublicSignedResultMetadata(
      this.requestId, this.signingDigest, this.chainId);
}

class _PublicResultMarker {
  final PublicVaultIdentity identity;
  final Map<String, dynamic> binding;
  SignatureResultDto? result;
  bool wasSigned;
  _PublicResultMarker(this.identity, this.binding,
      [this.result, this.wasSigned = false]);
}

/// Bounded, atomic, public-only response retention in Vault's private no-backup
/// directory. Response bodies may expire; known signing markers never do.
/// A reservation is persisted BEFORE signing, so interrupted result writes
/// cannot turn an uncertain prior signing attempt into a new approval.
class PublicSignedResultStore {
  static const maxMarkers = 128;
  static const maxResults = 20;
  static const maxBytes = 2 * 1024 * 1024;
  final String path;
  PublicVaultIdentity? activeIdentity;
  final List<_PublicResultMarker> _markers = [];
  String? error;

  PublicSignedResultStore(this.path);

  void load() {
    _markers.clear();
    activeIdentity = null;
    error = null;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      if (file.lengthSync() > maxBytes) {
        throw const FormatException('公開結果檔案超過上限');
      }
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, dynamic> || json['schema_version'] != 1) {
        throw const FormatException('公開結果版本無效');
      }
      final identity = json['active_identity'];
      if (identity != null) {
        if (identity is! Map<String, dynamic>) {
          throw const FormatException('公開身分格式無效');
        }
        activeIdentity = PublicVaultIdentity.fromJson(identity);
      }
      final entries = json['markers'];
      if (entries is! List || entries.length > maxMarkers) {
        throw const FormatException('簽署紀錄列表無效');
      }
      for (final entry in entries) {
        if (entry is! Map<String, dynamic> ||
            entry['identity'] is! Map<String, dynamic> ||
            entry['binding'] is! Map<String, dynamic>) {
          throw const FormatException('簽署紀錄格式無效');
        }
        final markerIdentity = PublicVaultIdentity.fromJson(entry['identity']);
        final binding = _validateBinding(entry['binding']);
        if (entry['outcome'] != 'signing_started' &&
            entry['outcome'] != 'signed') {
          throw const FormatException('簽署結果狀態無效');
        }
        if (_find(markerIdentity, binding) != null) {
          throw const FormatException('重複簽署紀錄');
        }
        SignatureResultDto? result;
        if (entry['result'] != null) {
          if (entry['outcome'] != 'signed') {
            throw const FormatException('未完成簽署不得包含成功結果');
          }
          if (entry['result'] is! Map<String, dynamic>) {
            throw const FormatException('公開簽章結果格式無效');
          }
          result = _decodePublicResult(entry['result'], binding);
        }
        _markers.add(_PublicResultMarker(
            markerIdentity, binding, result, entry['outcome'] == 'signed'));
      }
      if (_markers.where((marker) => marker.result != null).length >
          maxResults) {
        throw const FormatException('公開結果數量超過上限');
      }
    } catch (_) {
      _markers.clear();
      activeIdentity = null;
      error = '已簽結果儲存損毀或無法讀取，無法判定先前簽署狀態；禁止重新簽署。';
    }
  }

  String? activate(PublicVaultIdentity identity) {
    if (error != null) return error;
    if (activeIdentity?.key == identity.key) return null;
    activeIdentity = identity;
    return _persist();
  }

  List<SignatureResultDto> resultsFor(PublicVaultIdentity identity) => [
        for (final marker in _markers.reversed)
          if (marker.identity.key == identity.key && marker.result != null)
            marker.result!,
      ];

  bool hasUnavailableFor(PublicVaultIdentity identity) => _markers.any(
      (marker) => marker.identity.key == identity.key && marker.result == null);

  PublicSignedResultMetadata? metadataFor(SignatureResultDto result) {
    for (final marker in _markers) {
      if (identical(marker.result, result)) {
        return PublicSignedResultMetadata(marker.binding['request_id'],
            marker.binding['signing_digest'], marker.binding['chain_id']);
      }
    }
    return null;
  }

  PublicResultLookup lookup(
      PublicVaultIdentity identity, PreparedReviewDto review) {
    try {
      final marker = _find(identity, _binding(review));
      if (marker != null) {
        return marker.result == null
            ? PublicResultLookup(PublicResultLookupKind.unavailable,
                error: marker.wasSigned
                    ? '已簽結果無法取回，請查原交易；本機不會重新簽署。'
                    : '簽署結果待查，請查原交易；本機不會重新簽署。')
            : PublicResultLookup(PublicResultLookupKind.available,
                result: marker.result);
      }
      if (error != null) {
        return PublicResultLookup(PublicResultLookupKind.blocked, error: error);
      }
      if (_markers.length >= maxMarkers) {
        return const PublicResultLookup(PublicResultLookupKind.blocked,
            error: '已達簽署紀錄上限，禁止新增批准；既有簽署紀錄不會自動刪除。');
      }
      return const PublicResultLookup(PublicResultLookupKind.newRequest);
    } on FormatException {
      return const PublicResultLookup(PublicResultLookupKind.blocked,
          error: '請求缺少可核對的身分、摘要或批准綁定，禁止簽署。');
    }
  }

  String? reserve(PublicVaultIdentity identity, PreparedReviewDto review) {
    final existing = lookup(identity, review);
    if (existing.kind != PublicResultLookupKind.newRequest) {
      return existing.error ?? '此請求已簽署，請重顯示既有結果。';
    }
    if (activeIdentity?.key != identity.key) return '金庫公開身分已改變，禁止簽署。';
    _markers.add(_PublicResultMarker(identity, _binding(review)));
    return _persist();
  }

  String? complete(PublicVaultIdentity identity, PreparedReviewDto review,
      SignatureResultDto result) {
    try {
      final binding = _binding(review);
      final marker = _find(identity, binding);
      if (marker == null) return '缺少先前簽署紀錄；結果僅保留在本頁，請立即回傳。';
      // Clone only typed public fields. Native handle/session never match replay.
      marker.result = _decodePublicResult(_publicResultJson(result), binding);
      marker.wasSigned = true;
      return _persist();
    } catch (_) {
      return '簽章已產生，但公開結果無法保存；請保留本頁並查原交易，禁止重新簽署。';
    }
  }

  _PublicResultMarker? _find(
      PublicVaultIdentity identity, Map<String, dynamic> binding) {
    final encoded = jsonEncode(binding);
    for (final marker in _markers) {
      if (marker.identity.key == identity.key &&
          jsonEncode(marker.binding) == encoded) {
        return marker;
      }
    }
    return null;
  }

  String? _persist() {
    try {
      final retained =
          _markers.where((marker) => marker.result != null).toList();
      while (retained.length > maxResults) {
        retained.removeAt(0).result = null;
      }
      String encode() => jsonEncode({
            'schema_version': 1,
            'active_identity': activeIdentity?.toJson(),
            'markers': [
              for (final marker in _markers)
                {
                  'identity': marker.identity.toJson(),
                  'binding': marker.binding,
                  'outcome': marker.wasSigned ? 'signed' : 'signing_started',
                  if (marker.result != null)
                    'result': _publicResultJson(marker.result!),
                }
            ],
          });
      var encoded = encode();
      while (utf8.encode(encoded).length > maxBytes && retained.length > 1) {
        retained.removeAt(0).result = null;
        encoded = encode();
      }
      if (utf8.encode(encoded).length > maxBytes) {
        throw const FileSystemException('Public result capacity exceeded');
      }
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temporary = File('$path.tmp');
      temporary.writeAsStringSync(encoded, flush: true);
      temporary.renameSync(path);
      return null;
    } catch (_) {
      error = '公開簽署紀錄寫入失敗；目前結果可重顯示，但重啟後可能無法取回，禁止新增批准。';
      return error;
    }
  }
}

Map<String, dynamic> _binding(PreparedReviewDto review) {
  if (!review.isSignable) throw const FormatException('Review not approved');
  return _validateBinding({
    'request_id': review.requestId,
    'chain_id': review.chainId,
    'derivation_path': review.derivationPath,
    'signing_digest': review.signingDigestHex,
    'policy_approved': true,
    'is_bitcoin_psbt': review.isBitcoinPsbt,
    'network': review.btcNetwork,
    'signer_address': review.signerAddress,
    'token_contract': review.tokenContract,
    'recipient': review.recipient,
    'raw_amount': review.rawAmount,
    'fee_cap': review.feeCapWei,
  });
}

Map<String, dynamic> _validateBinding(Map<String, dynamic> json) {
  const fields = [
    'request_id',
    'chain_id',
    'derivation_path',
    'signing_digest',
    'policy_approved',
    'is_bitcoin_psbt',
    'network',
    'signer_address',
    'token_contract',
    'recipient',
    'raw_amount',
    'fee_cap',
  ];
  final binding = <String, dynamic>{};
  for (final field in fields) {
    if (!json.containsKey(field)) {
      throw const FormatException('Incomplete binding');
    }
    final value = json[field];
    if (value is String && value.length > 512) {
      throw const FormatException('Oversized binding');
    }
    if (value != null && value is! String && value is! int && value is! bool) {
      throw const FormatException('Invalid binding');
    }
    binding[field] = value;
  }
  if (binding['policy_approved'] != true ||
      binding['is_bitcoin_psbt'] is! bool ||
      binding['chain_id'] is! int ||
      binding['request_id'] is! String ||
      (binding['request_id'] as String).isEmpty ||
      binding['derivation_path'] is! String ||
      !(binding['derivation_path'] as String).startsWith('m/') ||
      binding['signing_digest'] is! String ||
      !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(binding['signing_digest'])) {
    throw const FormatException('Missing immutable signing binding');
  }
  return Map.unmodifiable(binding);
}

Map<String, dynamic> _publicResultJson(SignatureResultDto result) => {
      'status': result.status,
      'address': result.address,
      'signature': result.signatureHex,
      if (result.requestId != null) 'request_id': result.requestId,
      if (result.derivationPath != null)
        'derivation_path': result.derivationPath,
      if (result.digestHex != null) 'digest': result.digestHex,
      if (result.signatureUr != null) 'signature_ur': result.signatureUr,
      if (result.signatureUrFrames.isNotEmpty)
        'signature_ur_frames': result.signatureUrFrames,
      if (result.signedPsbtHex != null) 'signed_psbt_hex': result.signedPsbtHex,
      if (result.signedPsbtUr != null) 'signed_psbt_ur': result.signedPsbtUr,
      if (result.signedPsbtUrFrames.isNotEmpty)
        'signed_psbt_ur_frames': result.signedPsbtUrFrames,
    };

SignatureResultDto _decodePublicResult(
    Map<String, dynamic> json, Map<String, dynamic> binding) {
  if (json['status'] is! String ||
      json['address'] is! String ||
      json['signature'] is! String) {
    throw const FormatException('Incomplete public result');
  }
  const scalarFields = {
    'status',
    'address',
    'signature',
    'request_id',
    'derivation_path',
    'digest',
    'signature_ur',
    'signed_psbt_hex',
    'signed_psbt_ur',
  };
  const frameFields = {'signature_ur_frames', 'signed_psbt_ur_frames'};
  for (final entry in json.entries) {
    if (scalarFields.contains(entry.key)) {
      if (entry.value is! String) {
        throw const FormatException('Invalid public result');
      }
    } else if (frameFields.contains(entry.key)) {
      final frames = entry.value;
      if (frames is! List ||
          frames.length > 2048 ||
          frames.any((frame) => frame is! String || frame.length > 4096)) {
        throw const FormatException('Invalid public QR frames');
      }
    } else {
      throw const FormatException('Unknown public result field');
    }
  }
  final result = SignatureResultDto.fromJson({...json, 'handle_id': ''});
  final isBtc = binding['is_bitcoin_psbt'] == true;
  final prefix = isBtc ? 'ur:crypto-psbt/' : 'ur:eth-signature/';
  if (!result.isSuccess ||
      result.isPsbt != isBtc ||
      result.qrFrames.isEmpty ||
      result.qrFrames.any((frame) => !frame.toLowerCase().startsWith(prefix)) ||
      (!isBtc &&
          !RegExp(r'^(0x)?[a-fA-F0-9]{130}$').hasMatch(result.signatureHex)) ||
      (result.requestId != null && result.requestId != binding['request_id']) ||
      (result.digestHex != null &&
          result.digestHex != binding['signing_digest']) ||
      (result.derivationPath != null &&
          result.derivationPath != binding['derivation_path']) ||
      (!isBtc &&
          binding['signer_address'] != null &&
          result.address.toLowerCase() !=
              (binding['signer_address'] as String).toLowerCase())) {
    throw const FormatException(
        'Public result does not match approved request');
  }
  return SignatureResultDto(
    status: result.status,
    handleId: '',
    address: result.address,
    requestId: result.requestId,
    derivationPath: result.derivationPath,
    digestHex: result.digestHex,
    signatureHex: result.signatureHex,
    signatureUr: result.signatureUr,
    signatureUrFrames: List.unmodifiable(result.signatureUrFrames),
    signedPsbtHex: result.signedPsbtHex,
    signedPsbtUr: result.signedPsbtUr,
    signedPsbtUrFrames: List.unmodifiable(result.signedPsbtUrFrames),
  );
}
