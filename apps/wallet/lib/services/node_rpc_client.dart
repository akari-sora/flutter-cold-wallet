import 'dart:convert';
import 'package:http/http.dart' as http;
import 'node_url_policy.dart';

class RpcException implements Exception {
  final String method;
  final String message;

  const RpcException({required this.method, required this.message});

  @override
  String toString() => 'RpcException($method): $message';
}

/// JSON-RPC client for node chainId verification, balance queries, gas estimation,
/// and raw transaction broadcasting. Never fakes success on network or RPC failure.
class NodeRpcClient {
  final String rpcUrl;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  NodeRpcClient({
    this.rpcUrl = 'http://127.0.0.1:8545',
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// The caller retains ownership of an injected/shared HTTP client.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  static const String sepoliaUsdcContract =
      '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238';
  static const String sepoliaDaiContract =
      '0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357';

  Future<int> getChainId() async {
    final res = await _call('eth_chainId', []);
    final value = _quantity(res, 'eth_chainId');
    if (value <= BigInt.zero || value.bitLength > 63) {
      throw const RpcException(
          method: 'eth_chainId', message: 'Chain ID out of supported range');
    }
    return value.toInt();
  }

  Future<int> verifyChainId(int expectedChainId) async {
    final actual = await getChainId();
    if (actual != expectedChainId) {
      throw RpcException(
        method: 'eth_chainId',
        message:
            'RPC 節點 Chain ID 不符：預期 $expectedChainId，節點回傳 $actual (Fail-Closed)',
      );
    }
    return actual;
  }

  Future<BigInt> getBalance(String address) async {
    final res = await _call('eth_getBalance', [address, 'latest']);
    return _quantity(res, 'eth_getBalance');
  }

  Future<BigInt> getErc20Balance({
    required String tokenContract,
    required String holderAddress,
  }) async {
    final cleanAddr = holderAddress
        .trim()
        .toLowerCase()
        .replaceFirst('0x', '')
        .padLeft(64, '0');
    final data = '0x70a08231$cleanAddr';
    final res = await _call('eth_call', [
      {'to': tokenContract, 'data': data},
      'latest',
    ]);
    if (res is String && res.startsWith('0x')) {
      final cleanHex = res.substring(2);
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(cleanHex)) {
        return BigInt.parse(cleanHex, radix: 16);
      }
    }
    throw const RpcException(
      method: 'eth_call(balanceOf)',
      message: 'Invalid ERC-20 balance response',
    );
  }

  Future<int> getTransactionCount(String address) async {
    final res = await _call('eth_getTransactionCount', [address, 'pending']);
    final value = _quantity(res, 'eth_getTransactionCount');
    if (value.bitLength > 63) {
      throw const RpcException(
          method: 'eth_getTransactionCount',
          message: 'Nonce out of supported range');
    }
    return value.toInt();
  }

  Future<BigInt> getGasPrice() async {
    final res = await _call('eth_gasPrice', []);
    final value = _quantity(res, 'eth_gasPrice');
    if (value == BigInt.zero) {
      throw const RpcException(
          method: 'eth_gasPrice', message: 'Gas price must be positive');
    }
    return value;
  }

  Future<BigInt> getMaxPriorityFeePerGas() async {
    final res = await _call('eth_maxPriorityFeePerGas', []);
    return _quantity(res, 'eth_maxPriorityFeePerGas');
  }

  static BigInt _quantity(dynamic value, String method) {
    if (value is! String ||
        !RegExp(r'^0x(0|[1-9a-fA-F][0-9a-fA-F]*)$').hasMatch(value)) {
      throw RpcException(method: method, message: 'Invalid RPC quantity');
    }
    final parsed = BigInt.parse(value.substring(2), radix: 16);
    if (parsed.bitLength > 256) {
      throw RpcException(
          method: method, message: 'RPC quantity exceeds uint256');
    }
    return parsed;
  }

  Future<int> estimateGas({
    required String from,
    required String to,
    BigInt? valueWei,
    String? dataHex,
  }) async {
    final txObj = <String, dynamic>{
      'from': from,
      'to': to,
    };
    if (valueWei != null && valueWei > BigInt.zero) {
      txObj['value'] = '0x${valueWei.toRadixString(16)}';
    }
    if (dataHex != null && dataHex.isNotEmpty && dataHex != '0x') {
      txObj['data'] = dataHex.startsWith('0x') ? dataHex : '0x$dataHex';
    }
    final res = await _call('eth_estimateGas', [txObj]);
    final value = _quantity(res, 'eth_estimateGas');
    if (value < BigInt.from(21000) || value > BigInt.from(500000)) {
      throw const RpcException(
          method: 'eth_estimateGas',
          message: 'Gas estimate outside supported policy range');
    }
    return value.toInt();
  }

  Future<String> sendRawTransaction(
    String signedTxHex, {
    int? expectedChainId,
    bool Function()? canDispatch,
  }) async {
    if (expectedChainId != null) {
      await verifyChainId(expectedChainId);
    }
    final formatted =
        signedTxHex.startsWith('0x') ? signedTxHex : '0x$signedTxHex';
    if (canDispatch != null && !canDispatch()) {
      throw const RpcException(
          method: 'eth_sendRawTransaction', message: '廣播授權已撤銷，交易尚未傳送');
    }
    final res = await _call('eth_sendRawTransaction', [formatted]);
    if (res is String && RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(res)) {
      return res;
    }
    throw const RpcException(
      method: 'eth_sendRawTransaction',
      message: 'Unexpected broadcast response',
    );
  }

  Future<Map<String, dynamic>?> getTransactionReceipt(String txHash) async {
    final res = await _call('eth_getTransactionReceipt', [txHash]);
    if (res is Map<String, dynamic>) {
      return res;
    }
    if (res == null) return null;
    throw const RpcException(
        method: 'eth_getTransactionReceipt', message: 'Malformed receipt');
  }

  Future<Map<String, dynamic>?> getTransactionByHash(String txHash) async {
    final res = await _call('eth_getTransactionByHash', [txHash]);
    if (res == null) return null;
    if (res is Map<String, dynamic> &&
        res['hash'] is String &&
        (res['hash'] as String).toLowerCase() == txHash.toLowerCase()) {
      return res;
    }
    throw const RpcException(
        method: 'eth_getTransactionByHash',
        message: 'Malformed transaction response');
  }

  Future<dynamic> _call(String method, List<dynamic> params) async {
    // The settings screen refuses these URLs; nothing is sent to one anyway.
    final kind = NodeUrlPolicy.classify(rpcUrl);
    if (kind == NodeUrlKind.invalid) {
      throw RpcException(method: method, message: '無效的 RPC 網址，未送出請求');
    }
    if (kind == NodeUrlKind.publicHttp) {
      throw RpcException(
          method: method, message: NodeUrlPolicy.publicHttpRefused);
    }
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    });
    late final http.Response response;
    try {
      // A redirect changes the endpoint the user authorized and can disclose
      // signed bytes or credentials. Require the configured URL to reply.
      final request = http.Request('POST', Uri.parse(rpcUrl))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = body;
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      throw RpcException(
        method: method,
        message: '無法連線至 RPC 節點',
      );
    }

    if (response.statusCode != 200) {
      throw RpcException(
        method: method,
        message: 'RPC 節點回傳 HTTP ${response.statusCode}；請確認設定的節點網址',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw RpcException(
          method: method, message: 'Malformed JSON-RPC response');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['jsonrpc'] != '2.0' ||
        decoded['id'] != 1 ||
        (!decoded.containsKey('result') && !decoded.containsKey('error'))) {
      throw RpcException(
          method: method, message: 'Malformed JSON-RPC response');
    }
    final data = decoded;
    if (data.containsKey('error') && data['error'] != null) {
      final error = data['error'];
      final code = error is Map && error['code'] is int ? error['code'] : null;
      throw RpcException(
        method: method,
        message: code == null ? 'RPC 節點拒絕請求' : 'RPC 節點拒絕請求（錯誤碼 $code）',
      );
    }
    return data['result'];
  }
}
