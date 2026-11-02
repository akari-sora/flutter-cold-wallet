import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:public_models/public_models.dart';
import '../ffi/vault_ffi_service.dart';
import 'signed_result_screen.dart';

class ReviewScreen extends StatefulWidget {
  final PreparedReviewDto review;
  final VaultFfiService ffi;
  final String? Function(PreparedReviewDto review)? beforeSigning;
  final String? Function(PreparedReviewDto review, SignatureResultDto result)?
      onSignedResult;

  const ReviewScreen(
      {super.key,
      required this.review,
      required this.ffi,
      this.beforeSigning,
      this.onSignedResult});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _isSigning = false;
  SignatureResultDto? _signatureResult;
  String? _errorMessage;
  bool _cancelled = false;

  @override
  void dispose() {
    _cancelled = true;
    if (_signatureResult == null) widget.ffi.cancel(widget.review.handleId);
    super.dispose();
  }

  void _onSlideConfirmed() {
    if (_isSigning || _signatureResult != null) return;
    if (!widget.review.isSignable) {
      setState(() {
        _errorMessage = '此交易已被安全政策拒絕，無法簽署。';
      });
      return;
    }

    setState(() => _isSigning = true);

    try {
      final reservationError = widget.beforeSigning?.call(widget.review);
      if (!mounted || _cancelled) return;
      if (reservationError != null) {
        setState(() {
          _isSigning = false;
          _errorMessage = reservationError;
        });
        return;
      }
      final res = widget.ffi.approveAndSignResult(widget.review.handleId);
      if (!res.isSuccess || res.qrFrames.isEmpty) {
        setState(() {
          _isSigning = false;
          _errorMessage = res.error ?? '簽章產物產生失敗：未取得有效的 UR Tag 402/310 編碼';
        });
      } else {
        // Capture the result before persistence: a failed write must never
        // make the successfully signed request appear ready to sign again.
        _signatureResult = res;
        final persistenceError =
            widget.onSignedResult?.call(widget.review, res);
        setState(() {
          _isSigning = false;
          _errorMessage = persistenceError;
        });
      }
    } catch (e) {
      setState(() {
        _isSigning = false;
        _errorMessage = e.toString();
      });
    }
  }

  void _cancelTransaction() {
    _cancelled = true;
    widget.ffi.cancel(widget.review.handleId);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_signatureResult != null) {
      return SignedResultScreen(
        result: _signatureResult!,
        persistenceError: _errorMessage,
        requestId: widget.review.requestId,
        signingDigest: widget.review.signingDigestHex,
        chainId: widget.review.chainId,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('確認交易'),
        leading: IconButton(
          tooltip: '取消簽署',
          icon: const Icon(Icons.close),
          onPressed: _cancelTransaction,
        ),
      ),
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
                  TransactionReviewCard(review: widget.review),
                  const SizedBox(height: FcwSpace.xl),
                  if (_errorMessage != null) ...[
                    FcwBanner(tone: FcwTone.danger, message: _errorMessage!),
                    const SizedBox(height: FcwSpace.lg),
                  ],
                  if (_isSigning)
                    const Center(
                      child: CircularProgressIndicator(semanticsLabel: '正在簽署'),
                    )
                  else ...[
                    SlideToConfirm(
                      key: const Key('vault_slide_to_confirm'),
                      enabled: widget.review.isSignable,
                      onConfirmed: _onSlideConfirmed,
                    ),
                    if (widget.review.isSignable) ...[
                      const SizedBox(height: FcwSpace.md),
                      ElevatedButton.icon(
                        key: const Key('vault_explicit_approve_btn'),
                        icon: const Icon(Icons.verified_user, size: 20),
                        label: const Text('核准並簽署'),
                        onPressed: _onSlideConfirmed,
                      ),
                    ],
                  ],
                  const SizedBox(height: FcwSpace.md),
                  OutlinedButton(
                    key: const Key('vault_cancel_review_btn'),
                    onPressed: _cancelTransaction,
                    child: const Text('取消簽署'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
