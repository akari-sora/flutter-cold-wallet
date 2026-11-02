import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:design_system/design_system.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import '../app_info.dart';
import '../ffi/wallet_ffi_service.dart';
import '../ffi/bitcoin_ffi_service.dart';
import '../services/account_store.dart';
import '../services/node_rpc_client.dart';
import '../services/node_url_policy.dart';
import '../services/public_backup.dart';
import '../services/transaction_history.dart';
import '../widgets/node_url_field.dart';
import 'public_backup_screen.dart';
import 'send_tx_screen.dart';
import 'bitcoin_send_screen.dart';
import 'transaction_history_screen.dart';

class AccountScreen extends StatefulWidget {
  final WalletFfiService? ffiOverride;
  final NodeRpcClient? rpcOverride;

  /// Factory-created navigation clients are owned by their route.
  final NodeRpcClient Function(String rpcUrl)? routeRpcFactory;
  final BitcoinFfiService? bitcoinFfiOverride;
  final String? storagePathOverride;
  final TransactionHistory? historyOverride;
  const AccountScreen(
      {super.key,
      this.ffiOverride,
      this.rpcOverride,
      this.routeRpcFactory,
      this.bitcoinFfiOverride,
      this.storagePathOverride,
      this.historyOverride});
  @override
  State<AccountScreen> createState() => AccountScreenState();
}

class AccountScreenState extends State<AccountScreen> {
  WalletFfiService? _native;
  BitcoinFfiService? _bitcoin;
  WalletFfiService get _ffi => _native!;
  AccountStore? _store;
  bool _ready = false;
  bool _recoverableAccountStore = false;
  String? _accountRecoveryNotice;
  String? _historyRecoveryError;
  bool _publicImportPending = true;
  String? _fatalError;
  final TextEditingController _rpcUrlCtrl =
      TextEditingController(text: 'http://127.0.0.1:8545');
  String _savedRpcUrl = 'http://127.0.0.1:8545';
  List<AccountDescriptor> _accounts = [];
  List<AccountDescriptor>? _pendingAccounts;
  int _selectedIndex = 0;
  int _selectedChainId = 11155111;
  String? _pairingError;
  String? _pairingWarning;
  String? _rpcStatusMessage;
  bool _rpcOnline = false;
  bool _loadingBalance = false;
  int _balanceGeneration = 0;
  DateTime? _balanceUpdatedAt;
  String _ethBalanceDisplay = '--';
  String _usdcBalanceDisplay = '--';
  String _daiBalanceDisplay = '--';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _native = widget.ffiOverride ?? WalletFfiService();
      if (_ffi.init() != 0) throw StateError('核心初始化失敗');
      final override = widget.storagePathOverride;
      final directory = override == null
          ? await const MethodChannel('fcw/platform')
              .invokeMethod<String>('storageDirectory')
          : null;
      if (!mounted) return;
      if (override == null && (directory == null || directory.isEmpty)) {
        throw StateError('無法取得 App 永久儲存目錄');
      }
      _store = AccountStore(override ?? '$directory/paired_accounts.json');
      await loadPersistedAccounts();
    } catch (e) {
      if (mounted) {
        setState(() {
          _fatalError = '錢包無法啟用：$e。請安裝包含原生核心的完整 Wallet 安裝包；既有帳戶檔案不會被覆寫。';
        });
      }
    }
  }

  @override
  void dispose() {
    _balanceGeneration++;
    _rpcUrlCtrl.dispose();
    super.dispose();
  }

  AccountDescriptor? get currentAccount =>
      _accounts.isEmpty ? null : _accounts[_selectedIndex];
  List<AccountDescriptor> get accounts => List.unmodifiable(_accounts);
  List<AccountDescriptor> get pendingAccounts =>
      List.unmodifiable(_pendingAccounts ?? []);

  void _validateAccount(AccountDescriptor a) {
    if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(a.masterFingerprint) ||
        !a.derivationPath.startsWith('m/')) {
      throw const FormatException('缺少有效主指紋或派生路徑');
    }
    if (a.assetFamily == 'EVM') {
      if (!AccountStore.supportedChains.contains(a.chainId)) {
        throw const FormatException('僅支援 Sepolia 與本機測試鏈');
      }
      if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a.address) ||
          a.compressedPublicKeyHex == null ||
          !_ffi.verifyPubkeyAddress(
              compressedPubkeyHex: a.compressedPublicKeyHex!,
              expectedAddress: a.address)) {
        throw const FormatException('ERR_PUBKEY_ADDRESS_MISMATCH：缺少公鑰或地址與公鑰不符');
      }
    } else if (a.assetFamily == 'BTC') {
      if (a.extendedPublicKey == null ||
          a.btcDescriptor == null ||
          a.btcChangeAddress == null ||
          a.btcReceiveAddressRegtest == null ||
          !a.btcReceiveAddressRegtest!.startsWith('bcrt1')) {
        throw const FormatException('Bitcoin 配對缺少 regtest 收款／找零／descriptor 資料');
      }
      validateBitcoinPublicAccount(
          _bitcoin ??= widget.bitcoinFfiOverride ?? BitcoinFfiService(), a);
    } else {
      throw const FormatException('不支援的帳戶類型');
    }
  }

  Future<void> loadPersistedAccounts() async {
    try {
      var snapshot = _store!.load();
      for (final a in snapshot.accounts) {
        _validateAccount(a);
      }
      PublicBackupService.validateEvmBindingConflicts(snapshot.accounts);
      var recovered = snapshot;
      String? historyRecoveryError;
      try {
        recovered = await PublicBackupService(
                ffi: _ffi,
                history: widget.historyOverride ??
                    TransactionHistory(
                        pathOverride: widget.storagePathOverride == null
                            ? null
                            : '${File(widget.storagePathOverride!).parent.path}/public_transactions.json'))
            .recoverLegacyEvmBindings(snapshot);
      } catch (error) {
        final reason = error is FormatException
            ? error.message
            : error is FileSystemException
                ? '檔案讀取失敗'
                : '資料驗證失敗（${error.runtimeType}）';
        historyRecoveryError = '交易紀錄核對失敗：$reason；原始帳戶與交易紀錄已保留，所有 EVM 轉帳與交易恢復均已暫停。請保留原始檔案，勿清除資料或另建同筆付款。';
      }
      if (recovered.accounts.length != snapshot.accounts.length) {
        _store!.save(recovered);
        snapshot = recovered;
      }
      if (!mounted) return;
      setState(() {
        _accounts = snapshot.accounts;
        _selectedIndex = snapshot.selectedIndex;
        _selectedChainId = snapshot.chainId;
        _savedRpcUrl = snapshot.rpcUrl;
        _rpcUrlCtrl.text = snapshot.rpcUrl;
        _ready = true;
        _recoverableAccountStore = false;
        _historyRecoveryError = historyRecoveryError;
        _publicImportPending = _isPublicImportPending();
      });
    } catch (e) {
      setState(() {
        _fatalError = '觀察帳戶讀取失敗：$e。原始資料已保留，請先還原有效公開帳戶備份。';
        _ready = false;
        _recoverableAccountStore = _store != null && _native != null;
      });
    }
  }

  bool _isPublicImportPending() {
    try {
      return PublicImportProgress.isPendingAt(File(_store!.path).parent.path);
    } catch (_) {
      return true;
    }
  }

  bool _blocksPayment(AccountDescriptor account) {
    try {
      return PublicImportProgress.blocksPaymentAt(File(_store!.path).parent.path,
          assetFamily: account.assetFamily, account: account.address,
          chainId: account.chainId, masterFingerprint: account.masterFingerprint);
    } catch (_) {
      return true;
    }
  }

  bool _canOpenTransferRoute(AccountDescriptor account) {
    if (!_blocksPayment(account)) return true;
    setState(() => _publicImportPending = true);
    return false;
  }

  void _clearBalances() {
    _balanceGeneration++;
    _loadingBalance = false;
    _rpcOnline = false;
    _balanceUpdatedAt = null;
    _rpcStatusMessage = null;
    _ethBalanceDisplay = '--';
    _usdcBalanceDisplay = '--';
    _daiBalanceDisplay = '--';
  }

  bool _commit(List<AccountDescriptor> next, int selected,
      {int? chainId, String? rpcUrl}) {
    if (!_ready) return false;
    try {
      _store!.save(AccountSnapshot(
          accounts: next,
          selectedIndex: selected,
          chainId: chainId ?? _selectedChainId,
          rpcUrl: rpcUrl ?? _savedRpcUrl));
      setState(() {
        _accounts = next;
        _selectedIndex = selected;
        _selectedChainId = chainId ?? _selectedChainId;
        _savedRpcUrl = rpcUrl ?? _savedRpcUrl;
        _pendingAccounts = null;
        _pairingError = null;
        _clearBalances();
      });
      return true;
    } catch (e) {
      setState(() {
        _pairingError = '儲存失敗，帳戶與設定未變更：$e';
      });
      return false;
    }
  }

  /// Decode and stage only. Explicit confirmation is required before persistence.
  bool ingestPairingUr(String input) {
    if (!_ready) return false;
    try {
      final res = _ffi.decodeAndVerifyMultiAccountsUr(input.trim(),
          defaultChainId: _selectedChainId);
      if (res['status'] != 'SUCCESS') {
        throw FormatException(
            '[${res['error_code'] ?? 'ERR_PAIRING'}] ${res['error'] ?? '配對驗證失敗'}');
      }
      final parsed = <AccountDescriptor>[];
      var excludedBtc = (res['unsupported_accounts'] as List? ?? [])
          .where((e) => e is Map && e['chain_family'] == 'BTC')
          .length;
      for (final family in ['evm_accounts', 'btc_accounts']) {
        for (final item in res[family] as List? ?? []) {
          final map = Map<String, dynamic>.from(item as Map);
          map['chain_id'] = family == 'evm_accounts' ? _selectedChainId : 0;
          map['asset_family'] = family == 'evm_accounts' ? 'EVM' : 'BTC';
          final a = AccountDescriptor.fromJson(map);
          // The native decoder already authenticated public key derivation.
          // Legacy BTC QR lacks the descriptor/change information needed by UI.
          if (a.assetFamily == 'BTC' &&
              (a.extendedPublicKey == null ||
                  a.btcDescriptor == null ||
                  a.btcChangeAddress == null)) {
            excludedBtc++;
            continue;
          }
          _validateAccount(a);
          parsed.add(a);
        }
      }
      if (parsed.isEmpty) {
        throw const FormatException('ERR_EMPTY_ACCOUNTS：沒有有效公開帳戶');
      }
      setState(() {
        _pendingAccounts = parsed;
        _pairingWarning = excludedBtc == 0
            ? null
            : '$excludedBtc 個 Bitcoin 帳戶缺少公開描述或找零資料，本次不匯入；請由更新後 Vault 重新產生配對碼。';
        _pairingError = null;
      });
      return true;
    } catch (e) {
      setState(() {
        _pendingAccounts = null;
        _pairingWarning = null;
        _pairingError = '配對失敗：$e';
      });
      return false;
    }
  }

  bool confirmPairing() {
    final staged = _pendingAccounts;
    if (staged == null) return false;
    try {
      final next = [..._accounts];
      final existing = {
        for (final account in next)
          PublicBackupService.accountIdentity(account): account
      };
      for (final account in staged) {
        final identity = PublicBackupService.accountIdentity(account);
        final collision = existing[identity];
        if (collision != null) {
          if (!PublicBackupService.sameImmutableAccount(collision, account)) {
            throw const FormatException('同網路地址的公開派生資料與既有帳戶衝突');
          }
          continue;
        }
        existing[identity] = account;
        next.add(account);
      }
      PublicBackupService.validateEvmBindingConflicts(next);
      final ok = _commit(next, _selectedIndex);
      if (ok) _pendingAccounts = null;
      return ok;
    } catch (e) {
      setState(() => _pairingError = '配對失敗：$e；既有帳戶資料未變更');
      return false;
    }
  }

  void renameAccount(int index, String label) {
    if (index < 0 || index >= _accounts.length || label.trim().isEmpty) return;
    final trimmedLabel = label.trim();
    if (trimmedLabel.length > 100) {
      setState(() => _pairingError = '帳戶名稱不得超過 100 字元，原有名稱已保留');
      return;
    }
    final next = [..._accounts];
    next[index] = next[index].copyWith(label: trimmedLabel);
    _commit(next, _selectedIndex);
  }

  void removeAccountAt(int index) {
    if (index < 0 || index >= _accounts.length) return;
    final next = [..._accounts]..removeAt(index);
    final selected = next.isEmpty
        ? 0
        : (index < _selectedIndex
            ? _selectedIndex - 1
            : _selectedIndex.clamp(0, next.length - 1));
    _commit(next, selected);
  }

  void selectAccount(int index) {
    if (index >= 0 && index < _accounts.length) _commit([..._accounts], index);
  }

  void selectChainId(int chainId) {
    if (!AccountStore.supportedChains.contains(chainId)) {
      setState(() => _pairingError = '僅支援 Sepolia 與本機測試鏈');
      return;
    }
    _commit([..._accounts], _selectedIndex, chainId: chainId);
  }

  NodeRpcClient get _rpc =>
      widget.rpcOverride ?? NodeRpcClient(rpcUrl: _savedRpcUrl);

  Future<void> _openEvmRoute(
      Widget Function(NodeRpcClient rpc) screenBuilder) async {
    final shared = widget.rpcOverride;
    final rpc = shared ??
        widget.routeRpcFactory?.call(_savedRpcUrl) ??
        NodeRpcClient(rpcUrl: _savedRpcUrl);
    final route = MaterialPageRoute<void>(builder: (_) => screenBuilder(rpc));
    try {
      unawaited(Navigator.of(context).push(route));
      // A popped route can still use its client during the reverse transition.
      await route.completed;
    } finally {
      if (shared == null) rpc.close();
    }
  }

  Future<void> applyRpcSettings() async {
    final url = _rpcUrlCtrl.text.trim();
    final kind = NodeUrlPolicy.classify(url);
    if (kind == NodeUrlKind.invalid) {
      setState(() => _pairingError = '請輸入有效 http／https RPC 網址');
      return;
    }
    if (kind == NodeUrlKind.publicHttp) {
      setState(
          () => _pairingError = 'RPC 設定未套用：${NodeUrlPolicy.publicHttpRefused}');
      return;
    }
    final chain = _selectedChainId;
    final generation = _balanceGeneration;
    final rpc = widget.rpcOverride ?? NodeRpcClient(rpcUrl: url);
    try {
      await rpc.verifyChainId(chain);
      if (!mounted ||
          chain != _selectedChainId ||
          generation != _balanceGeneration) {
        return;
      }
      if (_commit([..._accounts], _selectedIndex, rpcUrl: url)) {
        setState(() => _rpcStatusMessage = 'RPC 已驗證 Chain ID $chain 並儲存');
      }
    } catch (e) {
      if (mounted) setState(() => _pairingError = 'RPC 設定未套用：$e');
    } finally {
      if (widget.rpcOverride == null) rpc.close();
    }
  }

  Future<void> refreshBalances() async {
    final acc = currentAccount;
    if (acc == null || acc.assetFamily != 'EVM') return;
    final refusal = NodeUrlPolicy.savedUrlRefusal(
        widget.rpcOverride?.rpcUrl ?? _savedRpcUrl,
        settings: '網路與節點設定',
        outcome: '沒有連線到節點');
    if (refusal != null) {
      setState(() {
        _clearBalances();
        _rpcStatusMessage = refusal;
      });
      return;
    }
    final rpc = _rpc;
    final generation = ++_balanceGeneration;
    setState(() {
      _loadingBalance = true;
      _balanceUpdatedAt = null;
      _ethBalanceDisplay = '--';
      _usdcBalanceDisplay = '--';
      _daiBalanceDisplay = '--';
      _rpcStatusMessage = '正在驗證網路並查詢餘額…';
    });
    try {
      await rpc.verifyChainId(acc.chainId);
      final wei = await rpc.getBalance(acc.address);
      var usdc = '本網路未設定';
      var dai = '本網路未設定';
      var tokenError = false;
      if (acc.chainId == 11155111) {
        try {
          usdc =
              '${DecimalAmountParser.formatBaseUnits(await rpc.getErc20Balance(tokenContract: NodeRpcClient.sepoliaUsdcContract, holderAddress: acc.address), decimals: 6, maxFractionDigits: 6)} USDC';
        } catch (_) {
          usdc = '查詢失敗';
          tokenError = true;
        }
        try {
          dai =
              '${DecimalAmountParser.formatBaseUnits(await rpc.getErc20Balance(tokenContract: NodeRpcClient.sepoliaDaiContract, holderAddress: acc.address), decimals: 18, maxFractionDigits: 18)} DAI';
        } catch (_) {
          dai = '查詢失敗';
          tokenError = true;
        }
      }
      if (!mounted || generation != _balanceGeneration) return;
      setState(() {
        _rpcOnline = true;
        _loadingBalance = false;
        _balanceUpdatedAt = DateTime.now();
        _ethBalanceDisplay =
            '${DecimalAmountParser.formatBaseUnits(wei, decimals: 18, maxFractionDigits: 18)} ETH';
        _usdcBalanceDisplay = usdc;
        _daiBalanceDisplay = dai;
        _rpcStatusMessage =
            'RPC 在線，Chain ID ${acc.chainId} 已驗證${tokenError ? '；部分 Token 查詢失敗' : ''}';
      });
    } catch (e) {
      if (!mounted || generation != _balanceGeneration) return;
      setState(() {
        _loadingBalance = false;
        _rpcOnline = false;
        _ethBalanceDisplay = '無法查詢';
        _usdcBalanceDisplay = '無法查詢';
        _daiBalanceDisplay = '無法查詢';
        _rpcStatusMessage = 'RPC 離線或錯誤：$e';
      });
    } finally {
      if (widget.rpcOverride == null) rpc.close();
    }
  }

  void _scanPairingQr() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AirGapScanner(
            expectedType: 'crypto-multi-accounts',
            title: '掃描金庫公開帳戶配對碼',
            onOpenAppSettings: defaultTargetPlatform == TargetPlatform.android
                ? () => const MethodChannel('fcw/platform')
                    .invokeMethod<void>('openAppSettings')
                : null,
            onPayloadComplete: (_) {},
            onRawUrComplete: (input) async {
              Navigator.of(context).pop();
              if (!ingestPairingUr(input) || !mounted) return;
              final staged = pendingAccounts;
              final warning = _pairingWarning;
              final approved = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                          title: const Text('確認匯入公開觀察帳戶'),
                          content: SingleChildScrollView(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                if (warning != null)
                                  FcwBanner(
                                      tone: FcwTone.warning, message: warning),
                                ...staged.map((a) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(a.assetFamily == 'BTC'
                                        ? Icons.currency_bitcoin
                                        : Icons.hub_outlined),
                                    title:
                                        Text('${a.label} · ${a.assetFamily}'),
                                    subtitle: Text(
                                        style: fcwMono(
                                            Theme.of(ctx).textTheme.bodySmall),
                                        '${a.address}\n${a.assetFamily == 'BTC' ? 'Bitcoin regtest' : 'Chain ID ${a.chainId}'}\n${a.derivationPath}\n主指紋 ${a.masterFingerprint.toUpperCase()}')))
                              ])),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消')),
                            ElevatedButton(
                                key: const Key('confirm_pairing_btn'),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('確認並儲存'))
                          ]));
              if (!mounted) return;
              if (approved == true) {
                confirmPairing();
              } else {
                _pendingAccounts = null;
              }
            })));
  }

  AccountSnapshot get _snapshot => AccountSnapshot(
      accounts: List.unmodifiable(_accounts),
      selectedIndex: _selectedIndex,
      chainId: _selectedChainId,
      rpcUrl: _savedRpcUrl);
  bool _mergePublicAccounts(List<AccountDescriptor> incoming) {
    if (!mounted) return false;
    setState(() => _publicImportPending = _isPublicImportPending());
    final next = [..._accounts];
    final existing = {
      for (final account in next)
        PublicBackupService.accountIdentity(account): account
    };
    for (final account in incoming) {
      _validateAccount(account);
      final identity = PublicBackupService.accountIdentity(account);
      final collision = existing[identity];
      if (collision != null) {
        if (!PublicBackupService.sameImmutableAccount(collision, account)) {
          throw const FormatException('公開帳戶與既有同網路地址的資料衝突');
        }
        continue;
      }
      existing[identity] = account;
      next.add(account);
    }
    PublicBackupService.validateEvmBindingConflicts(next);
    if (_recoverableAccountStore) {
      try {
        final preserved = _store!.recoverWithSnapshot(AccountSnapshot(
            accounts: next,
            selectedIndex: 0,
            chainId: _selectedChainId,
            rpcUrl: _savedRpcUrl));
        setState(() {
          _accounts = next;
          _selectedIndex = 0;
          _ready = true;
          _recoverableAccountStore = false;
          _fatalError = null;
          _pairingError = null;
          _accountRecoveryNotice = '公開帳戶已還原；原始無法讀取的帳戶檔案完整保留於 $preserved';
          _historyRecoveryError = '正在核對交易紀錄；核對完成前暫停 EVM 轉帳與交易恢復。';
          _clearBalances();
        });
        unawaited(loadPersistedAccounts());
        return true;
      } catch (e) {
        setState(() => _pairingError = '公開帳戶還原未保存，原始檔案已保留：$e');
        return false;
      }
    }
    return _commit(next, _selectedIndex);
  }

  void _showPublicBackup() {
    setState(() => _publicImportPending = true);
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PublicBackupScreen(
              snapshot: _snapshot,
              snapshotProvider: () => _snapshot,
              persistedSnapshotProvider: () => _store!.load(),
              importAccounts: _mergePublicAccounts,
              recoveryMode: _recoverableAccountStore,
              service: PublicBackupService(
                  ffi: _ffi,
                  directoryOverride: widget.storagePathOverride == null
                      ? null
                      : File(widget.storagePathOverride!).parent.path),
            ))).then((_) {
      if (mounted) setState(() => _publicImportPending = _isPublicImportPending());
    });
  }

  Future<void> _showRenameDialog() async {
    final acc = currentAccount;
    if (acc == null) return;
    final ctrl = TextEditingController(text: acc.label);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新命名觀察帳戶'),
        content: TextField(
          key: const Key('rename_account_field'),
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '帳戶名稱',
            helperText: '最多 100 字元',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            key: const Key('rename_account_submit_btn'),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (newName != null && newName.trim().isNotEmpty) {
      renameAccount(_selectedIndex, newName);
    }
  }

  String _networkLabel(AccountDescriptor account) =>
      account.assetFamily == 'BTC'
          ? 'Bitcoin regtest'
          : switch (account.chainId) {
              11155111 => 'Ethereum Sepolia',
              31337 => 'Anvil 本機網路',
              1337 => 'Hardhat 本機網路',
              _ => 'Chain ID ${account.chainId}',
            };

  void _showReceiveModal() {
    final acc = currentAccount;
    if (acc == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('收款'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(acc.label, style: Theme.of(ctx).textTheme.titleMedium),
                Text(_networkLabel(acc)),
                const SizedBox(height: 16),
                AnimatedFountainQr(
                  frames: [acc.address],
                  qrSize: 220,
                  title: '收款地址',
                  subtitle: _networkLabel(acc),
                ),
                const SizedBox(height: 16),
                FcwCodeBlock(
                  child: SelectableText(
                    acc.address,
                    key: const Key('receive_modal_address_text'),
                    style: fcwMono(Theme.of(ctx).textTheme.bodyLarge),
                  ),
                ),
                const SizedBox(height: FcwSpace.lg),
                const FcwBanner(
                  tone: FcwTone.warning,
                  icon: Icons.fact_check_outlined,
                  message: '首次收款前，請在 Vault 逐字核對地址。',
                ),
                const SizedBox(height: FcwSpace.sm),
                SelectableText(
                  '主指紋 ${acc.masterFingerprint.toUpperCase()}\n派生路徑 ${acc.derivationPath}',
                  style: fcwMono(Theme.of(ctx).textTheme.bodySmall).copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成')),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 20),
            label: const Text('複製地址'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: acc.address));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已複製收款地址')),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acc = currentAccount;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: FcwSpace.page,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FcwRoleBadge(FcwRole.wallet),
            SizedBox(width: FcwSpace.md),
            Flexible(child: Text('Wallet')),
          ],
        ),
        actions: [
          IconButton(
              key: const Key('public_backup_btn'),
              icon: const Icon(Icons.save_alt),
              tooltip: '公開備份與還原',
              onPressed: _ready || _recoverableAccountStore
                  ? _showPublicBackup
                  : null),
          IconButton(
            key: const Key('scan_pairing_qr_btn'),
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '加入觀察帳戶',
            onPressed: _ready ? _scanPairingQr : null,
          ),
          const SizedBox(width: FcwSpace.xs),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_fatalError != null)
                  _message(_fatalError!,
                      key: const Key('wallet_fatal_error'), error: true),
                if (_accountRecoveryNotice != null)
                  _message(_accountRecoveryNotice!,
                      key: const Key('account_recovery_notice')),
                if (_historyRecoveryError != null)
                  _message(_historyRecoveryError!,
                      key: const Key('history_recovery_error'), error: true),
                if (_publicImportPending)
                  _message('公開備份還原尚未完成；受影響帳戶的新付款暫停，仍可查看及查詢原交易。請回到公開備份完成各步驟；離開或暫停不會解除付款保留。',
                      key: const Key('public_import_pending'), error: true),
                if (_fatalError == null && !_ready)
                  const Padding(
                    padding: EdgeInsets.only(bottom: FcwSpace.lg),
                    child: LinearProgressIndicator(),
                  ),
                if (_pairingWarning != null)
                  _message(_pairingWarning!, key: const Key('pairing_warning')),
                if (_pairingError != null)
                  _message(_pairingError!,
                      key: const Key('wallet_pairing_error_text'), error: true),
                if (acc == null)
                  _buildEmptyUnpairedView()
                else
                  _buildPairedAccountView(acc),
                const SizedBox(height: FcwSpace.xl),
                const FcwUnauditedBanner(key: Key('wallet_unaudited_notice')),
                const SizedBox(height: FcwSpace.md),
                // A third app bar action would cut the title at 320dp.
                FcwPanel(
                  padding: const EdgeInsets.symmetric(vertical: FcwSpace.xs),
                  child: ListTile(
                    key: const Key('about_btn'),
                    leading: const Icon(Icons.info_outline),
                    title: const Text('關於與隱私權政策'),
                    subtitle: const Text('版本、原始碼與資料處理方式'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const FcwAboutPage(
                            appName: appName, version: appVersion))),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _message(String message, {Key? key, bool error = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FcwSpace.lg),
      child: FcwBanner(
        tone: error ? FcwTone.danger : FcwTone.info,
        content: SelectableText(message, key: key),
      ),
    );
  }

  Widget _buildEmptyUnpairedView() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: FcwSpace.xl),
      child: FcwPanel(
        padding: const EdgeInsets.all(FcwSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(FcwRadius.input),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(FcwSpace.md),
                  child: Icon(Icons.qr_code_2,
                      size: 32, color: colors.onPrimaryContainer),
                ),
              ),
            ),
            const SizedBox(height: FcwSpace.lg),
            Text('加入觀察帳戶',
                key: const Key('no_paired_accounts_title'),
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: FcwSpace.sm),
            Text('掃描 Vault 顯示的帳戶配對碼。\n私鑰保存在 Vault。',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: colors.onSurfaceVariant)),
            const SizedBox(height: FcwSpace.xl),
            FilledButton.icon(
              key: const Key('empty_state_scan_pairing_btn'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('掃描配對碼'),
              onPressed: _ready ? _scanPairingQr : null,
            ),
            const SizedBox(height: FcwSpace.md),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('還原公開備份'),
              onPressed:
                  _ready || _recoverableAccountStore ? _showPublicBackup : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPairedAccountView(AccountDescriptor acc) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('account_switcher_dropdown_$_selectedIndex'),
          isExpanded: true,
          initialValue: _selectedIndex.clamp(0, _accounts.length - 1),
          decoration: const InputDecoration(labelText: '觀察帳戶'),
          items: List.generate(_accounts.length, (i) {
            final item = _accounts[i];
            final shortAddr = item.address.length > 14
                ? '${item.address.substring(0, 8)}…${item.address.substring(item.address.length - 6)}'
                : item.address;
            return DropdownMenuItem<int>(
              value: i,
              child: Text('${item.label} · $shortAddr',
                  overflow: TextOverflow.ellipsis),
            );
          }),
          onChanged: (idx) {
            if (idx != null) selectAccount(idx);
          },
        ),
        const SizedBox(height: FcwSpace.lg),
        FcwPanel(
          padding: const EdgeInsets.all(FcwSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: FcwSpace.sm,
                runSpacing: FcwSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FcwStatusPill(_networkLabel(acc),
                      tone: FcwTone.info,
                      icon: acc.assetFamily == 'BTC'
                          ? Icons.currency_bitcoin
                          : Icons.hub_outlined),
                  FcwStatusPill('主指紋 ${acc.masterFingerprint.toUpperCase()}',
                      icon: Icons.fingerprint),
                ],
              ),
              const SizedBox(height: FcwSpace.lg),
              Text(acc.label,
                  key: const Key('current_account_label_text'),
                  style: theme.textTheme.headlineSmall),
              if (acc.assetFamily == 'EVM') ...[
                const SizedBox(height: FcwSpace.xl),
                Text('鏈上餘額',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: colors.onSurfaceVariant)),
                const SizedBox(height: FcwSpace.xs),
                Text('ETH: $_ethBalanceDisplay',
                    key: const Key('eth_balance_text'),
                    style: fcwFigures(theme.textTheme.headlineMedium)),
                const SizedBox(height: FcwSpace.md),
                Wrap(spacing: FcwSpace.lg, runSpacing: FcwSpace.xs, children: [
                  Text('USDC: $_usdcBalanceDisplay',
                      style: fcwFigures(theme.textTheme.bodyLarge)),
                  Text('DAI: $_daiBalanceDisplay',
                      style: fcwFigures(theme.textTheme.bodyLarge)),
                ]),
                const SizedBox(height: FcwSpace.md),
                if (_loadingBalance)
                  const Padding(
                    padding: EdgeInsets.only(bottom: FcwSpace.sm),
                    child: LinearProgressIndicator(),
                  ),
                Text(
                    _balanceUpdatedAt == null
                        ? '尚未取得本帳戶餘額'
                        : '更新時間：${_balanceUpdatedAt!.toLocal()}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant)),
                if (_rpcStatusMessage != null) ...[
                  const SizedBox(height: FcwSpace.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                            _rpcOnline
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                            size: 18,
                            color: _rpcOnline
                                ? colors.primary
                                : colors.onSurfaceVariant),
                      ),
                      const SizedBox(width: FcwSpace.sm),
                      Expanded(
                        child: Text(_rpcStatusMessage!,
                            key: const Key('rpc_status_message_text'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: _rpcOnline
                                    ? colors.primary
                                    : colors.onSurfaceVariant)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: FcwSpace.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('refresh_rpc_balances_btn'),
                    icon: const Icon(Icons.refresh),
                    label: const Text('更新餘額'),
                    onPressed: _loadingBalance ? null : refreshBalances,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: FcwSpace.lg),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('create_unsigned_tx_btn'),
                icon: const Icon(Icons.north_east),
                label: const Text('轉帳'),
                onPressed:
                    _blocksPayment(acc) ||
                            (acc.assetFamily == 'EVM' && _historyRecoveryError != null)
                        ? null
                        : () {
                            if (!_canOpenTransferRoute(acc)) return;
                            if (acc.assetFamily == 'BTC') {
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => BitcoinSendScreen(account: acc)));
                            } else {
                              _openEvmRoute((rpc) => SendTxScreen(
                                  account: acc, ffiOverride: _ffi, rpcOverride: rpc));
                            }
                          },
              ),
            ),
            const SizedBox(width: FcwSpace.md),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('show_receive_qr_btn'),
                icon: const Icon(Icons.south_west),
                label: const Text('收款'),
                onPressed: _showReceiveModal,
              ),
            ),
          ],
        ),
        const SizedBox(height: FcwSpace.lg),
        FcwPanel(
          padding: const EdgeInsets.symmetric(vertical: FcwSpace.xs),
          child: ListTile(
            key: const Key('account_history_btn'),
            leading: const Icon(Icons.history),
            title: const Text('交易紀錄'),
            subtitle: const Text('此 Wallet 建立的請求與交易'),
            trailing: const Icon(Icons.chevron_right),
            onTap: (acc.assetFamily == 'EVM' && _historyRecoveryError != null)
                ? null
                : () {
                    if (acc.assetFamily == 'BTC') {
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => BitcoinSendScreen(account: acc)));
                    } else {
                      _openEvmRoute((rpc) => TransactionHistoryScreen(
                          account: acc, rpcOverride: rpc));
                    }
                  },
          ),
        ),
        const SizedBox(height: FcwSpace.lg),
        FcwPanel(
          padding: const EdgeInsets.symmetric(horizontal: FcwSpace.md),
          child: Column(
            children: [
              ExpansionTile(
                key: const Key('account_details_toggle'),
                maintainState: true,
                leading: const Icon(Icons.badge_outlined),
                title: const Text('帳戶資料'),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(acc.address,
                          key: const Key('current_account_address_text'),
                          style: fcwMono(theme.textTheme.bodyLarge))),
                  const SizedBox(height: FcwSpace.md),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                          '主指紋 ${acc.masterFingerprint.toUpperCase()}\n派生路徑 ${acc.derivationPath}',
                          key: const Key('current_account_fp_path_text'),
                          style: theme.textTheme.bodyMedium)),
                  const SizedBox(height: FcwSpace.md),
                  Wrap(
                      spacing: FcwSpace.sm,
                      runSpacing: FcwSpace.sm,
                      children: [
                        TextButton.icon(
                            key: const Key('rename_account_btn'),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('重新命名'),
                            onPressed: _showRenameDialog),
                        TextButton.icon(
                            key: const Key('remove_account_btn'),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('移除觀察帳戶'),
                            style: TextButton.styleFrom(
                                foregroundColor: colors.error),
                            onPressed: () => removeAccountAt(_selectedIndex)),
                      ]),
                ],
              ),
              if (acc.assetFamily == 'EVM') ...[
                const Divider(),
                ExpansionTile(
                  key: const Key('node_settings_toggle'),
                  maintainState: true,
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('網路與節點設定'),
                  subtitle: Text(_networkLabel(acc)),
                  children: [
                    DropdownButtonFormField<int>(
                      key: ValueKey('network_$_selectedChainId'),
                      isExpanded: true,
                      initialValue: _selectedChainId,
                      decoration: const InputDecoration(labelText: '網路'),
                      items: const [
                        DropdownMenuItem(
                            value: 11155111, child: Text('Sepolia · 11155111')),
                        DropdownMenuItem(
                            value: 31337, child: Text('Anvil · 31337')),
                        DropdownMenuItem(
                            value: 1337, child: Text('Hardhat · 1337')),
                      ],
                      onChanged: (v) {
                        if (v != null) selectChainId(v);
                      },
                    ),
                    const SizedBox(height: FcwSpace.lg),
                    NodeUrlField(
                      fieldKey: const Key('rpc_url_input_field'),
                      controller: _rpcUrlCtrl,
                    ),
                    const SizedBox(height: FcwSpace.md),
                    OutlinedButton(
                        key: const Key('save_rpc_settings_btn'),
                        onPressed: applyRpcSettings,
                        child: const Text('驗證並儲存節點')),
                    if (acc.chainId == 11155111)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: FcwSpace.lg),
                        child: SelectableText(
                            'Sepolia 代幣合約\nUSDC ${NodeRpcClient.sepoliaUsdcContract}\nDAI ${NodeRpcClient.sepoliaDaiContract}',
                            style: fcwMono(theme.textTheme.bodySmall)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
