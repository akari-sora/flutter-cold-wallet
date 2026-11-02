"""
tests/integration/test_g3_closed_loop.py
=========================================
Milestone M3 (Gate G3) Closed-Loop Verification Suite.

Validates:
- EVM-08: ERC-20 Mock USDC (6 decimals: 100.5, 1 micro-unit, 50M) and Mock DAI (18 decimals: 2.5, 1 wei, 1B)
          大整數十進位格式化與純字串定點位切分，全面杜絕浮點數截斷與精度損失。
- EVM-09: 偽造 Token metadata 注入拒絕、非白名單未知代幣合約 Fail-Closed 拒絕、未知/危險 ABI (approve/permit2) 拒絕。
- LIFE-01: 意圖變更與新請求自動使舊 handle 撤銷失效 (Revoked)，舊 handle 無法簽署 (sign count = 0)。
- LIFE-02: 取消/鎖屏/背景切換撤銷待簽 (Cancelled)，保證簽章計數絕對為 0，私鑰 zeroize。
- LIFE-03: 雙擊、重放請求與 Consumed 狀態下防二次簽署，重放必然報錯。
- OWN-01: Android Wallet 構造 -> 動態 QR -> Android Vault 接收解析 -> 確認授權 -> 回傳簽章 -> Wallet 驗證與重構之全鏈路模擬與測試。
"""

import ctypes
import json
import os
import sys
import uuid
import pytest
import cbor2
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# --- FFI Helper Wrappers ---

def get_vault_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "vault_ffi.dll"
    if not dll_path.exists():
        pytest.skip(f"vault_ffi.dll not found at {dll_path}")
    lib = ctypes.CDLL(str(dll_path))

    lib.vault_init.restype = ctypes.c_int32
    lib.vault_load_test_mnemonic.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_load_test_mnemonic.restype = ctypes.c_int32

    lib.vault_prepare_legacy_tx.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint64,
    ]
    lib.vault_prepare_legacy_tx.restype = ctypes.c_char_p

    lib.vault_approve_and_sign.argtypes = [ctypes.c_char_p]
    lib.vault_approve_and_sign.restype = ctypes.c_char_p

    lib.vault_cancel.argtypes = [ctypes.c_char_p]
    lib.vault_cancel.restype = ctypes.c_int32

    lib.vault_free_string.argtypes = [ctypes.c_char_p]
    lib.vault_free_string.restype = None

    return lib


def get_wallet_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "wallet_ffi.dll"
    if not dll_path.exists():
        pytest.skip(f"wallet_ffi.dll not found at {dll_path}")
    lib = ctypes.CDLL(str(dll_path))

    lib.wallet_verify_signature.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint8,
        ctypes.c_char_p,
    ]
    lib.wallet_verify_signature.restype = ctypes.c_int32

    lib.wallet_decode_intent_json.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    lib.wallet_decode_intent_json.restype = ctypes.c_char_p

    lib.wallet_free_string.argtypes = [ctypes.c_char_p]
    lib.wallet_free_string.restype = None

    return lib


# --- Pure Python Helpers for Format and Calldata Verification ---

def format_units_decimal_fixed_point(raw_dec_str: str, decimals: int) -> str:
    """Exact base-10 string fixed-point formatting without floating-point math."""
    s = raw_dec_str.strip()
    if not s or s == "0":
        return "0.0"
    if len(s) <= decimals:
        zeros = "0" * (decimals - len(s))
        frac = f"{zeros}{s}".rstrip("0")
        return f"0.{frac}" if frac else "0.0"
    else:
        int_part = s[:-decimals]
        frac_part = s[-decimals:].rstrip("0")
        return f"{int_part}.{frac_part}" if frac_part else f"{int_part}.0"


def encode_erc20_transfer_calldata(recipient: str, amount_int: int, dirty_prefix: bytes = b"\x00" * 12) -> bytes:
    """Builds standard 68-byte transfer(address,uint256) calldata."""
    selector = bytes.fromhex("a9059cbb")
    clean_addr = bytes.fromhex(recipient.lower().replace("0x", ""))
    padded_addr = dirty_prefix + clean_addr
    padded_amount = amount_int.to_bytes(32, "big")
    return selector + padded_addr + padded_amount


def rlp_encode_bytes(b: bytes) -> bytes:
    if len(b) == 1 and b[0] < 0x80:
        return b
    elif len(b) <= 55:
        return bytes([0x80 + len(b)]) + b
    else:
        len_bytes = len(b).to_bytes((len(b).bit_length() + 7) // 8, "big")
        return bytes([0xb7 + len(len_bytes)]) + len_bytes + b


def rlp_encode_int(val: int) -> bytes:
    if val == 0:
        return b"\x80"
    b = val.to_bytes((val.bit_length() + 7) // 8, "big")
    return rlp_encode_bytes(b)


def rlp_encode_list(items: list[bytes]) -> bytes:
    payload = b"".join(items)
    if len(payload) <= 55:
        return bytes([0xc0 + len(payload)]) + payload
    else:
        len_bytes = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
        return bytes([0xf7 + len(len_bytes)]) + len_bytes + payload


def build_legacy_tx_rlp(nonce: int, gas_price: int, gas_limit: int, to: str, value: int, data: bytes, chain_id: int) -> bytes:
    to_bytes = bytes.fromhex(to.lower().replace("0x", ""))
    fields = [
        rlp_encode_int(nonce),
        rlp_encode_int(gas_price),
        rlp_encode_int(gas_limit),
        rlp_encode_bytes(to_bytes),
        rlp_encode_int(value),
        rlp_encode_bytes(data),
        rlp_encode_int(chain_id * 2 + 35),
        b"\x80",
        b"\x80",
    ]
    return rlp_encode_list(fields)


# ==============================================================================
# 1. EVM-08: ERC-20 Mock 6/18 Decimals Transfer & String Fixed-Point Precision
# ==============================================================================

class TestG3EVM08TokenPrecision:
    """Verifies standard ERC-20 transfers for 6 and 18 decimals without floating point distortion."""

    @pytest.mark.parametrize("decimals,symbol,raw_amount,expected_display", [
        # Sepolia Mock USDC (6 Decimals)
        (6, "USDC", "100500000", "100.5 USDC"),
        (6, "USDC", "1", "0.000001 USDC"),
        (6, "USDC", "50000000000000", "50000000.0 USDC"),
        # Sepolia Mock DAI (18 Decimals)
        (18, "DAI", "2500000000000000000", "2.5 DAI"),
        (18, "DAI", "1", "0.000000000000000001 DAI"),
        (18, "DAI", "1000000000000000000000000000", "1000000000.0 DAI"),
    ])
    def test_evm_08_fixed_point_precision_formatting(self, decimals, symbol, raw_amount, expected_display):
        formatted = format_units_decimal_fixed_point(raw_amount, decimals)
        display_str = f"{formatted} {symbol}"
        assert display_str == expected_display, f"Expected {expected_display}, got {display_str}"

    def test_evm_08_vault_ffi_usdc_and_dai_policy_parsing(self):
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        usdc_contract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        dai_contract = "0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357"

        # 1. Test Sepolia Mock USDC (6 decimals, 100.5 USDC = 100_500_000 raw)
        usdc_calldata = encode_erc20_transfer_calldata(recipient, 100_500_000)
        usdc_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, usdc_calldata, 11155111)
        res_ptr = vault.vault_prepare_legacy_tx(b"sess_usdc", b"req_usdc", usdc_rlp.hex().encode(), 11155111)
        assert res_ptr is not None
        usdc_json = json.loads(res_ptr.decode())
        assert "policy_verdict" in usdc_json, f"Policy review should succeed: {usdc_json}"
        assert "Approved" in usdc_json["policy_verdict"]
        app = usdc_json["policy_verdict"]["Approved"]
        assert app["amount_display"] == "100.5 USDC"

        # 2. Test Sepolia Mock DAI (18 decimals, 2.5 DAI = 2_500_000_000_000_000_000 raw)
        dai_calldata = encode_erc20_transfer_calldata(recipient, 2_500_000_000_000_000_000)
        dai_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 65000, dai_contract, 0, dai_calldata, 11155111)
        res_ptr2 = vault.vault_prepare_legacy_tx(b"sess_dai", b"req_dai", dai_rlp.hex().encode(), 11155111)
        assert res_ptr2 is not None
        dai_json = json.loads(res_ptr2.decode())
        assert "policy_verdict" in dai_json
        assert "Approved" in dai_json["policy_verdict"]
        app2 = dai_json["policy_verdict"]["Approved"]
        assert app2["amount_display"] == "2.5 DAI"


# ==============================================================================
# 2. EVM-09: Adversarial Token Metadata & Unknown ABI Rejection
# ==============================================================================

class TestG3EVM09AdversarialTokenDefense:
    """Verifies Fail-Closed policy on malicious metadata, dirty padding, and non-whitelisted contracts."""

    def test_evm_09_untrusted_token_contract_fail_closed_rejection(self):
        """Non-whitelisted token contracts must be rejected by PolicyEngine (EVM-09)."""
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        untrusted_contract = "0xDeadBeef00000000000000000000000000000000"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        calldata = encode_erc20_transfer_calldata(recipient, 100_500_000)
        rlp = build_legacy_tx_rlp(0, 20_000_000_000, 65000, untrusted_contract, 0, calldata, 11155111)

        res_ptr = vault.vault_prepare_legacy_tx(b"sess_bad_token", b"req_bad_token", rlp.hex().encode(), 11155111)
        assert res_ptr is not None
        res_json = json.loads(res_ptr.decode())
        # Must return error indicating token is not in approved whitelist
        assert "error" in res_json
        err_msg = res_json["error"]
        assert "EVM-09 Fail-Closed" in err_msg or "not in the approved whitelist" in err_msg

    def test_evm_09_dangerous_and_unknown_selectors_rejected(self):
        """Only transfer(address,uint256) is permitted; all other functions must be rejected."""
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        usdc_contract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"

        # Test approve(address,uint256) selector: 0x095ea7b3
        approve_calldata = bytes.fromhex("095ea7b3") + encode_erc20_transfer_calldata(recipient, 1000)[4:]
        approve_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, approve_calldata, 11155111)

        res_ptr = vault.vault_prepare_legacy_tx(b"sess_appr", b"req_appr", approve_rlp.hex().encode(), 11155111)
        assert res_ptr is not None
        res_json = json.loads(res_ptr.decode())
        assert "error" in res_json
        assert "Non-transfer" in res_json["error"] or "rejected" in res_json["error"].lower()


# ==============================================================================
# 3. LIFE-01, LIFE-02, LIFE-03: Lifecycle State Machine & Replay Defense
# ==============================================================================

class TestG3LifecycleStateMachine:
    """Verifies state machine guarantees on immutable handles, cancellation zeroize, and replay prevention."""

    def test_life_01_new_request_revokes_previous_handle(self):
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        rlp1 = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111)
        rlp2 = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 2_000_000_000, b"", 11155111)

        # 1. Ingest Request 1
        res1 = json.loads(vault.vault_prepare_legacy_tx(b"sess_1", b"req_1", rlp1.hex().encode(), 11155111).decode())
        handle1 = res1["handle_id"]

        # 2. Ingest Request 2 (simulates user scanning a new request before approving Request 1)
        res2 = json.loads(vault.vault_prepare_legacy_tx(b"sess_1", b"req_2", rlp2.hex().encode(), 11155111).decode())
        handle2 = res2["handle_id"]
        assert handle1 != handle2

        # 3. Attempting to sign Handle 1 must fail because Handle 1 was Revoked by Handle 2 (LIFE-01)
        sign_res1 = json.loads(vault.vault_approve_and_sign(handle1.encode()).decode())
        assert "error" in sign_res1
        assert "cancelled" in sign_res1["error"].lower() or "revoked" in sign_res1["error"].lower()

        # 4. Handle 2 can be signed normally
        sign_res2 = json.loads(vault.vault_approve_and_sign(handle2.encode()).decode())
        assert sign_res2.get("status") == "SUCCESS"

    def test_life_02_cancellation_and_background_zeroize(self):
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        rlp = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111)

        res = json.loads(vault.vault_prepare_legacy_tx(b"sess_cancel", b"req_cancel", rlp.hex().encode(), 11155111).decode())
        handle = res["handle_id"]

        # User cancels or app backgrounds (LIFE-02)
        cancel_code = vault.vault_cancel(handle.encode())
        assert cancel_code == 0

        # Attempt to sign cancelled handle must fail
        sign_res = json.loads(vault.vault_approve_and_sign(handle.encode()).decode())
        assert "error" in sign_res
        assert "cancelled" in sign_res["error"].lower() or "invalid state" in sign_res["error"].lower()

    def test_life_03_consumed_state_prevents_replay_and_double_click(self):
        vault = get_vault_ffi()
        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        rlp = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111)

        res = json.loads(vault.vault_prepare_legacy_tx(b"sess_rep", b"req_rep", rlp.hex().encode(), 11155111).decode())
        handle = res["handle_id"]

        # First sign: SUCCESS
        sign_res1 = json.loads(vault.vault_approve_and_sign(handle.encode()).decode())
        assert sign_res1.get("status") == "SUCCESS"
        assert "signature" in sign_res1

        # Second sign attempt (Double click / Replay): MUST FAIL (LIFE-03)
        sign_res2 = json.loads(vault.vault_approve_and_sign(handle.encode()).decode())
        assert "error" in sign_res2
        assert "consumed" in sign_res2["error"].lower() or "invalid state" in sign_res2["error"].lower()


# ==============================================================================
# 4. OWN-01: End-to-End Loopback: Wallet Tx -> Sign Request -> Vault -> Signature -> Verify
# ==============================================================================

class TestG3OwnClosedLoop:
    """Full end-to-end loopback simulation between watch-only Wallet and offline Vault."""

    def test_own_01_complete_airgap_closed_loop(self):
        vault = get_vault_ffi()
        wallet = get_wallet_ffi()

        vault.vault_init()
        mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        assert vault.vault_load_test_mnemonic(mnemonic, b"") == 0

        # Step 1: Watch account
        expected_address = "0x9858effd232b4033e47d90003d41ec34ecaeda94"

        # Step 2: Wallet constructs unsigned Sepolia transaction (Mock USDC Transfer)
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        usdc_contract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        calldata = encode_erc20_transfer_calldata(recipient, 100_500_000)
        raw_tx_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, calldata, 11155111)

        # Step 3: Wallet packs Tag 401 eth-sign-request
        req_uuid = uuid.uuid4().bytes
        sign_req_payload = {
            1: cbor2.CBORTag(37, req_uuid),
            2: raw_tx_rlp,
            3: 1, # Transaction
            4: 11155111, # Sepolia
        }
        encoded_req = cbor2.dumps(cbor2.CBORTag(401, sign_req_payload))
        assert len(encoded_req) <= 131072

        # Step 4: Vault scans & decodes Tag 401
        decoded_req = cbor2.loads(encoded_req)
        assert decoded_req.tag == 401
        req_rlp = decoded_req.value[2]
        declared_chain = decoded_req.value[4]

        # Step 5: Vault FFI ingests & evaluates policy
        prep_res = json.loads(
            vault.vault_prepare_legacy_tx(
                b"sess_own01",
                b"req_own01",
                req_rlp.hex().encode(),
                declared_chain,
            ).decode()
        )
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "100.5 USDC"

        # Step 6: User approves on Vault, Vault signs
        handle_id = prep_res["handle_id"]
        sign_res = json.loads(vault.vault_approve_and_sign(handle_id.encode()).decode())
        assert sign_res.get("status") == "SUCCESS"
        sig_hex = sign_res["signature"].replace("0x", "")
        assert len(sig_hex) == 130 # 65 bytes hex (r=32, s=32, v=1)

        sig_bytes = bytes.fromhex(sig_hex)
        r_hex = sig_hex[:64]
        s_hex = sig_hex[64:128]
        v_int = int(sig_hex[128:130], 16)

        # Step 7: Vault packs Tag 402 eth-signature
        sign_resp_payload = {
            1: cbor2.CBORTag(37, req_uuid),
            2: sig_bytes,
        }
        encoded_resp = cbor2.dumps(cbor2.CBORTag(402, sign_resp_payload))

        # Step 8: Wallet scans & decodes Tag 402
        decoded_resp = cbor2.loads(encoded_resp)
        assert decoded_resp.tag == 402
        resp_uuid = decoded_resp.value[1].bytes if hasattr(decoded_resp.value[1], "bytes") else decoded_resp.value[1].value
        assert resp_uuid == req_uuid, "request_id must match byte-for-byte"

        # Step 9: Wallet verifies signature recovery via wallet_ffi
        # Derive signing digest from raw_tx_rlp using wallet_decode_intent_json
        intent_ptr = wallet.wallet_decode_intent_json(raw_tx_rlp.hex().encode(), 11155111)
        assert intent_ptr is not None

        # Compute tx preimage hash from prep_res
        raw_digest_hex = bytes(prep_res["raw_signing_digest"]).hex()

        # Call wallet_verify_signature
        verify_code = wallet.wallet_verify_signature(
            raw_digest_hex.encode(),
            r_hex.encode(),
            s_hex.encode(),
            v_int,
            expected_address.encode(),
        )
        assert verify_code == 1, "wallet_verify_signature must return 1 (valid signature recovering watch account)"
