import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import '../services/account_store.dart';
import '../services/public_backup.dart';

class PublicBackupScreen extends StatefulWidget {
  final AccountSnapshot snapshot;
  final PublicBackupService service;
  final AccountSnapshot Function()? snapshotProvider;
  final AccountSnapshot Function()? persistedSnapshotProvider;
  final bool Function(List<AccountDescriptor>) importAccounts;
  final bool recoveryMode;
  const PublicBackupScreen(
      {super.key,
      required this.snapshot,
      required this.service,
      required this.importAccounts,
      this.recoveryMode = false,
      this.snapshotProvider,
      this.persistedSnapshotProvider});
  @override
  State<PublicBackupScreen> createState() => PublicBackupScreenState();
}

class PublicBackupScreenState extends State<PublicBackupScreen> {
  AccountSnapshot get _snapshot =>
      widget.snapshotProvider?.call() ?? widget.snapshot;
  late final Future<void> initialized;
  bool _busy = true;
  String? _error;
  String? _notice;
  bool _progressUnreadable = false;
  PublicImportProgress? _progress;
  PublicBackupBundle? _bundle;
  @override
  void initState() {
    super.initState();
    initialized = _resume();
  }

  Future<void> _resume() async {
    try {
      final progress = await widget.service.readProgress();
      if (progress != null) {
        if (widget.recoveryMode) progress.accountsDone = false;
        _progress = progress;
        _bundle = PublicBackupCodec.decode(progress.backupJson);
        _notice = '找到未完成的公開備份還原。已完成步驟會保留；重試同一步驟不會新增重複紀錄。若進度無法辨識，所有帳戶的新付款均會暫停。';
        if (!widget.recoveryMode) await _finishIfComplete();
      }
    } catch (e) {
      _progressUnreadable = _bundle == null;
      _error = _bundle == null
          ? '還原進度無法讀取或辨識，原始檔案已保留：$e'
          : '還原尚未完成，原始資料已保留；可重新核對並合併帳戶：$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> exportBackup() async {
    if (widget.recoveryMode) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final snapshot = _snapshot;
      final preview = await widget.service.prepareExport(snapshot);
      if (!mounted) return;
      setState(() => _busy = false);
      String reasons(Map<String, int> counts) => counts.entries
          .map((entry) =>
              '${entry.key == 'other_chain' ? '其他網路' : '未配對帳戶'} ${entry.value}')
          .join('、');
      if (!await _confirm(
          '確認匯出目前帳戶與網路',
          '此備份包含目前 ${preview.includedAccountCount} 個觀察帳戶、${preview.includedEvmTransactionCount} 筆 EVM 紀錄及 ${preview.includedBitcoinRecordCount} 份 Bitcoin 紀錄。EVM 網路 Chain ID：${snapshot.chainId}；Bitcoin：regtest。\n'
              '未納入 EVM 紀錄：${preview.excludedEvmCount} 筆${preview.excludedEvmCount == 0 ? '' : '（${reasons(preview.evmExclusionReasons)}）'}。\n'
              '未納入 Bitcoin 紀錄：${preview.excludedBitcoinRecordCount} 份${preview.excludedBitcoinRecordCount == 0 ? '' : '（${reasons(preview.bitcoinExclusionReasons)}）'}。\n'
              'Bitcoin 每份紀錄包含該帳戶的待處理交易與本機歷史。未納入的資料會完整保留在本機；重新配對帳戶並選擇對應網路後可另行備份。',
          confirmLabel: '確認並選擇儲存位置')) {
        return;
      }
      if (!mounted) return;
      setState(() => _busy = true);
      final saved = await const MethodChannel('fcw/platform')
          .invokeMethod<bool>('savePublicBackup', {'json': preview.backupJson});
      if (saved != true) throw StateError('公開備份檔案未儲存');
      if (mounted) {
        setState(() => _notice =
            '已儲存公開帳戶與目前網路的本機交易紀錄；未納入 ${preview.excludedEvmCount} 筆 EVM／${preview.excludedBitcoinRecordCount} 份 Bitcoin 紀錄，原始資料仍保留在本機。未包含助記詞、私鑰或 RPC 帳密。');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '公開備份未完成：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> readBackup() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final source = await const MethodChannel('fcw/platform')
          .invokeMethod<String>('readPublicBackup');
      if (source == null) throw StateError('未選取公開備份檔案');
      await widget.service.preflightImport(PublicBackupCodec.decode(source), _snapshot);
      final progress = await widget.service.beginImport(source);
      if (mounted) {
        setState(() {
          _progress = progress;
          _bundle = PublicBackupCodec.decode(source);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '公開備份驗證失敗，尚未修改帳戶或交易：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String detail,
          {String confirmLabel = '確認匯入'}) async =>
      await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text(title),
                  content: SingleChildScrollView(child: Text(detail)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    ElevatedButton(
                        key: const Key('confirm_public_import'),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(confirmLabel))
                  ])) ==
      true;
  Future<void> importAccountPhase() async {
    if (_progress == null ||
        _bundle == null ||
        _busy) {
      return;
    }
    if (!await _confirm(widget.recoveryMode ? '確認還原無法讀取的帳戶資料' : '確認合併觀察帳戶',
        '${widget.recoveryMode ? '確認後會先完整另存原始無法讀取的帳戶檔案，再將已驗證的公開帳戶保存為目前帳戶。預覽與取消均不覆寫原始帳戶檔案。' : '既有名稱與帳戶會保留，重複帳戶不新增。'}\n匯入 ${_bundle!.accounts.length} 個已驗證公開帳戶。每個 EVM 帳戶會保留備份中已驗證的測試網路綁定；目前選定網路不會改寫帳戶資料。')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.preflightImport(_bundle!, _snapshot);
      _progress!.accountsStarted = true;
      await widget.service.saveProgress(_progress!);
      if (!widget.importAccounts(_bundle!.accounts)) {
        throw StateError('帳戶原子保存失敗，尚未匯入交易紀錄');
      }
      _progress!.accountsDone = true;
      await widget.service.saveProgress(_progress!);
      await _finishIfComplete();
    } catch (e) {
      _progress!.accountsDone = false;
      if (mounted) setState(() => _error = '帳戶還原步驟未完成：$e。可重試此步驟。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> importHistoryPhase() async {
    if (_progress == null ||
        _bundle == null ||
        _busy ||
        !_progress!.accountsDone ||
        _progress!.evmDone) {
      return;
    }
    if (!await _confirm('確認合併 EVM 本機交易紀錄',
        '匯入 ${_bundle!.transactions.length} 筆公開交易。恢復後一律為結果待查，開啟時重新驗章並查詢同一交易，才可重新廣播同一份已簽內容。')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.importTransactions(_bundle!, snapshot: _snapshot);
      _progress!.evmDone = true;
      await widget.service.saveProgress(_progress!);
      await _finishIfComplete();
    } catch (e) {
      _progress!.evmDone = false;
      if (mounted) setState(() => _error = 'EVM 紀錄還原步驟未完成：$e。已存在紀錄會保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> importBitcoinPhase(Map<String, dynamic> record) async {
    final fingerprint = record['master_fingerprint'] as String;
    if (_progress == null ||
        _bundle == null ||
        _busy ||
        !_progress!.accountsDone ||
        _progress!.bitcoinDone.contains(fingerprint)) {
      return;
    }
    if (!await _confirm('確認合併 Bitcoin 本機紀錄',
        '帳戶：${record['account_address']}\n已簽交易會恢復為結果待查並再次驗證；未簽請求只保留為歷史資料，不恢復舊批准。既有不同待處理交易不會被覆寫。')) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.importBitcoinRecord(_bundle!, record);
      _progress!.bitcoinDone.add(fingerprint);
      await widget.service.saveProgress(_progress!);
      await _finishIfComplete();
    } catch (e) {
      _progress!.bitcoinDone.remove(fingerprint);
      if (mounted) setState(() => _error = 'Bitcoin 紀錄還原步驟未完成：$e。既有紀錄已保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishIfComplete() async {
    if (_progress!.accountsDone &&
        _progress!.evmDone &&
        _bundle!.bitcoinRecords.every(
            (r) => _progress!.bitcoinDone.contains(r['master_fingerprint']))) {
      final persisted = widget.persistedSnapshotProvider;
      if (persisted == null) throw StateError('無法讀回已保存的帳戶資料');
      await widget.service.completeImport(_progress!, _snapshot,
          snapshotProvider: () => _snapshot, persistedSnapshotProvider: persisted);
      if (mounted) {
        setState(() {
          _progress = null;
          _bundle = null;
          _notice = '公開帳戶與交易紀錄還原完成，已確認保存的交易資料。';
        });
      }
    }
  }

  Future<void> cancelImport() async {
    if (_progress == null) return;
    if (_progress!.accountsStarted) {
      if (mounted) {
        setState(() => _notice = '還原已暫停，進度已保留；受影響帳戶的新付款暫停。若進度無法辨識，所有帳戶的新付款均會暫停。');
      }
      return;
    }
    if (!await _confirm('取消尚未完成的還原', '只移除這次還原進度。已匯入的公開帳戶與紀錄會保留。',
        confirmLabel: '確認取消還原')) {
      return;
    }
    try {
      await widget.service.clearProgress();
      if (mounted) {
        setState(() {
          _progress = null;
          _bundle = null;
          _error = null;
          _notice = '已取消尚未完成的還原；既有資料已保留。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '無法清除還原進度：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('公開備份')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('保存 Wallet 的公開資料', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  const Text(
                      '備份包含目前配對帳戶及其所選網路的本機交易。匯出前會顯示未納入的紀錄數量。公開地址、公鑰及交易仍屬隱私資料，請妥善保管。'),
                  if (widget.recoveryMode) ...[
                    const SizedBox(height: 12),
                    const Text(
                        '目前帳戶檔案無法讀取，只開放還原。確認匯入後會先完整另存原始檔案，再保存驗證通過的公開帳戶。'),
                  ],
                  const SizedBox(height: 12),
                  const Text('助記詞與私鑰由 Vault 備份；RPC 設定與帳密不隨此備份搬移。'),
                  const SizedBox(height: 24),
                  if (_busy) const LinearProgressIndicator(),
                  if (_progressUnreadable)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('還原進度無法辨識，所有帳戶的新付款均暫停。'),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(_error!,
                          key: const Key('public_backup_error'),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.error)),
                    ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_notice!,
                          key: const Key('public_backup_notice'),
                          style: theme.textTheme.bodyLarge),
                    ),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('匯出備份', style: theme.textTheme.titleLarge),
                              const SizedBox(height: 8),
                              const Text(
                                  '將目前配對帳戶與所選網路紀錄存成檔案。其他紀錄會保留在本機，匯出前可核對未納入的數量。'),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                  key: const Key('export_public_backup'),
                                  icon: const Icon(Icons.save_alt),
                                  onPressed: !widget.recoveryMode &&
                                          !_busy &&
                                          _progress == null
                                      ? exportBackup
                                      : null,
                                  label: const Text('儲存公開備份')),
                            ])),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('還原備份', style: theme.textTheme.titleLarge),
                              const SizedBox(height: 8),
                              const Text('先驗證檔案，再逐步確認合併帳戶與交易。既有資料會保留。'),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                  key: const Key('read_public_backup'),
                                  icon: const Icon(Icons.folder_open),
                                  onPressed: !_busy && _progress == null
                                      ? readBackup
                                      : null,
                                  label: const Text('選取公開備份')),
                            ])),
                  ),
                  if (_bundle != null) ...[
                    const Divider(height: 40),
                    Text('確認還原內容', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    Text(
                        '匯入摘要：${_bundle!.accounts.length} 個帳戶／${_bundle!.transactions.length} 筆 EVM 紀錄／${_bundle!.bitcoinRecords.length} 份 Bitcoin 紀錄'),
                    const SizedBox(height: 16),
                    ..._bundle!.accounts.map((a) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('${a.label} · ${a.assetFamily}',
                                    style: theme.textTheme.titleMedium),
                                const SizedBox(height: 8),
                                SelectableText(
                                    '${a.address}\n${a.derivationPath}\n主指紋 ${a.masterFingerprint.toUpperCase()}'),
                              ]),
                        )),
                    FilledButton(
                        key: const Key('import_public_accounts'),
                        onPressed: !_busy
                            ? importAccountPhase
                            : null,
                        child: Text(_progress!.accountsDone
                            ? '帳戶已保存'
                            : '第一步：確認合併公開帳戶')),
                    if (_progress!.accountsDone)
                      const Text('可再次點選，重新核對並合併備份帳戶。'),
                    if (_bundle!.transactions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: FilledButton(
                            key: const Key('import_public_history'),
                            onPressed: !_busy &&
                                    _progress!.accountsDone &&
                                    !_progress!.evmDone
                                ? importHistoryPhase
                                : null,
                            child: Text(_progress!.evmDone
                                ? 'EVM 紀錄已保存'
                                : '第二步：確認合併 EVM 紀錄')),
                      ),
                    ..._bundle!.bitcoinRecords.map((r) => Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: FilledButton(
                              onPressed: !_busy &&
                                      _progress!.accountsDone &&
                                      !_progress!.bitcoinDone
                                          .contains(r['master_fingerprint'])
                                  ? () => importBitcoinPhase(r)
                                  : null,
                              child: Text(
                                  '合併 Bitcoin 紀錄 ${(r['master_fingerprint'] as String).toUpperCase()}')),
                        )),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: !_busy ? cancelImport : null,
                        child: Text(_progress!.accountsStarted
                            ? '暫停未完成的還原'
                            : '取消未開始的還原')),
                  ],
                  const SizedBox(height: 16),
                  const ExpansionTile(
                    title: Text('備份與還原說明'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(
                              '檔案上限 2 MiB。帳戶、EVM 紀錄與每個 Bitcoin 帳戶分步確認及原子保存；中斷後可在此繼續，重試不新增重複紀錄。恢復後須重新核對節點網路與交易。')),
                    ],
                  ),
                ]),
          ),
        ),
      ),
    );
  }
}
