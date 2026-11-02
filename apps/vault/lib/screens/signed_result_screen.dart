import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';

/// Public response display only. Deliberately has no FFI, unlock or sign API.
class SignedResultScreen extends StatelessWidget {
  final SignatureResultDto result;
  final String? persistenceError;
  final bool keysRemainLocked;
  final String? requestId;
  final String? signingDigest;
  final int? chainId;
  const SignedResultScreen({
    super.key,
    required this.result,
    this.persistenceError,
    this.keysRemainLocked = false,
    this.requestId,
    this.signingDigest,
    this.chainId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final payload = UrQrPayload(
      singleUr: result.isPsbt ? result.signedPsbtUr : result.signatureUr,
      frames: result.qrFrames,
    );
    final frames = payload.displayFrames();
    final hasQr = result.isSuccess && frames.isNotEmpty;
    final available = result.isSuccess && payload.hasCopy;
    final copyText = payload.copyText;
    return Scaffold(
      appBar: AppBar(title: const Text('簽署結果')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        available
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 30,
                        color: available
                            ? FcwPalette.resolve(context).success.accent
                            : colors.error,
                      ),
                      const SizedBox(width: FcwSpace.md),
                      Expanded(
                        child: Text(
                          available ? '簽署完成' : '無法顯示已簽結果',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: FcwSpace.sm),
                  Text(
                    '使用連網錢包掃描，核對後再廣播。重顯示不會再次簽署。',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (keysRemainLocked) ...[
                    const SizedBox(height: 16),
                    _notice(
                      context,
                      const Text('僅重顯示公開結果；私鑰保持鎖定。',
                          key: Key('public_result_keys_locked')),
                    ),
                  ],
                  if (persistenceError != null) ...[
                    const SizedBox(height: 16),
                    _notice(
                      context,
                      Text(persistenceError!,
                          key: const Key('public_result_persistence_error')),
                      isError: true,
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (!hasQr)
                    _notice(
                      context,
                      available
                          ? const Text('此公開結果無法顯示 QR，請複製完整公開 UR 至連網錢包。',
                              key: Key('public_result_qr_unavailable'))
                          : const Text('已簽結果無法取回，請查原交易。'),
                      isError: !available,
                    )
                  else ...[
                    // Paused on purpose; without playing, the online wallet
                    // only ever reads the first frame.
                    if (frames.length > 1) ...[
                      FcwBanner(
                        tone: FcwTone.info,
                        icon: Icons.play_circle_outline,
                        content: Text(
                            '此結果共 ${frames.length} 幀，預設為暫停。請按 QR 下方的播放鍵（▶）開始輪播，連網錢包才能讀到全部幀。',
                            key: const Key('signed_result_play_hint')),
                      ),
                      const SizedBox(height: 16),
                    ],
                    AnimatedFountainQr(
                      frames: frames,
                      startPaused: true,
                      title: '回傳至連網錢包',
                      subtitle: result.isPsbt
                          ? '已簽署 PSBT · crypto-psbt'
                          : '公開簽章 · eth-signature',
                    ),
                  ],
                  const SizedBox(height: 24),
                  FcwPanel(
                    child: DefaultTextStyle.merge(
                      style: fcwMono(theme.textTheme.bodyMedium),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('原始請求資料', style: theme.textTheme.titleMedium),
                          if (requestId != null) ...[
                            const SizedBox(height: 16),
                            SelectableText('原始請求識別碼：$requestId',
                                key: const Key('signed_result_request_id')),
                          ],
                          if (signingDigest != null) ...[
                            const SizedBox(height: 16),
                            SelectableText('原始簽署摘要：$signingDigest',
                                key: const Key('signed_result_digest')),
                          ],
                          // Bitcoin has no Chain ID; its stored metadata
                          // keeps the default 0.
                          if (chainId != null && !result.isPsbt) ...[
                            const SizedBox(height: 16),
                            Text('原始 Chain ID：$chainId'),
                          ],
                          if (result.address.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            SelectableText('簽署帳戶：${result.address}'),
                          ],
                          if (result.derivationPath != null) ...[
                            const SizedBox(height: 16),
                            SelectableText('派生路徑：${result.derivationPath}'),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (available) ...[
                    const SizedBox(height: 24),
                    Text('公開簽章 UR', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SelectableText(
                      copyText,
                      key: const Key('generated_signature_ur_text'),
                      maxLines: 3,
                      style: fcwMono(theme.textTheme.bodySmall).copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: FcwSpace.md),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy_outlined, size: 20),
                      label: const Text('複製公開簽章 UR'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: copyText));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已複製公開簽章 UR')));
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    key: const Key('signature_done_return_btn'),
                    onPressed: () => Navigator.of(context)
                        .popUntil((route) => route.isFirst),
                    child: const Text('完成並返回首頁'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(BuildContext context, Widget child, {bool isError = false}) {
    return SizedBox(
      width: double.infinity,
      child: FcwBanner(
        tone: isError ? FcwTone.danger : FcwTone.neutral,
        icon: isError ? Icons.error_outline : Icons.lock_outline,
        content: child,
      ),
    );
  }
}
