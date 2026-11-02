"""Production host-FFI evidence for the separate OKX EVM account profile.

This exercises actual native account derivation and both Apps' native QR paths
using a fresh, isolated test Vault. It proves neither stock OKX import nor camera
interoperability. No public RPC, mainnet signature, or existing user data is used.
"""

import ctypes
import json

import cbor2
import pytest

from .test_fcw_core_wallet_first_qr_e2e import (
    _read_vault_json,
    _read_wallet_json,
    get_vault_ffi,
    get_wallet_ffi,
)


@pytest.mark.parametrize("passphrase", [b"", b"isolated-OKX-profile-passphrase-2026"])
def test_same_generated_vault_own_and_okx_qr_derive_same_leaf_address(tmp_path, passphrase):
    vault, wallet = get_vault_ffi(), get_wallet_ffi()
    vault.vault_export_okx_accounts_json.argtypes = [ctypes.c_uint32]
    vault.vault_export_okx_accounts_json.restype = ctypes.c_void_p
    vault.vault_init()
    wallet.wallet_init()
    assert _read_vault_json(vault, vault.vault_export_okx_accounts_json(60))["status"] == "ERROR"
    generated = _read_vault_json(vault, vault.vault_generate_mnemonic_json(12))
    assert generated["status"] == "SUCCESS"
    mnemonic = generated["mnemonic"].encode()
    active = _read_vault_json(
        vault,
        vault.vault_activate_and_save_mnemonic_json(
            mnemonic,
            passphrase,
            str(tmp_path / "isolated-vault.json").encode(),
            b"isolated-vault-password-2026",
        ),
    )
    assert active["status"] == "SUCCESS"

    def decode(multi):
        return _read_wallet_json(
            wallet,
            wallet.wallet_decode_and_verify_multi_accounts_ur(
                json.dumps(multi["fountain_frames"]).encode(), 11155111
            ),
        )

    own = _read_vault_json(vault, vault.vault_export_multi_accounts_json(60))
    okx = _read_vault_json(vault, vault.vault_export_okx_accounts_json(60))
    assert own["status"] == okx["status"] == "SUCCESS"
    assert okx["adapter"] == "okx-evm-account-standard"
    assert okx["master_fingerprint"] == own["master_fingerprint"] == active["master_fingerprint"]
    assert okx["has_passphrase_hint"] is bool(passphrase)
    okx_multi = okx["multi_accounts"]
    assert okx_multi["btc_accounts"] == []
    assert okx_multi["evm_accounts"] == own["multi_accounts"]["evm_accounts"]
    assert len(okx_multi["fountain_frames"]) > 1
    # Independent CBOR library verifies the pinned KeystoneFW OKX profile.
    # Account data is deliberately public; only the test Vault is generated.
    cbor = cbor2.loads(bytes.fromhex(okx_multi["cbor_hex"]))
    assert cbor[1] == int(okx["master_fingerprint"], 16)
    assert len(cbor[2]) == 2
    assert cbor[2][0].tag == 303
    key = cbor[2][0].value
    assert set(key) == {3, 4, 6, 8, 9, 10}
    assert len(key[3]) == 33 and key[3][0] in (2, 3)
    assert len(key[4]) == 32
    assert key[6].tag == 304
    assert key[6].value == {1: [44, True, 60, True, 0, True], 2: cbor[1], 3: 3}
    assert 0 <= key[8] <= 0xFFFFFFFF
    assert key[9] == "Keystone"
    assert key[10] == "account.standard"
    assert cbor[2][1].tag == 303
    leaf = cbor[2][1].value
    assert set(leaf) == {3, 6, 9, 10}
    assert leaf[3].hex() == okx_multi["evm_accounts"][0]["compressed_pubkey_hex"]
    assert leaf[6].tag == 304
    assert leaf[6].value == {1: [44, True, 60, True, 0, True, 0, False, 0, False], 2: cbor[1], 3: 5}
    assert leaf[9] == "Keystone"
    assert leaf[10] == "account.ledger_live"
    # Explicit private registry input must be rejected by the real Wallet FFI.
    private_key = dict(key)
    private_key[2] = True
    private_cbor = dict(cbor)
    private_cbor[2] = [cbor2.CBORTag(303, private_key)]
    rejected = _read_wallet_json(
        wallet,
        wallet.wallet_decode_and_verify_multi_accounts_ur(
            cbor2.dumps(private_cbor).hex().encode(), 11155111
        ),
    )
    assert rejected["status"] == "ERROR"
    assert "evm_accounts" not in rejected
    decoded_own, decoded_okx = decode(own["multi_accounts"]), decode(okx_multi)
    assert decoded_own["status"] == decoded_okx["status"] == "SUCCESS"
    assert decoded_okx["btc_accounts"] == []
    assert len(decoded_okx["evm_accounts"]) == 1
    for field in ("address", "derivation_path", "compressed_pubkey_hex", "master_fingerprint"):
        assert decoded_okx["evm_accounts"][0][field] == decoded_own["evm_accounts"][0][field]
        assert decoded_okx["evm_accounts"][0][field] == okx_multi["evm_accounts"][0][field]
    assert decoded_okx["evm_accounts"][0]["derivation_path"] == "m/44'/60'/0'/0/0"

    serialized = json.dumps(okx)
    assert generated["mnemonic"] not in serialized
    assert "mnemonic" not in serialized.lower()
    assert "private_key" not in serialized.lower()
    assert "seed" not in serialized.lower()
    # Exporting the optional third-party profile must not mutate our own profile.
    assert _read_vault_json(vault, vault.vault_export_multi_accounts_json(60)) == own
    assert vault.vault_lock() == 0
    locked = _read_vault_json(vault, vault.vault_export_okx_accounts_json(60))
    assert locked["status"] == "ERROR"
    assert locked["error_code"] == "ERR_VAULT_LOCKED"
    assert "multi_accounts" not in locked
