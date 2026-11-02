import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'public_backup.dart';

/// Public transaction records only. Signed bytes are retained so an uncertain
/// network result never requires another signature or a different transaction.
class TransactionHistory {
  final String? pathOverride;
  TransactionHistory({this.pathOverride});
  static Future<void> _writeQueue = Future<void>.value();

  static Map<String, dynamic> normalizeRecord(Map<String, dynamic> record) {
    final normalized = Map<String, dynamic>.from(record);
    final account = normalized['account'];
    if (account is String &&
        RegExp(r'^0[xX][0-9a-fA-F]{40}$').hasMatch(account)) {
      normalized['account'] = account.toLowerCase();
    }
    for (final entry in {'masterFingerprint': 8, 'compressedPublicKeyHex': 66}
        .entries) {
      final value = normalized[entry.key];
      if (value is String &&
          RegExp('^[0-9a-fA-F]{${entry.value}}\$').hasMatch(value)) {
        normalized[entry.key] = value.toLowerCase();
      }
    }
    return normalized;
  }

  Future<File> _file() async {
    if (pathOverride != null) return File(pathOverride!);
    final path = await const MethodChannel('fcw/platform',
    )
        .invokeMethod<String>('storageDirectory');
    if (path == null || path.isEmpty) throw StateError('無法取得交易紀錄儲存目錄');
    return File('$path/public_transactions.json');
  }

  Future<List<Map<String, dynamic>>> read() async {
    final file = await _file();
    if (!await file.exists()) return [];
    return _decode(await file.readAsString());
  }

  List<Map<String, dynamic>> readSync() {
    final path = pathOverride;
    if (path == null) {
      throw StateError('同步讀取只允許明確的交易紀錄路徑');
    }
    final file = File(path);
    if (!file.existsSync()) return [];
    return _decode(file.readAsStringSync());
  }

  static List<Map<String, dynamic>> _decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['transactions'] is! List) {
      throw const FormatException('交易紀錄格式損毀');
    }
    return (decoded['transactions'] as List)
        .map((entry) {
      if (entry is! Map) {
        throw const FormatException('交易紀錄缺少有效帳戶或網路');
      }
      final record = Map<String, dynamic>.from(entry);
      final account = record['account'];
      final chainId = record['chainId'];
      if (account is! String ||
          !RegExp(r'^0[xX][0-9a-fA-F]{40}$').hasMatch(account) ||
          chainId is! int ||
          chainId <= 0) {
        throw const FormatException('交易紀錄缺少有效帳戶或網路');
      }
      return normalizeRecord(record);
    })
        .toList();
  }

  Future<void> save(Map<String, dynamic> record) => _modify((records) {
        final normalized = normalizeRecord(record);
        records.removeWhere((e) => e['requestId'] == normalized['requestId']);
        records.insert(
            0,
            normalized
              ..['updatedAt'] = DateTime.now().toUtc().toIso8601String(),
    );
      });

  /// Checks a complete restore against the latest queued history without writing.
  Future<void> validateRestoredRecords(
    List<Map<String, dynamic>> imported, {
    void Function(List<Map<String, dynamic>>)? validateExisting,
    void Function()? onValidated,
  }) {
    final incoming = _copyRestoredRecords(imported);
    return _enqueue(() async {
      final records = await read();
      _validateExistingRecords(records, validateExisting);
      _mergeRestoredRecords(records, incoming);
      onValidated?.call();
    });
  }

  /// Imports an already validated public backup as one atomic history mutation.
  /// Native signature verification remains mandatory when a signed row is opened.
  Future<void> mergeRestoredRecords(List<Map<String, dynamic>> imported, {
    void Function(List<Map<String, dynamic>>)? validateExisting,
  }) {
    final incoming = _copyRestoredRecords(imported);
    return _modify((records) {
      final merged = _mergeRestoredRecords(records, incoming);
      records
        ..clear()
        ..addAll(merged);
    }, validateExisting: validateExisting);
  }

  static List<Map<String, dynamic>> _copyRestoredRecords(
    List<Map<String, dynamic>> imported,
  ) {
    if (imported.length > 1000) {
      throw const FormatException('還原交易紀錄超過 1000 筆限制');
    }
    final encoded = jsonEncode(imported);
    if (utf8.encode(encoded).length > 2 * 1024 * 1024) {
      throw const FormatException('還原交易紀錄超過 2 MiB 限制');
    }
    return (jsonDecode(encoded) as List)
        .map((row) => normalizeRecord(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  static List<Map<String, dynamic>> _mergeRestoredRecords(
    List<Map<String, dynamic>> existingRecords,
    List<Map<String, dynamic>> incoming,
  ) {
    final records =
        existingRecords.map((row) => Map<String, dynamic>.from(row)).toList();
    const bindingFields = [
      'account',
      'chainId',
      'derivationPath',
      'masterFingerprint',
      'compressedPublicKeyHex',
      'requestId',
      'unsignedPayload',
    ];
    const signatureFields = ['signatureUr',
      'signedRaw',
      'hash'
    ];
    for (final restored in incoming) {
        if (restored['requestId'] is! String ||
            (restored['requestId'] as String).isEmpty ||
            restored['account'] is! String ||
            restored['chainId'] is! int ||
            restored['unsignedPayload'] is! String) {
          throw const FormatException('還原交易缺少請求綁定資料');
      }
      final restoredSigned = restored['signatureUr'] != null;
      if ((restoredSigned &&
              signatureFields.any(
                (field) =>
                    restored[field] is! String ||
                    (restored[field] as String).isEmpty,
              )) ||
          (!restoredSigned &&
              (restored['signedRaw'] != null || restored['hash'] != null))) {
        throw const FormatException('還原交易簽章資料不完整；原有資料已保留');
        }
        final sameId = records
            .where((record) => record['requestId'] == restored['requestId'])
            .toList();
        for (final existing in sameId) {
          if (bindingFields.any((field) => existing[field] != restored[field])) {
            throw const FormatException('還原交易請求與既有紀錄衝突；原有資料已保留');
          }
        final existingSigned = existing['signatureUr'] != null;
        if (existingSigned &&
            restoredSigned &&
            signatureFields.any(
              (field) => existing[field] != restored[field],
            )) {
          throw const FormatException('還原交易簽章與既有紀錄衝突；原有資料已保留');
        }
        if (!existingSigned && restoredSigned) {
          for (final field in signatureFields) {
            existing[field] = restored[field];
          }
          existing['state'] = 'unknown';
          existing['updatedAt'] = DateTime.now().toUtc().toIso8601String();
        }
      }
        if (sameId.isNotEmpty) continue;
        records.add(Map<String, dynamic>.from(restored)
          ..['state'] = 'unknown'
          ..['updatedAt'] = DateTime.now().toUtc().toIso8601String(),
      );
      }
      if (records.length > 10000) {
        throw const FormatException('交易紀錄超過 10000 筆限制；原有資料已保留');
      }
    return records;
  }

  static void _validateExistingRecords(
    List<Map<String, dynamic>> records,
    void Function(List<Map<String, dynamic>>)? validateExisting,
  ) {
    for (final record in records) {
      PublicBackupCodec.validateStoredTransaction(record);
    }
    validateExisting?.call(
      List.unmodifiable(
        records.map((record) => Map<String, dynamic>.unmodifiable(record)),
      ),
    );
  }

  Future<void> cancelPending(String requestId) => _modify((records) {
        for (final record in records) {
          if (record['requestId'] == requestId &&
              record['state'] == 'awaitingSignature') {
            record['state'] = 'cancelled';
            record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
          }
        }
      });

  /// Returns a durable same-account request that may still execute.
  ///
  /// Older releases marked an exported request `cancelled` when its form was
  /// edited or its screen was closed. The Watch cannot know whether the Vault
  /// signed that QR, so every state except a proven on-chain terminal result
  /// remains admission-blocking. This is intentionally conservative until the
  /// ADR-005 nonce-family model is implemented.
  Future<Map<String, dynamic>?> findPotentiallyExecutable({
    required String account,
    required int chainId,
  }) async {
    final normalizedAccount = account.toLowerCase();
    final directory = (await _file()).parent.path;
    PublicImportProgress.requirePaymentAllowedAt(
      directory,
      assetFamily: 'EVM',
      account: account,
      chainId: chainId,
    );
    final records = await read();
    _validateExistingRecords(records, null);
    PublicImportProgress.requirePaymentAllowedAt(
      directory,
      assetFamily: 'EVM',
      account: account,
      chainId: chainId,
    );
    for (final record in records) {
      if ((record['account'] as String?)?.toLowerCase() != normalizedAccount ||
          record['chainId'] != chainId) {
        continue;
      }
      final state = record['state'];
      if (state != 'confirmed' && state != 'executionFailed') {
        return Map<String, dynamic>.from(record);
      }
    }
    return null;
  }

  Future<void> requireRecoveryAllowed({
    required String account,
    required int chainId,
  }) async {
    final directory = (await _file()).parent.path;
    PublicImportProgress.requirePaymentAllowedAt(
      directory,
      assetFamily: 'EVM',
      account: account,
      chainId: chainId,
    );
  }

  static Future<void> _enqueue(Future<void> Function() action) {
    final operation = _writeQueue.then((_) => action());
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> _modify(void Function(List<Map<String, dynamic>>) update, {
    void Function(List<Map<String, dynamic>>)? validateExisting,
  }) => _enqueue(() async {
      final records = await read();
    _validateExistingRecords(records, validateExisting);
    update(records);
    _validateExistingRecords(records, null);
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
          jsonEncode({'version': 1, 'transactions': records}),
          flush: true,
    );
      await temporary.rename(file.path);
    });
}

class TransactionOutcome {
  static String receiptState(
      Map<String, dynamic> receipt, String expectedHash,
  ) {
    if (receipt['transactionHash'] is! String ||
        (receipt['transactionHash'] as String).toLowerCase() !=
            expectedHash.toLowerCase() ||
        receipt['blockNumber'] is! String ||
        !RegExp(r'^0x[0-9a-fA-F]+$',
        )
            .hasMatch(receipt['blockNumber'] as String)) {
      throw const FormatException('Receipt 與本地交易不符或缺少區塊資訊');
    }
    if (receipt['status'] == '0x1') return 'confirmed';
    if (receipt['status'] == '0x0') return 'executionFailed';
    throw const FormatException('Receipt 缺少有效執行狀態');
  }

  static String label(String state) =>
      const {
        'awaitingSignature': '待離線簽章',
        'verified': '簽章已驗證，待確認廣播',
        'broadcasting': '廣播中',
        'accepted': '節點已接受，待查確認',
        'pending': '待確認',
        'confirmed': '已確認（執行成功）',
        'executionFailed': '已確認（執行失敗）',
        'unknown': '結果待查，請查詢同一筆交易',
        'cancelled': '本機流程已取消，交易仍待核對',
      }[state] ??
      '未知狀態';
}
