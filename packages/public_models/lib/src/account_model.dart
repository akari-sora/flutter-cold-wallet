/// Immutable Account Descriptor DTO for watch-only and paired accounts.
/// Strictly contains public metadata only, no private keys or seed material.
class AccountDescriptor {
  final String masterFingerprint;
  final String derivationPath;
  final String address;
  final int chainId;
  final String label;
  final String? extendedPublicKey;
  final String? compressedPublicKeyHex;
  final String? chainCodeHex;
  final String assetFamily; // 'EVM' or 'BTC'
  final String? btcReceiveAddressRegtest;
  final String? btcReceiveAddressMainnet;
  final String? btcChangeAddress;
  final String? btcDescriptor;

  const AccountDescriptor({
    required this.masterFingerprint,
    required this.derivationPath,
    required this.address,
    required this.chainId,
    this.label = 'Default Account',
    this.extendedPublicKey,
    this.compressedPublicKeyHex,
    this.chainCodeHex,
    this.assetFamily = 'EVM',
    this.btcReceiveAddressRegtest,
    this.btcReceiveAddressMainnet,
    this.btcChangeAddress,
    this.btcDescriptor,
  });

  AccountDescriptor copyWith({
    String? masterFingerprint,
    String? derivationPath,
    String? address,
    int? chainId,
    String? label,
    String? extendedPublicKey,
    String? compressedPublicKeyHex,
    String? chainCodeHex,
    String? assetFamily,
    String? btcReceiveAddressRegtest,
    String? btcReceiveAddressMainnet,
    String? btcChangeAddress,
    String? btcDescriptor,
  }) {
    return AccountDescriptor(
      masterFingerprint: masterFingerprint ?? this.masterFingerprint,
      derivationPath: derivationPath ?? this.derivationPath,
      address: address ?? this.address,
      chainId: chainId ?? this.chainId,
      label: label ?? this.label,
      extendedPublicKey: extendedPublicKey ?? this.extendedPublicKey,
      compressedPublicKeyHex:
          compressedPublicKeyHex ?? this.compressedPublicKeyHex,
      chainCodeHex: chainCodeHex ?? this.chainCodeHex,
      assetFamily: assetFamily ?? this.assetFamily,
      btcReceiveAddressRegtest:
          btcReceiveAddressRegtest ?? this.btcReceiveAddressRegtest,
      btcReceiveAddressMainnet:
          btcReceiveAddressMainnet ?? this.btcReceiveAddressMainnet,
      btcChangeAddress: btcChangeAddress ?? this.btcChangeAddress,
      btcDescriptor: btcDescriptor ?? this.btcDescriptor,
    );
  }

  Map<String, dynamic> toJson() => {
        'master_fingerprint': masterFingerprint,
        'derivation_path': derivationPath,
        'address': address,
        'chain_id': chainId,
        'label': label,
        'asset_family': assetFamily,
        if (extendedPublicKey != null) 'extended_public_key': extendedPublicKey,
        if (compressedPublicKeyHex != null)
          'compressed_pubkey_hex': compressedPublicKeyHex,
        if (chainCodeHex != null) 'chain_code_hex': chainCodeHex,
        if (btcReceiveAddressRegtest != null)
          'receive_address_regtest': btcReceiveAddressRegtest,
        if (btcReceiveAddressMainnet != null)
          'receive_address_mainnet': btcReceiveAddressMainnet,
        if (btcChangeAddress != null) 'change_address': btcChangeAddress,
        if (btcDescriptor != null) 'descriptor': btcDescriptor,
      };

  factory AccountDescriptor.fromJson(Map<String, dynamic> json) =>
      AccountDescriptor(
        masterFingerprint: json['master_fingerprint'] as String? ?? '',
        derivationPath: json['derivation_path'] as String? ?? '',
        address: (json['address'] ??
                json['receive_address'] ??
                json['receive_address_regtest'] ??
                '') as String,
        chainId: json['chain_id'] as int? ?? 11155111,
        label: json['label'] as String? ?? 'Default Account',
        extendedPublicKey:
            (json['extended_public_key'] ?? json['account_xpub']) as String?,
        compressedPublicKeyHex: json['compressed_pubkey_hex'] as String?,
        chainCodeHex: json['chain_code_hex'] as String?,
        assetFamily: json['asset_family'] as String? ??
            ((json['derivation_path'] as String? ?? '').startsWith("m/84'")
                ? 'BTC'
                : 'EVM'),
        btcReceiveAddressRegtest:
            (json['receive_address_regtest'] ?? json['receive_address'])
                as String?,
        btcReceiveAddressMainnet: json['receive_address_mainnet'] as String?,
        btcChangeAddress: json['change_address'] as String?,
        btcDescriptor: json['descriptor'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountDescriptor &&
          runtimeType == other.runtimeType &&
          masterFingerprint == other.masterFingerprint &&
          derivationPath == other.derivationPath &&
          address == other.address &&
          chainId == other.chainId &&
          label == other.label &&
          assetFamily == other.assetFamily;

  @override
  int get hashCode =>
      masterFingerprint.hashCode ^
      derivationPath.hashCode ^
      address.hashCode ^
      chainId.hashCode ^
      label.hashCode ^
      assetFamily.hashCode;
}

/// Type alias / compatibility class for WatchAccount
typedef WatchAccount = AccountDescriptor;
