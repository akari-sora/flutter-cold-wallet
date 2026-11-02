/// Immutable Prepared Transaction DTO for review and signing requests.
/// Binds unsigned transaction parameters without exposing any signing secrets.
class PreparedTxDto {
  final String requestId;
  final String sessionId;
  final int chainId;
  final String rawRlpHex;
  final String txType;
  final String to;
  final String valueWei;
  final int gasLimit;
  final int nonce;
  final String calldataHex;
  final String? gasPriceWei;
  final String? maxFeePerGasWei;
  final String? maxPriorityFeePerGasWei;
  final String? tokenContract;
  final String? tokenAmountRaw;
  final bool isErc20;

  const PreparedTxDto({
    required this.requestId,
    required this.sessionId,
    required this.chainId,
    required this.rawRlpHex,
    required this.txType,
    required this.to,
    required this.valueWei,
    required this.gasLimit,
    required this.nonce,
    required this.calldataHex,
    this.gasPriceWei,
    this.maxFeePerGasWei,
    this.maxPriorityFeePerGasWei,
    this.tokenContract,
    this.tokenAmountRaw,
    this.isErc20 = false,
  });

  Map<String, dynamic> toJson() => {
    'request_id': requestId,
    'session_id': sessionId,
    'chain_id': chainId,
    'raw_rlp_hex': rawRlpHex,
    'tx_type': txType,
    'to': to,
    'value_wei': valueWei,
    'gas_limit': gasLimit,
    'nonce': nonce,
    'calldata_hex': calldataHex,
    if (gasPriceWei != null) 'gas_price_wei': gasPriceWei,
    if (maxFeePerGasWei != null) 'max_fee_per_gas_wei': maxFeePerGasWei,
    if (maxPriorityFeePerGasWei != null)
      'max_priority_fee_per_gas_wei': maxPriorityFeePerGasWei,
    if (tokenContract != null) 'token_contract': tokenContract,
    if (tokenAmountRaw != null) 'token_amount_raw': tokenAmountRaw,
    'is_erc20': isErc20,
  };

  factory PreparedTxDto.fromJson(Map<String, dynamic> json) => PreparedTxDto(
    requestId: json['request_id'] as String? ?? '',
    sessionId: json['session_id'] as String? ?? '',
    chainId: json['chain_id'] as int? ?? 0,
    rawRlpHex: json['raw_rlp_hex'] as String? ?? '',
    txType: json['tx_type'] as String? ?? 'Legacy',
    to: json['to'] as String? ?? '',
    valueWei: json['value_wei'] as String? ?? '0',
    gasLimit: json['gas_limit'] as int? ?? 21000,
    nonce: json['nonce'] as int? ?? 0,
    calldataHex: json['calldata_hex'] as String? ?? '',
    gasPriceWei: json['gas_price_wei'] as String?,
    maxFeePerGasWei: json['max_fee_per_gas_wei'] as String?,
    maxPriorityFeePerGasWei: json['max_priority_fee_per_gas_wei'] as String?,
    tokenContract: json['token_contract'] as String?,
    tokenAmountRaw: json['token_amount_raw'] as String?,
    isErc20: json['is_erc20'] as bool? ?? false,
  );
}
