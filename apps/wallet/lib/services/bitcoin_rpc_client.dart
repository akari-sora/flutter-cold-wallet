import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:public_models/public_models.dart';
import 'node_url_policy.dart';

class BitcoinRpcException implements Exception {
  final String message;
  final bool uncertain;

  /// JSON-RPC error code returned by the node, when it returned one.
  final int? code;

  /// True only when the node never ran `sendrawtransaction` for this attempt.
  final bool notSent;

  /// The node's own error message, kept verbatim for classification.
  final String? rpcMessage;
  const BitcoinRpcException(this.message,
      {this.uncertain = false,
      this.code,
      this.notSent = false,
      this.rpcMessage});

  /// Bitcoin Core returns -5 for several lookups. Only this message means a
  /// synced txindex has neither a mempool nor a blockchain copy; without
  /// txindex (or while it is still building) the node cannot prove absence.
  bool get transactionNotFound =>
      code == -5 &&
      (rpcMessage?.startsWith('No such mempool or blockchain transaction') ??
          false);

  /// -5 that cannot prove absence (no txindex, or index still building).
  bool get lookupInconclusive => code == -5 && !transactionNotFound;
  @override
  String toString() => message;
}

/// Wallet-side regtest RPC only. Credentials remain in memory and HTTP headers.
class BitcoinRpcClient {
  final String endpoint;
  final String username;
  final String password;
  final http.Client _client;
  BitcoinRpcClient(
      {required this.endpoint,
      this.username = '',
      this.password = '',
      http.Client? client})
      : _client = client ?? http.Client();
  void close() => _client.close();
  Future<dynamic> _call(String method, List<dynamic> params) async {
    final kind = NodeUrlPolicy.classify(endpoint);
    if (kind == NodeUrlKind.invalid) {
      throw const BitcoinRpcException('請輸入有效 RPC 網址；使用者名稱與密碼請填入獨立欄位');
    }
    if (kind == NodeUrlKind.publicHttp) {
      throw const BitcoinRpcException(NodeUrlPolicy.publicHttpRefused);
    }
    final uri = Uri.parse(endpoint);
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'content-type': 'application/json',
          if (username.isNotEmpty || password.isNotEmpty)
            'authorization':
                'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        })
        ..body = jsonEncode({
          'jsonrpc': '1.0',
          'id': 'fcw-regtest',
          'method': method,
          'params': params
        });
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        // The configured endpoint may have forwarded a broadcast already.
        // Do not follow Location or claim those signed bytes were unsent.
        throw BitcoinRpcException('Bitcoin RPC 拒絕重新導向；請確認設定的節點網址',
            uncertain: method == 'sendrawtransaction');
      }
      // Bitcoin Core answers both with an empty body before running the
      // method, but a proxy in front of it may already have forwarded the
      // request. The signed bytes left the device, so the send is uncertain.
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw BitcoinRpcException(_accessDenied(method, response.statusCode),
            uncertain: method == 'sendrawtransaction');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['error'] != null) {
        final error = json['error'] as Map;
        final code = error['code'] is int ? error['code'] as int : null;
        throw BitcoinRpcException(
            code == null
                ? 'Bitcoin RPC $method 拒絕請求'
                : 'Bitcoin RPC $method 拒絕請求（錯誤碼 $code）',
            code: code,
            rpcMessage:
                error['message'] is String ? error['message'] as String : null);
      }
      if (response.statusCode != 200 || !json.containsKey('result')) {
        throw const FormatException('無效 RPC 回應');
      }
      return json['result'];
    } on BitcoinRpcException {
      rethrow;
    } catch (_) {
      throw BitcoinRpcException('Bitcoin RPC $method 無法連線或回應無法解析',
          uncertain: method == 'sendrawtransaction');
    }
  }

  String _accessDenied(String method, int status) {
    if (method == 'sendrawtransaction') {
      // The reply may come from a proxy that already forwarded the send, so
      // it is not attributed to the node.
      final received = 'Bitcoin RPC $method 收到 HTTP $status（可能來自節點或其前方的代理）';
      return status == 403
          ? '$received：此 RPC 帳號可能沒有執行權限或來源未獲允許；請確認節點的 rpcwhitelist／rpcallowip 設定與 RPC 帳號'
          : '$received：RPC 使用者名稱或密碼可能不正確；請在節點設定重新輸入';
    }
    if (status == 403) {
      return 'Bitcoin RPC $method 遭節點拒絕（HTTP 403）：此 RPC 帳號沒有執行權限或來源未獲允許；請確認節點的 rpcwhitelist／rpcallowip 設定與 RPC 帳號';
    }
    // Credentials live only in memory and are cleared when the screen closes.
    return username.isEmpty && password.isEmpty
        ? 'Bitcoin RPC $method 未通過節點認證（HTTP 401）：RPC 使用者名稱與密碼皆為空白（離開 BTC 畫面時會從記憶體清除）；請在節點設定重新輸入'
        : 'Bitcoin RPC $method 未通過節點認證（HTTP 401）：節點拒絕此 RPC 使用者名稱或密碼；請在節點設定重新輸入';
  }

  Future<void> verifyRegtest() async {
    final info = await _call('getblockchaininfo', []) as Map;
    if (info['chain'] != 'regtest') {
      throw const BitcoinRpcException('僅允許 Bitcoin regtest，已拒絕此節點');
    }
  }

  Future<void> _verifyWatchOnly() async {
    final info = await _call('getwalletinfo', []) as Map;
    if (info['private_keys_enabled'] != false) {
      throw const BitcoinRpcException(
          '請連接 disable_private_keys 的 Bitcoin Core 觀察錢包 RPC');
    }
  }

  /// `listdescriptors` prints hardened steps as `h` while `getdescriptorinfo`
  /// keeps the caller's `'`; compare both without checksum in the `h` form.
  static String _canonical(String descriptor) =>
      descriptor.split('#').first.replaceAll("'", 'h');

  /// Inclusive ranges of the ranged descriptors already in this wallet.
  Future<Map<String, List<int>>> _importedRanges() async {
    final listed = await _call('listdescriptors', []);
    final descriptors = listed is Map ? listed['descriptors'] : null;
    if (descriptors is! List) {
      throw const BitcoinRpcException('節點 descriptor 清單格式錯誤');
    }
    final ranges = <String, List<int>>{};
    for (final entry in descriptors) {
      final range = entry is Map ? entry['range'] : null;
      if (entry is Map &&
          entry['desc'] is String &&
          range is List &&
          range.length == 2 &&
          range.every((value) => value is int && value >= 0)) {
        ranges[_canonical(entry['desc'] as String)] = List<int>.from(range);
      }
    }
    return ranges;
  }

  static String _receiveDescriptor(AccountDescriptor account) {
    final descriptor = account.btcDescriptor;
    if (descriptor == null || !descriptor.contains('/0/*')) {
      throw const BitcoinRpcException('公開帳戶缺少受支援的接收 descriptor');
    }
    return descriptor.split('#').first;
  }

  /// The node's checksummed form of a public-only ranged descriptor.
  Future<String> _checkedDescriptor(String descriptor) async {
    final info = await _call('getdescriptorinfo', [descriptor]) as Map;
    if (info['hasprivatekeys'] != false ||
        info['isrange'] != true ||
        info['descriptor'] is! String) {
      throw const BitcoinRpcException('節點拒絕純公開範圍 descriptor');
    }
    return info['descriptor'] as String;
  }

  Future<void> importPublicDescriptors(AccountDescriptor account) async {
    await verifyRegtest();
    await _verifyWatchOnly();
    final external = _receiveDescriptor(account);
    final internal = external.replaceFirst('/0/*', '/1/*');
    final imported = await _importedRanges();
    final requests = <Map<String, dynamic>>[];
    for (final isChange in [false, true]) {
      final descriptor =
          await _checkedDescriptor(isChange ? internal : external);
      // Bitcoin Core rejects a re-import that does not cover the current
      // range, and extends that range itself once addresses are used.
      final current = imported[_canonical(descriptor)];
      requests.add({
        'desc': descriptor,
        'timestamp': 0,
        'range': [0, max(current?.last ?? 0, 100)],
        'internal': isChange,
        'active': false
      });
    }
    final result = await _call('importdescriptors', [requests]) as List;
    if (result.length != 2 ||
        result.any((e) => e is! Map || e['success'] != true)) {
      throw const BitcoinRpcException('公開 descriptor 匯入失敗；請檢查節點觀察錢包');
    }
  }

  /// Lowest change index (`/1/i`) that never received funds, within the range
  /// the node tracks. For these non-active imports only `getreceivedbyaddress`
  /// with minconf 0 also counts spent, mempool and own-change receipts;
  /// `listtransactions` and `listreceivedbyaddress` leave them out.
  Future<int> unusedChangeIndex(AccountDescriptor account) async {
    await verifyRegtest();
    await _verifyWatchOnly();
    final internal = await _checkedDescriptor(
        _receiveDescriptor(account).replaceFirst('/0/*', '/1/*'));
    final range = (await _importedRanges())[_canonical(internal)];
    if (range == null) {
      throw const BitcoinRpcException('觀察錢包尚未匯入找零描述；請先同步公開描述');
    }
    final addresses = await _call('deriveaddresses', [internal, range]);
    if (addresses is! List ||
        addresses.length != range.last - range.first + 1) {
      throw const BitcoinRpcException('節點找零地址回應格式錯誤');
    }
    for (var i = 0; i < addresses.length; i++) {
      final received = await _call('getreceivedbyaddress', [addresses[i], 0]);
      if (received is! num) {
        throw const BitcoinRpcException('節點找零地址回應格式錯誤');
      }
      if (received == 0) return range.first + i;
    }
    throw const BitcoinRpcException(
        '觀察錢包追蹤的找零地址皆已收過款；請先在節點擴充找零 descriptor range');
  }

  Future<List<Map<String, dynamic>>> loadUtxos(
      AccountDescriptor account) async {
    await verifyRegtest();
    await _verifyWatchOnly();
    final unspent = await _call('listunspent', [1, 9999999]) as List;
    final selected = <Map<String, dynamic>>[];
    for (final raw in unspent) {
      final row = Map<String, dynamic>.from(raw as Map);
      int? branch;
      int? index;
      final origin = RegExp(
              r'\[([0-9a-fA-F]{8})/84[hH\x27]/1[hH\x27]/0[hH\x27]/([01])/([0-9]+)\]')
          .firstMatch('${row['desc'] ?? ''}');
      if (origin != null &&
          origin.group(1)!.toLowerCase() ==
              account.masterFingerprint.toLowerCase()) {
        branch = int.parse(origin.group(2)!);
        index = int.parse(origin.group(3)!);
      } else if (row['address'] == account.btcReceiveAddressRegtest ||
          row['address'] == account.address) {
        branch = 0;
        index = 0;
      } else if (row['address'] == account.btcChangeAddress) {
        branch = 1;
        index = 0;
      }
      if (branch == null || index == null) continue;
      final txid = row['txid'];
      final vout = row['vout'];
      if (txid is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(txid) ||
          vout is! int ||
          vout < 0 ||
          index >= 0x80000000) {
        throw const BitcoinRpcException('節點 UTXO 格式錯誤');
      }
      final previous = await _call('getrawtransaction', [txid, false]);
      if (previous is! String || previous.isEmpty) {
        throw const BitcoinRpcException('無法取得 UTXO 的原始前置交易；節點需啟用 txindex');
      }
      selected.add({
        'txid': txid,
        'vout': vout,
        'previous_tx_hex': previous,
        'branch': branch,
        'address_index': index
      });
      if (selected.length > 64) {
        throw const BitcoinRpcException('超過本版 64 個輸入限制，請先整理測試 UTXO');
      }
    }
    return selected;
  }

  Future<String> broadcast(String rawTransaction,
      {bool Function()? canDispatch}) async {
    try {
      await verifyRegtest();
    } catch (e) {
      // Nothing has been dispatched yet, so the signed bytes stay sendable.
      throw BitcoinRpcException('$e；交易尚未傳送',
          code: e is BitcoinRpcException ? e.code : null, notSent: true);
    }
    if (canDispatch != null && !canDispatch()) {
      throw const BitcoinRpcException('廣播授權已撤銷，交易尚未傳送', notSent: true);
    }
    final txid = await _call('sendrawtransaction', [rawTransaction]);
    if (txid is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(txid)) {
      throw const BitcoinRpcException('廣播回應不確定，請查詢同一筆交易', uncertain: true);
    }
    return txid.toLowerCase();
  }

  Future<Map<String, dynamic>> transactionStatus(String txid) async {
    await verifyRegtest();
    final result = await _call('getrawtransaction', [txid, true]);
    if (result is! Map || result['txid'] != txid) {
      throw const BitcoinRpcException('節點交易結果與本地 txid 不符');
    }
    return Map<String, dynamic>.from(result);
  }
}
