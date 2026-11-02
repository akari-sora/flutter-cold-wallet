import 'dart:convert';
import 'dart:io';
import 'package:public_models/public_models.dart';

class AccountSnapshot {
  final List<AccountDescriptor> accounts;
  final int selectedIndex;
  final int chainId;
  final String rpcUrl;
  const AccountSnapshot(
      {required this.accounts,
      this.selectedIndex = 0,
      this.chainId = 11155111,
      this.rpcUrl = 'http://127.0.0.1:8545'});
}

/// Public watch-only state. Write first, publish to UI only after rename succeeds.
class AccountStore {
  final String path;
  const AccountStore(this.path);
  static const supportedChains = [11155111, 31337, 1337];
  AccountSnapshot load() {
    final file = File(path);
    if (!file.existsSync()) return const AccountSnapshot(accounts: []);
    try {
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (raw['schema_version'] != 1 ||
          raw['accounts'] is! List ||
          raw['selected_index'] is! int ||
          raw['rpc_url'] is! String ||
          !supportedChains.contains(raw['selected_chain_id'])) {
        throw const FormatException('觀察帳戶檔案格式或網路不受支援');
      }
      final accounts = (raw['accounts'] as List)
          .map((e) =>
              AccountDescriptor.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final index = raw['selected_index'] as int;
      if (index < 0 ||
          (accounts.isNotEmpty && index >= accounts.length) ||
          (accounts.isEmpty && index != 0)) {
        throw const FormatException('觀察帳戶選擇資料損毀');
      }
      return AccountSnapshot(
          accounts: accounts,
          selectedIndex: index,
          chainId: raw['selected_chain_id'] as int,
          rpcUrl: raw['rpc_url'] as String);
    } on FileSystemException {
      rethrow;
    } catch (e) {
      throw FormatException('無法讀取觀察帳戶，原檔已保留：$e');
    }
  }

  void save(AccountSnapshot value) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'selected_index': value.selectedIndex,
          'selected_chain_id': value.chainId,
          'rpc_url': value.rpcUrl,
          'accounts': value.accounts.map((a) => a.toJson()).toList(),
        }),
        flush: true);
    tmp.renameSync(path);
  }

  /// Used only after explicit public-backup import confirmation. Preserve the
  /// unreadable original before replacing it with validated public accounts.
  String recoverWithSnapshot(AccountSnapshot value) {
    final original = File(path).readAsBytesSync();
    final preserved = File(
        '$path.corrupt-${DateTime.now().toUtc().microsecondsSinceEpoch}.bak');
    preserved.createSync(exclusive: true);
    preserved.writeAsBytesSync(original, flush: true);
    final copied = preserved.readAsBytesSync();
    if (copied.length != original.length) {
      throw const FileSystemException('無法完整保留原始帳戶檔案');
    }
    for (var index = 0; index < original.length; index++) {
      if (copied[index] != original[index]) {
        throw const FileSystemException('無法完整保留原始帳戶檔案');
      }
    }
    save(value);
    return preserved.path;
  }
}
