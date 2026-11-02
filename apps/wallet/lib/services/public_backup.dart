import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import '../ffi/bitcoin_ffi_service.dart';
import '../ffi/wallet_ffi_service.dart';
import 'account_store.dart';
import 'transaction_history.dart';

class PublicBackupBundle {
  final int chainId;
  final List<AccountDescriptor> accounts;
  final List<Map<String, dynamic>> transactions;
  final List<Map<String, dynamic>> bitcoinRecords;
  PublicBackupBundle(
      {required this.chainId,
      required this.accounts,
      required this.transactions,
      required this.bitcoinRecords,
  });
}

/// Allowlisted public data only. Secret-bearing Vault backups are never accepted.
class PublicBackupCodec {
  static const maxBytes = 2 * 1024 * 1024;
  // Multipart UR JSON expands beyond the raw 128 KiB CBOR payload. The whole
  // backup remains bounded by maxBytes, independently of this field contract.
  static const maxUrCharacters = 2097152 + 16384;
  static const _accountKeys = {
    'master_fingerprint',
    'derivation_path',
    'address',
    'chain_id',
    'label',
    'asset_family',
    'extended_public_key',
    'compressed_pubkey_hex',
    'chain_code_hex',
    'receive_address_regtest',
    'receive_address_mainnet',
    'change_address',
    'descriptor',
  };
  static const _transactionKeys = {
    'requestId',
    'sessionId',
    'account',
    'chainId',
    'unsignedPayload',
    'signatureUr',
    'signedRaw',
    'hash',
    'state',
    'updatedAt',
    'derivationPath',
    'masterFingerprint',
    'compressedPublicKeyHex',
  };
  static const _bitcoinKeys = {
    'account_address',
    'master_fingerprint',
    'state',
    'request',
    'built',
    'response_ur',
    'confirmations',
    'checked_at',
    'history',
  };
  static const _requestKeys = {
    'account_xpub',
    'master_fingerprint',
    'recipient_address',
    'amount_sat',
    'fee_sat',
    'change_index',
    'utxos',
  };
  static const _builtKeys = {
    'status',
    'network',
    'psbt_hex',
    'expected_digest',
    'ur_frames',
    'txid',
    'unsigned_tx_hex',
    'recipient_address',
    'change_address',
    'amount_sat',
    'change_sat',
    'fee_sat',
  };
  static void _only(Map<String, dynamic> value, Set<String> keys) {
    if (value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('公開備份含不允許的欄位；不可匯入私鑰、助記詞或 Vault 備份');
    }
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) throw const FormatException('公開備份資料型別錯誤');
    return Map<String, dynamic>.from(value);
  }

  static List<dynamic> _list(dynamic value, int limit) {
    if (value is! List || value.length > limit) {
      throw const FormatException('公開備份清單缺漏或超過數量限制');
    }
    return value;
  }

  static String _string(dynamic value, {int limit = 262144}) {
    if (value is! String || value.length > limit) {
      throw const FormatException('公開備份文字欄位缺漏或過長');
    }
    return value;
  }

  static void _hex(dynamic value, {int? bytes, bool prefix = false}) {
    final text = _string(value);
    final clean = prefix && text.startsWith('0x') ? text.substring(2) : text;
    if (clean.isEmpty ||
        clean.length.isOdd ||
        !RegExp(r'^[a-fA-F0-9]+$').hasMatch(clean) ||
        (bytes != null && clean.length != bytes * 2)) {
      throw const FormatException('公開備份十六進位欄位錯誤');
    }
  }

  static void validateStoredTransaction(Map<String, dynamic> stored) {
    transaction({
      for (final key in _transactionKeys)
        if (stored.containsKey(key)) key: stored[key],
    });
  }

  static Map<String, dynamic> transaction(dynamic value) {
    final row = _map(value);
    _only(row, _transactionKeys);
    _hex(row['requestId'], bytes: 16);
    _string(row['sessionId'], limit: 128);
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$',
        )
            .hasMatch(_string(row['account'], limit: 42)) ||
        !AccountStore.supportedChains.contains(row['chainId'])) {
      throw const FormatException('交易紀錄不是受支援的測試鏈帳戶');
    }
    _hex(row['unsignedPayload']);
    _string(row['state'], limit: 40);
    final hasPath = row.containsKey('derivationPath');
    final hasFingerprint = row.containsKey('masterFingerprint');
    if (hasPath != hasFingerprint) {
      throw const FormatException('交易派生路徑與主指紋必須一起保存');
    }
    if (hasPath) {
      if (!RegExp(r"^m/44'/60'/[0-9]+'/[01]/[0-9]+$",
      )
          .hasMatch(_string(row['derivationPath'], limit: 100))) {
        throw const FormatException('交易派生路徑錯誤');
      }
      _hex(row['masterFingerprint'], bytes: 4);
    }
    if (row.containsKey('compressedPublicKeyHex') &&
        row['compressedPublicKeyHex'] != null) {
      _hex(row['compressedPublicKeyHex'], bytes: 33);
    }
    if (row['updatedAt'] != null &&
        DateTime.tryParse(_string(row['updatedAt'], limit: 40)) == null) {
      throw const FormatException('交易時間格式錯誤');
    }
    if ((row['state'] == 'confirmed' || row['state'] == 'executionFailed') &&
        row['signatureUr'] == null) {
      throw const FormatException('已確認交易缺少簽章資料');
    }
    if (row['signatureUr'] != null) {
      _string(row['signatureUr'], limit: maxUrCharacters);
      _hex(row['signedRaw'], prefix: true);
      _hex(row['hash'], bytes: 32, prefix: true);
    } else if (row['signedRaw'] != null || row['hash'] != null) {
      throw const FormatException('交易缺少原始簽章回傳');
    }
    return row;
  }

  static Map<String, dynamic> bitcoin(dynamic value) {
    final row = _map(value);
    _only(row, _bitcoinKeys);
    _string(row['account_address'], limit: 100);
    _hex(row['master_fingerprint'], bytes: 4);
    _string(row['state'], limit: 40);
    _statusDetails(row);
    if (row['request'] != null) {
      final request = _map(row['request']);
      _only(request, _requestKeys);
      if (!RegExp(r'^tpub[1-9A-HJ-NP-Za-km-z]+$',
      )
          .hasMatch(_string(request['account_xpub'], limit: 120))) {
        throw const FormatException('Bitcoin 請求只允許公開 tpub');
      }
      _hex(request['master_fingerprint'], bytes: 4);
      _string(request['recipient_address'], limit: 100);
      _string(request['amount_sat'], limit: 16);
      _string(request['fee_sat'], limit: 16);
      if (request['change_index'] is! int) {
        throw const FormatException('Bitcoin 找零索引錯誤');
      }
      for (final u in _list(request['utxos'], 64)) {
        final utxo = _map(u);
        _only(utxo,
            {'txid', 'vout', 'previous_tx_hex', 'branch', 'address_index',
        });
        _hex(utxo['txid'], bytes: 32);
        _hex(utxo['previous_tx_hex']);
        if (utxo['vout'] is! int ||
            utxo['branch'] is! int ||
            utxo['address_index'] is! int) {
          throw const FormatException('Bitcoin UTXO 派生資料錯誤');
        }
      }
      final built = _map(row['built']);
      _only(built, _builtKeys);
      for (final key in ['psbt_hex', 'unsigned_tx_hex']) {
        _hex(built[key]);
      }
      _hex(built['expected_digest'], bytes: 32);
      _hex(built['txid'], bytes: 32);
      _string(built['status'], limit: 20);
      if (built['network'] != 'regtest') {
        throw const FormatException('Bitcoin 備份僅支援 regtest');
      }
      for (final key in [
        'recipient_address',
        'change_address',
        'amount_sat',
        'change_sat',
        'fee_sat',
      ]) {
        _string(built[key]);
      }
      for (final frame in _list(built['ur_frames'], 4096)) {
        _string(frame, limit: 10000);
      }
      if (row['response_ur'] != null) {
        _string(row['response_ur'], limit: maxUrCharacters);
      }
    } else if (row['built'] != null || row['response_ur'] != null) {
      throw const FormatException('Bitcoin 待簽紀錄不完整');
    }
    for (final item in _list(row['history'], 1000)) {
      final record = _map(item);
      _only(record, {
        'txid',
        'state',
        'amount_sat',
        'recipient_address',
        'recovery',
        'confirmations',
        'checked_at',
      });
      _hex(record['txid'], bytes: 32);
      _string(record['state'], limit: 40);
      _string(record['amount_sat'], limit: 16);
      _string(record['recipient_address'], limit: 100);
      _statusDetails(record);
      if (record['recovery'] != null) {
        final recovery = _map(record['recovery']);
        _only(recovery, {'request', 'built', 'response_ur'});
        if (recovery['request'] == null) {
          throw const FormatException('Bitcoin 封存恢復資料缺少公開請求');
        }
        // Validate the same allowlist as an active bundle, with no nested history.
        bitcoin({
          'account_address': row['account_address'],
          'master_fingerprint': row['master_fingerprint'],
          'state': record['state'],
          ...recovery,
          'history': <dynamic>[],
        });
        final built = _map(recovery['built']);
        if (record['txid'] != built['txid'] ||
            record['amount_sat'] != built['amount_sat'] ||
            record['recipient_address'] != built['recipient_address']) {
          throw const FormatException('Bitcoin 封存摘要與公開請求不符');
        }
      }
    }
    return row;
  }

  static void _statusDetails(Map<String, dynamic> row) {
    if (row['confirmations'] != null && row['confirmations'] is! int) {
      throw const FormatException('Bitcoin 確認數格式錯誤');
    }
    if (row['checked_at'] != null &&
        DateTime.tryParse(_string(row['checked_at'], limit: 40)) == null) {
      throw const FormatException('Bitcoin 查詢時間格式錯誤');
    }
  }

  static PublicBackupBundle decode(String source) {
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('公開備份超過 2 MiB 限制');
    }
    try {
      final raw = _map(jsonDecode(source));
      _only(raw, {
        'schema',
        'version',
        'created_at',
        'chain_id',
        'accounts',
        'transactions',
        'bitcoin_records',
      });
      if (raw['schema'] != 'fcw-public-wallet-backup' ||
          ![1, 2].contains(raw['version']) ||
          !AccountStore.supportedChains.contains(raw['chain_id']) ||
          DateTime.tryParse(_string(raw['created_at'], limit: 40)) == null) {
        throw const FormatException('公開備份版本、網路或時間格式不受支援');
      }
      final accounts = _list(raw['accounts'], 100).map((value) {
        final row = _map(value);
        _only(row, _accountKeys);
        _hex(row['master_fingerprint'], bytes: 4);
        _string(row['derivation_path'], limit: 120);
        _string(row['address'], limit: 100);
        _string(row['label'], limit: 100);
        if (row['asset_family'] != 'EVM' && row['asset_family'] != 'BTC') {
          throw const FormatException('不支援的公開帳戶類型');
        }
        if (row['asset_family'] == 'EVM' &&
            !AccountStore.supportedChains.contains(row['chain_id'])) {
          throw const FormatException('不支援的 EVM 網路');
        }
        if (row['asset_family'] == 'BTC' && row['chain_id'] != 0) {
          throw const FormatException('Bitcoin 帳戶網路標示錯誤');
        }
        if (row['compressed_pubkey_hex'] != null) {
          _hex(row['compressed_pubkey_hex'], bytes: 33);
        }
        if (row['chain_code_hex'] != null) {
          _hex(row['chain_code_hex'], bytes: 32);
        }
        if (row['extended_public_key'] != null &&
            !RegExp(r'^(tpub|xpub)[1-9A-HJ-NP-Za-km-z]+$',
                )
                .hasMatch(_string(row['extended_public_key'], limit: 120))) {
          throw const FormatException('只允許公開延伸金鑰');
        }
        if (row['asset_family'] == 'EVM' &&
            [
              'receive_address_regtest',
              'receive_address_mainnet',
              'change_address',
              'descriptor',
                ].any((key) => row[key] != null)) {
          throw const FormatException('EVM 備份含無關的 Bitcoin 欄位');
        }
        for (final key in _accountKeys.difference({'chain_id'})) {
          if (row[key] != null) {
            _string(row[key], limit: key == 'descriptor' ? 1000 : 150);
          }
        }
        return AccountDescriptor.fromJson(row);
      }).toList();
      return PublicBackupBundle(
          chainId: raw['chain_id'] as int,
          accounts: accounts,
          transactions:
              _list(raw['transactions'], 500).map(transaction).toList(),
          bitcoinRecords:
              _list(raw['bitcoin_records'], 100).map(bitcoin).toList(),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('公開備份 JSON 損毀或型別不符');
    }
  }

  static String encode(
      {required int chainId,
      required List<AccountDescriptor> accounts,
      required List<Map<String, dynamic>> transactions,
      required List<Map<String, dynamic>> bitcoinRecords,
  }) {
    final cleanTransactions = transactions.map((r) {
      _only(r, {..._transactionKeys, 'rpcUrl'});
      return {
        for (final key in _transactionKeys)
          if (r.containsKey(key)) key: r[key],
          };
    }).toList();
    final cleanBitcoin = bitcoinRecords.map((r) {
      _only(r, {..._bitcoinKeys, 'schema_version', 'rpc_endpoint'});
      return {
        for (final key in _bitcoinKeys)
          if (r.containsKey(key)) key: r[key],
          };
    }).toList();
    final encoded = jsonEncode({
      'schema': 'fcw-public-wallet-backup',
      'version': bitcoinRecords.any((row) =>
              row['confirmations'] != null ||
              row['checked_at'] != null ||
              (row['history'] as List).any((item) =>
                  item['recovery'] != null ||
                  item['confirmations'] != null ||
                  item['checked_at'] != null,
                    ),
              )
          ? 2
          : 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'chain_id': chainId,
      'accounts': accounts.map((a) => a.toJson()).toList(),
      'transactions': cleanTransactions,
      'bitcoin_records': cleanBitcoin,
    });
    decode(encoded);
    return encoded;
  }
}

class PublicImportProgress {
  static bool isPendingAt(String directory) =>
      FileSystemEntity.typeSync(
        '$directory/public_import_progress.json',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;

  static void requireCompleteAt(String directory) {
    if (isPendingAt(directory)) {
      throw StateError('公開備份還原尚未完成；請繼續完成帳戶與交易紀錄還原後再建立付款');
    }
  }

  static bool blocksPaymentAt(
    String directory, {
    required String assetFamily,
    required String account,
    int? chainId,
    String? masterFingerprint,
  }) {
    try {
      final file = File('$directory/public_import_progress.json');
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return false;
      if (type != FileSystemEntityType.file ||
          file.lengthSync() > PublicBackupCodec.maxBytes * 3) {
        return true;
      }
      final raw = PublicBackupCodec._map(jsonDecode(file.readAsStringSync()));
      PublicBackupCodec._only(raw, {
        'version',
        'backup_json',
        'accounts_started',
        'accounts_done',
        'evm_done',
        'bitcoin_done',
      });
      if (raw['version'] != 1 ||
          raw['accounts_done'] is! bool ||
          raw['evm_done'] is! bool ||
          raw['bitcoin_done'] is! List ||
          (raw.containsKey('accounts_started') &&
              raw['accounts_started'] is! bool) ||
          (raw['accounts_started'] == false && raw['accounts_done'] == true)) {
        return true;
      }
      final bundle = PublicBackupCodec.decode(
        PublicBackupCodec._string(
          raw['backup_json'],
          limit: PublicBackupCodec.maxBytes,
        ),
      );
      PublicBackupService.validateEvmBindingConflicts(bundle.accounts);
      final ids = <String>{};
      final fingerprints = <String>{};
      for (final item in bundle.accounts) {
        if (item.assetFamily == 'EVM' &&
            (item.compressedPublicKeyHex == null ||
                !RegExp(
                  r"^m/44'/60'/[0-9]+'/[01]/[0-9]+$",
                ).hasMatch(item.derivationPath))) {
          return true;
        }
        if (item.assetFamily == 'BTC' &&
            !(item.extendedPublicKey?.startsWith('tpub') ?? false)) {
          return true;
        }
        final id =
            item.assetFamily == 'EVM'
                ? 'EVM:${item.chainId}:${item.address.toLowerCase()}'
                : 'BTC:${item.address.toLowerCase()}';
        if (!ids.add(id)) return true;
        if (item.assetFamily == 'BTC' &&
            !fingerprints.add(item.masterFingerprint.toLowerCase())) {
          return true;
        }
      }
      final requests = <String>{};
      for (final row in bundle.transactions) {
        if (!requests.add(row['requestId'] as String)) return true;
        final matches =
            bundle.accounts
                .where(
                  (item) =>
                      item.assetFamily == 'EVM' &&
                      item.chainId == row['chainId'] &&
                      item.address.toLowerCase() ==
                          (row['account'] as String).toLowerCase(),
                )
                .toList();
        if (matches.length != 1) return true;
        PublicBackupService.validateEvmRecordBinding(row, matches.single);
      }
      final bitcoinIds = <String>{};
      for (final row in bundle.bitcoinRecords) {
        final fingerprint = (row['master_fingerprint'] as String).toLowerCase();
        if (!bitcoinIds.add(fingerprint)) return true;
        final matches =
            bundle.accounts
                .where(
                  (item) =>
                      item.assetFamily == 'BTC' &&
                      item.masterFingerprint.toLowerCase() == fingerprint &&
                      item.address == row['account_address'],
                )
                .toList();
        if (matches.length != 1) return true;
        final entries = [
          row,
          for (final item in row['history'] as List)
            if (item['recovery'] != null) item['recovery'] as Map,
        ];
        for (final entry in entries) {
          final request = entry['request'];
          if (request != null &&
              (request['master_fingerprint'] != row['master_fingerprint'] ||
                  request['account_xpub'] !=
                      matches.single.extendedPublicKey)) {
            return true;
          }
        }
      }
      final done = raw['bitcoin_done'] as List;
      if (done.any(
            (value) =>
                value is! String || !bitcoinIds.contains(value.toLowerCase()),
          ) ||
          done.toSet().length != done.length) {
        return true;
      }
      if (assetFamily == 'EVM' && chainId != null && account.isNotEmpty) {
        return bundle.transactions.any(
          (row) =>
              row['chainId'] == chainId &&
              (row['account'] as String).toLowerCase() == account.toLowerCase(),
        );
      }
      if (assetFamily == 'BTC' &&
          masterFingerprint != null &&
          masterFingerprint.isNotEmpty &&
          account.isNotEmpty) {
        return bundle.bitcoinRecords.any(
          (row) =>
              (row['master_fingerprint'] as String).toLowerCase() ==
                  masterFingerprint.toLowerCase() &&
              (row['request'] != null || (row['history'] as List).isNotEmpty),
        );
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  static void requirePaymentAllowedAt(
    String directory, {
    required String assetFamily,
    required String account,
    int? chainId,
    String? masterFingerprint,
  }) {
    if (blocksPaymentAt(
      directory,
      assetFamily: assetFamily,
      account: account,
      chainId: chainId,
      masterFingerprint: masterFingerprint,
    )) {
      throw StateError('公開備份仍保留此帳戶的交易資料；請先完成核對，可能需要長期保留限制');
    }
  }

  final String backupJson;
  bool accountsStarted;
  bool accountsDone;
  bool evmDone;
  final Set<String> bitcoinDone;
  PublicImportProgress(this.backupJson,
      {this.accountsStarted = false,
    this.accountsDone = false,
      this.evmDone = false,
      Set<String>? bitcoinDone,
  })
      : bitcoinDone = bitcoinDone ?? {};
}

class PublicBackupExportPreview {
  final String backupJson;
  final int includedAccountCount;
  final int includedEvmTransactionCount;
  final int includedBitcoinRecordCount;
  final int excludedEvmCount;

  /// Each Bitcoin record is one bitcoin_*.json account bundle, including its
  /// pending request and archived history.
  final int excludedBitcoinRecordCount;
  final Map<String, int> evmExclusionReasons;
  final Map<String, int> bitcoinExclusionReasons;
  PublicBackupExportPreview({
    required this.backupJson,
    required this.includedAccountCount,
    required this.includedEvmTransactionCount,
    required this.includedBitcoinRecordCount,
    required this.excludedEvmCount,
    required this.excludedBitcoinRecordCount,
    required Map<String, int> evmExclusionReasons,
    required Map<String, int> bitcoinExclusionReasons,
  })  : evmExclusionReasons = Map.unmodifiable(evmExclusionReasons),
        bitcoinExclusionReasons = Map.unmodifiable(bitcoinExclusionReasons);
}

class PublicBackupService {
  final WalletFfiService ffi;
  final TransactionHistory history;
  final String? directoryOverride;
  BitcoinFfiService? _bitcoin;
  PublicBackupService(
      {required this.ffi,
      TransactionHistory? history,
      this.directoryOverride,
      BitcoinFfiService? bitcoin,
  })
      : history = history ?? TransactionHistory(),
        _bitcoin = bitcoin;

  static String accountIdentity(AccountDescriptor account) =>
      account.assetFamily == 'EVM'
          ? 'EVM:${account.chainId}:${account.address.toLowerCase()}'
          : 'BTC:${account.masterFingerprint.toLowerCase()}:${account.derivationPath}:${account.address.toLowerCase()}';

  static Map<String, dynamic> _immutableIdentity(AccountDescriptor account,
      {bool ignoreChain = false,
  }) {
    final identity = Map<String, dynamic>.from(account.toJson())
      ..remove('label')
      ..['address'] = account.address.toLowerCase()
      ..['master_fingerprint'] = account.masterFingerprint.toLowerCase();
    if (account.compressedPublicKeyHex != null) {
      identity['compressed_pubkey_hex'] =
          account.compressedPublicKeyHex!.toLowerCase();
    }
    if (account.chainCodeHex != null) {
      identity['chain_code_hex'] = account.chainCodeHex!.toLowerCase();
    }
    if (ignoreChain) identity.remove('chain_id');
    return identity;
  }

  static bool sameImmutableAccount(
      AccountDescriptor existing, AccountDescriptor incoming,
      {bool ignoreChain = false,
  }) {
    final left = _immutableIdentity(existing, ignoreChain: ignoreChain);
    final right = _immutableIdentity(incoming, ignoreChain: ignoreChain);
    return left.length == right.length &&
        left.entries.every((entry) => right[entry.key] == entry.value);
  }

  static void validateEvmBindingConflicts(
      Iterable<AccountDescriptor> accounts,
  ) {
    final existing = <String, AccountDescriptor>{};
    for (final account
        in accounts.where((account) => account.assetFamily == 'EVM',
    )) {
      final identity = accountIdentity(account);
      final collision = existing[identity];
      if (collision != null && !sameImmutableAccount(collision, account)) {
        throw const FormatException('同網路地址存在互相衝突的公開派生資料');
      }
      existing[identity] = account;
    }
  }

  static void validateEvmRecordBinding(
      Map<String, dynamic> record, AccountDescriptor account,
  ) {
    if (record['derivationPath'] != null &&
        record['derivationPath'] != account.derivationPath) {
      throw const FormatException('交易派生路徑與公開帳戶不符');
    }
    if (record['masterFingerprint'] != null &&
        (record['masterFingerprint'] as String).toLowerCase() !=
            account.masterFingerprint.toLowerCase()) {
      throw const FormatException('交易主指紋與公開帳戶不符');
    }
    if (record['compressedPublicKeyHex'] != null &&
        (record['compressedPublicKeyHex'] as String).toLowerCase() !=
            account.compressedPublicKeyHex?.toLowerCase()) {
      throw const FormatException('交易壓縮公鑰與公開帳戶不符');
    }
  }

  BitcoinFfiService get bitcoin => _bitcoin ??= BitcoinFfiService();
  Future<String> _directory() async {
    if (directoryOverride != null) return directoryOverride!;
    final result = await const MethodChannel('fcw/platform',
    )
        .invokeMethod<String>('storageDirectory');
    if (result == null || result.isEmpty) throw StateError('無法取得公開備份復原目錄');
    return result;
  }

  Future<void> validate(PublicBackupBundle bundle) async {
    validateEvmBindingConflicts(bundle.accounts);
    final identities = <String>{};
    final btcFingerprints = <String>{};
    final requestIds = <String>{};
    final btcRecordIds = <String>{};
    for (final account in bundle.accounts) {
      final id = account.assetFamily == 'EVM'
          ? 'EVM:${account.chainId}:${account.address.toLowerCase()}'
          : 'BTC:${account.address.toLowerCase()}';
      if (!identities.add(id)) throw const FormatException('備份中存在重複帳戶');
      if (account.assetFamily == 'EVM') {
        if (!RegExp(r"^m/44'/60'/[0-9]+'/[01]/[0-9]+$",
            )
                .hasMatch(account.derivationPath) ||
            account.compressedPublicKeyHex == null ||
            !ffi.verifyPubkeyAddress(
                compressedPubkeyHex: account.compressedPublicKeyHex!,
                expectedAddress: account.address,
            )) {
          throw const FormatException('備份 EVM 公鑰、地址或派生路徑無效');
        }
      } else {
        if (!btcFingerprints.add(account.masterFingerprint.toLowerCase())) {
          throw const FormatException('本版備份不支援相同主指紋的不同 Bitcoin 帳戶');
        }
        validateBitcoinPublicAccount(bitcoin, account);
      }
    }
    for (final record in bundle.transactions) {
      if (!requestIds.add(record['requestId'] as String)) {
        throw const FormatException('公開備份包含重複交易 requestId');
      }
      final matches = bundle.accounts
          .where((a) =>
              a.assetFamily == 'EVM' &&
              a.chainId == record['chainId'] &&
              a.address.toLowerCase() ==
                  (record['account'] as String).toLowerCase(),
              )
          .toList();
      if (matches.length != 1) {
        throw const FormatException('交易紀錄缺少唯一且同網路的公開帳戶');
      }
      final account = matches.single;
      _validateEvmRecord(record, account);
    }
    for (final record in bundle.bitcoinRecords) {
      if (!btcRecordIds.add(record['master_fingerprint'] as String)) {
        throw const FormatException('公開備份包含重複 Bitcoin 紀錄');
      }
      final account = bundle.accounts
          .where((a) =>
              a.assetFamily == 'BTC' &&
              a.address == record['account_address'] &&
              a.masterFingerprint == record['master_fingerprint'],
              )
          .firstOrNull;
      if (account == null) throw const FormatException('Bitcoin 紀錄缺少對應公開帳戶');
      final recoverable = <Map<String, dynamic>>[
        record,
        for (final item in record['history'] as List)
          if (item['recovery'] != null)
            Map<String, dynamic>.from(item['recovery'] as Map),
      ];
      for (final entry
          in recoverable.where((entry) => entry['request'] != null,
      )) {
        final original = Map<String, dynamic>.from(entry['request'] as Map);
        if (original['account_xpub'] != account.extendedPublicKey ||
            original['master_fingerprint'] != account.masterFingerprint) {
          throw const FormatException('Bitcoin 請求公開金鑰與帳戶不符');
        }
        final built = bitcoin.build(original);
        final stored = entry['built'] as Map;
        if (built['status'] != 'SUCCESS' ||
            built['psbt_hex'] != stored['psbt_hex'] ||
            built['expected_digest'] != stored['expected_digest'] ||
            built['txid'] != stored['txid']) {
          throw const FormatException('Bitcoin 備份 PSBT 與本地帳戶／前置交易不符');
        }
        // Archive summaries are compared with `built`; `built` must in turn be
        // exactly what the native core derives from the public request.
        for (final key in const [
          'recipient_address',
          'amount_sat',
          'fee_sat',
          'change_address',
          'change_sat',
          'network',
        ]) {
          if (built[key] != stored[key]) {
            throw const FormatException('Bitcoin 備份交易摘要與核心重建結果不符');
          }
        }
        if (entry['response_ur'] != null) {
          final verified = bitcoin.verify({
            'original_psbt_hex': built['psbt_hex'],
            'expected_digest': built['expected_digest'],
            'response_ur': entry['response_ur'],
          });
          if (verified['status'] != 'VERIFIED' ||
              verified['txid'] != built['txid']) {
            throw const FormatException('Bitcoin 備份簽章無法通過核心驗證');
          }
        }
      }
    }
  }

  void _validateEvmRecord(
      Map<String, dynamic> record, AccountDescriptor account,
  ) {
    validateEvmRecordBinding(record, account);
    final session = 'public-import-${DateTime.now().microsecondsSinceEpoch}';
    try {
      final registered = ffi.buildEthSignRequestUr(
          sessionId: session,
          requestIdHex: record['requestId'] as String,
          rawTxHex: record['unsignedPayload'] as String,
          chainId: record['chainId'] as int,
          derivationPath: account.derivationPath,
          masterFingerprintHex: account.masterFingerprint,
          expectedAddress: account.address,
      );
      if (registered['status'] != 'PENDING_REGISTERED') {
        throw const FormatException('交易原始內容、網路或帳戶無法通過核心驗證');
      }
      if (record['signatureUr'] != null) {
        final verified = ffi.verifyAndAssembleEthSignatureUr(
            sessionId: session,
            expectedRequestIdHex: record['requestId'] as String,
            urOrFrames: record['signatureUr'] as String,
        );
        if (verified['status'] != 'SIGNED_TX_READY' ||
            verified['verified'] != true ||
            verified['signed_raw_tx_hex'] != record['signedRaw'] ||
            verified['local_tx_hash'] != record['hash'] ||
            (verified['recovered_address'] as String?)?.toLowerCase() !=
                account.address.toLowerCase()) {
          throw const FormatException('備份交易簽章、帳戶或交易 hash 不符');
        }
      }
    } finally {
      ffi.cancelPendingSession(session);
    }
  }

  Future<PublicBackupExportPreview> prepareExport(
      AccountSnapshot snapshot,
  ) async {
    validateEvmBindingConflicts(snapshot.accounts);
    final records = await history.read();
    final pairedEvmAccounts = {
      for (final account
          in snapshot.accounts.where((account) => account.assetFamily == 'EVM',
      ))
        '${account.chainId}:${account.address.toLowerCase()}': account,
    };
    final transactions = <Map<String, dynamic>>[];
    final evmExclusionReasons = <String, int>{};
    final bitcoinExclusionReasons = <String, int>{};
    void exclude(Map<String, int> reasons, String reason) {
      reasons.update(reason, (count) => count + 1, ifAbsent: () => 1);
    }

    for (final record in records) {
      PublicBackupCodec._only(
          record, {...PublicBackupCodec._transactionKeys, 'rpcUrl',
      });
      final clean = PublicBackupCodec.transaction({
        for (final key in PublicBackupCodec._transactionKeys)
          if (record.containsKey(key)) key: record[key],
      });
      final identity =
          '${clean['chainId']}:${(clean['account'] as String).toLowerCase()}';
      final account = pairedEvmAccounts[identity];
      if (account == null) {
        exclude(evmExclusionReasons, 'unpaired_account');
      } else {
        validateEvmRecordBinding(clean, account);
        transactions.add(clean);
      }
    }

    final bitcoinRecords = <Map<String, dynamic>>[];
    final directory = await _directory();
    final sourceDirectory = Directory(directory);
    final sources = await sourceDirectory.exists()
        ? await sourceDirectory.list(followLinks: false).toList()
        : <FileSystemEntity>[];
    sources.sort((left, right) => left.path.compareTo(right.path));
    for (final source in sources) {
      final name =
          source.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
      if (!name.startsWith('bitcoin_') || !name.endsWith('.json')) continue;
      if (source is! File) {
        throw const FormatException('Bitcoin 紀錄來源無法讀取，無法核對匯出範圍');
      }
      if (await source.length() > PublicBackupCodec.maxBytes) {
        throw const FormatException('Bitcoin 紀錄超過備份大小限制');
      }
      final stored =
          PublicBackupCodec._map(jsonDecode(await source.readAsString()),
      );
      PublicBackupCodec._only(stored, {
        ...PublicBackupCodec._bitcoinKeys,
        'schema_version',
        'rpc_endpoint',
      });
      if (![1, 2].contains(stored['schema_version'])) {
        throw const FormatException('Bitcoin 紀錄版本不受支援，無法核對匯出範圍');
      }
      final clean = PublicBackupCodec.bitcoin({
        for (final key in PublicBackupCodec._bitcoinKeys)
          if (stored.containsKey(key)) key: stored[key],
      });
      if (name.toLowerCase() !=
          'bitcoin_${(clean['master_fingerprint'] as String).toLowerCase()}.json') {
        throw const FormatException('Bitcoin 紀錄檔名與帳戶不符，無法核對匯出範圍');
      }
      final paired = snapshot.accounts.any((account) =>
          account.assetFamily == 'BTC' &&
          account.masterFingerprint == clean['master_fingerprint'] &&
          account.address == clean['account_address'],
      );
      if (!paired) {
        exclude(bitcoinExclusionReasons, 'unpaired_account');
      } else {
        bitcoinRecords.add(clean);
      }
    }
    final result = PublicBackupCodec.encode(
        chainId: snapshot.chainId,
        accounts: snapshot.accounts,
        transactions: transactions,
        bitcoinRecords: bitcoinRecords,
    );
    await validate(PublicBackupCodec.decode(result));
    return PublicBackupExportPreview(
        backupJson: result,
        includedAccountCount: snapshot.accounts.length,
        includedEvmTransactionCount: transactions.length,
        includedBitcoinRecordCount: bitcoinRecords.length,
        excludedEvmCount: records.length - transactions.length,
        excludedBitcoinRecordCount:
            bitcoinExclusionReasons.values.fold(0, (sum, count) => sum + count,
      ),
        evmExclusionReasons: evmExclusionReasons,
        bitcoinExclusionReasons: bitcoinExclusionReasons,
    );
  }

  Future<String> export(AccountSnapshot snapshot) async =>
      (await prepareExport(snapshot)).backupJson;

  Future<File> _progressFile() async =>
      File('${await _directory()}/public_import_progress.json');
  Future<PublicImportProgress?> readProgress() async {
    final file = await _progressFile();
    if (!await file.exists()) return null;
    if (await file.length() > PublicBackupCodec.maxBytes * 3) {
      throw const FormatException('還原進度資料過大');
    }
    final raw = PublicBackupCodec._map(jsonDecode(await file.readAsString()));
    PublicBackupCodec._only(raw, {
      'version',
      'backup_json',
      'accounts_started',
      'accounts_done',
      'evm_done',
      'bitcoin_done',
    });
    if (raw['version'] != 1 ||
        (raw.containsKey('accounts_started') &&
            raw['accounts_started'] is! bool) ||
        raw['accounts_done'] is! bool ||
        raw['evm_done'] is! bool ||
        raw['bitcoin_done'] is! List) {
      throw const FormatException('還原進度損毀，原始進度已保留');
    }
    final accountsStarted = raw['accounts_started'] as bool? ?? true;
    if (!accountsStarted && raw['accounts_done'] == true) {
      throw const FormatException('還原進度損毀，原始進度已保留');
    }
    final source = PublicBackupCodec._string(raw['backup_json'],
        limit: PublicBackupCodec.maxBytes,
    );
    await validate(PublicBackupCodec.decode(source));
    return PublicImportProgress(source,
      accountsStarted: accountsStarted,
        accountsDone: raw['accounts_done'] as bool,
        evmDone: raw['evm_done'] as bool,
        bitcoinDone: Set<String>.from(raw['bitcoin_done'] as List),
    );
  }

  Future<void> saveProgress(PublicImportProgress progress) async {
    final file = await _progressFile();
    _writeAtomic(file, {
      'version': 1,
      'backup_json': progress.backupJson,
      'accounts_started': progress.accountsStarted,
      'accounts_done': progress.accountsDone,
      'evm_done': progress.evmDone,
      'bitcoin_done': progress.bitcoinDone.toList(),
    });
  }

  Future<PublicImportProgress> beginImport(String source) async {
    final bundle = PublicBackupCodec.decode(source);
    await validate(bundle);
    final previous = await readProgress();
    if (previous != null) {
      if (previous.backupJson != source) {
        throw const FormatException('尚有公開備份還原進度；已開始的進度必須保留');
      }
      return previous;
    }
    if (PublicImportProgress.isPendingAt((await _progressFile()).parent.path)) {
      throw StateError('無法讀取未完成的還原進度，原始進度已保留');
    }
    final progress =
        PublicImportProgress(source, evmDone: bundle.transactions.isEmpty,
    );
    await saveProgress(progress);
    return progress;
  }

  Future<void> clearProgress() async {
    final file = await _progressFile();
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError('無法確認還原進度，原始進度已保留');
    }
    final progress = await readProgress();
    if (progress == null) throw StateError('無法確認還原進度，原始進度已保留');
    if (progress.accountsStarted) {
      throw StateError('已開始的還原進度必須保留，以保護備份中的交易');
    }
    await file.delete();
  }

  /// Remove a started marker only after its actual restored data is present.
  Future<void> completeImport(
    PublicImportProgress progress,
    AccountSnapshot current, {
    AccountSnapshot Function()? snapshotProvider,
    required AccountSnapshot Function() persistedSnapshotProvider,
  }) async {
    final file = await _progressFile();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('無法確認還原進度，原始資料已保留');
    }
    if (file.lengthSync() > PublicBackupCodec.maxBytes * 3) {
      throw StateError('還原進度資料過大，原始資料已保留');
    }
    final original = file.readAsBytesSync();
    final persisted = await readProgress();
    if (persisted == null ||
        persisted.backupJson != progress.backupJson ||
        !persisted.accountsStarted ||
        !persisted.accountsDone ||
        !persisted.evmDone) {
      throw StateError('尚無完整還原進度，原始資料已保留');
    }
    final bundle = PublicBackupCodec.decode(persisted.backupJson);
    if (!bundle.bitcoinRecords.every(
      (record) => persisted.bitcoinDone.contains(record['master_fingerprint']),
    )) {
      throw StateError('Bitcoin 還原尚未完成，原始資料已保留');
    }
    void finish() {
      final latest = snapshotProvider?.call() ?? current;
      final persistedAccounts = persistedSnapshotProvider();
      for (final snapshot in [latest, persistedAccounts]) {
        for (final account in bundle.accounts) {
          final matches =
              snapshot.accounts
                  .where(
                    (existing) =>
                        accountIdentity(existing) == accountIdentity(account),
                  )
                  .toList();
          if (matches.length != 1 ||
              !sameImmutableAccount(matches.single, account)) {
            throw StateError('還原帳戶未完整保存，原始進度已保留');
          }
        }
      }
      validateEvmBindingConflicts([...latest.accounts, ...bundle.accounts]);
      for (final record in bundle.bitcoinRecords) {
        final prepared = _prepareBitcoinMerge(record, file.parent.path);
        if (FileSystemEntity.typeSync(prepared.$1.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('Bitcoin 紀錄尚未保存，原始進度已保留');
        }
        final actual = jsonDecode(prepared.$1.readAsStringSync());
        if (!_samePublicJson(actual, prepared.$2) ||
            (record['request'] != null &&
                record['response_ur'] != null &&
                actual['request'] != null &&
                actual['response_ur'] != record['response_ur'])) {
          throw StateError('Bitcoin 紀錄尚未完整保存，原始進度已保留');
        }
      }
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !_samePublicJson(original, file.readAsBytesSync())) {
        throw StateError('還原進度已變更，原始資料已保留');
      }
      file.deleteSync();
    }

    final incoming = _restoredTransactions(bundle);
    if (incoming.isNotEmpty) {
      await history.validateRestoredRecords(
        incoming,
        validateExisting: (records) {
          final latest = snapshotProvider?.call() ?? current;
          _validateExistingTransactions(records, [
            ...latest.accounts,
            ...bundle.accounts,
          ], incoming);
          for (final restored in incoming) {
            final matches = records.where(
              (row) => row['requestId'] == restored['requestId'],
            );
            if (matches.isEmpty ||
                matches.any(
                  (row) =>
                      restored['signatureUr'] != null &&
                      [
                        'signatureUr',
                        'signedRaw',
                        'hash',
                      ].any((key) => row[key] != restored[key]),
                )) {
              throw StateError('還原交易尚未完整保存，原始進度已保留');
            }
          }
        },
        onValidated: finish,
      );
    } else {
      finish();
    }
  }

  List<Map<String, dynamic>> _restoredTransactions(PublicBackupBundle bundle) =>
      bundle.transactions
        .map((r) => TransactionHistory.normalizeRecord(
            {...r, 'state': 'unknown', 'rpcUrl': '',
            }),
          )
        .toList();

  void _validateExistingTransactions(
    List<Map<String, dynamic>> records,
    List<AccountDescriptor> accounts,
    List<Map<String, dynamic>> incoming,
  ) {
    for (final record in records) {
      final matches =
          accounts
              .where(
                (a) =>
                    a.assetFamily == 'EVM' &&
                    a.chainId == record['chainId'] &&
                    a.address.toLowerCase() ==
                        (record['account'] as String).toLowerCase(),
              )
              .toList();
      if (matches.isEmpty) {
        if (incoming.any((row) => row['requestId'] == record['requestId'])) {
          throw const FormatException('現有交易缺少同網路公開帳戶，原始資料已保留');
        }
        continue;
      }
      final account = matches.first;
      if (matches.any((a) => !sameImmutableAccount(account, a)) ||
          account.compressedPublicKeyHex == null ||
          !ffi.verifyPubkeyAddress(
            compressedPubkeyHex: account.compressedPublicKeyHex!,
            expectedAddress: account.address,
          )) {
        throw const FormatException('現有交易公開帳戶資料衝突，原始資料已保留');
      }
      _validateEvmRecord(record, account);
    }
  }

  Future<void> preflightImport(
    PublicBackupBundle bundle,
    AccountSnapshot current,
  ) async {
    await validate(bundle);
    final accounts = [...current.accounts];
    for (final incoming in bundle.accounts) {
      for (final existing in accounts) {
        if ((accountIdentity(existing) == accountIdentity(incoming) ||
                (existing.assetFamily == 'BTC' &&
                    incoming.assetFamily == 'BTC' &&
                    existing.masterFingerprint.toLowerCase() ==
                        incoming.masterFingerprint.toLowerCase())) &&
            !sameImmutableAccount(existing, incoming)) {
          throw const FormatException('公開帳戶與既有資料衝突，原始資料已保留');
        }
      }
      accounts.add(incoming);
    }
    validateEvmBindingConflicts(accounts);
    if (bundle.transactions.isNotEmpty) {
      await history.validateRestoredRecords(
        _restoredTransactions(bundle),
        validateExisting:
            (records) => _validateExistingTransactions(records, accounts, _restoredTransactions(bundle)),
      );
    }
    if (bundle.bitcoinRecords.isNotEmpty) {
      final directory = await _directory();
      for (final record in bundle.bitcoinRecords) {
        _prepareBitcoinMerge(record, directory);
      }
    }
  }

  Future<void> importTransactions(
    PublicBackupBundle bundle, {
    AccountSnapshot? snapshot,
  }) async {
    await validate(bundle);
    final accounts = [...?snapshot?.accounts, ...bundle.accounts];
    validateEvmBindingConflicts(accounts);
    await history.mergeRestoredRecords(
      _restoredTransactions(bundle),
      validateExisting:
          (records) => _validateExistingTransactions(records, accounts, _restoredTransactions(bundle)),
    );
  }

  /// Recovers per-chain descriptors lost by releases that rewrote an account's
  /// chain when the selected network changed. A descriptor is added only when
  /// the native core validates the exact stored request on that chain.
  Future<AccountSnapshot> recoverLegacyEvmBindings(
      AccountSnapshot snapshot,
  ) async {
    validateEvmBindingConflicts(snapshot.accounts);
    final records = history.pathOverride == null
        ? await history.read()
        : history.readSync();
    final accounts = [...snapshot.accounts];
    final identities = accounts
        .where((account) => account.assetFamily == 'EVM')
        .map((account) =>
            '${account.chainId}:${account.address.toLowerCase()}',
            )
        .toSet();

    for (final stored in records) {
      final clean = PublicBackupCodec.transaction({
        for (final key in PublicBackupCodec._transactionKeys)
          if (stored.containsKey(key)) key: stored[key],
      });
      final address = (clean['account'] as String).toLowerCase();
      final chainId = clean['chainId'] as int;
      final identity = '$chainId:$address';
      if (identities.contains(identity)) {
        final existing = accounts.singleWhere((account) =>
            account.assetFamily == 'EVM' &&
            account.chainId == chainId &&
            account.address.toLowerCase() == address,
        );
        if (clean['state'] == 'confirmed' ||
            clean['state'] == 'executionFailed') {
          _validateEvmRecord(clean, existing);
        } else {
          validateEvmRecordBinding(clean, existing);
        }
        continue;
      }

      final candidates = accounts
          .where((account) =>
              account.assetFamily == 'EVM' &&
              account.address.toLowerCase() == address,
              )
          .toList();
      if (candidates.isEmpty) continue;
      if (candidates
          .skip(1)
          .any((candidate) => !sameImmutableAccount(
              candidates.first, candidate,
              ignoreChain: true,
                ),
          )) {
        throw const FormatException('舊版跨鏈帳戶公開資料互相衝突；原始資料已保留');
      }

      final recovered =
          candidates.first.copyWith(address: address, chainId: chainId,
      );
      if (recovered.compressedPublicKeyHex == null ||
          !ffi.verifyPubkeyAddress(
              compressedPubkeyHex: recovered.compressedPublicKeyHex!,
              expectedAddress: recovered.address,
          )) {
        throw const FormatException('舊版跨鏈帳戶公鑰與地址無法通過核心驗證');
      }
      _validateEvmRecord(clean, recovered);
      accounts.add(recovered);
      identities.add(identity);
    }
    if (accounts.length == snapshot.accounts.length) return snapshot;
    return AccountSnapshot(
        accounts: accounts,
        selectedIndex: snapshot.selectedIndex,
        chainId: snapshot.chainId,
        rpcUrl: snapshot.rpcUrl,
    );
  }

  static void _writeAtomic(File file, Map<String, dynamic> value) {
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(value), flush: true);
    temporary.renameSync(file.path);
  }

  /// `built` is validated against the native rebuild on import, so its
  /// identity is the PSBT, digest and TXID; UR framing is derived data.
  static bool _sameBuiltIdentity(dynamic left, dynamic right) =>
      left is Map &&
      right is Map &&
      left['psbt_hex'] == right['psbt_hex'] &&
      left['expected_digest'] == right['expected_digest'] &&
      left['txid'] == right['txid'];

  static bool _samePublicJson(dynamic left, dynamic right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every((key) =>
              right.containsKey(key) && _samePublicJson(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_samePublicJson(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

  Future<void> importBitcoinRecord(
      PublicBackupBundle bundle, Map<String, dynamic> incoming,
  ) async {
    await validate(bundle);
    final directory = await _directory();
    final prepared = _prepareBitcoinMerge(incoming, directory);
    _writeAtomic(prepared.$1, prepared.$2);
  }

  (File, Map<String, dynamic>) _prepareBitcoinMerge(
    Map<String, dynamic> incoming,
    String directory,
  ) {
    final fingerprint = incoming['master_fingerprint'] as String;
    final file = File('$directory/bitcoin_$fingerprint.json');
    Map<String, dynamic> existing = {
      'schema_version': 2,
      'account_address': incoming['account_address'],
      'master_fingerprint': fingerprint,
      'rpc_endpoint': 'http://127.0.0.1:18443/wallet/fcw_watch',
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'history': <dynamic>[],
    };
    final existingType = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound &&
        existingType != FileSystemEntityType.file) {
      throw const FormatException('現有 Bitcoin 紀錄無法安全讀取，原始資料已保留');
    }
    if (existingType == FileSystemEntityType.file) {
      if (file.lengthSync() > PublicBackupCodec.maxBytes) {
        throw const FormatException('現有 Bitcoin 紀錄過大');
      }
      existing =
          Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map,
      );
      final safe = {
        for (final key in PublicBackupCodec._bitcoinKeys)
          if (existing.containsKey(key)) key: existing[key],
      };
      PublicBackupCodec.bitcoin(safe);
      if (![1, 2].contains(existing['schema_version']) ||
          existing['account_address'] != incoming['account_address'] ||
          existing['master_fingerprint'] != fingerprint) {
        throw const FormatException('現有 Bitcoin 紀錄帳戶不符，未修改');
      }
      if (existing['request'] != null && incoming['request'] != null) {
        if (!_samePublicJson(existing['request'], incoming['request']) ||
            !_sameBuiltIdentity(existing['built'], incoming['built'])) {
          throw const FormatException('已有不同 Bitcoin 待處理交易，拒絕覆寫');
        }
        if (existing['response_ur'] != null && incoming['response_ur'] != null &&
            existing['response_ur'] != incoming['response_ur']) {
          throw const FormatException('同一 Bitcoin 待處理交易的簽章不符，拒絕覆寫');
        }
        if (existing['response_ur'] == null &&
            incoming['response_ur'] != null) {
          existing['response_ur'] = incoming['response_ur'];
          existing['state'] = 'unknown';
          existing.remove('confirmations');
          existing.remove('checked_at');
        }
      }
    }
    final mergedHistory = List<dynamic>.from(existing['history'] as List);
    final locallySigned = {
      for (final item in mergedHistory)
        if (item['recovery'] is Map &&
            (item['recovery'] as Map)['response_ur'] != null)
          item['txid'],
    };
    void add(Map<String, dynamic> item) {
      final index = mergedHistory.indexWhere((e) => e['txid'] == item['txid']);
      final restored = {...item, 'state': 'unknown'}
        ..remove('confirmations')
        ..remove('checked_at');
      if (index < 0) {
        mergedHistory.add(restored);
      } else {
        final summary = mergedHistory[index] as Map;
        if (summary['amount_sat'] != item['amount_sat'] ||
            summary['recipient_address'] != item['recipient_address']) {
          throw const FormatException('同 TXID 的歷史摘要不符，拒絕覆寫');
        }
        if ((summary['state'] == 'confirmed' || summary['state'] == 'failed') &&
            summary['recovery'] != null &&
            item['state'] != 'confirmed' && item['state'] != 'failed' &&
            item['recovery'] == null) {
          throw const FormatException('備份中尚未結算的 Bitcoin 紀錄缺少輸入資料，無法安全合併');
        }
        if (item['recovery'] == null) return;
        final existingRecovery = mergedHistory[index]['recovery'];
        final incomingRecovery = item['recovery'] as Map;
        if (existingRecovery != null &&
            (!_samePublicJson(
                    existingRecovery['request'], incomingRecovery['request'],
                ) ||
                !_sameBuiltIdentity(
                    existingRecovery['built'], incomingRecovery['built'],
                ) ||
                (existingRecovery['response_ur'] != null &&
                    incomingRecovery['response_ur'] != null &&
                    existingRecovery['response_ur'] !=
                        incomingRecovery['response_ur']))) {
          throw const FormatException('同 TXID 的封存恢復資料不符，拒絕覆寫');
        }
        if (existingRecovery == null ||
            (existingRecovery['response_ur'] == null &&
                incomingRecovery['response_ur'] != null)) {
          mergedHistory[index] = {
            ...Map<String, dynamic>.from(mergedHistory[index] as Map),
            'recovery': incomingRecovery,
          };
        }
      }
    }

    for (final item in incoming['history'] as List) {
      add(Map<String, dynamic>.from(item as Map));
    }
    if (incoming['request'] != null && existing['request'] == null) {
      if (incoming['response_ur'] != null) {
        final built = incoming['built'] as Map;
        final archived = mergedHistory.any((item) {
          final recovery = item['recovery'];
          return item['txid'] == built['txid'] &&
              item['amount_sat'] == built['amount_sat'] &&
              item['recipient_address'] == built['recipient_address'] &&
              recovery is Map &&
              _samePublicJson(recovery['request'], incoming['request']) &&
              _samePublicJson(recovery['built'], incoming['built']) &&
              recovery['response_ur'] == incoming['response_ur'];
        });
        if (!archived) {
          existing['request'] = incoming['request'];
          existing['built'] = incoming['built'];
          existing['response_ur'] = incoming['response_ur'];
          existing['state'] = 'unknown';
          existing.remove('confirmations');
          existing.remove('checked_at');
        }
      } else {
        final built = incoming['built'] as Map;
        add({
          'txid': built['txid'],
          'amount_sat': built['amount_sat'],
          'recipient_address': built['recipient_address'],
          'recovery': {
            'request': incoming['request'],
            'built': incoming['built'],
            'response_ur': incoming['response_ur'],
          },
          'state': 'unknown',
        });
      }
    }
    final activeBuilt = existing['request'] == null ? null : existing['built'];
    if (activeBuilt is Map && existing['response_ur'] == null) {
      final signedTwin = !locallySigned.contains(activeBuilt['txid']) &&
          mergedHistory.any((item) =>
              item['txid'] == activeBuilt['txid'] &&
              item['recovery'] is Map &&
              (item['recovery'] as Map)['response_ur'] != null,
          );
      if (signedTwin) {
        throw const FormatException(
            '本機待簽 Bitcoin 交易在備份中已有同 TXID 的已簽封存；請先封存本機待簽交易再匯入，原始資料未修改',
        );
      }
    }
    existing['history'] = mergedHistory;
    existing['schema_version'] = 2;
    PublicBackupCodec.bitcoin({
      for (final key in PublicBackupCodec._bitcoinKeys)
        if (existing.containsKey(key)) key: existing[key],
    });
    if (utf8.encode(jsonEncode(existing)).length > PublicBackupCodec.maxBytes) {
      throw const FormatException('合併後 Bitcoin 紀錄超過 2 MiB，原始資料未修改');
    }
    return (file, existing);
  }
}
