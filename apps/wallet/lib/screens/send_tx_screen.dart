import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import '../ffi/wallet_ffi_service.dart';
import '../services/node_rpc_client.dart';
import '../services/node_url_policy.dart';
import '../services/transaction_builder.dart';
import '../services/transaction_history.dart';
import 'scan_signature_screen.dart';

class SendTxScreen extends StatefulWidget {
  final AccountDescriptor account;
  final WalletFfiService? ffiOverride;
  final NodeRpcClient? rpcOverride;
  final TransactionHistory? historyOverride;

  const SendTxScreen({
    super.key,
    required this.account,
    this.ffiOverride,
    this.rpcOverride,
    this.historyOverride,
  });

  @override
  State<SendTxScreen> createState() => SendTxScreenState();
}

class SendTxScreenState extends State<SendTxScreen>
    with WidgetsBindingObserver {
  late final WalletFfiService _ffi;
  late final NodeRpcClient _rpc;
  late final TransactionHistory _history;

  final _recipientController = TextEditingController();
  final _requestQrKey = GlobalKey();
  bool _building = false;
  final _amountController = TextEditingController();
  final _nonceController = TextEditingController();
  final _gasLimitController = TextEditingController();
  final _gasPriceGweiController = TextEditingController();
  final _maxFeeGweiController = TextEditingController();
  final _priorityFeeGweiController = TextEditingController();
  final _psbtHexController = TextEditingController();

  String _selectedAsset = 'ETH'; // 'ETH', 'USDC', 'DAI', 'BTC_PSBT'
  String _txFormat = 'EIP1559'; // 'EIP1559' or 'LEGACY'
  bool _useFountainQr = true;

  String? _errorMessage;
  String? _rpcSyncStatus;
  String? _sessionId;
  String? _requestIdHex;
  String? _unsignedPayloadHex;
  String? _singleUr;
  List<String>? _fountainFrames;
  String? _expectedDigestHex;
  int _formRevision = 0;
  bool _syncing = false;
  bool _openingScanner = false;
  bool _foreground = true;
  String? _nativeError;
  bool _feeEstimateStale = false;

  List<TextEditingController> get _controllers => [
        _recipientController,
        _amountController,
        _nonceController,
        _gasLimitController,
        _gasPriceGweiController,
        _maxFeeGweiController,
        _priorityFeeGweiController,
        _psbtHexController
      ];

  void _invalidate({bool invalidateFeeEstimate = true}) {
    _formRevision++;
    if (invalidateFeeEstimate) {
      if (_rpcSyncStatus != null) _feeEstimateStale = true;
      _rpcSyncStatus = null;
    }
    if (_sessionId != null && _nativeError == null) {
      _ffi.cancelPendingSession(_sessionId!);
    }
    // An exported QR may already have been signed by the Vault. Keep its
    // durable history record admission-blocking when this local receive
    // session is retired.
    _sessionId = null;
    _requestIdHex = null;
    _unsignedPayloadHex = null;
    _singleUr = null;
    _fountainFrames = null;
    _expectedDigestHex = null;
  }

  void _onEdit() {
    if (mounted) setState(() => _invalidate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground && !_openingScanner && mounted) {
      final hadPendingRequest = _requestIdHex != null;
      setState(() {
        _invalidate();
        if (hadPendingRequest) {
          _errorMessage =
              '已離開前景，待簽畫面已撤銷。若 Vault 已簽署，請由本機交易紀錄核對並接收原請求的既有簽章；不需重新簽署。';
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant SendTxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account) _invalidate();
  }

  BigInt _amount(String text, int decimals, {bool allowZero = false}) {
    if (text.length > 160) throw const AmountParseException('金額過長');
    final value = DecimalAmountParser.parseToBaseUnits(text,
        decimals: decimals, allowZero: allowZero);
    if (value.bitLength > 256) {
      throw const AmountParseException('金額超過 uint256 上限');
    }
    return value;
  }

  String? get _maximumNetworkFee {
    try {
      final gasText = _gasLimitController.text.trim();
      if (gasText.length > 30) return null;
      final gas = BigInt.tryParse(gasText);
      if (gas == null || gas <= BigInt.zero) return null;
      final price = _amount(
          (_txFormat == 'EIP1559'
                  ? _maxFeeGweiController
                  : _gasPriceGweiController)
              .text
              .trim(),
          9,
          allowZero: true);
      return DecimalAmountParser.formatBaseUnits(gas * price, decimals: 18);
    } catch (_) {
      return null;
    }
  }

  String get _rpcDisplay {
    final uri = Uri.tryParse(_rpc.rpcUrl);
    if (uri == null || !uri.hasAuthority) return '未設定';
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  }

  ({String to, BigInt value, Uint8List data}) _transfer() {
    final recipient = _recipientController.text.trim();
    if (!TransactionBuilder.isValidEvmAddress(recipient)) {
      throw const FormatException('收款地址格式錯誤');
    }
    if (_selectedAsset == 'ETH') {
      return (
        to: recipient,
        value: _amount(_amountController.text, 18),
        data: Uint8List(0)
      );
    }
    if (widget.account.chainId != 11155111) {
      throw const FormatException('此 Token 僅支援 Sepolia，請核對網路與合約');
    }
    final contract = _selectedAsset == 'USDC'
        ? NodeRpcClient.sepoliaUsdcContract
        : NodeRpcClient.sepoliaDaiContract;
    return (
      to: contract,
      value: BigInt.zero,
      data: TransactionBuilder.encodeErc20TransferCalldata(
          recipientAddress: recipient,
          amountRaw: _amount(
              _amountController.text, _selectedAsset == 'USDC' ? 6 : 18))
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _ffi = widget.ffiOverride ?? WalletFfiService();
    } catch (e) {
      _nativeError = '無法載入原生交易核心：$e';
    }
    for (final controller in _controllers) {
      controller.addListener(_onEdit);
    }
    _rpc = widget.rpcOverride ?? NodeRpcClient();
    _history = widget.historyOverride ?? TransactionHistory();
    if (widget.account.assetFamily == 'BTC') {
      _selectedAsset = 'BTC_PSBT';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_nativeError == null) _invalidate();
    for (final controller in _controllers) {
      controller.removeListener(_onEdit);
    }
    _recipientController.dispose();
    _amountController.dispose();
    _nonceController.dispose();
    _gasLimitController.dispose();
    _gasPriceGweiController.dispose();
    _maxFeeGweiController.dispose();
    _priorityFeeGweiController.dispose();
    _psbtHexController.dispose();
    if (widget.rpcOverride == null) _rpc.close();
    super.dispose();
  }

  String _generateRequestIdHex() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<bool> _admitIndependentPayment(int revision) async {
    try {
      final blocking = await _history.findPotentiallyExecutable(
          account: widget.account.address, chainId: widget.account.chainId);
      if (!mounted || !_foreground || revision != _formRevision) return false;
      if (blocking == null) return true;
      final nonce = blocking['nonce'];
      final nonceText = nonce is int ? '（Nonce $nonce）' : '';
      final legacy = blocking['derivationPath'] is! String ||
          blocking['masterFingerprint'] is! String;
      final recoveryHint = legacy
          ? '舊紀錄缺少原始派生身分，本版本無法安全恢復；請保留紀錄，勿清除資料或另建同一筆付款。'
          : '請先從交易紀錄恢復並核對原請求；本版本不支援取消或替換已匯出的請求。';
      setState(() => _errorMessage =
          '同一帳戶與網路仍有可能執行的先前交易$nonceText。$recoveryHint 在結果確定前不會建立另一筆付款。');
      return false;
    } catch (_) {
      if (mounted && _foreground && revision == _formRevision) {
        setState(() => _errorMessage =
            '無法核對既有交易紀錄；為避免重複付款，未建立新的交易。');
      }
      return false;
    }
  }

  Future<void> syncFromRpc() async {
    if (_syncing) return;
    final admissionRevision = _formRevision;
    if (!await _admitIndependentPayment(admissionRevision)) return;
    final refusal = NodeUrlPolicy.savedUrlRefusal(_rpc.rpcUrl,
        settings: '網路與節點設定', outcome: '沒有連線到節點');
    if (refusal != null) {
      setState(() => _errorMessage = refusal);
      return;
    }
    setState(() {
      _errorMessage = null;
      _syncing = true;
      _invalidate();
      _rpcSyncStatus = '正在核對網路並估算此筆交易';
    });
    final revision = _formRevision;
    try {
      final transfer = _transfer();
      await _rpc.verifyChainId(widget.account.chainId);
      final nonce = await _rpc.getTransactionCount(widget.account.address);
      final gasPrice = await _rpc.getGasPrice();
      final priority = _txFormat == 'EIP1559'
          ? await _rpc.getMaxPriorityFeePerGas()
          : BigInt.zero;
      final estimate = await _rpc.estimateGas(
          from: widget.account.address,
          to: transfer.to,
          valueWei: transfer.value,
          dataHex: transfer.data
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join());
      if (!mounted || revision != _formRevision) return;
      _nonceController.text = nonce.toString();
      _gasLimitController.text = estimate.toString();
      _gasPriceGweiController.text =
          DecimalAmountParser.formatBaseUnits(gasPrice, decimals: 9);
      _priorityFeeGweiController.text =
          DecimalAmountParser.formatBaseUnits(priority, decimals: 9);
      _maxFeeGweiController.text = DecimalAmountParser.formatBaseUnits(
          gasPrice * BigInt.two + priority,
          decimals: 9);
      final feeSource = _txFormat == 'EIP1559'
          ? 'Type-2 Max Fee 為節點 gasPrice × 2 + priority，上限可自行核對調整。'
          : 'Legacy Gas 單價採用節點 gasPrice（${_gasPriceGweiController.text} Gwei），可自行核對調整。';
      setState(() {
        _feeEstimateStale = false;
        _rpcSyncStatus =
            '來源：$_rpcDisplay；Chain ID ${widget.account.chainId}；Nonce $nonce；Gas 估算 $estimate。$feeSource';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'RPC 查詢／估算失敗：$e';
          _rpcSyncStatus = null;
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> generateUnsignedTx() async {
    if (_building) return;
    setState(() => _building = true);
    try {
      await _generateUnsignedTx();
    } finally {
      if (mounted) setState(() => _building = false);
    }
    // The QR is built below the form; bring it into view so the action
    // visibly completes instead of inviting a second tap. Revealing the QR's
    // end keeps a short screen from cutting it off below the heading.
    if (mounted && _activeQrFrames.isNotEmpty) {
      // A QR image says nothing to a screen reader on its own.
      SemanticsService.sendAnnouncement(View.of(context),
          '待簽交易 QR 已建立，請用 Vault 掃描並核對後簽署。', Directionality.of(context));
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

  Future<void> _generateUnsignedTx() async {
    if (_nativeError != null) {
      setState(() => _errorMessage = _nativeError);
      return;
    }
    final admissionRevision = _formRevision;
    if (!await _admitIndependentPayment(admissionRevision)) return;
    // The request records the RPC it will be sent to; never bind one to a
    // refused URL, even when nonce and gas were typed by hand.
    final refusal = NodeUrlPolicy.savedUrlRefusal(_rpc.rpcUrl,
        settings: '網路與節點設定', outcome: '未建立交易');
    if (refusal != null) {
      setState(() => _errorMessage = refusal);
      return;
    }
    setState(() {
      _errorMessage = null;
      _invalidate(invalidateFeeEstimate: false);
    });

    if (_selectedAsset == 'BTC_PSBT') {
      setState(() => _errorMessage = 'Bitcoin UTXO／找零與請求綁定流程尚未接入，暫不提供此入口');
      return;
    }

    final recipient = _recipientController.text.trim();
    if (!TransactionBuilder.isValidEvmAddress(recipient)) {
      setState(() {
        _errorMessage = '收款地址格式錯誤：必須為 0x 開頭之 40 位十六進位地址';
      });
      return;
    }

    final nonceText = _nonceController.text.trim();
    final nonce = RegExp(r'^\d{1,19}$').hasMatch(nonceText)
        ? int.tryParse(nonceText)
        : null;
    if (nonce == null || nonce < 0) {
      setState(() => _errorMessage = 'Nonce 必須為非負整數');
      return;
    }

    final gasText = _gasLimitController.text.trim();
    final gasLimit =
        RegExp(r'^\d{1,6}$').hasMatch(gasText) ? int.tryParse(gasText) : null;
    // This builder emits empty calldata/access lists for native ETH. Keep the
    // Sepolia self-transfer exception aligned with the native signer-bound guard.
    final isSepoliaType2SelfTransfer = widget.account.chainId == 11155111 &&
        _txFormat == 'EIP1559' &&
        _selectedAsset == 'ETH' &&
        recipient.toLowerCase() == widget.account.address.toLowerCase();
    final minimumGas = isSepoliaType2SelfTransfer ? 12000 : 21000;
    if (gasLimit == null || gasLimit < minimumGas || gasLimit > 500000) {
      setState(() {
        _errorMessage =
            'Gas Limit 超出安全範圍 (必須介於 ${isSepoliaType2SelfTransfer ? '12,000' : '21,000'} 與 500,000 之間)';
      });
      return;
    }

    late final String toAddr;
    late final BigInt valueWei;
    late final Uint8List calldata;
    try {
      final transfer = _transfer();
      toAddr = transfer.to;
      valueWei = transfer.value;
      calldata = transfer.data;
    } catch (e) {
      setState(() => _errorMessage = '$e');
      return;
    }

    late final String rawTxHex;
    try {
      if (_txFormat == 'EIP1559') {
        final maxFeeWei = _amount(
          _maxFeeGweiController.text,
          9,
          allowZero: false,
        );
        final prioFeeWei = _amount(
          _priorityFeeGweiController.text,
          9,
          allowZero: true,
        );
        if (prioFeeWei > maxFeeWei) {
          setState(() {
            _errorMessage = 'Max Priority Fee 不可大於 Max Fee Per Gas';
          });
          return;
        }
        rawTxHex = TransactionBuilder.buildEip1559UnsignedPayload(
          chainId: widget.account.chainId,
          nonce: nonce,
          maxPriorityFeePerGasWei: prioFeeWei,
          maxFeePerGasWei: maxFeeWei,
          gasLimit: gasLimit,
          toAddress: toAddr,
          valueWei: valueWei,
          calldata: calldata,
        );
      } else {
        final gasPriceWei = _amount(
          _gasPriceGweiController.text,
          9,
          allowZero: false,
        );
        rawTxHex = TransactionBuilder.buildLegacyUnsignedRlp(
          nonce: nonce,
          gasPriceWei: gasPriceWei,
          gasLimit: gasLimit,
          toAddress: toAddr,
          valueWei: valueWei,
          calldata: calldata,
          chainId: widget.account.chainId,
        );
      }
    } on AmountParseException catch (e) {
      setState(() => _errorMessage = 'Gas 價格格式錯誤: ${e.message}');
      return;
    } catch (e) {
      setState(() => _errorMessage = e.toString());
      return;
    }

    final sessId = 'wallet-${_generateRequestIdHex()}';
    final reqIdHex = _generateRequestIdHex();

    late final Map<String, dynamic> urRes;
    try {
      urRes = _ffi.buildEthSignRequestUr(
        sessionId: sessId,
        requestIdHex: reqIdHex,
        rawTxHex: rawTxHex,
        chainId: widget.account.chainId,
        derivationPath: widget.account.derivationPath,
        masterFingerprintHex: widget.account.masterFingerprint,
        expectedAddress: widget.account.address,
        maxFragmentLen: 0,
      );
    } catch (e) {
      setState(() => _errorMessage = '原生請求建立失敗：$e');
      return;
    }

    if (urRes['status'] == 'PENDING_REGISTERED') {
      final framesRaw = urRes['fountain_frames'] as List<dynamic>?;
      final single = urRes['ur_single'] as String?;
      final payload = UrQrPayload(
          singleUr: single,
          frames: framesRaw?.map((e) => e.toString()) ?? const []);
      if (payload.displayFrames().isEmpty) {
        _ffi.cancelPendingSession(sessId);
        setState(() => _errorMessage = '原生核心未傳回有效 QR');
        return;
      }
      _sessionId = sessId;
      _requestIdHex = urRes['request_id'] as String? ?? reqIdHex;
      _unsignedPayloadHex = rawTxHex;
      try {
        await _history.save({
          'requestId': _requestIdHex,
          'sessionId': _sessionId,
          'account': widget.account.address.toLowerCase(),
          'chainId': widget.account.chainId,
          'derivationPath': widget.account.derivationPath,
          'masterFingerprint': widget.account.masterFingerprint.toLowerCase(),
          'compressedPublicKeyHex':
              widget.account.compressedPublicKeyHex?.toLowerCase(),
          'rpcUrl': _rpc.rpcUrl,
          'unsignedPayload': rawTxHex,
          'state': 'awaitingSignature',
        });
        if (!mounted || _sessionId != sessId) return;
        setState(() {
          _singleUr = payload.singleUr;
          _fountainFrames = payload.frames;
          if (!payload.hasSingle) _useFountainQr = true;
          _expectedDigestHex = urRes['expected_digest'] as String?;
        });
      } catch (e) {
        if (mounted && _sessionId == sessId) {
          setState(() {
            _invalidate();
            _errorMessage = '無法保存待簽交易：$e';
          });
        }
      }
    } else {
      setState(() {
        _errorMessage =
            '[${urRes['error_code'] ?? 'ERR_BUILD_UR'}] ${urRes['error'] ?? '產生 UR Tag 401 待簽請求失敗'}';
      });
    }
  }

  List<String> get _activeQrFrames {
    return UrQrPayload(singleUr: _singleUr, frames: _fountainFrames ?? const [])
        .displayFrames(preferSingle: !_useFountainQr);
  }

  @override
  Widget build(BuildContext context) {
    final isPsbt = _selectedAsset == 'BTC_PSBT';
    final qrFrames = _activeQrFrames;
    final qrPayload =
        UrQrPayload(singleUr: _singleUr, frames: _fountainFrames ?? const []);
    final theme = Theme.of(context);
    final palette = FcwPalette.resolve(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('轉帳')),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: FcwStatusPill(
                      '網路 ${widget.account.chainId == 11155111 ? 'Ethereum Sepolia' : 'Chain ID ${widget.account.chainId}'}',
                      tone: FcwTone.info,
                      icon: Icons.hub_outlined),
                ),
                const SizedBox(height: FcwSpace.xl),
                DropdownButtonFormField<String>(
                  key: const Key('asset_selector_dropdown'),
                  initialValue: _selectedAsset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '資產'),
                  items: [
                    if (widget.account.assetFamily != 'BTC')
                      const DropdownMenuItem(value: 'ETH', child: Text('ETH')),
                    if (widget.account.assetFamily != 'BTC' &&
                        widget.account.chainId == 11155111)
                      const DropdownMenuItem(
                          value: 'USDC', child: Text('USDC · Sepolia')),
                    if (widget.account.assetFamily != 'BTC' &&
                        widget.account.chainId == 11155111)
                      const DropdownMenuItem(
                          value: 'DAI', child: Text('DAI · Sepolia')),
                    if (widget.account.assetFamily == 'BTC')
                      const DropdownMenuItem(
                          value: 'BTC_PSBT', child: Text('Bitcoin PSBT')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _invalidate();
                        _selectedAsset = val;
                        _gasLimitController.clear();
                      });
                    }
                  },
                ),
                const SizedBox(height: 20),
                if (isPsbt)
                  TextField(
                    key: const Key('psbt_hex_input_field'),
                    controller: _psbtHexController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                        labelText: '未簽署 PSBT',
                        helperText: '輸入十六進位內容（70736274ff…）'),
                  )
                else ...[
                  TextField(
                    key: const Key('tx_recipient_field'),
                    controller: _recipientController,
                    style: fcwMono(Theme.of(context).textTheme.bodyLarge),
                    maxLines: null,
                    decoration: const InputDecoration(labelText: '收款地址'),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const Key('tx_amount_field'),
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: '金額', suffixText: _selectedAsset),
                  ),
                  const SizedBox(height: FcwSpace.xl),
                  FcwPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('網路費用', style: theme.textTheme.titleMedium),
                        const SizedBox(height: FcwSpace.xs),
                        Text(
                            '測試用途 · Chain ID ${widget.account.chainId} · RPC 節點：$_rpcDisplay',
                            style: muted),
                        if (_maximumNetworkFee != null)
                          Padding(
                              padding: const EdgeInsets.only(top: FcwSpace.md),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.local_gas_station_outlined,
                                      size: 20,
                                      color: theme.colorScheme.primary),
                                  const SizedBox(width: FcwSpace.sm),
                                  Expanded(
                                    child: Text(
                                        '最高網路費：$_maximumNetworkFee ETH'
                                        '${_selectedAsset == 'ETH' ? '' : '（另以 ETH 支付）'}。實際費用以執行結果為準。',
                                        key:
                                            const Key('tx_maximum_network_fee'),
                                        style: fcwFigures(
                                            theme.textTheme.bodyMedium)),
                                  ),
                                ],
                              )),
                        if (_feeEstimateStale)
                          Padding(
                            padding: const EdgeInsets.only(top: FcwSpace.sm),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    size: 20, color: palette.warning.accent),
                                const SizedBox(width: FcwSpace.sm),
                                Expanded(
                                  child: Text('費用輸入或交易內容已變更，請重新估算或核對手動上限。',
                                      key: const Key('tx_fee_estimate_stale'),
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                              color: palette.warning.accent)),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: FcwSpace.md),
                        Text('先取得節點提供的 Nonce 與費用，或在進階設定中明確輸入。', style: muted),
                        const SizedBox(height: FcwSpace.md),
                        OutlinedButton.icon(
                          key: const Key('sync_rpc_nonce_gas_btn'),
                          icon: const Icon(Icons.sync),
                          label: Text(_syncing ? '正在取得…' : '取得網路資料'),
                          onPressed: _syncing ? null : syncFromRpc,
                        ),
                        if (_rpcSyncStatus != null)
                          Padding(
                            padding: const EdgeInsets.only(top: FcwSpace.md),
                            child: Text(_rpcSyncStatus!, style: muted),
                          ),
                        ExpansionTile(
                          key: const Key('tx_fee_settings_toggle'),
                          maintainState: true,
                          tilePadding: EdgeInsets.zero,
                          title: const Text('費用與進階設定'),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(spacing: 8, runSpacing: 8, children: [
                                for (final format in ['EIP1559', 'LEGACY'])
                                  ChoiceChip(
                                    label: Text(format == 'EIP1559'
                                        ? 'EIP-1559'
                                        : 'Legacy'),
                                    selected: _txFormat == format,
                                    onSelected: (selected) {
                                      if (selected && _txFormat != format) {
                                        setState(() {
                                          _invalidate();
                                          _txFormat = format;
                                        });
                                      }
                                    },
                                  ),
                              ]),
                            ),
                            const SizedBox(height: 20),
                            TextField(
                                key: const Key('tx_nonce_field'),
                                controller: _nonceController,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: 'Nonce')),
                            const SizedBox(height: 20),
                            TextField(
                                key: const Key('tx_gas_limit_field'),
                                controller: _gasLimitController,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: 'Gas 上限')),
                            const SizedBox(height: 20),
                            if (_txFormat == 'EIP1559') ...[
                              TextField(
                                  key: const Key('tx_max_fee_gwei_field'),
                                  controller: _maxFeeGweiController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: 'Gas 單價上限',
                                      suffixText: 'Gwei')),
                              const SizedBox(height: 20),
                              TextField(
                                  key: const Key('tx_priority_fee_gwei_field'),
                                  controller: _priorityFeeGweiController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: '優先費上限', suffixText: 'Gwei')),
                            ] else
                              TextField(
                                  key: const Key('tx_gas_price_gwei_field'),
                                  controller: _gasPriceGweiController,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: 'Gas 單價', suffixText: 'Gwei')),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: FcwSpace.lg),
                    child: FcwBanner(
                      tone: FcwTone.danger,
                      content: SelectableText(_errorMessage!,
                          key: const Key('send_tx_error_text')),
                    ),
                  ),
                const SizedBox(height: FcwSpace.xl),
                const FcwBanner(
                  tone: FcwTone.warning,
                  message:
                      '建立 QR 後，這筆請求可能已在 Vault 簽署。本測試版不支援取消或替換已匯出的請求；在原交易結果確認前，同一帳戶與網路不能建立另一筆付款。請先核對收款地址、金額與費率。',
                ),
                const SizedBox(height: FcwSpace.md),
                FilledButton.icon(
                  key: const Key('generate_sign_request_qr_btn'),
                  icon: const Icon(Icons.qr_code),
                  label: const Text('建立待簽交易'),
                  onPressed: _building ? null : generateUnsignedTx,
                ),
                if (qrFrames.isNotEmpty) ...[
                  const SizedBox(height: FcwSpace.xxl),
                  Text('交給 Vault 簽署', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: FcwSpace.xs),
                  Text('用 Vault 掃描下方 QR，核對完整交易內容後簽署。', style: muted),
                  const SizedBox(height: FcwSpace.xl),
                  AnimatedFountainQr(
                      key: _requestQrKey,
                      frames: qrFrames,
                      title: '待簽交易',
                      subtitle: isPsbt ? 'Bitcoin PSBT' : 'Ethereum 簽署請求'),
                  const SizedBox(height: 12),
                  Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                            key: const Key('sign_request_fountain_toggle'),
                            label: Text(_useFountainQr ? '動態 QR' : '單張 QR'),
                            selected: _useFountainQr,
                            onSelected: !qrPayload.hasSingle
                                ? null
                                : (v) => setState(() => _useFountainQr = v)),
                        TextButton.icon(
                          key: const Key('copy_sign_request_ur_btn'),
                          icon: const Icon(Icons.copy),
                          label: const Text('複製待簽資料'),
                          onPressed: () {
                            final text = qrPayload.copyText;
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已複製待簽 UR 字串')));
                          },
                        ),
                      ]),
                  if (_requestIdHex != null)
                    ExpansionTile(
                      title: const Text('請求資料'),
                      tilePadding: EdgeInsets.zero,
                      maintainState: true,
                      children: [
                        SelectableText(qrPayload.copyText,
                            key: const Key('generated_sign_request_ur_text'),
                            style: fcwMono(theme.textTheme.bodySmall)),
                        const SizedBox(height: 12),
                        SelectableText(
                            'Request ID: $_requestIdHex\nDigest: ${_expectedDigestHex ?? "PSBT"}',
                            style: fcwMono(theme.textTheme.bodySmall)),
                      ],
                    ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('proceed_scan_signature_btn'),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('掃描簽署結果'),
                    onPressed: () async {
                      // Otherwise the last edited field regains focus (and
                      // the keyboard) when the scanner route is popped.
                      FocusManager.instance.primaryFocus?.unfocus();
                      _openingScanner = true;
                      await Navigator.of(context).push(MaterialPageRoute(
                        builder: (context) => ScanSignatureScreen(
                          account: widget.account,
                          sessionId: _sessionId!,
                          requestId: _requestIdHex!,
                          unsignedRlpHex: _unsignedPayloadHex!,
                          isPsbt: isPsbt,
                          ffiOverride: _ffi,
                          rpcOverride: _rpc,
                          historyOverride: _history,
                        ),
                      ));
                      _openingScanner = false;
                      if (mounted) setState(_invalidate);
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
