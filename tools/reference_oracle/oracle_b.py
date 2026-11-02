#!/usr/bin/env python3
"""
tools/reference_oracle/oracle_b.py
==================================
Reference Oracle Algorithm B: Python 3 independent derivation using
bip_utils (2.10.0) and Crypto.Hash.keccak (pycryptodome).

Computes:
- Master fingerprint (4 bytes hex)
- Account xpub (m/44'/60'/0')
- Account compressed pubkey (33B) and chain code (32B)
- Leaf compressed pubkey (m/44'/60'/0'/0/0)
- EIP-55 checksum Ethereum address
"""

import sys
import json
from pathlib import Path
import bip_utils
from Crypto.Hash import keccak


def to_eip55_checksum(address_lower: str) -> str:
    """Encode 40-hex lowercase address into EIP-55 checksum format."""
    clean_addr = address_lower.lower().removeprefix("0x")
    k = keccak.new(digest_bits=256)
    k.update(clean_addr.encode("ascii"))
    hash_hex = k.hexdigest()
    
    checksummed = "".join(
        c.upper() if int(hash_hex[i], 16) >= 8 else c.lower()
        for i, c in enumerate(clean_addr)
    )
    return "0x" + checksummed


def derive_eth_oracle_b(mnemonic: str, passphrase: str = "") -> dict:
    """Derive master fingerprint, account xpub, leaf pubkey, and EIP-55 address."""
    # 1. BIP-39 Seed
    seed_bytes = bip_utils.Bip39SeedGenerator(mnemonic).Generate(passphrase)
    
    # 2. Master Key & Fingerprint
    bip32_mst = bip_utils.Bip32Secp256k1.FromSeed(seed_bytes)
    master_fp = bip32_mst.PublicKey().FingerPrint().ToHex()
    
    # 3. BIP-44 Ethereum Account derivation m/44'/60'/0'
    bip44_mst = bip_utils.Bip44.FromSeed(seed_bytes, bip_utils.Bip44Coins.ETHEREUM)
    bip44_acc = bip44_mst.Purpose().Coin().Account(0)
    account_xpub = bip44_acc.PublicKey().ToExtended()
    account_compressed_pub = bip44_acc.PublicKey().RawCompressed().ToHex()
    account_chain_code = bip44_acc.PublicKey().ChainCode().ToHex()
    
    # 4. Leaf derivation m/44'/60'/0'/0/0
    bip44_leaf = bip44_acc.Change(bip_utils.Bip44Changes.CHAIN_EXT).AddressIndex(0)
    leaf_compressed_pub = bip44_leaf.PublicKey().RawCompressed().ToHex()
    leaf_uncompressed_bytes = bip44_leaf.PublicKey().RawUncompressed().ToBytes()[1:] # 64 bytes
    
    # 5. Keccak-256 for Ethereum address
    k = keccak.new(digest_bits=256)
    k.update(leaf_uncompressed_bytes)
    raw_addr_bytes = k.digest()[-20:]
    raw_addr_hex = raw_addr_bytes.hex()
    
    # 6. EIP-55 checksum
    eip55_address = to_eip55_checksum(raw_addr_hex)
    
    return {
        "master_fingerprint": master_fp,
        "account_xpub": account_xpub,
        "account_compressed_pubkey": account_compressed_pub,
        "account_chain_code": account_chain_code,
        "leaf_compressed_pubkey": leaf_compressed_pub,
        "eip55_address": eip55_address
    }


def main():
    fixtures_path = Path(__file__).resolve().parent / "fixtures" / "public_vectors.json"
    if not fixtures_path.exists():
        print(f"ERROR: Fixtures not found at {fixtures_path}", file=sys.stderr)
        sys.exit(1)
        
    fixtures = json.loads(fixtures_path.read_text(encoding="utf-8"))
    results = []
    
    for vec in fixtures["vectors"]:
        derived = derive_eth_oracle_b(vec["mnemonic"], vec.get("passphrase", ""))
        results.append({
            "id": vec["id"],
            "name": vec["name"],
            "derived": derived
        })
        
    output = {
        "algorithm": "Algorithm B (Python 3.11 / bip_utils 2.10.0 / pycryptodome Keccak)",
        "results": results
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
