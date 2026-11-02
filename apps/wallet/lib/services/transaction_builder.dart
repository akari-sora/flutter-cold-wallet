import 'dart:typed_data';

/// Minimal RLP and EVM transaction builder for watch-only wallet.
/// Strictly encodes public transaction parameters (Legacy EIP-155 & EIP-1559 Type 2)
/// without holding private keys or using floating-point arithmetic.
class TransactionBuilder {
  static final RegExp _evmAddressRegex = RegExp(r'^0x[0-9a-fA-F]{40}$');

  static bool isValidEvmAddress(String addr) {
    return _evmAddressRegex.hasMatch(addr.trim());
  }

  /// Encodes 68-byte standard ERC-20 transfer(address,uint256) calldata.
  static Uint8List encodeErc20TransferCalldata({
    required String recipientAddress,
    required BigInt amountRaw,
  }) {
    if (!isValidEvmAddress(recipientAddress)) {
      throw ArgumentError('Invalid recipient EVM address: $recipientAddress');
    }
    if (amountRaw <= BigInt.zero || amountRaw.bitLength > 256) {
      throw ArgumentError('ERC-20 transfer amount must be greater than zero');
    }

    final cleanAddr =
        recipientAddress.trim().toLowerCase().replaceFirst('0x', '');
    final addrBytes = <int>[];
    for (var i = 0; i < cleanAddr.length; i += 2) {
      addrBytes.add(int.parse(cleanAddr.substring(i, i + 2), radix: 16));
    }

    final out = Uint8List(68);
    // Selector 0xa9059cbb
    out[0] = 0xa9;
    out[1] = 0x05;
    out[2] = 0x9c;
    out[3] = 0xbb;

    // First parameter: 32 bytes with 12 zero padding bytes followed by 20 bytes address
    for (var i = 0; i < addrBytes.length; i++) {
      out[16 + i] = addrBytes[i];
    }

    // Second parameter: 32 bytes big-endian uint256 amount
    var temp = amountRaw;
    for (var i = 67; i >= 36; i--) {
      out[i] = (temp & BigInt.from(0xff)).toInt();
      temp = temp >> 8;
    }

    return out;
  }

  /// Builds Legacy EIP-155 unsigned RLP hex string:
  /// `rlp([nonce, gasPrice, gasLimit, to, value, data, chain_id, 0, 0])`
  static String buildLegacyUnsignedRlp({
    required int nonce,
    required BigInt gasPriceWei,
    required int gasLimit,
    required String toAddress,
    required BigInt valueWei,
    required Uint8List calldata,
    required int chainId,
  }) {
    if (!isValidEvmAddress(toAddress)) {
      throw ArgumentError('Invalid target EVM address: $toAddress');
    }
    final fields = <Uint8List>[
      _encodeBigInt(BigInt.from(nonce)),
      _encodeBigInt(gasPriceWei),
      _encodeBigInt(BigInt.from(gasLimit)),
      _hexToBytes(toAddress),
      _encodeBigInt(valueWei),
      _encodeBytes(calldata),
      _encodeBigInt(BigInt.from(chainId)),
      Uint8List.fromList([0x80]),
      Uint8List.fromList([0x80]),
    ];
    final encoded = _encodeList(fields);
    return _bytesToHex(encoded);
  }

  /// Builds EIP-1559 Type-2 unsigned payload hex string:
  /// `0x02 || rlp([chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas, gas_limit, to, value, data, []])`
  static String buildEip1559UnsignedPayload({
    required int chainId,
    required int nonce,
    required BigInt maxPriorityFeePerGasWei,
    required BigInt maxFeePerGasWei,
    required int gasLimit,
    required String toAddress,
    required BigInt valueWei,
    required Uint8List calldata,
  }) {
    if (!isValidEvmAddress(toAddress)) {
      throw ArgumentError('Invalid target EVM address: $toAddress');
    }
    if (maxPriorityFeePerGasWei > maxFeePerGasWei) {
      throw ArgumentError(
        'maxPriorityFeePerGas ($maxPriorityFeePerGasWei) cannot exceed maxFeePerGas ($maxFeePerGasWei)',
      );
    }
    final fields = <Uint8List>[
      _encodeBigInt(BigInt.from(chainId)),
      _encodeBigInt(BigInt.from(nonce)),
      _encodeBigInt(maxPriorityFeePerGasWei),
      _encodeBigInt(maxFeePerGasWei),
      _encodeBigInt(BigInt.from(gasLimit)),
      _hexToBytes(toAddress),
      _encodeBigInt(valueWei),
      _encodeBytes(calldata),
      Uint8List.fromList([0xc0]), // empty access_list []
    ];
    final rlpList = _encodeList(fields);
    final payload = Uint8List(1 + rlpList.length);
    payload[0] = 0x02;
    payload.setRange(1, payload.length, rlpList);
    return _bytesToHex(payload);
  }

  /// Reconstructs Signed Legacy EIP-155 raw transaction RLP:
  /// `[nonce, gasPrice, gasLimit, to, value, data, v, r, s]`
  static String reconstructSignedLegacyTx({
    required int nonce,
    required BigInt gasPriceWei,
    required int gasLimit,
    required String toAddress,
    required BigInt valueWei,
    required Uint8List calldata,
    required int chainId,
    required String rHex,
    required String sHex,
    required int vByte,
  }) {
    final recoveryBit = vByte >= 27 ? (vByte - 27) : (vByte & 1);
    final eip155V = BigInt.from(chainId * 2 + 35 + recoveryBit);

    final fields = <Uint8List>[
      _encodeBigInt(BigInt.from(nonce)),
      _encodeBigInt(gasPriceWei),
      _encodeBigInt(BigInt.from(gasLimit)),
      _hexToBytes(toAddress),
      _encodeBigInt(valueWei),
      _encodeBytes(calldata),
      _encodeBigInt(eip155V),
      _encodeStrippedHexQuantity(rHex),
      _encodeStrippedHexQuantity(sHex),
    ];
    final encoded = _encodeList(fields);
    return '0x${_bytesToHex(encoded)}';
  }

  /// Reconstructs Signed EIP-1559 Type-2 raw transaction:
  /// `0x02 || rlp([chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas, gas_limit, to, value, data, [], y_parity, r, s])`
  static String reconstructSignedEip1559Tx({
    required int chainId,
    required int nonce,
    required BigInt maxPriorityFeePerGasWei,
    required BigInt maxFeePerGasWei,
    required int gasLimit,
    required String toAddress,
    required BigInt valueWei,
    required Uint8List calldata,
    required String rHex,
    required String sHex,
    required int vByte,
  }) {
    final yParity = vByte >= 27 ? (vByte - 27) : (vByte & 1);
    final fields = <Uint8List>[
      _encodeBigInt(BigInt.from(chainId)),
      _encodeBigInt(BigInt.from(nonce)),
      _encodeBigInt(maxPriorityFeePerGasWei),
      _encodeBigInt(maxFeePerGasWei),
      _encodeBigInt(BigInt.from(gasLimit)),
      _hexToBytes(toAddress),
      _encodeBigInt(valueWei),
      _encodeBytes(calldata),
      Uint8List.fromList([0xc0]),
      _encodeBigInt(BigInt.from(yParity)),
      _encodeStrippedHexQuantity(rHex),
      _encodeStrippedHexQuantity(sHex),
    ];
    final rlpList = _encodeList(fields);
    final out = Uint8List(1 + rlpList.length);
    out[0] = 0x02;
    out.setRange(1, out.length, rlpList);
    return '0x${_bytesToHex(out)}';
  }

  // --- Internal RLP Encoding Helpers ---

  static Uint8List _encodeBigInt(BigInt val) {
    if (val.isNegative || val.bitLength > 256) {
      throw ArgumentError('Transaction quantity exceeds uint256');
    }
    if (val == BigInt.zero) {
      return Uint8List.fromList([0x80]);
    }
    final bytes = <int>[];
    var temp = val;
    while (temp > BigInt.zero) {
      bytes.insert(0, (temp & BigInt.from(0xff)).toInt());
      temp = temp >> 8;
    }
    if (bytes.length == 1 && bytes[0] < 0x80) {
      return Uint8List.fromList(bytes);
    }
    return _encodeItemHeader(0x80, bytes.length, bytes);
  }

  static Uint8List _encodeBytes(Uint8List raw) {
    if (raw.isEmpty) return Uint8List.fromList([0x80]);
    if (raw.length == 1 && raw[0] < 0x80) {
      return Uint8List.fromList(raw);
    }
    return _encodeItemHeader(0x80, raw.length, raw);
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.trim().replaceFirst('0x', '');
    if (clean.isEmpty) return Uint8List.fromList([0x80]);
    final raw = <int>[];
    for (var i = 0; i < clean.length; i += 2) {
      raw.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return _encodeBytes(Uint8List.fromList(raw));
  }

  static Uint8List _encodeStrippedHexQuantity(String hex) {
    final clean = hex.trim().replaceFirst('0x', '');
    if (clean.isEmpty) return Uint8List.fromList([0x80]);
    if (!RegExp(r'^[0-9a-fA-F]{1,64}$').hasMatch(clean)) {
      throw ArgumentError('Invalid signature quantity');
    }
    final big = BigInt.parse(clean, radix: 16);
    return _encodeBigInt(big);
  }

  static Uint8List _encodeList(List<Uint8List> items) {
    final totalPayload = <int>[];
    for (final it in items) {
      totalPayload.addAll(it);
    }
    return _encodeItemHeader(0xc0, totalPayload.length, totalPayload);
  }

  static Uint8List _encodeItemHeader(int offset, int len, List<int> payload) {
    if (len <= 55) {
      final header = offset + len;
      return Uint8List.fromList([header, ...payload]);
    } else {
      final lenBytes = <int>[];
      var temp = len;
      while (temp > 0) {
        lenBytes.insert(0, temp & 0xff);
        temp = temp >> 8;
      }
      final header = offset + 55 + lenBytes.length;
      return Uint8List.fromList([header, ...lenBytes, ...payload]);
    }
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
