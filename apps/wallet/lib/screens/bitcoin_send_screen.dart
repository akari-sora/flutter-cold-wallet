import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import '../ffi/bitcoin_ffi_service.dart';
import '../services/bitcoin_rpc_client.dart';
import '../services/node_url_policy.dart';
import '../services/public_backup.dart';
import '../widgets/node_url_field.dart';

class BitcoinSendScreen extends StatefulWidget {
  final AccountDescriptor account;
  final BitcoinRpcClient? rpcOverride;
  final BitcoinFfiService? ffiOverride;
  final String? storagePathOverride;
  const BitcoinSendScreen(
      {super.key,
      required this.account,
      this.rpcOverride,
      this.ffiOverride,
      this.storagePathOverride});
  @override
  State<BitcoinSendScreen> createState() => BitcoinSendScreenState();
}

class BitcoinSendScreenState extends State<BitcoinSendScreen>
    with WidgetsBindingObserver {
  final _endpoint =
      TextEditingController(text: 'http://127.0.0.1:18443/wallet/fcw_watch');

  /// The node URL in the record file. Like the EVM settings, a URL the policy
  /// refuses is never written; the record keeps the last allowed one, or no
  /// URL when there is none (a record from before 1.2.1).
  late String _storedEndpoint = _endpoint.text;

  static bool _allowedEndpoint(String url) => const [
        NodeUrlKind.https,
        NodeUrlKind.loopbackHttp,
        NodeUrlKind.privateHttp
      ].contains(NodeUrlPolicy.classify(url));
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _fee = TextEditingController();
  final _requestQrKey = GlobalKey();
  BitcoinFfiService? _native;
  String? _storagePath;
  String? _error;
  String _status = 'draft';
  bool _busy = false;
  bool _foreground = true;
  int _generation = 0;
  Map<String, dynamic>? _request;
  Map<String, dynamic>? _built;
  Map<String, dynamic>? _verified;
  String? _responseUr;
  int? _confirmations;
  String? _checkedAt;
  List<dynamic> _history = [];

  /// Set only after the node reported that these signed bytes are neither in
  /// the mempool nor in a block. Resending the identical bytes is idempotent.
  bool _canResend = false;

  /// Set once the current send passed its last guard and may reach the node.
  bool _sendDispatched = false;

  /// Restored when leaving the app revokes a send before dispatch.
  String _statusBeforeSend = 'verified';

  /// The latest send attempt. Leaving the app retires it, so its late answer
  /// can neither change the state nor release `_busy` for a newer operation.
  int _sendAttempt = 0;

  static const _settledStates = [
    'awaitingSignature',
    'verified',
    'pending',
    'confirmed',
    'failed'
  ];

  /// A possibly sent transaction is archived only after a lookup proved the
  /// node does not have it; an uncertain send must be queried before any
  /// replacement can be created.
  bool get _archivable =>
      _settledStates.contains(_status) ||
      (_canResend && ['unknown', 'broadcasting'].contains(_status));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _generation++;
      // As on the EVM screen: a dispatched send may have reached the node and
      // its late answer is discarded, so only a lookup can settle it; a send
      // revoked before dispatch was never sent and returns to the state
      // before it. The attempt is retired and `_busy` released, so the lookup
      // can be used right after returning.
      final sending = _status == 'broadcasting';
      final dispatched = sending && _sendDispatched;
      if (sending) {
        _sendAttempt++;
        _busy = false;
        _status = dispatched ? 'unknown' : _statusBeforeSend;
        try {
          _save();
        } catch (_) {
          /* A durable `broadcasting` record reloads as unknown. */
        }
      }
      if ((_canResend || sending) && mounted) {
        setState(() {
          _canResend = false;
          if (dispatched) {
            _error = '廣播未確認：送出期間已離開前景，結果待查。請查詢同一筆交易，不要建立新請求。';
          } else if (sending && _statusBeforeSend != 'verified') {
            // A resend after a lookup; the first send is still unsettled.
            _error = '這次重新傳送沒有送出；前一次送出的結果仍待查，請再查詢同一筆交易，查無結果後才能重新傳送。';
          } else if (sending) {
            _error = '廣播尚未送出：送出前已離開前景，廣播授權已撤銷，本次未傳送交易。';
          }
        });
      } else {
        _canResend = false;
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    for (final c in [
      _endpoint,
      _username,
      _password,
      _recipient,
      _amount,
      _fee
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  BitcoinRpcClient _rpc() =>
      widget.rpcOverride ??
      BitcoinRpcClient(
          endpoint: _endpoint.text.trim(),
          username: _username.text,
          password: _password.text);

  /// True, with the reason shown, when the saved node URL is now refused.
  bool _nodeUrlRefused(String outcome) {
    final refusal = NodeUrlPolicy.savedUrlRefusal(
        widget.rpcOverride?.endpoint ?? _endpoint.text.trim(),
        settings: '節點設定',
        outcome: outcome);
    if (refusal != null) setState(() => _error = refusal);
    return refusal != null;
  }

  Future<T> _withRpc<T>(Future<T> Function(BitcoinRpcClient) action) async {
    final rpc = _rpc();
    try {
      return await action(rpc);
    } finally {
      if (widget.rpcOverride == null) rpc.close();
    }
  }

  Future<void> _initialize() async {
    try {
      _native = widget.ffiOverride ?? BitcoinFfiService();
      final directory = widget.storagePathOverride == null
          ? await const MethodChannel('fcw/platform')
              .invokeMethod<String>('storageDirectory')
          : null;
      if (!mounted) return;
      if (widget.storagePathOverride == null &&
          (directory == null || directory.isEmpty)) {
        throw StateError('無法取得永久儲存目錄');
      }
      _storagePath = widget.storagePathOverride ??
          '$directory/bitcoin_${widget.account.masterFingerprint}.json';
      final file = File(_storagePath!);
      if (file.existsSync()) {
        if (file.lengthSync() > PublicBackupCodec.maxBytes) {
          throw const FormatException('Bitcoin 紀錄超過 2 MiB，原始資料已保留');
        }
        final saved =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (![1, 2].contains(saved['schema_version']) ||
            saved['account_address'] != widget.account.address ||
            saved['master_fingerprint'] != widget.account.masterFingerprint) {
          throw const FormatException('Bitcoin 紀錄帳戶或版本不符');
        }
        _history = saved['history'] as List<dynamic>;
        if (_history.length > 1000) {
          throw const FormatException('Bitcoin 歷史超過數量限制');
        }
        // The field shows a refused URL so it can be corrected.
        _endpoint.text = saved['rpc_endpoint'] as String;
        _storedEndpoint =
            _allowedEndpoint(_endpoint.text) ? _endpoint.text : '';
        if (saved['request'] != null) {
          final recovered = _recoverBundle(saved);
          _request = recovered.request;
          _built = recovered.built;
          _responseUr = recovered.response;
          _verified = recovered.verified;
          _status = saved['state'] as String;
          _confirmations = saved['confirmations'] as int?;
          _checkedAt = saved['checked_at'] as String?;
          if (_responseUr != null) {
            if (_status == 'broadcasting' || _status == 'accepted') {
              _status = 'unknown';
            }
          } else if (_status != 'awaitingSignature') {
            throw const FormatException('交易狀態與簽章紀錄不符');
          }
        }
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {
          _storagePath = null;
          _error = 'Bitcoin 無法啟用，原始紀錄已保留：$e';
        });
      }
    }
  }

  void _save() {
    final path = _storagePath;
    if (path == null) throw StateError('尚未啟用安全的本地紀錄儲存');
    if (_history.length > 1000) {
      throw const FormatException('Bitcoin 歷史超過數量限制，原始資料未修改');
    }
    final typed = _endpoint.text.trim();
    final endpoint = _allowedEndpoint(typed) ? typed : _storedEndpoint;
    final encoded = jsonEncode({
      'schema_version': 2,
      'account_address': widget.account.address,
      'master_fingerprint': widget.account.masterFingerprint,
      'rpc_endpoint': endpoint,
      'state': _status,
      'request': _request,
      'built': _built,
      'response_ur': _responseUr,
      if (_confirmations != null) 'confirmations': _confirmations,
      if (_checkedAt != null) 'checked_at': _checkedAt,
      'history': _history
    });
    if (utf8.encode(encoded).length > PublicBackupCodec.maxBytes) {
      throw const FormatException('Bitcoin 紀錄超過 2 MiB，原始資料未修改');
    }
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(encoded, flush: true);
    tmp.renameSync(path);
    _storedEndpoint = endpoint;
  }

  ({
    Map<String, dynamic> request,
    Map<String, dynamic> built,
    String? response,
    Map<String, dynamic>? verified
  }) _recoverBundle(Map<String, dynamic> saved) {
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    if (request['account_xpub'] != widget.account.extendedPublicKey ||
        request['master_fingerprint'] != widget.account.masterFingerprint) {
      throw const FormatException('本地 PSBT 的公開帳戶不符');
    }
    final rebuilt = _native!.build(request);
    final old = saved['built'] as Map;
    if (rebuilt['status'] != 'SUCCESS' ||
        rebuilt['psbt_hex'] != old['psbt_hex'] ||
        rebuilt['expected_digest'] != old['expected_digest'] ||
        rebuilt['txid'] != old['txid']) {
      throw const FormatException('本地待簽 PSBT／帳戶資料損毀');
    }
    final response = saved['response_ur'] as String?;
    final verified =
        response == null ? null : _verifyResponse(response, rebuilt);
    return (
      request: request,
      built: rebuilt,
      response: response,
      verified: verified
    );
  }

  Map<String, dynamic> _verifyResponse(String response,
      [Map<String, dynamic>? built]) {
    final original = built ?? _built!;
    final result = _native!.verify({
      'original_psbt_hex': original['psbt_hex'],
      'expected_digest': original['expected_digest'],
      'response_ur': response
    });
    if (result['status'] != 'VERIFIED' ||
        result['tx_hex'] is! String ||
        result['txid'] is! String ||
        result['txid'] != original['txid']) {
      throw FormatException(
          '簽章未通過原始 PSBT 綁定與核心驗證：${result['error'] ?? result['error_code']}');
    }
    return result;
  }

  Future<void> syncDescriptors() async {
    if (_importBlocksPayment()) return;
    if (_nodeUrlRefused('沒有連線到節點')) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _withRpc((rpc) => rpc.importPublicDescriptors(widget.account));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已同步公開接收與找零描述；未包含任何私鑰')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _importBlocksPayment() {
    try {
      return _storagePath == null || PublicImportProgress.blocksPaymentAt(
          File(_storagePath!).parent.path, assetFamily: 'BTC',
          account: widget.account.address,
          masterFingerprint: widget.account.masterFingerprint);
    } catch (_) {
      return true;
    }
  }

  void _requireImportPaymentAllowed() {
    PublicImportProgress.requirePaymentAllowedAt(File(_storagePath!).parent.path,
        assetFamily: 'BTC', account: widget.account.address,
        masterFingerprint: widget.account.masterFingerprint);
  }

  Future<void> createRequest() async {
    if (_busy || _storagePath == null || _built != null) return;
    if (_nodeUrlRefused('未建立交易')) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _requireImportPaymentAllowed();
      final recipient = _recipient.text.trim();
      if (!recipient.startsWith('bcrt1')) {
        throw const FormatException('僅接受 Bitcoin regtest bcrt1 收款地址');
      }
      final amount = DecimalAmountParser.parseToBaseUnits(_amount.text.trim(),
          decimals: 8);
      if (amount <= BigInt.zero || amount > BigInt.from(2100000000000000)) {
        throw const FormatException('BTC 金額必須大於零且不得超過供應量');
      }
      final feeText = _fee.text.trim();
      if (!RegExp(r'^[0-9]+$').hasMatch(feeText)) {
        throw const FormatException('請明確輸入整數 sat 總手續費');
      }
      final fee = BigInt.parse(feeText);
      if (fee <= BigInt.zero || fee > BigInt.from(5000000)) {
        throw const FormatException('本版手續費必須介於 1 與 5000000 sat');
      }
      final nodeUtxos = await _withRpc((rpc) => rpc.loadUtxos(widget.account));
      if (nodeUtxos.isEmpty) {
        throw const FormatException(
            '沒有屬於此公開帳戶且已確認的可用 UTXO；請先同步公開描述並注入 regtest 測試幣');
      }
      final reserved = _reservedOutpoints();
      final utxos = nodeUtxos.where((utxo) {
        final txid = utxo['txid'];
        final vout = utxo['vout'];
        if (txid is! String || vout is! int) {
          throw const FormatException('節點回傳的 UTXO 缺少有效 outpoint');
        }
        return !reserved.contains('${txid.toLowerCase()}:$vout');
      }).toList();
      if (utxos.isEmpty) {
        throw const FormatException(
            '所有可用 UTXO 仍被先前交易保留；請恢復並核對原 PSBT，確認結算前不會重複使用相同輸入');
      }
      if (!mounted || !_foreground || generation != _generation) return;
      // One fixed change address would link every transaction of this account.
      final changeIndex =
          await _withRpc((rpc) => rpc.unusedChangeIndex(widget.account));
      if (!_currentOperation(generation)) return;
      _requireImportPaymentAllowed();
      final request = <String, dynamic>{
        'account_xpub': widget.account.extendedPublicKey,
        'master_fingerprint': widget.account.masterFingerprint,
        'recipient_address': recipient,
        'amount_sat': amount.toString(),
        'fee_sat': fee.toString(),
        'change_index': changeIndex,
        'utxos': utxos
      };
      final built = _native!.build(request);
      if (built['status'] != 'SUCCESS' ||
          built['ur_frames'] is! List ||
          (built['ur_frames'] as List).isEmpty) {
        throw FormatException(
            'PSBT 建立失敗：${built['error'] ?? built['error_code']}');
      }
      _request = request;
      _built = built;
      _status = 'awaitingSignature';
      try {
        _save();
      } catch (_) {
        _request = null;
        _built = null;
        _status = 'draft';
        rethrow;
      }
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // As on the EVM screen: reveal the whole request QR below the form, its
    // end first so a short screen does not cut off the play control.
    if (mounted && _built != null && _verified == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _requestQrKey.currentContext;
        if (!mounted || target == null) return;
        Scrollable.ensureVisible(target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      });
    }
  }

  Set<String> _reservedOutpoints() {
    final reserved = <String>{};
    for (final item in _history) {
      if (item is! Map) throw const FormatException('Bitcoin 歷史紀錄格式損毀');
      final state = item['state'];
      if (state == 'confirmed' || state == 'failed') continue;
      final recovery = item['recovery'];
      if (recovery is! Map || recovery['request'] is! Map) {
        throw const FormatException('Bitcoin 歷史缺少可核對的保留輸入');
      }
      final inputs = (recovery['request'] as Map)['utxos'];
      if (inputs is! List || inputs.isEmpty) {
        throw const FormatException('Bitcoin 歷史缺少可核對的保留輸入');
      }
      for (final input in inputs) {
        final txid = input is Map ? input['txid'] : null;
        final vout = input is Map ? input['vout'] : null;
        if (txid is! String ||
            !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(txid) ||
            vout is! int ||
            vout < 0 ||
            vout > 0xffffffff) {
          throw const FormatException('Bitcoin 歷史含無效的保留 outpoint');
        }
        reserved.add('${txid.toLowerCase()}:$vout');
      }
      final recovered = _recoverBundle(Map<String, dynamic>.from(recovery));
      final archivedTxid = item['txid'];
      final rebuiltTxid = recovered.built['txid'];
      if (archivedTxid is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(archivedTxid) ||
          rebuiltTxid is! String ||
          archivedTxid.toLowerCase() != rebuiltTxid.toLowerCase()) {
        throw const FormatException('Bitcoin 歷史的 PSBT／TXID 綁定不符');
      }
    }
    return reserved;
  }

  Future<void> ingestSignature(String response) async {
    if (_busy || !_foreground || _built == null || _verified != null) return;
    try {
      _requireImportPaymentAllowed();
      final verified = _verifyResponse(response);
      _verified = verified;
      _responseUr = response;
      _status = 'verified';
      try {
        _save();
      } catch (_) {
        _verified = null;
        _responseUr = null;
        _status = 'awaitingSignature';
        rethrow;
      }
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scanSignature() {
    if (_importBlocksPayment()) return;
    // Otherwise the last edited field regains focus when the scanner pops.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AirGapScanner(
            expectedType: 'crypto-psbt',
            title: '掃描 Vault 已簽 Bitcoin PSBT',
            onOpenAppSettings: defaultTargetPlatform == TargetPlatform.android
                ? () => const MethodChannel('fcw/platform')
                    .invokeMethod<void>('openAppSettings')
                : null,
            onPayloadComplete: (_) {},
            onRawUrComplete: (ur) {
              Navigator.of(context).pop();
              ingestSignature(ur);
            })));
  }

  Future<void> broadcast() async {
    if (_importBlocksPayment()) return;
    final resend = _status != 'verified';
    if (_busy || !_foreground || _verified == null || (resend && !_canResend)) {
      return;
    }
    if (_nodeUrlRefused('未傳送交易')) return;
    final generation = _generation;
    final verified = _verified!;
    final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(resend
                    ? '重新傳送同一筆已簽交易至 Bitcoin regtest'
                    : '確認廣播至 Bitcoin regtest'),
                content: Text(
                    '收款：${_built!['recipient_address']}\n金額：${_built!['amount_sat']} sat\n手續費：${_built!['fee_sat']} sat\nTXID：${_verified!['txid']}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('確認廣播'))
                ]));
    if (_importBlocksPayment() || approved != true ||
        !_currentOperation(generation) ||
        !identical(verified, _verified) ||
        _busy ||
        (resend && !_canResend)) {
      return;
    }
    final previousStatus = _status;
    final attempt = ++_sendAttempt;
    setState(() {
      _busy = true;
      _error = null;
      _canResend = false;
    });
    try {
      _status = 'broadcasting';
      _statusBeforeSend = previousStatus;
      _sendDispatched = false;
      _save();
      final hash = await _withRpc((rpc) => rpc.broadcast(
              verified['tx_hex'] as String, canDispatch: () {
            // A retired attempt must not mark a newer send as dispatched.
            if (_importBlocksPayment() || attempt != _sendAttempt ||
                !_currentOperation(generation) ||
                !identical(verified, _verified)) {
              return false;
            }
            return _sendDispatched = true;
          }));
      if (!_currentOperation(generation) || !identical(verified, _verified)) {
        return;
      }
      if (hash != verified['txid']) {
        throw const BitcoinRpcException('節點回傳 TXID 與本地交易不符，結果待查',
            uncertain: true);
      }
      _status = 'accepted';
      _save();
      if (mounted) setState(() {});
      await _lookupCurrentStatus(generation, verified);
    } catch (e) {
      // Leaving the app has already settled a retired attempt.
      if (attempt != _sendAttempt ||
          !_currentOperation(generation) ||
          !identical(verified, _verified)) {
        return;
      }
      if (e is BitcoinRpcException && e.notSent) {
        // Nothing reached the node: return to the state before this attempt.
        _status = previousStatus;
        try {
          _save();
        } catch (_) {
          /* A durable `broadcasting` reloads as unknown, then lookup allows resend. */
        }
        setState(() => _error = '廣播尚未送出：$e');
        return;
      }
      // Every send error requires a lookup of these same bytes before another send.
      _status = 'unknown';
      try {
        _save();
      } catch (_) {
        /* Previous durable broadcasting state remains query-only on restart. */
      }
      if (mounted) setState(() => _error = '廣播未確認：$e。請查詢同一筆交易，不要建立新請求。');
    } finally {
      if (mounted && attempt == _sendAttempt) setState(() => _busy = false);
    }
  }

  Future<void> checkStatus() async {
    if (_busy || !_foreground || _verified == null) return;
    if (_nodeUrlRefused('未查詢交易')) return;
    final generation = _generation;
    final verified = _verified!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _lookupCurrentStatus(generation, verified);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _currentOperation(int generation) =>
      mounted && _foreground && generation == _generation;

  /// `getrawtransaction <txid> true` omits `confirmations` while the
  /// transaction is still in the mempool; only a present non-integer is malformed.
  static int _confirmationCount(Map<String, dynamic> result) {
    if (!result.containsKey('confirmations')) return 0;
    final confirmations = result['confirmations'];
    if (confirmations is! int) throw const FormatException('節點未回傳有效確認數');
    return confirmations;
  }

  static const _inconclusiveMessage =
      '此節點無法證明交易不存在（可能未啟用 txindex 或索引尚未完成），結果仍待查；請改用已同步 txindex 的節點查詢同一筆交易。';

  static const _notFoundMessage =
      '節點查無此交易（不在 mempool 也不在區塊）。核對後可重新傳送同一筆已簽交易，不需重新簽署。';

  Future<void> _lookupCurrentStatus(
      int generation, Map<String, dynamic> verified) async {
    final endpoint = _endpoint.text.trim();
    _canResend = false;
    try {
      final result = await _withRpc(
          (rpc) => rpc.transactionStatus(verified['txid'] as String));
      if (!_currentOperation(generation) ||
          !identical(verified, _verified) ||
          endpoint != _endpoint.text.trim()) {
        return;
      }
      final confirmations = _confirmationCount(result);
      final previousStatus = _status;
      final previousConfirmations = _confirmations;
      final previousCheckedAt = _checkedAt;
      _confirmations = confirmations;
      _checkedAt = DateTime.now().toUtc().toIso8601String();
      _status = confirmations < 0
          ? 'failed'
          : confirmations > 0
              ? 'confirmed'
              : 'pending';
      try {
        _save();
      } catch (_) {
        _status = previousStatus;
        _confirmations = previousConfirmations;
        _checkedAt = previousCheckedAt;
        rethrow;
      }
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (_currentOperation(generation) &&
          identical(verified, _verified) &&
          endpoint == _endpoint.text.trim()) {
        if (e is BitcoinRpcException && e.transactionNotFound) {
          setState(() {
            _canResend = _status != 'verified';
            _error = _notFoundMessage;
          });
        } else if (e is BitcoinRpcException && e.lookupInconclusive) {
          setState(() => _error = _inconclusiveMessage);
        } else {
          setState(() => _error = '同一筆交易結果待查：$e');
        }
      }
    }
  }

  void newDraft() {
    if (_busy || !_foreground || _built == null || !_archivable) {
      return;
    }
    if (_importBlocksPayment()) {
      try {
        _reservedOutpoints();
        for (final item in _history) {
          final recovery = item['recovery'];
          if (recovery is! Map || recovery['request'] is! Map ||
              (recovery['request'] as Map)['utxos'] is! List ||
              ((recovery['request'] as Map)['utxos'] as List).isEmpty) {
            throw const FormatException('歷史紀錄缺少可核對的保留輸入');
          }
          // Even settled rows must be checked before preserving all inputs.
          final archived = _recoverBundle(Map<String, dynamic>.from(recovery));
          if (item['txid'] != archived.built['txid']) {
            throw const FormatException('歷史 PSBT／TXID 綁定不符');
          }
          for (final input in (recovery['request'] as Map)['utxos'] as List) {
            if (input is! Map || input['txid'] is! String ||
                !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(input['txid'] as String) ||
                input['vout'] is! int || (input['vout'] as int) < 0 ||
                (input['vout'] as int) > 0xffffffff) {
              throw const FormatException('歷史紀錄含無效的保留 outpoint');
            }
          }
        }
        if (_request == null || _built == null) {
          throw const FormatException('缺少完整原始請求');
        }
        final inputs = _request!['utxos'];
        if (inputs is! List || inputs.isEmpty || inputs.any((input) =>
            input is! Map || input['txid'] is! String ||
            !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(input['txid'] as String) ||
            input['vout'] is! int || (input['vout'] as int) < 0 ||
            (input['vout'] as int) > 0xffffffff)) {
          throw const FormatException('缺少可核對的保留輸入');
        }
        final recovered = _recoverBundle({'request': _request, 'built': _built,
          'response_ur': _responseUr});
        final txid = recovered.built['txid'];
        if (txid is! String || _history.any((item) =>
            item['txid'] is String &&
            (item['txid'] as String).toLowerCase() == txid.toLowerCase())) {
          throw const FormatException('相同 TXID 的紀錄無法安全合併');
        }
      } catch (e) {
        setState(() => _error = '無法安全封存原交易：$e');
        return;
      }
    }
    final previousHistory = [..._history];
    final request = _request;
    final built = _built;
    final response = _responseUr;
    final verified = _verified;
    final status = _status;
    final record = <String, dynamic>{
      'txid': verified?['txid'] ?? built?['txid'],
      // Only never-sent bundles are cancelled; anything that may have reached
      // the network keeps an honest pending/unknown state for later lookup.
      'state': switch (status) {
        'confirmed' || 'failed' || 'pending' => status,
        'awaitingSignature' || 'verified' => status,
        _ => 'unknown',
      },
      'amount_sat': built?['amount_sat'],
      'recipient_address': built?['recipient_address'],
      'recovery': {'request': request, 'built': built, 'response_ur': response},
      if (_confirmations != null) 'confirmations': _confirmations,
      if (_checkedAt != null) 'checked_at': _checkedAt,
    };
    final previousIndex =
        _history.indexWhere((item) => item['txid'] == record['txid']);
    if (previousIndex < 0) {
      _history = [..._history, record];
    } else {
      final previous = _history[previousIndex] as Map;
      final recovery = previous['recovery'] as Map?;
      // Rebuilding still-unspent inputs can reproduce the same TXID. Keep the
      // original complete bundle when a later unsigned draft is archived.
      final possiblySent =
          record['state'] == 'unknown' || record['state'] == 'pending';
      final retained = recovery?['response_ur'] != null
          ? {
              ...previous,
              if (_checkedAt != null) ...{
                'state': record['state'],
                'confirmations': _confirmations,
                'checked_at': _checkedAt,
              } else if (possiblySent)
                'state': record['state'],
            }
          : record;
      _history = [..._history]..[previousIndex] = retained;
    }
    _request = null;
    _built = null;
    _verified = null;
    _responseUr = null;
    _status = 'draft';
    _confirmations = null;
    _checkedAt = null;
    _canResend = false;
    _generation++;
    try {
      _save();
      // A new draft starts empty: a stale recipient is a mis-send risk.
      _recipient.clear();
      _amount.clear();
      _fee.clear();
      setState(() => _error = null);
    } catch (e) {
      _history = previousHistory;
      _request = request;
      _built = built;
      _responseUr = response;
      _verified = verified;
      _status = status;
      _confirmations = record['confirmations'] as int?;
      _checkedAt = record['checked_at'] as String?;
      setState(() => _error = '紀錄儲存失敗：$e');
    }
  }

  void restoreHistory(int index) {
    if (_importBlocksPayment() || _busy || !_foreground || _built != null) return;
    try {
      final row = _history[index] as Map;
      if (row['recovery'] == null) {
        throw const FormatException('舊摘要沒有原始 PSBT；仍可查詢此 TXID');
      }
      final recovered =
          _recoverBundle(Map<String, dynamic>.from(row['recovery'] as Map));
      if (recovered.built['txid'] != row['txid']) {
        throw const FormatException('封存交易 TXID 不符');
      }
      _request = recovered.request;
      _built = recovered.built;
      _responseUr = recovered.response;
      _verified = recovered.verified;
      // Restored signed bytes are lookup-only; restoring never sends a transaction.
      _status = _verified == null ? 'awaitingSignature' : 'unknown';
      _canResend = false;
      _generation++;
      try {
        _save();
      } catch (_) {
        _request = null;
        _built = null;
        _responseUr = null;
        _verified = null;
        _status = 'draft';
        rethrow;
      }
      setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = '無法恢復交易：$e');
    }
  }

  Future<void> checkArchivedStatus(int index) async {
    if (_busy || !_foreground) return;
    final generation = _generation;
    final record = _history[index];
    final txid = record['txid'];
    if (txid is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(txid)) return;
    if (_nodeUrlRefused('未查詢交易')) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _withRpc((rpc) => rpc.transactionStatus(txid));
      if (!_currentOperation(generation) ||
          !identical(_history[index], record)) {
        return;
      }
      final confirmations = _confirmationCount(result);
      final previous = _history;
      _history = [..._history];
      _history[index] = {
        ...Map<String, dynamic>.from(record as Map),
        'state': confirmations < 0
            ? 'failed'
            : confirmations > 0
                ? 'confirmed'
                : 'pending',
        'confirmations': confirmations,
        'checked_at': DateTime.now().toUtc().toIso8601String()
      };
      try {
        _save();
      } catch (_) {
        _history = previous;
        rethrow;
      }
      setState(() {});
    } catch (e) {
      if (_currentOperation(generation)) {
        setState(
            () => _error = e is BitcoinRpcException && e.transactionNotFound
                ? '封存交易查詢：節點查無此交易（不在 mempool 也不在區塊）。'
                : e is BitcoinRpcException && e.lookupInconclusive
                    ? '封存交易查詢：$_inconclusiveMessage'
                    : '封存交易查詢失敗：$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _statusText =>
      const {
        'draft': '草稿',
        'awaitingSignature': '待離線簽章',
        'verified': '簽章已驗證，尚未廣播',
        'broadcasting': '廣播中',
        'accepted': '節點已接受，尚未確認',
        'pending': '待確認',
        'confirmed': '已確認',
        'unknown': '結果待查',
        'failed': '執行失敗'
      }[_status] ??
      '未知狀態';
  FcwTone get _statusTone => switch (_status) {
        'confirmed' => FcwTone.success,
        'pending' || 'broadcasting' || 'verified' => FcwTone.info,
        'unknown' => FcwTone.warning,
        'failed' => FcwTone.danger,
        _ => FcwTone.neutral,
      };

  IconData get _statusIcon => switch (_status) {
        'confirmed' => Icons.check_circle_outline,
        'pending' || 'broadcasting' => Icons.schedule,
        'verified' => Icons.verified_outlined,
        'awaitingSignature' => Icons.qr_code_2,
        'unknown' => Icons.help_outline,
        'failed' => Icons.error_outline,
        _ => Icons.edit_note,
      };

  @override
  Widget build(BuildContext context) {
    final enabled = !_busy && _storagePath != null;
    final paymentEnabled = enabled && !_importBlocksPayment();
    final theme = Theme.of(context);
    final palette = FcwPalette.resolve(context);
    final statusColors = palette.of(_statusTone);
    return Scaffold(
      appBar: AppBar(title: const Text('BTC 轉帳')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.account.label, style: theme.textTheme.titleLarge),
                  const SizedBox(height: FcwSpace.sm),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: FcwStatusPill('Bitcoin regtest',
                        tone: FcwTone.info, icon: Icons.currency_bitcoin),
                  ),
                  const SizedBox(height: FcwSpace.lg),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: statusColors.container,
                      borderRadius: BorderRadius.circular(FcwRadius.card),
                    ),
                    child: Padding(
                        padding: const EdgeInsets.all(FcwSpace.lg),
                        child: Row(children: [
                          Icon(_statusIcon,
                              size: 24, color: statusColors.onContainer),
                          const SizedBox(width: FcwSpace.md),
                          Expanded(
                            child: Text('交易狀態：$_statusText',
                                key: const Key('btc_state'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                    color: statusColors.onContainer)),
                          ),
                        ])),
                  ),
                  if (_storagePath != null && _importBlocksPayment())
                    const Padding(
                      padding: EdgeInsets.only(top: FcwSpace.md),
                      child: FcwBanner(tone: FcwTone.warning,
                          message: '公開備份還原尚未完成；此帳戶的新付款與簽章暫停，仍可查詢或安全封存原交易。離開或暫停不會解除付款保留。'),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: FcwSpace.md),
                      child: FcwBanner(
                        tone: FcwTone.danger,
                        content: SelectableText(_error!,
                            key: const Key('btc_error')),
                      ),
                    ),
                  if (_busy || (_storagePath == null && _error == null))
                    const Padding(
                      padding: EdgeInsets.only(top: FcwSpace.md),
                      child: LinearProgressIndicator(),
                    ),
                  const SizedBox(height: FcwSpace.xl),
                  if (_built == null) ...[
                    TextField(
                        key: const Key('btc_recipient'),
                        controller: _recipient,
                        style: fcwMono(Theme.of(context).textTheme.bodyLarge),
                        enabled: enabled,
                        maxLines: null,
                        decoration: const InputDecoration(
                            labelText: '收款地址',
                            helperText: 'Bitcoin regtest 地址，以 bcrt1 開頭')),
                    const SizedBox(height: 20),
                    TextField(
                        key: const Key('btc_amount'),
                        controller: _amount,
                        enabled: enabled,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: '金額',
                            suffixText: 'BTC',
                            helperText: '最多 8 位小數')),
                    const SizedBox(height: 20),
                    TextField(
                        key: const Key('btc_fee'),
                        controller: _fee,
                        enabled: enabled,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: '總手續費',
                            suffixText: 'sat',
                            helperText: '請明確設定，此值不是節點估算')),
                    const SizedBox(height: 24),
                  ],
                  FcwPanel(
                    padding:
                        const EdgeInsets.symmetric(horizontal: FcwSpace.md),
                    child: ExpansionTile(
                      key: const Key('btc_node_settings_toggle'),
                      maintainState: true,
                      leading: const Icon(Icons.dns_outlined),
                      title: const Text('節點設定'),
                      subtitle: const Text('Bitcoin Core 觀察錢包'),
                      children: [
                        NodeUrlField(
                            fieldKey: const Key('btc_rpc_endpoint'),
                            controller: _endpoint,
                            enabled: enabled,
                            bitcoin: true),
                        const SizedBox(height: 20),
                        TextField(
                            controller: _username,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                                labelText: 'RPC 使用者名稱', helperText: '僅留於記憶體')),
                        const SizedBox(height: 20),
                        TextField(
                            controller: _password,
                            enabled: !_busy,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: const InputDecoration(
                                labelText: 'RPC 密碼', helperText: '僅留於記憶體')),
                        const SizedBox(height: 16),
                        const Text(
                            '節點需啟用 txindex，RPC 錢包需 disable_private_keys。僅支援 PSBT v0、P2WPKH 與 SIGHASH_ALL。'),
                        const SizedBox(height: 16),
                        if (_built == null)
                          OutlinedButton(
                              onPressed: paymentEnabled ? syncDescriptors : null,
                              child: const Text('驗證節點並同步公開帳戶')),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                  if (_built == null) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                        key: const Key('btc_create'),
                        onPressed: paymentEnabled ? createRequest : null,
                        child: const Text('建立待簽交易')),
                    const SizedBox(height: 12),
                    Text('輸入會由原始前置交易獨立驗證，找零返回此公開帳戶。',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ] else ...[
                    const SizedBox(height: FcwSpace.xl),
                    Text('交易內容', style: theme.textTheme.titleLarge),
                    const SizedBox(height: FcwSpace.md),
                    FcwPanel(
                      child: SelectableText(
                          '收款：${_built!['recipient_address']}\n金額：${_built!['amount_sat']} sat\n找零：${_built!['change_address']}\n找零金額：${_built!['change_sat']} sat\n手續費：${_built!['fee_sat']} sat\n本地摘要：${_built!['expected_digest']}',
                          style: fcwFigures(theme.textTheme.bodyMedium)
                              .copyWith(height: 1.7)),
                    ),
                    const SizedBox(height: FcwSpace.xl),
                    if (_verified == null && !_importBlocksPayment()) ...[
                      AnimatedFountainQr(
                          key: _requestQrKey,
                          frames:
                              List<String>.from(_built!['ur_frames'] as List),
                          title: '交給 Vault 簽署',
                          subtitle: 'Bitcoin regtest 待簽交易'),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        key: const Key('btc_request_text_toggle'),
                        tilePadding: EdgeInsets.zero,
                        title: const Text('請求資料'),
                        children: [
                          SelectableText(
                            List<String>.from(_built!['ur_frames'] as List)
                                .join('\n'),
                            key: const Key('btc_request_ur_text'),
                            style: fcwMono(theme.textTheme.bodySmall),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                          onPressed: paymentEnabled ? _scanSignature : null,
                          child: const Text('掃描簽署結果')),
                    ] else if (_verified != null) ...[
                      FcwPanel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText('已驗證 TXID：${_verified!['txid']}',
                                style: fcwMono(theme.textTheme.bodyMedium)),
                            if (_confirmations != null) ...[
                              const SizedBox(height: FcwSpace.sm),
                              Text(
                                  '確認數：$_confirmations · 最後查詢：${_checkedAt ?? ''}',
                                  style: fcwFigures(theme.textTheme.bodySmall)
                                      .copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant)),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: FcwSpace.lg),
                      if ((_status == 'verified' || _canResend) && !_importBlocksPayment())
                        FilledButton(
                            key: const Key('btc_broadcast'),
                            onPressed: enabled ? broadcast : null,
                            child: Text(_status == 'verified'
                                ? '確認並廣播交易'
                                : '確認重新傳送同一筆已簽交易')),
                      const SizedBox(height: 12),
                      OutlinedButton(
                          onPressed: enabled ? checkStatus : null,
                          child: const Text('查詢交易與確認數')),
                    ],
                    if (_archivable) ...[
                      const SizedBox(height: FcwSpace.lg),
                      Text(
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          [
                            'awaitingSignature',
                            'verified',
                            'confirmed',
                            'failed'
                          ].contains(_status)
                              ? '停止本機流程不會撤銷已產生的簽章。封存會保留公開請求與回傳，供日後恢復或查詢。'
                              : '此交易可能已送出。封存只停止本機流程並保留公開請求與回傳；之後請以「查詢此 TXID」核對，勿用相同輸入另建交易。'),
                      TextButton(
                        key: const Key('btc_archive'),
                        onPressed: enabled ? newDraft : null,
                        child: Text(
                            _status == 'confirmed' || _status == 'failed'
                                ? '封存並建立下一筆交易'
                                : '封存並停止本機流程'),
                      ),
                    ],
                  ],
                  const SizedBox(height: FcwSpace.xxl),
                  Text('本機交易紀錄', style: theme.textTheme.titleLarge),
                  const SizedBox(height: FcwSpace.xs),
                  Text('此 Wallet 建立的交易；不代表完整鏈上歷史。',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: FcwSpace.md),
                  if (_history.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('尚無本機歷史紀錄')),
                  ..._history.asMap().entries.toList().reversed.map((entry) {
                    final item = entry.value;
                    final state = item['state'];
                    final tone = switch (state) {
                      'confirmed' => FcwTone.success,
                      'pending' => FcwTone.info,
                      'failed' => FcwTone.danger,
                      'cancelled' => FcwTone.neutral,
                      _ => FcwTone.warning,
                    };
                    return Padding(
                        padding: const EdgeInsets.only(bottom: FcwSpace.md),
                        child: FcwPanel(
                            padding: const EdgeInsets.fromLTRB(FcwSpace.lg,
                                FcwSpace.md, FcwSpace.lg, FcwSpace.sm),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                        switch (state) {
                                          'confirmed' =>
                                            Icons.check_circle_outline,
                                          'pending' => Icons.schedule,
                                          'failed' => Icons.error_outline,
                                          'cancelled' => Icons.block_outlined,
                                          _ => Icons.help_outline,
                                        },
                                        color: palette.of(tone).accent),
                                    title: Text('${const {
                                          'confirmed': '已確認',
                                          'failed': '執行失敗',
                                          'pending': '待確認',
                                          'cancelled': '已取消'
                                        }[item['state']] ?? '紀錄狀態待查'} · ${item['amount_sat']} sat'),
                                    subtitle: Text(
                                        style:
                                            fcwMono(theme.textTheme.bodySmall)
                                                .copyWith(
                                                    color: theme.colorScheme
                                                        .onSurfaceVariant),
                                        '${item['txid']}\n${item['recipient_address']}'
                                        '${item['confirmations'] == null ? '' : '\n確認數：${item['confirmations']}'}'
                                        '${item['checked_at'] == null ? '' : '\n最後查詢：${item['checked_at']}'}'),
                                  ),
                                  if (item['recovery'] == null)
                                    const Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 16),
                                        child: Text(
                                            '舊摘要僅支援查詢 TXID；缺少原始 PSBT，無法接回簽章。')),
                                  Wrap(spacing: 12, children: [
                                    if (item['recovery'] != null)
                                      TextButton(
                                          onPressed: paymentEnabled && _built == null
                                              ? () => restoreHistory(entry.key)
                                              : null,
                                          child: const Text('恢復公開請求')),
                                    TextButton(
                                        onPressed: enabled
                                            ? () =>
                                                checkArchivedStatus(entry.key)
                                            : null,
                                        child: const Text('查詢此 TXID')),
                                  ]),
                                ])));
                  }),
                ]),
          ),
        ),
      ),
    );
  }
}
