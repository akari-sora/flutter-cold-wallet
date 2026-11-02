import 'package:flutter/material.dart';
import 'package:public_models/public_models.dart';

import 'components.dart';
import 'tokens.dart';

/// Read-only transaction details from the immutable native review result.
class TransactionReviewCard extends StatelessWidget {
  final PreparedReviewDto review;

  const TransactionReviewCard({super.key, required this.review});

  // vault_ffi refuses new preparations once MAX_RETAINED_PREPARED_REQUESTS
  // signing records are retained for the process; only a restart (vault_init)
  // releases them, a lock does not. The English text is the only marker: the
  // UR path reports it as ERR_REQUEST_REJECTED and the review drops the code.
  static const _retentionLimitPrefix =
      'Prepared request retention limit reached';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isRejected = !review.isSignable;
    final atRetentionLimit = isRejected &&
        (review.rejectionReason?.startsWith(_retentionLimitPrefix) ?? false);
    final amountText = review.isBitcoinPsbt ||
            review.displayAmount.endsWith(review.tokenSymbol)
        ? review.displayAmount
        : '${review.displayAmount} ${review.tokenSymbol}';

    final divider = Padding(
      padding: const EdgeInsets.only(bottom: FcwSpace.lg),
      child: Divider(color: colors.outlineVariant),
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(FcwSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FcwAmountHero(
              caption: review.isBitcoinPsbt ? '外部收款總額' : '轉帳金額',
              amount: amountText,
              amountKey: const Key('review_amount'),
            ),
            const SizedBox(height: FcwSpace.xl),
            _field(
              context,
              '收款地址',
              review.recipient.isEmpty
                  ? review.isBitcoinPsbt
                      ? '無法驗證'
                      : '合約或空白'
                  : review.recipient,
              fieldKey: const Key('review_recipient'),
              mono: review.recipient.isNotEmpty,
            ),
            _field(
              context,
              '網路',
              review.isBitcoinPsbt
                  ? review.btcNetwork == 'regtest'
                      ? 'Bitcoin regtest · BIP-84 P2WPKH · PSBT v0'
                      : 'Bitcoin 網路無法驗證'
                  : '${_formatChainName(review.chainId)} (${review.chainId})',
              fieldKey: const Key('review_network'),
            ),
            divider,
            if (review.signerAddress != null)
              _field(
                context,
                '簽署帳戶',
                review.signerAddress!,
                fieldKey: const Key('review_signer'),
                mono: true,
              ),
            if (review.tokenContract != null)
              _field(
                context,
                '代幣合約',
                review.tokenContract!,
                fieldKey: const Key('review_contract'),
                mono: true,
              ),
            if (review.derivationPath != null &&
                review.derivationPath!.isNotEmpty)
              _field(context, '簽署路徑', review.derivationPath!, mono: true),
            if (!review.isBitcoinPsbt) ..._evmFields(context),
            if (review.isBitcoinPsbt) ...[
              _field(context, '已核對輸入數量', '${review.btcInputsCount ?? "無法驗證"}'),
              _field(
                context,
                '輸入總額',
                review.btcTotalInputSats == null
                    ? '無法驗證'
                    : '${review.btcTotalInputSats} sats',
              ),
              _field(
                context,
                '輸出總額（含找零）',
                review.btcTotalOutputSats == null
                    ? '無法驗證'
                    : '${review.btcTotalOutputSats} sats',
              ),
              for (var i = 0; i < review.btcOutputs.length; i++)
                _field(
                  context,
                  '輸出 ${i + 1} · ${review.btcOutputs[i].isChange ? "已驗證找零" : "收款"}',
                  '${review.btcOutputs[i].address}\n${review.btcOutputs[i].valueSats} sats',
                  fieldKey: Key('review_btc_output_$i'),
                  mono: true,
                ),
            ],
            _field(
              context,
              review.isBitcoinPsbt ? '交易手續費' : '最高手續費限制',
              review.feeCapWei.isEmpty ? '無法驗證' : review.formattedFeeCap,
              fieldKey: const Key('review_fee'),
            ),
            if (review.requestId.isNotEmpty || review.signingDigestHex != null)
              divider,
            if (review.requestId.isNotEmpty)
              _field(
                context,
                '請求識別碼',
                review.requestId,
                fieldKey: const Key('review_request_id'),
                mono: true,
              ),
            if (review.signingDigestHex != null)
              _field(
                context,
                '簽署摘要',
                review.signingDigestHex!,
                fieldKey: const Key('review_signing_digest'),
                mono: true,
              ),
            FcwBanner(
              tone: isRejected ? FcwTone.danger : FcwTone.neutral,
              icon: isRejected ? Icons.block_outlined : Icons.pending_outlined,
              title: atRetentionLimit
                  ? '待簽請求已達上限'
                  : isRejected
                      ? '政策拒絕'
                      : '等待確認',
              message: atRetentionLimit
                  ? '本次開啟金庫後送出簽署的請求已達保留上限；為保留既有簽署紀錄，金庫不會再準備新的請求。這不是交易內容或安全政策的問題。請完全關閉金庫 App 後重新開啟，再重新掃描；只鎖定金庫不會清除這些紀錄。'
                  : isRejected
                      ? review.rejectionReason ??
                          review.evmValidationError ??
                          '未知政策衝突，無法簽署'
                      : '請逐項核對以上交易資料，再確認簽署。',
            ),
            if (review.warnings.isNotEmpty)
              for (final warning in review.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: FcwSpace.md),
                  child: FcwBanner(
                    tone: FcwTone.warning,
                    message: '注意：$warning',
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context, String label, String value,
      {Key? fieldKey, bool mono = false}) {
    return FcwField(label: label, value: value, valueKey: fieldKey, mono: mono);
  }

  List<Widget> _evmFields(BuildContext context) {
    final details = review.evmDetails;
    if (details == null) {
      return [_field(context, '原生交易參數', '無法驗證：缺少完整交易參數')];
    }
    String gasPrice(String wei) =>
        '$wei wei / Gas (${DecimalAmountParser.formatBaseUnits(BigInt.parse(wei), decimals: 9)} Gwei)';
    return [
      _field(context, '交易類型', details.typeLabel,
          fieldKey: const Key('review_evm_type')),
      _field(context, 'Nonce（交易序號）', details.nonce,
          fieldKey: const Key('review_evm_nonce')),
      _field(context, 'Gas 上限', details.gasLimit,
          fieldKey: const Key('review_evm_gas_limit')),
      if (details.gasPriceWei != null)
        _field(context, 'Gas 單價', gasPrice(details.gasPriceWei!),
            fieldKey: const Key('review_evm_gas_price')),
      if (details.maxFeePerGasWei != null)
        _field(context, '每單位 Gas 最高費用', gasPrice(details.maxFeePerGasWei!),
            fieldKey: const Key('review_evm_max_fee_per_gas')),
      if (details.maxPriorityFeePerGasWei != null)
        _field(
            context, '每單位 Gas 優先費用', gasPrice(details.maxPriorityFeePerGasWei!),
            fieldKey: const Key('review_evm_priority_fee_per_gas')),
      _field(context, '交易目的地址', details.to,
          fieldKey: const Key('review_evm_to'), mono: true),
      _field(
        context,
        '原生幣金額',
        '${DecimalAmountParser.formatBaseUnits(BigInt.parse(details.valueWei), decimals: 18)} ETH (${details.valueWei} wei)',
        fieldKey: const Key('review_evm_native_value'),
      ),
      _field(context, '呼叫資料', details.dataHex,
          fieldKey: const Key('review_evm_data'), mono: true),
      _field(
          context,
          '存取清單',
          details.accessList.isEmpty
              ? '空（0 筆）'
              : '${details.accessList.length} 筆',
          fieldKey: const Key('review_evm_access_list')),
      for (var i = 0; i < details.accessList.length; i++) ...[
        _field(context, '存取地址 ${i + 1}', details.accessList[i].address,
            fieldKey: Key('review_evm_access_address_$i'), mono: true),
        if (details.accessList[i].storageKeys.isEmpty)
          _field(context, '儲存鍵 ${i + 1}', '空（0 筆）'),
        for (var j = 0; j < details.accessList[i].storageKeys.length; j++)
          _field(context, '儲存鍵 ${i + 1}.${j + 1}',
              details.accessList[i].storageKeys[j],
              fieldKey: Key('review_evm_storage_key_${i}_$j'), mono: true),
      ],
    ];
  }

  String _formatChainName(int chainId) {
    switch (chainId) {
      case 11155111:
        return 'Ethereum Sepolia Testnet';
      case 1337:
        return 'Local Hardhat Node';
      case 31337:
        return 'Local Anvil Node';
      default:
        return 'Unknown / Disallowed Network';
    }
  }
}
