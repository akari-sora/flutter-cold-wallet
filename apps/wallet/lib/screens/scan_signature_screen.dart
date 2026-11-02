import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:design_system/design_system.dart';
import '../widgets/outcome_style.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import '../ffi/wallet_ffi_service.dart';
import '../services/node_rpc_client.dart';
import '../services/node_url_policy.dart';
import '../services/transaction_history.dart';
import '../services/public_backup.dart';

class ScanSignatureScreen extends StatefulWidget {
  final AccountDescriptor account;
  final String sessionId;
  final String requestId;
  final String unsignedRlpHex;
  final bool isPsbt;
  final WalletFfiService? ffiOverride;
  final NodeRpcClient? rpcOverride;
  final TransactionHistory? historyOverride;
  final Map<String, dynamic>? restoredRecord;
  const ScanSignatureScreen(
      {super.key,
      required this.account,
      this.sessionId = 'default-session',
      this.requestId = '',
      required this.unsignedRlpHex,
      this.isPsbt = false,
      this.ffiOverride,
      this.rpcOverride,
      this.historyOverride,
      this.restoredRecord});
  @override
  State<ScanSignatureScreen> createState() => ScanSignatureScreenState();
}

class ScanSignatureScreenState extends State<ScanSignatureScreen>
    with WidgetsBindingObserver {
  WalletFfiService? _ffi;
  late final NodeRpcClient _rpc;
  late final TransactionHistory _history;
  Map<String, dynamic>? _verified;
  Map<String, dynamic>? _intent;
  Map<String, dynamic>? _receipt;
  String? _error;
  String? _signatureUr;
  String _state = 'awaitingSignature';
  bool _busy = false;
  String? _importDirectory;
  bool _canResend = false;

  /// Set once the current send passed its last guard and may reach the node.
  bool _sendDispatched = false;

  /// Restored when leaving the foreground revokes a send before dispatch.
  String _stateBeforeSend = 'verified';
  bool _foreground = true;

  /// Set while the scanner's camera start is asking for the camera permission.
  bool _askingForCamera = false;
  bool _pendingRegistered = true;
  bool _recoveryEligible = false;
  bool _requiresRecoveryConfirmation = false;
  UrQrPayload? _originalRequestQr;
  int _generation = 0;
  late final Map<String, dynamic>? _restoredRecord;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rpc = widget.rpcOverride ?? NodeRpcClient();
    _history = widget.historyOverride ?? TransactionHistory();
    _loadImportDirectory();
    _restoredRecord = widget.restoredRecord == null
        ? null
        : Map<String, dynamic>.unmodifiable(widget.restoredRecord!);
    if (_restoredRecord != null) _pendingRegistered = false;
    try {
      _ffi = widget.ffiOverride ?? WalletFfiService();
      _intent = _ffi!.decodeIntentJson(
          rawRlpHex: widget.unsignedRlpHex,
          declaredChainId: widget.account.chainId);
      if (_intent == null) throw const FormatException('無法解析本地原始交易');
      if (widget.isPsbt) throw const FormatException('Bitcoin 簽章回傳請求綁定尚未完成');
      if (_restoredRecord != null) _restore();
    } catch (e) {
      _error = '$e';
    }
  }

  Future<void> _loadImportDirectory() async {
    try {
      final path = _history.pathOverride;
      final directory = path != null ? File(path).parent.path :
          await const MethodChannel('fcw/platform')
              .invokeMethod<String>('storageDirectory');
      if (directory == null || directory.isEmpty) return;
      if (mounted) setState(() => _importDirectory = directory);
    } catch (_) {
      // Missing storage information must not authorize a payment.
    }
  }

  bool _importBlocksPayment() {
    try {
      return _importDirectory == null || PublicImportProgress.blocksPaymentAt(
          _importDirectory!, assetFamily: 'EVM', account: widget.account.address,
          chainId: widget.account.chainId);
    } catch (_) {
      return true;
    }
  }

  /// A record bound to a public http:// node, which the URL policy now
  /// refuses, may move to the compliant RPC configured now, as one restored
  /// from a public backup does: only after that node reports the record's
  /// chain, keeping the original payload, signature and account.
  bool get _movesFromRefusedUrl {
    final saved = _restoredRecord?['rpcUrl'];
    return saved is String &&
        saved != _rpc.rpcUrl &&
        NodeUrlPolicy.classify(saved) == NodeUrlKind.publicHttp &&
        const [
          NodeUrlKind.https,
          NodeUrlKind.loopbackHttp,
          NodeUrlKind.privateHttp
        ]
            .contains(NodeUrlPolicy.classify(_rpc.rpcUrl));
  }

  void _validateRestoredBinding({required bool unsigned}) {
    final record = _restoredRecord!;
    if (record['derivationPath'] is! String ||
        record['masterFingerprint'] is! String) {
      throw const FormatException('舊交易缺少原始派生身分，本版本無法安全恢復或確認其結果；原紀錄與付款保留不會解除。請勿清除紀錄或另建同一筆付款。');
    }
    if (record['derivationPath'] != widget.account.derivationPath ||
        (record['masterFingerprint'] as String).toLowerCase() !=
            widget.account.masterFingerprint.toLowerCase() ||
        (record['compressedPublicKeyHex'] as String?)?.toLowerCase() !=
            widget.account.compressedPublicKeyHex?.toLowerCase()) {
      throw const FormatException('原始派生身分與目前帳戶不符，原交易已保留待核對');
    }
    if (record['account'] is! String ||
        (record['account'] as String).toLowerCase() !=
            widget.account.address.toLowerCase() ||
        record['chainId'] != widget.account.chainId ||
        record['requestId'] != widget.requestId ||
        record['unsignedPayload'] != widget.unsignedRlpHex ||
        (record['sessionId'] != null &&
            record['sessionId'] != widget.sessionId) ||
        record['rpcUrl'] is! String ||
        (record['rpcUrl'] != '' &&
            record['rpcUrl'] != _rpc.rpcUrl &&
            !_movesFromRefusedUrl)) {
      throw const FormatException('原始請求、帳戶、網路或 RPC 已變更，拒絕重播');
    }
    if (unsigned &&
        (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(widget.requestId) ||
            widget.sessionId.isEmpty ||
            record['sessionId'] != widget.sessionId ||
            record['signedRaw'] != null ||
            record['hash'] != null ||
            !((['awaitingSignature', 'cancelled'].contains(record['state']) &&
                    record['rpcUrl'] != '') ||
                (record['state'] == 'unknown' && record['rpcUrl'] == '')))) {
      throw const FormatException('原始待簽紀錄不完整，無法接收既有簽章');
    }
  }

  Map<String, dynamic> _registerOriginalPending() {
    _ffi!.cancelPendingSession(widget.sessionId);
    final registered = _ffi!.buildEthSignRequestUr(
        sessionId: widget.sessionId,
        requestIdHex: widget.requestId,
        rawTxHex: widget.unsignedRlpHex,
        chainId: widget.account.chainId,
        derivationPath: widget.account.derivationPath,
        masterFingerprintHex: widget.account.masterFingerprint,
        expectedAddress: widget.account.address);
    if (registered['status'] != 'PENDING_REGISTERED') {
      throw StateError('${registered['error'] ?? '原生請求綁定失敗'}');
    }
    _pendingRegistered = true;
    return registered;
  }

  Future<void> _restore() async {
    final record = _restoredRecord!;
    final generation = _generation;
    _busy = true;
    try {
      final unsigned = record['signatureUr'] == null;
      _validateRestoredBinding(unsigned: unsigned);
      if (unsigned) {
        _state = record['state'] as String;
        _recoveryEligible = true;
        _requiresRecoveryConfirmation = true;
        return;
      }
      if (record['signatureUr'] is! String ||
          (record['signatureUr'] as String).isEmpty) {
        throw const FormatException('已儲存簽章格式錯誤');
      }
      if (record['rpcUrl'] == '' || _movesFromRefusedUrl) {
        final refusal = NodeUrlPolicy.savedUrlRefusal(_rpc.rpcUrl,
            settings: '網路與節點設定', outcome: '沒有連線到節點');
        if (refusal != null) {
          _error = refusal;
          return;
        }
        await _rpc.verifyChainId(widget.account.chainId);
        if (!mounted || !_foreground || generation != _generation) return;
      }
      if (!mounted || !_foreground || generation != _generation) return;
      _registerOriginalPending();
      _busy = false;
      await ingestSignatureUr(record['signatureUr'] as String, persist: false);
      if (_verified == null) return;
      if (_verified!['signed_raw_tx_hex'] != record['signedRaw'] ||
          _verified!['local_tx_hash'] != record['hash']) {
        throw const FormatException('已儲存簽章／交易不一致');
      }
      if (mounted && generation == _generation) {
        setState(() {
          _state = record['state'] == 'verified' && record['rpcUrl'] != ''
              ? 'verified'
              : 'unknown';
          _busy = true;
        });
        if (!_importBlocksPayment()) await _history.save(_record);
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _verified = null;
          _error = '無法還原交易：$e';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmExistingSignatureRecovery(
      {bool showOriginalRequest = false}) async {
    if (_importBlocksPayment() || _busy ||
        !_foreground ||
        !_recoveryEligible ||
        !_requiresRecoveryConfirmation) {
      return;
    }
    if (_nodeUrlRefused('沒有連線到節點')) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _validateRestoredBinding(unsigned: true);
      await _rpc.verifyChainId(widget.account.chainId);
      if (!mounted || !_foreground || generation != _generation) return;
      if (_importBlocksPayment()) return;
      final registered = _registerOriginalPending();
      if (showOriginalRequest) {
        final frames = registered['fountain_frames'];
        final single = registered['ur_single'];
        final payload = UrQrPayload(
            singleUr: single is String ? single : null,
            frames: frames is List ? frames.cast<String>() : const []);
        if (registered['request_id'] is! String ||
            (registered['request_id'] as String).toLowerCase() !=
                widget.requestId.toLowerCase() ||
            payload.displayFrames().isEmpty) {
          _ffi!.cancelPendingSession(widget.sessionId);
          _pendingRegistered = false;
          throw const FormatException('原生核心未傳回綁定原請求的有效 QR');
        }
        _originalRequestQr = payload;
      }
      _requiresRecoveryConfirmation = false;
    } catch (e) {
      if (mounted && generation == _generation) {
        _error = '無法接收原請求簽章：$e';
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant ScanSignatureScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestId != widget.requestId ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.unsignedRlpHex != widget.unsignedRlpHex ||
        oldWidget.account.address != widget.account.address ||
        oldWidget.account.chainId != widget.account.chainId ||
        oldWidget.account.derivationPath != widget.account.derivationPath ||
        oldWidget.account.masterFingerprint !=
            widget.account.masterFingerprint ||
        oldWidget.account.compressedPublicKeyHex !=
            widget.account.compressedPublicKeyHex ||
        oldWidget.rpcOverride?.rpcUrl != widget.rpcOverride?.rpcUrl) {
      _generation++;
      _ffi?.cancelPendingSession(oldWidget.sessionId);
      _pendingRegistered = false;
      _recoveryEligible = false;
      _requiresRecoveryConfirmation = false;
      _originalRequestQr = null;
      _verified = null;
      _busy = false;
      _error = '帳戶、網路或原始請求已變更，請返回本機交易紀錄重新核對。';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The scanner's camera permission request puts a system dialog over the
    // app, which only makes it inactive; that must not revoke the receive
    // authorization it is scanning for. Any other loss of focus still revokes.
    if (state == AppLifecycleState.inactive &&
        _verified == null &&
        _askingForCamera) {
      return;
    }
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground && _verified != null) {
      _generation++;
      // A dispatched send may already have reached the node and its late
      // response is discarded, so only a lookup can settle the outcome. A send
      // revoked before dispatch was never sent and returns to its previous
      // state, so it can be sent again after returning.
      final sending = _state == 'broadcasting';
      final interruptedSend = sending && _sendDispatched;
      if (sending) {
        _state = interruptedSend ? 'unknown' : _stateBeforeSend;
        _history.save(_record).catchError((Object _) {
          /* A durable `broadcasting` record also restores as unknown. */
        });
      }
      if (!mounted) {
        _foreground = false;
        return;
      }
      setState(() {
        _foreground = false;
        _busy = false;
        _canResend = false;
        if (interruptedSend) {
          _error = '廣播未確認：送出期間已離開前景，結果待查。請查詢同一筆交易，不要建立新請求。';
        } else if (sending && _stateBeforeSend == 'unknown') {
          // A resend after a lookup; the first send is still unsettled.
          _error = '這次重新傳送沒有送出；前一次送出的結果仍待查，請再查詢同一筆交易，查無結果後才能重新傳送。';
        } else if (sending) {
          _error = '廣播尚未送出：送出前已離開前景，廣播授權已撤銷，本次未傳送交易。';
        }
      });
      return;
    }
    if (!foreground && _verified == null) {
      _generation++;
      _ffi?.cancelPendingSession(widget.sessionId);
      _pendingRegistered = false;
      _originalRequestQr = null;
      if (!mounted) {
        _foreground = false;
        return;
      }
      setState(() {
        _foreground = false;
        _busy = false;
        _requiresRecoveryConfirmation = _recoveryEligible;
        _error = '已離開前景，接收授權已撤銷。若 Vault 已簽署，請重新核對原請求並接收既有簽章；不需重新簽署。';
      });
      return;
    }
    if (!mounted) {
      _foreground = foreground;
      return;
    }
    if (_foreground != foreground) {
      setState(() => _foreground = foreground);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _ffi?.cancelPendingSession(widget.sessionId);
    if (widget.rpcOverride == null) _rpc.close();
    super.dispose();
  }

  Map<String, dynamic> get _record => {
        'requestId': widget.requestId,
        'sessionId': widget.sessionId,
        'account': widget.account.address.toLowerCase(),
        'chainId': widget.account.chainId,
        'derivationPath': widget.account.derivationPath,
        'masterFingerprint': widget.account.masterFingerprint.toLowerCase(),
        'compressedPublicKeyHex':
            widget.account.compressedPublicKeyHex?.toLowerCase(),
        'rpcUrl': _rpc.rpcUrl,
        'unsignedPayload': widget.unsignedRlpHex,
        'signatureUr': _signatureUr,
        'signedRaw': _verified?['signed_raw_tx_hex'],
        'hash': _verified?['local_tx_hash'],
        'state': _state,
      };

  Future<void> ingestSignatureUr(String ur, {bool persist = true}) async {
    if ((persist && _importBlocksPayment()) || _busy ||
        _verified != null ||
        !_foreground ||
        _error != null ||
        _originalRequestQr != null ||
        !_pendingRegistered ||
        _requiresRecoveryConfirmation) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = _ffi!.verifyAndAssembleEthSignatureUr(
          sessionId: widget.sessionId,
          expectedRequestIdHex: widget.requestId,
          urOrFrames: ur.trim());
      if (result['verified'] != true ||
          result['status'] != 'SIGNED_TX_READY' ||
          result['chain_id'] != widget.account.chainId ||
          result['request_id'] != widget.requestId ||
          (result['recovered_address'] as String?)?.toLowerCase() !=
              widget.account.address.toLowerCase() ||
          result['signed_raw_tx_hex'] is! String ||
          !RegExp(r'^0x[0-9a-fA-F]{64}$')
              .hasMatch(result['local_tx_hash'] as String? ?? '')) {
        throw StateError(
            '${result['error_code'] ?? 'ERR_SIG_VERIFY'}: ${result['error'] ?? '簽章、帳戶或交易不符'}');
      }
      _verified = result;
      _signatureUr = ur.trim();
      _state = 'verified';
      if (persist) await _history.save(_record);
    } on StateError catch (e) {
      // Keep the machine code for diagnosis, without Dart's "Bad state:" prefix.
      _error = e.message.startsWith('ERR_REQUEST_ID_MISMATCH')
          ? '此簽章不屬於這筆請求（Request ID 不符），未接收。請在 Vault 核對同一筆交易。\n${e.message}'
          : e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// True, with the reason shown, when the saved node URL is now refused.
  bool _nodeUrlRefused(String outcome) {
    final refusal = NodeUrlPolicy.savedUrlRefusal(_rpc.rpcUrl,
        settings: '網路與節點設定', outcome: outcome);
    if (refusal != null) setState(() => _error = refusal);
    return refusal != null;
  }

  Future<void> queryTransaction() async {
    if (_busy || !_foreground || _verified == null) return;
    if (_nodeUrlRefused('未查詢交易')) return;
    final generation = _generation;
    final verified = _verified!;
    setState(() {
      _busy = true;
      _error = null;
      _canResend = false;
    });
    try {
      await _rpc.verifyChainId(widget.account.chainId);
      if (!_currentOperation(generation, verified)) return;
      final hash = verified['local_tx_hash'] as String;
      final receipt = await _rpc.getTransactionReceipt(hash);
      if (!_currentOperation(generation, verified)) return;
      String state;
      var canResend = false;
      if (receipt != null) {
        state = TransactionOutcome.receiptState(receipt, hash);
      } else {
        final transaction = await _rpc.getTransactionByHash(hash);
        if (!_currentOperation(generation, verified)) return;
        if (transaction != null) {
          state = 'pending';
        } else {
          state = 'unknown';
          canResend = true;
        }
      }
      _receipt = receipt;
      _state = state;
      _canResend = canResend;
      await _history.save(_record);
      if (!_currentOperation(generation, verified)) return;
    } catch (e) {
      if (!_currentOperation(generation, verified)) return;
      _state = 'unknown';
      _error = '查詢失敗：$e';
    } finally {
      if (_currentOperation(generation, verified)) {
        setState(() => _busy = false);
      }
    }
  }

  bool _currentOperation(int generation, Map<String, dynamic> verified) =>
      mounted &&
      _foreground &&
      generation == _generation &&
      identical(verified, _verified);

  Future<void> broadcast() async {
    if (_importBlocksPayment() || _busy ||
        _verified == null ||
        !_foreground ||
        !(_state == 'verified' || _canResend)) {
      return;
    }
    // Before `broadcasting` is entered: the record keeps its state.
    if (_nodeUrlRefused('未傳送交易')) return;
    final generation = _generation;
    final verified = _verified!;
    setState(() {
      _busy = true;
      _error = null;
      _canResend = false;
      _sendDispatched = false;
      _stateBeforeSend = _state;
      _state = 'broadcasting';
    });
    try {
      await _history
          .save(_record); // Persist the exact bytes before any network write.
      if (!_currentOperation(generation, verified)) return;
      final hash = await _rpc.sendRawTransaction(
          verified['signed_raw_tx_hex'] as String,
          expectedChainId: widget.account.chainId,
          canDispatch: () {
            // A revoked attempt must not clear the flag of a newer send.
            if (_importBlocksPayment() || !_currentOperation(generation, verified)) return false;
            return _sendDispatched = true;
          });
      if (!_currentOperation(generation, verified)) return;
      if (hash.toLowerCase() !=
          (verified['local_tx_hash'] as String).toLowerCase()) {
        throw const FormatException('節點回傳 hash 與本地 signed transaction 不符');
      }
      _state = 'accepted';
      await _history.save(_record);
      if (!_currentOperation(generation, verified)) return;
    } catch (e) {
      if (!_currentOperation(generation, verified)) return;
      _state = 'unknown';
      _error = '廣播未確認：$e。請先查詢同一筆交易。';
      try {
        await _history.save(_record);
      } catch (_) {}
    } finally {
      if (_currentOperation(generation, verified)) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _intentSummary() {
    final tx = _intent?['transaction'];
    final rawIntent = _intent?['intent'];
    if (tx is! Map || rawIntent is! Map) {
      return SelectableText(const JsonEncoder.withIndent('  ').convert(_intent),
          key: const Key('verified_intent_text'));
    }
    final native = rawIntent['NativeTransfer'];
    final token = rawIntent['Erc20Transfer'];
    final details = native is Map
        ? native
        : token is Map
            ? token
            : <String, dynamic>{};
    final contract = details['token_contract'];
    final decimals = contract?.toString().toLowerCase() ==
            NodeRpcClient.sepoliaUsdcContract.toLowerCase()
        ? 6
        : 18;
    final rawAmount =
        '${details['token_amount_raw'] ?? details['value_wei'] ?? ''}';
    final amount = BigInt.tryParse(rawAmount);
    final fee = BigInt.tryParse('${details['fee_cap_wei']}');
    return SelectableText(
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.7),
        [
          '格式：${tx['type']}',
          '收款地址：${details['recipient']}',
          '金額：${amount == null ? rawAmount : DecimalAmountParser.formatBaseUnits(amount, decimals: decimals)} ${contract == null ? 'ETH' : 'Token'}',
          if (contract != null) 'Token 合約：$contract；小數位數：$decimals',
          'Nonce：${tx['nonce']}',
          'Gas 上限：${tx['gas_limit']}',
          if (tx['gas_price_wei'] != null) 'Gas 單價（Wei）：${tx['gas_price_wei']}',
          if (tx['max_fee_per_gas_wei'] != null)
            'Gas 單價上限（Wei）：${tx['max_fee_per_gas_wei']}',
          if (tx['max_priority_fee_per_gas_wei'] != null)
            '優先費上限（Wei）：${tx['max_priority_fee_per_gas_wei']}',
          '最高網路費：${fee == null ? details['fee_cap_wei'] : DecimalAmountParser.formatBaseUnits(fee, decimals: 18)} ETH',
          '原始合約資料：${tx['data_hex']}',
        ].join('\n'),
        key: const Key('verified_intent_text'));
  }

  @override
  Widget build(BuildContext context) {
    if (!_importBlocksPayment() && _verified == null &&
        _error == null &&
        !_busy &&
        _pendingRegistered &&
        _originalRequestQr == null &&
        !_requiresRecoveryConfirmation) {
      return AirGapScanner(
        expectedType: 'eth-signature',
        title: '掃描簽署結果',
        onOpenAppSettings: defaultTargetPlatform == TargetPlatform.android
            ? () => const MethodChannel('fcw/platform')
                .invokeMethod<void>('openAppSettings')
            : null,
        // Leaving the app revokes this receive authorization, so the scanner
        // is gone on return; the original request is recovered from history.
        deniedPermissionHint:
            '相機權限未允許。若系統不再詢問，請到系統設定的「權限」開啟相機；離開本 App 會撤銷這次接收授權，返回後請由本機交易紀錄核對並接收原請求的既有簽章，不需重新簽署。也可以現在使用手動輸入。',
        onPermissionRequest: (asking) => _askingForCamera = asking,
        onPayloadComplete: (_) {},
        onRawUrComplete: ingestSignatureUr,
      );
    }
    final theme = Theme.of(context);
    final palette = FcwPalette.resolve(context);
    final stateColors = palette.of(outcomeTone(_state));
    return Scaffold(
      appBar: AppBar(title: const Text('交易詳情')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_importBlocksPayment())
                    const FcwBanner(tone: FcwTone.warning,
                        message: '公開備份還原尚未完成；此帳戶的新付款與簽章暫停，仍可查詢原交易。離開或暫停不會解除付款保留。'),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: FcwSpace.md),
                      child: LinearProgressIndicator(),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: stateColors.container,
                      borderRadius: BorderRadius.circular(FcwRadius.card),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(FcwSpace.lg),
                      child: Row(children: [
                        Icon(outcomeIcon(_state),
                            size: 28, color: stateColors.onContainer),
                        const SizedBox(width: FcwSpace.md),
                        Expanded(
                          child: Text(TransactionOutcome.label(_state),
                              key: const Key('transaction_state_text'),
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(color: stateColors.onContainer)),
                        ),
                      ]),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: FcwSpace.md),
                    FcwBanner(
                      tone: FcwTone.danger,
                      content: SelectableText(_error!,
                          key: Key(_verified == null
                              ? 'signature_verification_error_text'
                              : 'broadcast_rpc_error_text'),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: palette.danger.onContainer)),
                    ),
                  ],
                  if (_verified == null &&
                      _error != null &&
                      _ffi != null &&
                      _intent != null &&
                      _pendingRegistered &&
                      !_requiresRecoveryConfirmation) ...[
                    const SizedBox(height: 16),
                    OutlinedButton(
                        key: const Key('rescan_signature_btn'),
                        onPressed:
                            _busy || _importBlocksPayment() ? null : () => setState(() => _error = null),
                        child: const Text('重新掃描簽章')),
                  ],
                  if (_recoveryEligible &&
                      (_requiresRecoveryConfirmation ||
                          _originalRequestQr != null)) ...[
                    const SizedBox(height: FcwSpace.lg),
                    const FcwBanner(
                      tone: FcwTone.info,
                      message:
                          '請先核對原始請求。若 Vault 已簽署，請接收既有簽章；若尚未收到請求，可重顯同一筆 QR。關閉或取消本機流程不會撤銷簽章，請勿建立另一筆付款。',
                    ),
                    if (_movesFromRefusedUrl)
                      const Padding(
                        padding: EdgeInsets.only(top: FcwSpace.sm),
                        child: FcwBanner(
                          key: Key('refused_rpc_migration_notice'),
                          tone: FcwTone.warning,
                          message:
                              '原請求綁定的節點使用公開網路上的 http://，已不再允許。確認後會先核對下方目前 RPC 的 Chain ID，再接收同一請求的既有簽章，並改用此 RPC。',
                        ),
                      ),
                    if (_restoredRecord?['rpcUrl'] == '')
                      const Padding(
                        padding: EdgeInsets.only(top: FcwSpace.sm),
                        child: FcwBanner(
                          tone: FcwTone.warning,
                          message:
                              '原始 RPC 未備份。確認後將先核對以下目前 RPC 的 Chain ID，再接收同一請求的既有簽章。',
                        ),
                      ),
                    const SizedBox(height: FcwSpace.lg),
                    FcwPanel(
                      child: SelectableText(
                          '原始 Request ID：${widget.requestId}\n帳戶：${widget.account.label}\n簽署者：${widget.account.address}\n派生路徑：${widget.account.derivationPath}\n金庫指紋：${widget.account.masterFingerprint.toUpperCase()}\n網路 Chain ID：${widget.account.chainId}\nRPC：${_rpc.rpcUrl}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.7)),
                    ),
                    const SizedBox(height: FcwSpace.xl),
                    Text('交易內容與費用', style: theme.textTheme.titleLarge),
                    const SizedBox(height: FcwSpace.md),
                    FcwPanel(child: _intentSummary()),
                    const SizedBox(height: FcwSpace.xl),
                    if (_requiresRecoveryConfirmation)
                      FilledButton(
                          key: const Key('confirm_existing_signature_btn'),
                          onPressed: _busy || !_foreground || _importBlocksPayment()
                              ? null
                              : _confirmExistingSignatureRecovery,
                          child: const Text('核對並接收原請求既有簽章')),
                    if (_requiresRecoveryConfirmation) ...[
                      const SizedBox(height: FcwSpace.md),
                      OutlinedButton.icon(
                          key: const Key('confirm_original_request_qr_btn'),
                          onPressed: _busy || !_foreground || _importBlocksPayment()
                              ? null
                              : () => _confirmExistingSignatureRecovery(
                                  showOriginalRequest: true),
                          icon: const Icon(Icons.qr_code),
                          label: const Text('核對並重顯同一筆待簽 QR')),
                    ],
                    if (_originalRequestQr != null && !_importBlocksPayment()) ...[
                      const SizedBox(height: FcwSpace.xl),
                      AnimatedFountainQr(
                          key: const Key('original_request_qr'),
                          frames: _originalRequestQr!.displayFrames(),
                          title: '原始待簽交易',
                          subtitle: '沿用原始 Request ID 與交易內容'),
                      const SizedBox(height: FcwSpace.md),
                      FilledButton.icon(
                          key: const Key('scan_original_request_signature_btn'),
                          onPressed: _busy || !_foreground || _importBlocksPayment()
                              ? null
                              : () => setState(() => _originalRequestQr = null),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('掃描此筆交易的簽署結果')),
                    ],
                  ],
                  if (_verified != null) ...[
                    const SizedBox(height: FcwSpace.xl),
                    Text('簽署帳戶與網路', style: theme.textTheme.titleLarge),
                    const SizedBox(height: FcwSpace.md),
                    FcwPanel(
                      child: SelectableText(
                          '帳戶：${widget.account.label}\n簽署者：${widget.account.address}\n網路 Chain ID：${widget.account.chainId}\nRPC：${_rpc.rpcUrl}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(height: 1.7)),
                    ),
                    // A signed record moves when it is opened; say so.
                    if (_movesFromRefusedUrl)
                      const Padding(
                        padding: EdgeInsets.only(top: FcwSpace.sm),
                        child: FcwBanner(
                          key: Key('refused_rpc_migration_notice'),
                          tone: FcwTone.info,
                          message:
                              '原請求綁定的節點使用公開網路上的 http://，已不再允許。已核對目前 RPC 的 Chain ID，並改用此 RPC。',
                        ),
                      ),
                    const SizedBox(height: FcwSpace.xl),
                    Text('交易內容與費用', style: theme.textTheme.titleLarge),
                    const SizedBox(height: FcwSpace.md),
                    FcwPanel(child: _intentSummary()),
                    const SizedBox(height: FcwSpace.xl),
                    FcwPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SelectableText('交易雜湊：${_verified!['local_tx_hash']}',
                              key: const Key('verified_tx_hash_text'),
                              style: fcwMono(theme.textTheme.bodyMedium)),
                          const SizedBox(height: FcwSpace.lg),
                          Text('已簽交易資料',
                              style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                          const SizedBox(height: FcwSpace.xs),
                          SelectableText(
                              _verified!['signed_raw_tx_hex'] as String,
                              key: const Key('signed_raw_tx_hex_text'),
                              style: fcwMono(theme.textTheme.bodySmall)),
                          if (_receipt != null)
                            Padding(
                                padding:
                                    const EdgeInsets.only(top: FcwSpace.md),
                                child: SelectableText(
                                    'Receipt：${jsonEncode(_receipt)}',
                                    style: fcwMono(theme.textTheme.bodySmall))),
                        ],
                      ),
                    ),
                    const SizedBox(height: FcwSpace.xl),
                    if (_state == 'verified' || _canResend)
                      FilledButton(
                          key: const Key('confirm_broadcast_btn'),
                          onPressed: _busy || _importBlocksPayment() ? null : broadcast,
                          child: Text(
                              _canResend ? '確認重新傳送同一筆已簽交易' : '確認以上完整交易並廣播')),
                    if (_state != 'verified' || _importBlocksPayment())
                      OutlinedButton(
                          key: const Key('query_transaction_btn'),
                          onPressed: _busy ? null : queryTransaction,
                          child: const Text('查詢此筆交易與 Receipt')),
                    const SizedBox(height: FcwSpace.md),
                    Text('節點接受不等於已確認。結果待查時，先查詢相同雜湊；重新傳送沿用相同已簽 bytes。',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 20),
                  TextButton(
                      onPressed:
                          _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('返回')),
                ]),
          ),
        ),
      ),
    );
  }
}
