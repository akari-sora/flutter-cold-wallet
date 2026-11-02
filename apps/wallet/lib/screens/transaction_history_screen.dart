import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import '../widgets/outcome_style.dart';
import 'package:public_models/public_models.dart';
import '../ffi/wallet_ffi_service.dart';
import '../services/node_rpc_client.dart';
import '../services/transaction_history.dart';
import 'scan_signature_screen.dart';

class TransactionHistoryScreen extends StatefulWidget {
  final AccountDescriptor account;
  final NodeRpcClient? rpcOverride;
  final WalletFfiService? ffiOverride;
  final TransactionHistory? historyOverride;
  const TransactionHistoryScreen(
      {super.key,
      required this.account,
      this.rpcOverride,
      this.ffiOverride,
      this.historyOverride});
  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  late Future<List<Map<String, dynamic>>> _records;
  String _displayTime(dynamic value) {
    final time = value is String ? DateTime.tryParse(value)?.toLocal() : null;
    if (time == null) return '未記錄';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}/${two(time.month)}/${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)} ${time.timeZoneName}';
  }

  @override
  void initState() {
    super.initState();
    _records = (widget.historyOverride ?? TransactionHistory()).read();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('交易紀錄')),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _records,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                    padding: const EdgeInsets.all(FcwSpace.xl),
                    child: FcwBanner(
                      tone: FcwTone.danger,
                      content: SelectableText('交易紀錄讀取失敗：${snapshot.error}',
                          style: TextStyle(
                              color: FcwPalette.resolve(context)
                                  .danger
                                  .onContainer)),
                    )),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final records = snapshot.data!
                .where((r) =>
                    (r['account'] as String?)?.toLowerCase() ==
                        widget.account.address.toLowerCase() &&
                    r['chainId'] == widget.account.chainId)
                .toList();
            final theme = Theme.of(context);
            final palette = FcwPalette.resolve(context);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(widget.account.label,
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: FcwSpace.xs),
                        Text('僅顯示此 Wallet 建立的請求；不代表完整鏈上歷史。',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: FcwSpace.xl),
                        if (records.isEmpty)
                          FcwPanel(
                            padding: const EdgeInsets.all(FcwSpace.xl),
                            child: Row(children: [
                              Icon(Icons.inbox_outlined,
                                  color: theme.colorScheme.onSurfaceVariant),
                              const SizedBox(width: FcwSpace.md),
                              Expanded(
                                child: Text('尚無本機交易紀錄',
                                    style: theme.textTheme.titleMedium),
                              ),
                            ]),
                          ),
                        ...records.map((r) {
                          final state = r['state'] is String
                              ? r['state'] as String
                              : 'unknown';
                          return Card(
                            margin: const EdgeInsets.only(bottom: FcwSpace.md),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(FcwSpace.lg),
                              leading: Icon(outcomeIcon(state),
                                  color: palette.of(outcomeTone(state)).accent),
                              title: Text(TransactionOutcome.label(state)),
                              subtitle: Padding(
                                padding:
                                    const EdgeInsets.only(top: FcwSpace.sm),
                                child: Text('EVM · Chain ID ${r['chainId']}\n'
                                    '紀錄更新：${_displayTime(r['updatedAt'])}\n'
                                    '${r['hash'] == null ? '請求 ID' : '交易 hash'}：${r['hash'] ?? r['requestId']}'),
                              ),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(
                                  builder: (_) => ScanSignatureScreen(
                                    account: widget.account,
                                    ffiOverride: widget.ffiOverride,
                                    rpcOverride: widget.rpcOverride,
                                    historyOverride: widget.historyOverride,
                                    sessionId: r['sessionId'] is String
                                        ? r['sessionId'] as String
                                        : '',
                                    requestId: r['requestId'] is String
                                        ? r['requestId'] as String
                                        : '',
                                    unsignedRlpHex:
                                        r['unsignedPayload'] is String
                                            ? r['unsignedPayload'] as String
                                            : '',
                                    restoredRecord: r,
                                  ),
                                ));
                                if (mounted) {
                                  setState(() => _records =
                                      (widget.historyOverride ??
                                              TransactionHistory())
                                          .read());
                                }
                              },
                            ),
                          );
                        }),
                      ]),
                ),
              ),
            );
          },
        ),
      );
}
