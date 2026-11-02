/// Immutable Signature Result DTO capturing the output of vault signing
/// for both EVM (`eth-signature` Tag 402) and Bitcoin (`crypto-psbt` Tag 310).
class SignatureResultDto {
  final String status;
  final String handleId;
  final String? requestId;
  final String address;
  final String? derivationPath;
  final String? digestHex;
  final String signatureHex;
  final String? signatureUr;
  final List<String> signatureUrFrames;
  final String? signedPsbtHex;
  final String? signedPsbtUr;
  final List<String> signedPsbtUrFrames;
  final String? error;

  const SignatureResultDto({
    required this.status,
    required this.handleId,
    this.requestId,
    required this.address,
    this.derivationPath,
    this.digestHex,
    required this.signatureHex,
    this.signatureUr,
    this.signatureUrFrames = const [],
    this.signedPsbtHex,
    this.signedPsbtUr,
    this.signedPsbtUrFrames = const [],
    this.error,
  });

  bool get isSuccess =>
      (status == 'SUCCESS' || status == 'SIGNED_PSBT') && error == null;

  bool get isPsbt => status == 'SIGNED_PSBT' || signedPsbtUr != null;

  /// Returns the frames to display in AnimatedFountainQr (strictly from real CBOR UR encoding).
  List<String> get qrFrames {
    if (isPsbt) {
      if (signedPsbtUrFrames.isNotEmpty) return signedPsbtUrFrames;
      if (signedPsbtUr != null && signedPsbtUr!.isNotEmpty) {
        return [signedPsbtUr!];
      }
      return const [];
    }
    if (signatureUrFrames.isNotEmpty) return signatureUrFrames;
    if (signatureUr != null && signatureUr!.isNotEmpty) {
      return [signatureUr!];
    }
    return const [];
  }

  String get rHex {
    final clean = signatureHex.startsWith('0x')
        ? signatureHex.substring(2)
        : signatureHex;
    return clean.length >= 64 ? clean.substring(0, 64) : '';
  }

  String get sHex {
    final clean = signatureHex.startsWith('0x')
        ? signatureHex.substring(2)
        : signatureHex;
    return clean.length >= 128 ? clean.substring(64, 128) : '';
  }

  int get v {
    final clean = signatureHex.startsWith('0x')
        ? signatureHex.substring(2)
        : signatureHex;
    if (clean.length >= 130) {
      return int.tryParse(clean.substring(128, 130), radix: 16) ?? 27;
    }
    return 27;
  }

  Map<String, dynamic> toJson() => {
        'status': status,
        'handle_id': handleId,
        if (requestId != null) 'request_id': requestId,
        'address': address,
        if (derivationPath != null) 'derivation_path': derivationPath,
        if (digestHex != null) 'digest': digestHex,
        'signature': signatureHex,
        if (signatureUr != null) 'signature_ur': signatureUr,
        if (signatureUrFrames.isNotEmpty)
          'signature_ur_frames': signatureUrFrames,
        if (signedPsbtHex != null) 'signed_psbt_hex': signedPsbtHex,
        if (signedPsbtUr != null) 'signed_psbt_ur': signedPsbtUr,
        if (signedPsbtUrFrames.isNotEmpty)
          'signed_psbt_ur_frames': signedPsbtUrFrames,
        if (error != null) 'error': error,
      };

  factory SignatureResultDto.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('error')) {
      return SignatureResultDto(
        status: 'ERROR',
        handleId: json['handle_id'] as String? ?? '',
        address: '',
        signatureHex: '',
        error: json['error'] as String?,
      );
    }

    final sigFramesRaw = json['signature_ur_frames'] as List<dynamic>?;
    final psbtFramesRaw = json['signed_psbt_ur_frames'] as List<dynamic>?;

    return SignatureResultDto(
      status: json['status'] as String? ?? 'SUCCESS',
      handleId: json['handle_id'] as String? ?? '',
      requestId: json['request_id'] as String?,
      address: json['address'] as String? ?? '',
      derivationPath: json['derivation_path'] as String?,
      digestHex: json['digest'] as String?,
      signatureHex: json['signature'] as String? ?? '',
      signatureUr: json['signature_ur'] as String?,
      signatureUrFrames:
          sigFramesRaw?.map((e) => e.toString()).toList() ?? const [],
      signedPsbtHex: json['signed_psbt_hex'] as String?,
      signedPsbtUr: json['signed_psbt_ur'] as String?,
      signedPsbtUrFrames:
          psbtFramesRaw?.map((e) => e.toString()).toList() ?? const [],
    );
  }
}
