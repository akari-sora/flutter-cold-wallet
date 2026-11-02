import 'amount_parser.dart';

/// Review verdict indicator.
enum ReviewVerdictType { approved, rejected }

/// Immutable Review Intent DTO representing an inspected transaction
/// ready for physical display on Vault's immutable review card.
class PreparedReviewDto {
  final String handleId;
  final String sessionId;
  final String requestId;
  final int chainId;
  final String recipient;
  final String? signerAddress;
  final String? tokenContract;
  final List<BtcReviewOutput> btcOutputs;
  final String rawAmount;
  final String displayAmount;
  final String tokenSymbol;
  final int decimals;
  final String feeCapWei;
  final ReviewVerdictType verdict;
  final String? rejectionReason;
  final List<String> warnings;
  final String? derivationPath;
  final String? signingDigestHex;
  final EvmReviewDetails? evmDetails;
  final bool isBitcoinPsbt;
  final String? btcChangeAddress;
  final String? btcChangeAmountSats;
  final int? btcInputsCount;
  final String? btcTotalInputSats;
  final String? btcTotalOutputSats;
  final String? btcNetwork;

  const PreparedReviewDto({
    required this.handleId,
    required this.sessionId,
    required this.requestId,
    required this.chainId,
    required this.recipient,
    this.signerAddress,
    this.tokenContract,
    this.btcOutputs = const [],
    required this.rawAmount,
    required this.displayAmount,
    required this.tokenSymbol,
    required this.decimals,
    required this.feeCapWei,
    required this.verdict,
    this.rejectionReason,
    this.warnings = const [],
    this.derivationPath,
    this.signingDigestHex,
    this.evmDetails,
    this.isBitcoinPsbt = false,
    this.btcChangeAddress,
    this.btcChangeAmountSats,
    this.btcInputsCount,
    this.btcTotalInputSats,
    this.btcTotalOutputSats,
    this.btcNetwork,
  });

  bool get isSignable =>
      verdict == ReviewVerdictType.approved &&
      rejectionReason == null &&
      handleId.isNotEmpty &&
      (isBitcoinPsbt || evmValidationError == null);

  String? get evmValidationError {
    if (isBitcoinPsbt) return null;
    final details = evmDetails;
    if (details == null) return '缺少完整的原生 EVM 交易參數，無法簽署';
    return details.validationError(
      chainId: chainId,
      recipient: recipient,
      tokenContract: tokenContract,
      rawAmount: rawAmount,
      feeCapWei: feeCapWei,
    );
  }

  String get formattedFeeCap {
    final parsed = BigInt.tryParse(feeCapWei);
    if (parsed == null) return feeCapWei;
    if (isBitcoinPsbt) {
      return '$feeCapWei sats (${DecimalAmountParser.formatBaseUnits(parsed, decimals: 8)} BTC)';
    }
    return '${DecimalAmountParser.formatBaseUnits(parsed, decimals: 18)} ETH ($feeCapWei wei)';
  }

  Map<String, dynamic> toJson() => {
        'handle_id': handleId,
        'session_id': sessionId,
        'request_id': requestId,
        'chain_id': chainId,
        'recipient': recipient,
        if (signerAddress != null) 'signer_address': signerAddress,
        if (tokenContract != null) 'token_contract': tokenContract,
        'btc_outputs': btcOutputs.map((output) => output.toJson()).toList(),
        'raw_amount': rawAmount,
        'display_amount': displayAmount,
        'token_symbol': tokenSymbol,
        'decimals': decimals,
        'fee_cap_wei': feeCapWei,
        'verdict': verdict.name,
        if (rejectionReason != null) 'rejection_reason': rejectionReason,
        'warnings': warnings,
        if (derivationPath != null) 'derivation_path': derivationPath,
        if (signingDigestHex != null) 'signing_digest': signingDigestHex,
        if (evmDetails != null) 'transaction': evmDetails!.toJson(),
        'is_bitcoin_psbt': isBitcoinPsbt,
        if (btcChangeAddress != null) 'btc_change_address': btcChangeAddress,
        if (btcChangeAmountSats != null)
          'btc_change_amount_sats': btcChangeAmountSats,
        if (btcInputsCount != null) 'btc_inputs_count': btcInputsCount,
        if (btcTotalInputSats != null)
          'btc_total_input_sats': btcTotalInputSats,
        if (btcTotalOutputSats != null)
          'btc_total_output_sats': btcTotalOutputSats,
        if (btcNetwork != null) 'btc_network': btcNetwork,
      };

  factory PreparedReviewDto.fromJson(Map<String, dynamic> json) {
    String text(dynamic value) => value is String ? value : '';
    // 1. Error response from FFI
    if (json.containsKey('error')) {
      final err = json['error'] is String
          ? json['error'] as String
          : 'Unknown policy rejection';
      return PreparedReviewDto(
        handleId: text(json['handle_id']),
        sessionId: text(json['session_id']),
        requestId: text(json['request_id']),
        chainId: json['chain_id'] is int ? json['chain_id'] as int : 0,
        recipient: text(json['account_address']),
        rawAmount: '0',
        displayAmount: '0',
        tokenSymbol: 'N/A',
        decimals: 18,
        feeCapWei: '0',
        verdict: ReviewVerdictType.rejected,
        rejectionReason: err,
      );
    }

    // 2. Bitcoin PSBT response from vault_prepare_psbt_request / vault_prepare_ur_request
    if (json['type'] == 'BITCOIN_PSBT' || json.containsKey('psbt_summary')) {
      return _bitcoinReviewFromJson(json);
    }

    // 3. Policy verdict object
    final verdictValue = json['policy_verdict'];
    final verdictObj =
        verdictValue is Map<String, dynamic> ? verdictValue : null;
    final isApproved = verdictObj?['Approved'] is Map<String, dynamic>;

    String dispAmt = '0';
    String? rejReason;
    if (isApproved) {
      final appData = verdictObj!['Approved'] as Map<String, dynamic>;
      dispAmt = text(appData['amount_display']);
    } else if (verdictObj?['Rejected'] is Map<String, dynamic>) {
      final rejData = verdictObj!['Rejected'] as Map<String, dynamic>;
      rejReason =
          rejData['reason'] is String ? rejData['reason'] as String : null;
    }

    // 4. Intent decoding
    final intentValue = json['intent'];
    final intent = intentValue is Map<String, dynamic> ? intentValue : null;
    String symbol = 'ETH';
    int dec = 18;
    String rawAmt = '0';
    String feeCap = '0';
    String toAddr = text(json['account_address']);
    String? tokenContract;

    if (intent != null) {
      if (intent.containsKey('NativeTransfer')) {
        final natValue = intent['NativeTransfer'];
        final nat =
            natValue is Map<String, dynamic> ? natValue : <String, dynamic>{};
        toAddr = text(nat['recipient']);
        rawAmt = text(nat['value_wei']);
        feeCap = text(nat['fee_cap_wei']);
        symbol = 'ETH';
        dec = 18;
        final rawBig = BigInt.tryParse(rawAmt);
        if (rawBig != null) {
          dispAmt =
              '${DecimalAmountParser.formatBaseUnits(rawBig, decimals: 18)} ETH';
        }
      } else if (intent.containsKey('Erc20Transfer')) {
        final ercValue = intent['Erc20Transfer'];
        final erc =
            ercValue is Map<String, dynamic> ? ercValue : <String, dynamic>{};
        tokenContract = text(erc['token_contract']);
        toAddr = text(erc['recipient']);
        rawAmt = text(erc['token_amount_raw']);
        feeCap = text(erc['fee_cap_wei']);
        final contract = tokenContract.toLowerCase();
        if (contract == '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238') {
          symbol = 'USDC';
          dec = 6;
        } else if (contract == '0xff34b3d4aee8ddcd6f9afffb6fe49bd371b8a357') {
          symbol = 'DAI';
          dec = 18;
        } else {
          symbol = 'UNKNOWN';
          dec = 18;
          rejReason ??= 'Token contract is not whitelisted';
        }
        final rawBig = BigInt.tryParse(rawAmt);
        if (rawBig != null && symbol != 'UNKNOWN') {
          dispAmt =
              '${DecimalAmountParser.formatBaseUnits(rawBig, decimals: dec)} $symbol';
        }
      }
    }

    final signingDigest = _decodeSigningDigest(json);
    if (isApproved && signingDigest == null) {
      rejReason ??= '原生簽署摘要缺少、格式無效或不一致，禁止簽署';
    }

    EvmReviewDetails? evmDetails;
    try {
      final transaction = json['transaction'];
      if (transaction is! Map<String, dynamic>) {
        throw const FormatException('缺少完整的原生 EVM 交易參數');
      }
      evmDetails = EvmReviewDetails.fromJson(transaction);
      if (intent == null ||
          intent.length != 1 ||
          (!intent.containsKey('NativeTransfer') &&
              !intent.containsKey('Erc20Transfer'))) {
        throw const FormatException('缺少已核對的交易意圖');
      }
      final intentData = intent.values.single;
      if (intentData is! Map<String, dynamic> ||
          intentData['chain_id'] is! int ||
          intentData['chain_id'] != json['chain_id']) {
        throw const FormatException('交易意圖與請求的 Chain ID 不一致');
      }
      _evmAddress(intentData['recipient'], 'intent.recipient');
      _evmUnsigned(intentData['fee_cap_wei'], 'intent.fee_cap_wei');
      _evmUnsigned(
        intentData[intent.containsKey('Erc20Transfer')
            ? 'token_amount_raw'
            : 'value_wei'],
        'intent.amount',
      );
      final validationError = evmDetails.validationError(
        chainId: json['chain_id'] is int ? json['chain_id'] as int : 0,
        recipient: toAddr,
        tokenContract: tokenContract,
        rawAmount: rawAmt,
        feeCapWei: feeCap,
      );
      if (validationError != null) throw FormatException(validationError);
    } on FormatException catch (error) {
      rejReason ??= 'EVM 交易參數無法驗證：${error.message}';
    }

    return PreparedReviewDto(
      handleId: text(json['handle_id']),
      sessionId: text(json['session_id']),
      requestId: text(json['request_id']),
      chainId: json['chain_id'] is int ? json['chain_id'] as int : 0,
      recipient: toAddr,
      signerAddress: json['signer_address'] is String
          ? json['signer_address'] as String
          : null,
      tokenContract: tokenContract,
      rawAmount: rawAmt,
      displayAmount: dispAmt,
      tokenSymbol: symbol,
      decimals: dec,
      feeCapWei: feeCap,
      verdict: (isApproved && rejReason == null)
          ? ReviewVerdictType.approved
          : ReviewVerdictType.rejected,
      rejectionReason: rejReason,
      derivationPath: json['derivation_path'] is String
          ? json['derivation_path'] as String
          : null,
      signingDigestHex: signingDigest,
      evmDetails: evmDetails,
    );
  }
}

enum EvmTransactionType { legacyEip155, eip1559 }

/// Complete public parameters from the native transaction used for signing.
/// Construction validates canonical fields and freezes the nested access list.
final class EvmReviewDetails {
  final EvmTransactionType type;
  final String chainId;
  final String nonce;
  final String gasLimit;
  final String? gasPriceWei;
  final String? maxFeePerGasWei;
  final String? maxPriorityFeePerGasWei;
  final String to;
  final String valueWei;
  final String dataHex;
  final List<EvmAccessListEntry> accessList;

  const EvmReviewDetails._({
    required this.type,
    required this.chainId,
    required this.nonce,
    required this.gasLimit,
    required this.gasPriceWei,
    required this.maxFeePerGasWei,
    required this.maxPriorityFeePerGasWei,
    required this.to,
    required this.valueWei,
    required this.dataHex,
    required this.accessList,
  });

  String get typeLabel =>
      type == EvmTransactionType.legacyEip155 ? 'Legacy EIP-155' : 'EIP-1559';

  BigInt get maximumFeeWei =>
      BigInt.parse(gasLimit) * BigInt.parse(gasPriceWei ?? maxFeePerGasWei!);

  factory EvmReviewDetails.fromJson(Map<String, dynamic> json) {
    final EvmTransactionType type;
    switch (json['type']) {
      case 'Legacy EIP-155':
        type = EvmTransactionType.legacyEip155;
      case 'EIP-1559':
        type = EvmTransactionType.eip1559;
      default:
        throw const FormatException('不支援或缺少交易類型');
    }
    String uint64(String field, {bool positive = false}) {
      final parsed = _evmUnsigned(json[field], field, maximum: _evmUint64Max);
      if (positive && parsed == BigInt.zero) {
        throw FormatException('$field 必須大於零');
      }
      return json[field] as String;
    }

    final chainId = uint64('chain_id', positive: true);
    final nonce = uint64('nonce');
    final gasLimit = uint64('gas_limit', positive: true);
    _evmUnsigned(json['value_wei'], 'value_wei');
    final to = _evmAddress(json['to'], 'to');
    final data = json['data_hex'];
    if (data is! String || !RegExp(r'^0x(?:[a-fA-F0-9]{2})*$').hasMatch(data)) {
      throw const FormatException('呼叫資料必須為完整的 0x 十六進位位元組');
    }
    final entries = json['access_list'];
    if (entries is! List) {
      throw const FormatException('缺少或無效的存取清單');
    }
    final accessList = <EvmAccessListEntry>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('存取清單項目格式無效');
      }
      accessList.add(EvmAccessListEntry.fromJson(entry));
    }

    String? gasPrice;
    String? maxFee;
    String? priority;
    if (type == EvmTransactionType.legacyEip155) {
      gasPrice = uint64('gas_price_wei');
      if (json.containsKey('max_fee_per_gas_wei') ||
          json.containsKey('max_priority_fee_per_gas_wei') ||
          accessList.isNotEmpty) {
        throw const FormatException('Legacy 交易不能包含 Type 2 費用或存取清單');
      }
    } else {
      maxFee = uint64('max_fee_per_gas_wei');
      priority = uint64('max_priority_fee_per_gas_wei');
      if (json.containsKey('gas_price_wei')) {
        throw const FormatException('Type 2 交易不能包含 Legacy Gas 價格');
      }
      if (BigInt.parse(priority) > BigInt.parse(maxFee)) {
        throw const FormatException('優先費用不能超過每單位最高費用');
      }
    }
    return EvmReviewDetails._(
      type: type,
      chainId: chainId,
      nonce: nonce,
      gasLimit: gasLimit,
      gasPriceWei: gasPrice,
      maxFeePerGasWei: maxFee,
      maxPriorityFeePerGasWei: priority,
      to: to,
      valueWei: json['value_wei'] as String,
      dataHex: data,
      accessList: List.unmodifiable(accessList),
    );
  }

  String? validationError({
    required int chainId,
    required String recipient,
    required String? tokenContract,
    required String rawAmount,
    required String feeCapWei,
  }) {
    try {
      if (chainId <= 0 || BigInt.from(chainId) != BigInt.parse(this.chainId)) {
        throw const FormatException('交易與請求的 Chain ID 不一致');
      }
      _evmAddress(recipient, 'recipient');
      final expectedTo = tokenContract == null
          ? recipient
          : _evmAddress(tokenContract, 'token_contract');
      if (to.toLowerCase() != expectedTo.toLowerCase()) {
        throw const FormatException('交易目的地址與已核對意圖不一致');
      }
      final amount = _evmUnsigned(rawAmount, 'raw_amount');
      final nativeValue = BigInt.parse(valueWei);
      if (tokenContract != null && nativeValue != BigInt.zero) {
        throw const FormatException('代幣轉帳不得夾帶原生幣金額');
      }
      if (tokenContract == null && nativeValue != amount) {
        throw const FormatException('原生幣金額與已核對意圖不一致');
      }
      if (_evmUnsigned(feeCapWei, 'fee_cap_wei') != maximumFeeWei) {
        throw const FormatException('最高手續費與 Gas 上限乘以單價不一致');
      }
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Map<String, dynamic> toJson() => {
        'type': typeLabel,
        'chain_id': chainId,
        'nonce': nonce,
        'gas_limit': gasLimit,
        if (gasPriceWei != null) 'gas_price_wei': gasPriceWei,
        if (maxFeePerGasWei != null) 'max_fee_per_gas_wei': maxFeePerGasWei,
        if (maxPriorityFeePerGasWei != null)
          'max_priority_fee_per_gas_wei': maxPriorityFeePerGasWei,
        'to': to,
        'value_wei': valueWei,
        'data_hex': dataHex,
        'access_list': accessList.map((entry) => entry.toJson()).toList(),
      };
}

final class EvmAccessListEntry {
  final String address;
  final List<String> storageKeys;

  const EvmAccessListEntry._(this.address, this.storageKeys);

  factory EvmAccessListEntry.fromJson(Map<String, dynamic> json) {
    final address = _evmAddress(json['address'], 'access_list.address');
    final keys = json['storage_keys'];
    if (keys is! List ||
        keys.any((key) =>
            key is! String || !RegExp(r'^0x[a-fA-F0-9]{64}$').hasMatch(key))) {
      throw const FormatException('存取清單儲存鍵必須為完整的 32 位元組');
    }
    return EvmAccessListEntry._(address, List<String>.unmodifiable(keys));
  }

  Map<String, dynamic> toJson() =>
      {'address': address, 'storage_keys': storageKeys.toList()};
}

final _evmUint64Max = (BigInt.one << 64) - BigInt.one;
final _evmUint256Max = (BigInt.one << 256) - BigInt.one;

BigInt _evmUnsigned(dynamic value, String field, {BigInt? maximum}) {
  if (value is! String ||
      value.length > 78 ||
      !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    throw FormatException('$field 必須為精確非負十進位整數字串');
  }
  final parsed = BigInt.parse(value);
  if (parsed > (maximum ?? _evmUint256Max)) {
    throw FormatException('$field 超過允許範圍');
  }
  return parsed;
}

String _evmAddress(dynamic value, String field) {
  if (value is! String || !RegExp(r'^0x[a-fA-F0-9]{40}$').hasMatch(value)) {
    throw FormatException('$field 必須為完整的 20 位元組地址');
  }
  return value;
}

String? _decodeSigningDigest(Map<String, dynamic> json) {
  String? rawHex;
  if (json.containsKey('raw_signing_digest')) {
    final raw = json['raw_signing_digest'];
    if (raw is! List ||
        raw.length != 32 ||
        raw.any((byte) => byte is! int || byte < 0 || byte > 255)) {
      return null;
    }
    rawHex = raw
        .map((byte) => (byte as int).toRadixString(16).padLeft(2, '0'))
        .join();
  }
  if (json.containsKey('signing_digest')) {
    final explicit = json['signing_digest'];
    if (explicit is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(explicit)) {
      return null;
    }
    final hex = explicit.toLowerCase();
    if (rawHex != null && rawHex != hex) return null;
    return hex;
  }
  return rawHex;
}

PreparedReviewDto _bitcoinReviewFromJson(Map<String, dynamic> json) {
  try {
    if (json['type'] != 'BITCOIN_PSBT' || json['status'] != 'SUCCESS') {
      throw const FormatException('原生 Bitcoin 審查未成功');
    }
    if (json['network'] != 'regtest') {
      throw const FormatException('僅允許 Bitcoin regtest');
    }
    final handle = _requiredReviewString(json, 'handle_id');
    final session = _requiredReviewString(json, 'session_id');
    final request = _requiredReviewString(json, 'request_id');
    final digest = _decodeSigningDigest(json);
    if (digest == null) {
      throw const FormatException('簽署摘要格式無效');
    }
    final summaryValue =
        json.containsKey('psbt_summary') ? json['psbt_summary'] : json;
    if (summaryValue is! Map<String, dynamic>) {
      throw const FormatException('缺少 Bitcoin 交易摘要');
    }
    final inputSats = _bitcoinAmount(summaryValue['total_input_sat']);
    final outputSats = _bitcoinAmount(summaryValue['total_output_sat']);
    final feeSats = _bitcoinAmount(summaryValue['fee_sat']);
    final inputCount = _canonicalUnsigned(summaryValue['inputs_count'],
        maximum: BigInt.from(0xffffffff));
    if (inputCount == BigInt.zero || inputSats == BigInt.zero) {
      throw const FormatException('輸入數量與金額必須大於零');
    }
    final destinations = _bitcoinOutputs(summaryValue['destinations'], false);
    final changes = _bitcoinOutputs(summaryValue['changes'], true);
    final outputs = [...destinations, ...changes];
    if (outputs.isEmpty) {
      throw const FormatException('缺少已核對輸出');
    }
    BigInt total(List<BtcReviewOutput> items) => items.fold(
        BigInt.zero, (sum, output) => sum + BigInt.parse(output.valueSats));
    final recipientSats = total(destinations);
    if (recipientSats + total(changes) != outputSats ||
        outputSats + feeSats != inputSats) {
      throw const FormatException('輸入、收款、找零及手續費總額不一致');
    }
    if (summaryValue.containsKey('recipient_amount_sats') &&
        _bitcoinAmount(summaryValue['recipient_amount_sats']) !=
            recipientSats) {
      throw const FormatException('外部收款總額與已核對輸出不一致');
    }
    return PreparedReviewDto(
      handleId: handle,
      sessionId: session,
      requestId: request,
      chainId: 0,
      recipient:
          destinations.isEmpty ? '無外部收款（僅找零）' : destinations.first.address,
      rawAmount: recipientSats.toString(),
      displayAmount:
          '${DecimalAmountParser.formatBaseUnits(recipientSats, decimals: 8)} BTC ($recipientSats sats)',
      tokenSymbol: 'BTC',
      decimals: 8,
      feeCapWei: feeSats.toString(),
      verdict: ReviewVerdictType.approved,
      derivationPath: "m/84'/1'/0'",
      signingDigestHex: digest,
      isBitcoinPsbt: true,
      btcChangeAddress: changes.isEmpty ? null : changes.first.address,
      btcChangeAmountSats: changes.isEmpty ? null : changes.first.valueSats,
      btcInputsCount: inputCount.toInt(),
      btcOutputs: List.unmodifiable(outputs),
      btcTotalInputSats: inputSats.toString(),
      btcTotalOutputSats: outputSats.toString(),
      btcNetwork: 'regtest',
    );
  } on FormatException catch (error) {
    String binding(String field) => json[field] is String ? json[field] : '';
    return PreparedReviewDto(
      handleId: binding('handle_id'),
      sessionId: binding('session_id'),
      requestId: binding('request_id'),
      chainId: 0,
      recipient: '',
      rawAmount: '',
      displayAmount: '無法驗證',
      tokenSymbol: 'BTC',
      decimals: 8,
      feeCapWei: '',
      verdict: ReviewVerdictType.rejected,
      rejectionReason: 'Bitcoin 交易摘要無法驗證：${error.message}',
      isBitcoinPsbt: true,
    );
  }
}

String _requiredReviewString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw FormatException('缺少或無效的 $field');
  }
  return value;
}

BigInt _canonicalUnsigned(dynamic value, {required BigInt maximum}) {
  final text = value is int || value is String ? value.toString() : '';
  if (text.length > 20 || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(text)) {
    throw const FormatException('金額或數量必須為精確非負整數');
  }
  final parsed = BigInt.parse(text);
  if (parsed > maximum) {
    throw const FormatException('金額或數量超過允許範圍');
  }
  return parsed;
}

BigInt _bitcoinAmount(dynamic value) =>
    _canonicalUnsigned(value, maximum: BigInt.parse('2100000000000000'));

List<BtcReviewOutput> _bitcoinOutputs(dynamic value, bool isChange) {
  if (value is! List) {
    throw const FormatException('缺少收款或找零輸出列表');
  }
  return [
    for (final output in value)
      if (output is Map<String, dynamic>)
        BtcReviewOutput.fromJson(output, isChange)
      else
        throw const FormatException('輸出資料格式無效'),
  ];
}

class BtcReviewOutput {
  final String address;
  final String valueSats;
  final bool isChange;
  const BtcReviewOutput(this.address, this.valueSats, this.isChange);
  factory BtcReviewOutput.fromJson(Map<String, dynamic> json, bool isChange) {
    final address = _requiredReviewString(json, 'address');
    if (json['is_change'] is! bool || json['is_change'] != isChange) {
      throw const FormatException('輸出找零標記與核對分類不一致');
    }
    final amount = _bitcoinAmount(json['amount_sat']);
    return BtcReviewOutput(address, amount.toString(), isChange);
  }
  Map<String, dynamic> toJson() =>
      {'address': address, 'amount_sat': valueSats, 'is_change': isChange};
}

/// Type alias for ReviewIntentDto
typedef ReviewIntentDto = PreparedReviewDto;
