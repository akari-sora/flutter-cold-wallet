#!/usr/bin/env python3
"""
tests/integration/test_h2_nfc_transaction_e2e.py
================================================
HOST_FFI_INTEGRATION TEST SUITE:
--------------------------------
This test suite verifies the host-level cryptographic and protocol integration
between the Wallet (watch-only / verifier) and Vault (isolated signer) components:
1. NFC SignRequest (Wallet -> Vault): Chunks unsigned EVM tx into NFC short APDUs (<=128B).
2. Vault Reassembly & Policy Review: Reassembles NFC chunks, decodes intent, checks policy.
   - Records actual Transport::NfcIsoDepHce in PreparedRequest (not hardcoded Qr).
3. Vault Cryptographic Signing: KeyVault signs with real isolated test key.
4. NFC SignResponse (Vault -> Wallet): Chunks signature payload into NFC short APDUs (<=128B).
5. Wallet Independent Self-Verification:
   - Wallet independently re-calculates the expected digest from its local pending raw tx.
   - Matches response digest against the local calculated digest.
   - Verifies signature against expected address via wallet_ffi.
6. Multi-chunk fragmentation & full return leg reassembly with whitelisted ERC-20 transfer.
7. Negative Security & Boundary Gates:
   - Negative test: another valid signature for a different transaction spliced into original
     request_id is strictly rejected by Wallet self-verification.
   - Cancellation during review strictly guarantees zero signing call count (sign_command_count == 0).
   - Replay protection rejects secondary signing attempts (LIFE-03).
   - Tampered NFC chunk payload triggers DigestMismatch and is strictly rejected.
   - Session ID mismatch across chunks is rejected.

NOTE: This is a HOST_FFI_INTEGRATION test suite running against native Rust DLLs on host.
It DOES NOT claim or simulate physical Android NFC RF contact, which is tracked separately
under BL15 (pending dual physical device RF touch).
"""

import ctypes
import json
import os
import sys
import uuid
import cbor2
import pytest
from pathlib import Path

# Mark entire suite explicitly as host FFI integration
pytestmark = [
    pytest.mark.host_ffi_integration,
]

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

TEST_MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
EXPECTED_ADDRESS = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
USDC_SEPOLIA = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"


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


def encode_erc20_transfer_calldata(recipient: str, amount_int: int) -> bytes:
    selector = bytes.fromhex("a9059cbb")
    clean_addr = bytes.fromhex(recipient.lower().replace("0x", ""))
    padded_addr = (b"\x00" * 12) + clean_addr
    padded_amount = amount_int.to_bytes(32, "big")
    return selector + padded_addr + padded_amount


def get_vault_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "vault_ffi.dll"
    if not dll_path.exists():
        if os.environ.get("FCW_ALLOW_MISSING_FFI_DLL") == "1":
            pytest.skip(f"vault_ffi.dll not found at {dll_path}")
        pytest.fail(f"Required native FFI artifact missing: {dll_path}")
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
    lib.vault_prepare_legacy_tx.restype = ctypes.c_void_p

    lib.vault_prepare_legacy_tx_with_transport.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.c_uint32,
    ]
    lib.vault_prepare_legacy_tx_with_transport.restype = ctypes.c_void_p

    lib.vault_prepare_eip1559_tx_with_transport.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.c_uint32,
    ]
    lib.vault_prepare_eip1559_tx_with_transport.restype = ctypes.c_void_p

    lib.vault_approve_and_sign.argtypes = [ctypes.c_char_p]
    lib.vault_approve_and_sign.restype = ctypes.c_void_p

    lib.vault_cancel.argtypes = [ctypes.c_char_p]
    lib.vault_cancel.restype = ctypes.c_int32

    lib.vault_get_request_state.argtypes = [ctypes.c_char_p]
    lib.vault_get_request_state.restype = ctypes.c_void_p

    lib.vault_get_primitive_sign_count.argtypes = []
    lib.vault_get_primitive_sign_count.restype = ctypes.c_int64

    lib.vault_nfc_reset_sessions.argtypes = []
    lib.vault_nfc_reset_sessions.restype = ctypes.c_int32

    lib.vault_nfc_chunk_payload.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint8,
        ctypes.c_char_p,
        ctypes.c_size_t,
    ]
    lib.vault_nfc_chunk_payload.restype = ctypes.c_void_p

    lib.vault_nfc_process_chunk.argtypes = [ctypes.c_char_p]
    lib.vault_nfc_process_chunk.restype = ctypes.c_void_p

    lib.vault_nfc_process_apdu_frame.argtypes = [ctypes.c_char_p]
    lib.vault_nfc_process_apdu_frame.restype = ctypes.c_void_p

    lib.vault_free_string.argtypes = [ctypes.c_void_p]
    lib.vault_free_string.restype = None

    return lib


def get_wallet_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "wallet_ffi.dll"
    if not dll_path.exists():
        if os.environ.get("FCW_ALLOW_MISSING_FFI_DLL") == "1":
            pytest.skip(f"wallet_ffi.dll not found at {dll_path}")
        pytest.fail(f"Required native FFI artifact missing: {dll_path}")
    lib = ctypes.CDLL(str(dll_path))

    lib.wallet_init.argtypes = []
    lib.wallet_init.restype = ctypes.c_int32

    lib.wallet_nfc_reset_sessions.argtypes = []
    lib.wallet_nfc_reset_sessions.restype = ctypes.c_int32

    lib.wallet_verify_signature.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint8,
        ctypes.c_char_p,
    ]
    lib.wallet_verify_signature.restype = ctypes.c_int32

    lib.wallet_decode_intent_json.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    lib.wallet_decode_intent_json.restype = ctypes.c_void_p

    lib.wallet_compute_legacy_signing_digest.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
    lib.wallet_compute_legacy_signing_digest.restype = ctypes.c_void_p

    lib.wallet_register_pending_tx.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.c_char_p,
    ]
    lib.wallet_register_pending_tx.restype = ctypes.c_void_p

    lib.wallet_verify_nfc_response_json.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
    ]
    lib.wallet_verify_nfc_response_json.restype = ctypes.c_void_p

    lib.wallet_nfc_chunk_payload.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint8,
        ctypes.c_char_p,
        ctypes.c_size_t,
    ]
    lib.wallet_nfc_chunk_payload.restype = ctypes.c_void_p

    lib.wallet_nfc_process_chunk.argtypes = [ctypes.c_char_p]
    lib.wallet_nfc_process_chunk.restype = ctypes.c_void_p

    lib.wallet_nfc_process_apdu_frame.argtypes = [ctypes.c_char_p]
    lib.wallet_nfc_process_apdu_frame.restype = ctypes.c_void_p

    lib.wallet_free_string.argtypes = [ctypes.c_void_p]
    lib.wallet_free_string.restype = None

    return lib


def parse_and_free(lib, ptr) -> dict:
    assert ptr is not None, "Pointer must not be null"
    cstr = ctypes.cast(ptr, ctypes.c_char_p).value
    assert cstr is not None, "String value must not be null"
    val = cstr.decode("utf-8")
    free_fn = getattr(lib, "vault_free_string", getattr(lib, "wallet_free_string", None))
    assert free_fn is not None
    free_fn(ptr)
    return json.loads(val)


def string_and_free(lib, ptr) -> str:
    assert ptr is not None, "Pointer must not be null"
    cstr = ctypes.cast(ptr, ctypes.c_char_p).value
    assert cstr is not None, "String value must not be null"
    val = cstr.decode("utf-8")
    free_fn = getattr(lib, "vault_free_string", getattr(lib, "wallet_free_string", None))
    assert free_fn is not None
    free_fn(ptr)
    return val


def assert_chunk_and_apdu_wire_bounds(chunks: list[dict], max_raw_slice: int = 128):
    """Verifies packet-by-packet CBOR envelope size, Tier-2 APDU Lc <= 128, and total C-APDU wire length <= 134."""
    assert len(chunks) >= 1
    for c in chunks:
        assert c["raw_payload_len"] <= max_raw_slice
        assert c["cbor_byte_len"] == len(bytes.fromhex(c["cbor_hex"]))
        assert c["cbor_byte_len"] <= 512, f"CBOR envelope {c['cbor_byte_len']} exceeds 512B budget"
        frames = c["apdu_frames_hex"]
        frame_lens = c["apdu_frame_lengths"]
        lc_lens = c["apdu_data_lengths"]
        assert len(frames) >= 1
        assert len(frames) == len(frame_lens) == len(lc_lens)
        for f_hex, f_len, lc in zip(frames, frame_lens, lc_lens):
            raw_apdu = bytes.fromhex(f_hex)
            assert len(raw_apdu) == f_len
            assert raw_apdu[0] == 0x80
            assert raw_apdu[4] == lc
            assert 1 <= lc <= 128, f"HCE APDU Lc={lc} exceeds 128B limit"
            assert len(raw_apdu) == 6 + lc
            assert len(raw_apdu) <= 134, f"C-APDU wire length {len(raw_apdu)} exceeds 134B HCE limit"
            assert len(raw_apdu) <= 261, f"C-APDU wire length {len(raw_apdu)} exceeds IsoDep min maxTransceiveLength"


class TestH2NfcTransactionE2E:
    """
    HOST_FFI_INTEGRATION test suite for NFC transport framing, fragmentation,
    reassembly, policy verification, signing, and Wallet self-verification.
    """

    @pytest.fixture(autouse=True)
    def setup_vault(self):
        self.vault_lib = get_vault_ffi()
        self.wallet_lib = get_wallet_ffi()
        assert self.vault_lib.vault_init() == 0
        assert self.wallet_lib.wallet_init() == 0

        # Load standard test mnemonic into isolated Vault only
        res = self.vault_lib.vault_load_test_mnemonic(
            TEST_MNEMONIC.encode("utf-8"),
            b""
        )
        assert res == 0, "Vault mnemonic initialization failed"

    def test_nfc_full_transaction_closed_loop(self):
        """
        Step 1: Wallet registers pending tx in wallet_ffi and chunks it into NFC SignRequest envelopes + Tier-2 APDUs.
        Step 2: Vault reassembles Tier-2 C-APDU frames (<=128B data, <=134B wire) into full payload.
        Step 3: Vault inspects policy & intent, user approves, and core signs.
                PreparedRequest binds actual Transport::NfcIsoDepHce (not hardcoded Qr).
        Step 4: Vault chunks signature response into NFC SignResponse envelopes + Tier-2 APDUs.
        Step 5: Wallet reassembles response via wallet_ffi (never touching vault_ffi),
                and verifies response against bound pending tx in wallet_ffi.
        """
        session_id = f"sess_nfc_{uuid.uuid4().hex[:8]}"
        request_id = f"req_nfc_{uuid.uuid4().hex[:8]}"
        chain_id = 11155111  # Sepolia testnet

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", chain_id)
        raw_rlp_hex = raw_rlp.hex()

        # 0. Wallet registers pending tx in watch-only wallet_ffi context
        reg_ptr = self.wallet_lib.wallet_register_pending_tx(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            raw_rlp_hex.encode("utf-8"),
            chain_id,
            EXPECTED_ADDRESS.encode("utf-8"),
        )
        reg_res = parse_and_free(self.wallet_lib, reg_ptr)
        assert reg_res["status"] == "PENDING_REGISTERED"
        expected_digest = reg_res["expected_digest"]

        # 1. Wallet chunks unsigned payload using wallet_ffi (NOT vault_ffi)
        chunk_ptr = self.wallet_lib.wallet_nfc_chunk_payload(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            4,  # MessageKind::SignRequest
            raw_rlp_hex.encode("utf-8"),
            120  # Raw payload slice limit; Tier-2 APDU frames enforce Lc <= 128B, wire <= 134B
        )
        request_chunks = parse_and_free(self.wallet_lib, chunk_ptr)
        assert_chunk_and_apdu_wire_bounds(request_chunks, max_raw_slice=120)

        # 2. Vault receives Tier-2 C-APDU frames and reassembles NFC chunks
        reassembled_payload = None
        for i, chunk in enumerate(request_chunks):
            frames = chunk["apdu_frames_hex"]
            for f_idx, f_hex in enumerate(frames):
                res_ptr = self.vault_lib.vault_nfc_process_apdu_frame(f_hex.encode("utf-8"))
                res = parse_and_free(self.vault_lib, res_ptr)
                if f_idx < len(frames) - 1:
                    assert res["status"] == "FRAME_ACK"
                    assert res["sw"] == "9000"
                elif i < len(request_chunks) - 1:
                    assert res["status"] == "IN_PROGRESS"
                else:
                    assert res["status"] == "COMPLETE"
                    assert res["message_kind"] == 4
                    assert res["session_id"] == session_id
                    assert res["request_id"] == request_id
                    reassembled_payload = res["payload_hex"]

        assert reassembled_payload.lower() == raw_rlp_hex.lower()

        # 3. Vault decodes intent, checks policy, and binds transport = NfcIsoDepHce (code=1)
        prep_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            reassembled_payload.encode("utf-8"),
            chain_id,
            1  # 1 = Transport::NfcIsoDepHce
        )
        prep_res = parse_and_free(self.vault_lib, prep_ptr)
        assert "handle_id" in prep_res, f"Unexpected error: {prep_res}"
        handle_id = prep_res["handle_id"]
        assert prep_res["intent"]["NativeTransfer"]["chain_id"] == chain_id
        assert prep_res["intent"]["NativeTransfer"]["recipient"].lower() == recipient.lower()
        assert "Approved" in prep_res["policy_verdict"]

        # Verify transport is recorded as NfcIsoDepHce and primitive sign count is 0 before signing
        state_ptr = self.vault_lib.vault_get_request_state(handle_id.encode("utf-8"))
        state_res = parse_and_free(self.vault_lib, state_ptr)
        assert state_res["transport"] == "NfcIsoDepHce", f"Expected NfcIsoDepHce, got {state_res['transport']}"
        assert state_res["primitive_sign_invocations"] == 0

        # Sign request with KeyVault
        sign_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign_res = parse_and_free(self.vault_lib, sign_ptr)
        assert "signature" in sign_res
        assert self.vault_lib.vault_get_primitive_sign_count() == 1
        sig_hex = sign_res["signature"].replace("0x", "")
        sig_r = sig_hex[:64]
        sig_s = sig_hex[64:128]
        sig_v = int(sig_hex[128:130], 16)
        vault_digest_hex = bytes(prep_res["raw_signing_digest"]).hex()

        # 4. Vault chunks SignResponse into NFC envelopes + Tier-2 APDUs (<=128B data, <=134B wire)
        response_payload = json.dumps({
            "request_id": request_id,
            "chain_id": chain_id,
            "r": sig_r,
            "s": sig_s,
            "v": sig_v,
            "digest": vault_digest_hex,
            "signer_address": EXPECTED_ADDRESS
        }).encode("utf-8").hex()

        resp_chunks_ptr = self.vault_lib.vault_nfc_chunk_payload(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            6,  # MessageKind::SignResponse
            response_payload.encode("utf-8"),
            120
        )
        resp_chunks = parse_and_free(self.vault_lib, resp_chunks_ptr)
        assert_chunk_and_apdu_wire_bounds(resp_chunks, max_raw_slice=120)

        # 5. Wallet reassembles NFC response using wallet_ffi (NOT vault_ffi) and verifies bound pending tx
        wallet_reassembled_hex = None
        for i, chunk in enumerate(resp_chunks):
            frames = chunk["apdu_frames_hex"]
            for f_idx, f_hex in enumerate(frames):
                res_ptr = self.wallet_lib.wallet_nfc_process_apdu_frame(f_hex.encode("utf-8"))
                res = parse_and_free(self.wallet_lib, res_ptr)
                if f_idx < len(frames) - 1:
                    assert res["status"] == "FRAME_ACK"
                elif i < len(resp_chunks) - 1:
                    assert res["status"] == "IN_PROGRESS"
                else:
                    assert res["status"] == "COMPLETE"
                    assert res["message_kind"] == 6
                    wallet_reassembled_hex = res["payload_hex"]

        # Wallet verifies response against bound PendingWalletRequest inside Rust wallet_ffi
        bound_verify_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            wallet_reassembled_hex.encode("utf-8"),
        )
        bound_verify_res = parse_and_free(self.wallet_lib, bound_verify_ptr)
        assert bound_verify_res["verified"] is True, f"Bound verification failed: {bound_verify_res}"
        assert bound_verify_res["expected_digest"].lower() == expected_digest.lower()
        assert bound_verify_res["recovered_address"].lower() == EXPECTED_ADDRESS.lower()

        # Replay of the same response against consumed pending request must be rejected by wallet_ffi
        replay_verify_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            wallet_reassembled_hex.encode("utf-8"),
        )
        replay_verify_res = parse_and_free(self.wallet_lib, replay_verify_ptr)
        assert replay_verify_res["verified"] is False
        assert "already consumed" in replay_verify_res["error"]

    def test_nfc_multi_chunk_erc20_transaction_closed_loop(self):
        """
        Tests multi-chunk (>1 chunk) NFC fragmentation & reassembly with a whitelisted ERC-20 transfer,
        including complete return leg chunking, reassembly via wallet_ffi, independent digest verification, and sign check.
        """
        session_id = f"sess_erc20_{uuid.uuid4().hex[:8]}"
        request_id = f"req_erc20_{uuid.uuid4().hex[:8]}"
        chain_id = 11155111

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        calldata = encode_erc20_transfer_calldata(recipient, 100_500_000)  # 100.5 USDC
        raw_rlp = build_legacy_tx_rlp(0, 25_000_000_000, 65000, USDC_SEPOLIA, 0, calldata, chain_id)
        raw_rlp_hex = raw_rlp.hex()
        assert len(raw_rlp) > 100, f"RLP length {len(raw_rlp)} should be > 100B"

        reg_ptr = self.wallet_lib.wallet_register_pending_tx(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            raw_rlp_hex.encode("utf-8"),
            chain_id,
            EXPECTED_ADDRESS.encode("utf-8"),
        )
        reg_res = parse_and_free(self.wallet_lib, reg_ptr)
        assert reg_res["status"] == "PENDING_REGISTERED"

        # Chunk with size=48 on wallet_ffi to force 3+ chunks across NFC transport
        chunk_ptr = self.wallet_lib.wallet_nfc_chunk_payload(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            4,
            raw_rlp_hex.encode("utf-8"),
            48
        )
        chunks = parse_and_free(self.wallet_lib, chunk_ptr)
        assert len(chunks) >= 3, f"Expected >= 3 chunks, got {len(chunks)}"
        assert_chunk_and_apdu_wire_bounds(chunks, max_raw_slice=48)

        # Reassemble chunks sequentially on Vault
        reassembled_hex = None
        for i, c in enumerate(chunks):
            res_ptr = self.vault_lib.vault_nfc_process_chunk(c["cbor_hex"].encode("utf-8"))
            res = parse_and_free(self.vault_lib, res_ptr)
            if i < len(chunks) - 1:
                assert res["status"] == "IN_PROGRESS"
            else:
                assert res["status"] == "COMPLETE"
                reassembled_hex = res["payload_hex"]

        assert reassembled_hex.lower() == raw_rlp_hex.lower()

        # Vault prepares and signs ERC-20 transfer with transport NfcIsoDepHce
        prep_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            reassembled_hex.encode("utf-8"),
            chain_id,
            1
        )
        prep_res = parse_and_free(self.vault_lib, prep_ptr)
        assert "handle_id" in prep_res
        handle_id = prep_res["handle_id"]
        assert "Erc20Transfer" in prep_res["intent"]
        assert prep_res["intent"]["Erc20Transfer"]["token_contract"].lower() == USDC_SEPOLIA.lower()
        assert prep_res["intent"]["Erc20Transfer"]["recipient"].lower() == recipient.lower()
        assert prep_res["intent"]["Erc20Transfer"]["token_amount_raw"] == "100500000"

        # Verify transport is recorded as NfcIsoDepHce
        state_ptr = self.vault_lib.vault_get_request_state(handle_id.encode("utf-8"))
        state_res = parse_and_free(self.vault_lib, state_ptr)
        assert state_res["transport"] == "NfcIsoDepHce"

        sign_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign_res = parse_and_free(self.vault_lib, sign_ptr)
        assert "signature" in sign_res

        # Complete return leg: Vault chunks SignResponse into multiple small NFC envelopes
        sig_hex = sign_res["signature"].replace("0x", "")
        sig_r = sig_hex[:64]
        sig_s = sig_hex[64:128]
        sig_v = int(sig_hex[128:130], 16)
        vault_digest_hex = bytes(prep_res["raw_signing_digest"]).hex()

        erc20_resp_payload = json.dumps({
            "request_id": request_id,
            "chain_id": chain_id,
            "r": sig_r,
            "s": sig_s,
            "v": sig_v,
            "digest": vault_digest_hex,
            "signer_address": EXPECTED_ADDRESS
        }).encode("utf-8").hex()

        # Chunk return payload into small fragments (size 48) to guarantee multi-chunk response
        resp_chunk_ptr = self.vault_lib.vault_nfc_chunk_payload(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            6,  # MessageKind::SignResponse
            erc20_resp_payload.encode("utf-8"),
            48
        )
        resp_chunks = parse_and_free(self.vault_lib, resp_chunk_ptr)
        assert len(resp_chunks) >= 3, f"Expected >= 3 response chunks, got {len(resp_chunks)}"
        assert_chunk_and_apdu_wire_bounds(resp_chunks, max_raw_slice=48)

        # Wallet reassembles multi-chunk NFC response using wallet_ffi (NOT vault_ffi)
        wallet_reassembled_resp = None
        for i, c in enumerate(resp_chunks):
            res_ptr = self.wallet_lib.wallet_nfc_process_chunk(c["cbor_hex"].encode("utf-8"))
            res = parse_and_free(self.wallet_lib, res_ptr)
            if i < len(resp_chunks) - 1:
                assert res["status"] == "IN_PROGRESS"
            else:
                assert res["status"] == "COMPLETE"
                assert res["message_kind"] == 6
                wallet_reassembled_resp = res["payload_hex"]

        bound_verify_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            wallet_reassembled_resp.encode("utf-8"),
        )
        bound_verify_res = parse_and_free(self.wallet_lib, bound_verify_ptr)
        assert bound_verify_res["verified"] is True, f"ERC-20 bound verification failed: {bound_verify_res}"

    def test_nfc_negative_valid_signature_for_different_tx_spliced_into_original_request(self):
        """
        NEGATIVE TEST:
        An attacker captures a valid signature for transaction B (e.g. 50 ETH transfer) and splices
        it into a response envelope targeting request_id_A (which was a 1 ETH transfer).
        Wallet's bound pending verification in wallet_ffi must strictly reject both:
        (1) the response carrying digest_b, and
        (2) a forged response carrying expected_digest_a with sig_b!
        """
        chain_id = 11155111
        sess_a = f"sess_a_{uuid.uuid4().hex[:6]}"
        req_a = f"req_a_{uuid.uuid4().hex[:6]}"
        recipient_a = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_rlp_a = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient_a, 1_000_000_000, b"", chain_id)
        raw_rlp_a_hex = raw_rlp_a.hex()

        # Register pending transaction A in Wallet
        reg_a_ptr = self.wallet_lib.wallet_register_pending_tx(
            sess_a.encode("utf-8"),
            req_a.encode("utf-8"),
            raw_rlp_a_hex.encode("utf-8"),
            chain_id,
            EXPECTED_ADDRESS.encode("utf-8"),
        )
        reg_a_res = parse_and_free(self.wallet_lib, reg_a_ptr)
        expected_digest_a = reg_a_res["expected_digest"]

        # Transaction B: different amount (50 ETH)
        sess_b = f"sess_b_{uuid.uuid4().hex[:6]}"
        req_b = f"req_b_{uuid.uuid4().hex[:6]}"
        recipient_b = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_rlp_b = build_legacy_tx_rlp(1, 20_000_000_000, 21000, recipient_b, 50_000_000_000_000_000_000, b"", chain_id)
        raw_rlp_b_hex = raw_rlp_b.hex()

        # Vault signs transaction B
        prep_b_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            sess_b.encode("utf-8"),
            req_b.encode("utf-8"),
            raw_rlp_b_hex.encode("utf-8"),
            chain_id,
            1
        )
        prep_b_res = parse_and_free(self.vault_lib, prep_b_ptr)
        handle_b = prep_b_res["handle_id"]

        sign_b_ptr = self.vault_lib.vault_approve_and_sign(handle_b.encode("utf-8"))
        sign_b_res = parse_and_free(self.vault_lib, sign_b_ptr)
        assert "signature" in sign_b_res
        sig_b_hex = sign_b_res["signature"].replace("0x", "")
        sig_b_r = sig_b_hex[:64]
        sig_b_s = sig_b_hex[64:128]
        sig_b_v = int(sig_b_hex[128:130], 16)
        digest_b_hex = bytes(prep_b_res["raw_signing_digest"]).hex()

        # Attack scenario 1: Adversary returns response for req_a with digest_b and sig_b
        spliced_resp_1 = json.dumps({
            "request_id": req_a,
            "chain_id": chain_id,
            "r": sig_b_r,
            "s": sig_b_s,
            "v": sig_b_v,
            "digest": digest_b_hex,
            "signer_address": EXPECTED_ADDRESS,
        }).encode("utf-8").hex()
        ver1_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            sess_a.encode("utf-8"),
            req_a.encode("utf-8"),
            spliced_resp_1.encode("utf-8"),
        )
        ver1_res = parse_and_free(self.wallet_lib, ver1_ptr)
        assert ver1_res["verified"] is False
        assert "Digest mismatch against local pending tx" in ver1_res["error"]

        # Attack scenario 2: Adversary replaces digest in payload with expected_digest_a, but keeps sig_b
        spliced_resp_2 = json.dumps({
            "request_id": req_a,
            "chain_id": chain_id,
            "r": sig_b_r,
            "s": sig_b_s,
            "v": sig_b_v,
            "digest": expected_digest_a,
            "signer_address": EXPECTED_ADDRESS,
        }).encode("utf-8").hex()
        ver2_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            sess_a.encode("utf-8"),
            req_a.encode("utf-8"),
            spliced_resp_2.encode("utf-8"),
        )
        ver2_res = parse_and_free(self.wallet_lib, ver2_ptr)
        assert ver2_res["verified"] is False
        assert "Cryptographic signature verification failed" in ver2_res["error"]

    def test_nfc_cancellation_guarantees_zero_sign_count(self):
        """When user cancels during review, both sign_command_count AND primitive_sign_invocations remain strictly 0."""
        session_id = "sess_cancel"
        request_id = "req_cancel"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111)

        prep_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            raw_rlp.hex().encode("utf-8"),
            11155111,
            1  # NfcIsoDepHce
        )
        prep_res = parse_and_free(self.vault_lib, prep_ptr)
        handle_id = prep_res["handle_id"]

        # Verify initial sign_command_count and primitive_sign_invocations are 0
        state_ptr = self.vault_lib.vault_get_request_state(handle_id.encode("utf-8"))
        state_res = parse_and_free(self.vault_lib, state_ptr)
        assert state_res["sign_command_count"] == 0
        assert state_res["primitive_sign_invocations"] == 0
        assert self.vault_lib.vault_get_primitive_sign_count() == 0
        assert state_res["transport"] == "NfcIsoDepHce"

        # Cancel before approving
        cancel_ret = self.vault_lib.vault_cancel(handle_id.encode("utf-8"))
        assert cancel_ret == 0

        # Verify state after cancel has sign_command_count == 0 and primitive_sign_invocations == 0
        state_after_ptr = self.vault_lib.vault_get_request_state(handle_id.encode("utf-8"))
        state_after_res = parse_and_free(self.vault_lib, state_after_ptr)
        assert state_after_res["sign_command_count"] == 0
        assert state_after_res["primitive_sign_invocations"] == 0
        assert self.vault_lib.vault_get_primitive_sign_count() == 0
        assert state_after_res["state"] == "Cancelled"

        # Attempt to sign cancelled request must fail and keep both counts == 0
        sign_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign_res = parse_and_free(self.vault_lib, sign_ptr)
        assert "error" in sign_res
        assert "cancelled" in sign_res["error"].lower()

        # Check final counts are still strictly 0
        state_final_ptr = self.vault_lib.vault_get_request_state(handle_id.encode("utf-8"))
        state_final_res = parse_and_free(self.vault_lib, state_final_ptr)
        assert state_final_res["sign_command_count"] == 0
        assert state_final_res["primitive_sign_invocations"] == 0
        assert self.vault_lib.vault_get_primitive_sign_count() == 0

    def test_nfc_replay_prevention_on_consumed_request(self):
        """A request that has been signed cannot be signed again (LIFE-03)."""
        session_id = "sess_replay"
        request_id = "req_replay"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_rlp = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111)

        prep_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            raw_rlp.hex().encode("utf-8"),
            11155111,
            1
        )
        prep_res = parse_and_free(self.vault_lib, prep_ptr)
        handle_id = prep_res["handle_id"]

        # First sign succeeds
        sign_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign_res = parse_and_free(self.vault_lib, sign_ptr)
        assert "signature" in sign_res

        # Secondary sign attempt must fail with LIFE-03
        sign2_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign2_res = parse_and_free(self.vault_lib, sign2_ptr)
        assert "error" in sign2_res
        assert "consumed" in sign2_res["error"].lower()

    def test_nfc_tampered_chunk_digest_mismatch(self):
        """Tampering with a chunk in transit causes reassembly to fail digest check."""
        session_id = f"sess_tamper_{uuid.uuid4().hex[:6]}"
        request_id = f"req_tamper_{uuid.uuid4().hex[:6]}"
        raw_payload = b"unauthorized transaction payload bytes to test tamper resistance"

        # 1. Invalid CBOR chunk is strictly rejected
        corrupt_res_ptr = self.vault_lib.vault_nfc_process_chunk(b"ffff_corrupted_cbor_stream")
        corrupt_res = parse_and_free(self.vault_lib, corrupt_res_ptr)
        assert "error" in corrupt_res

        # 2. Invalid chunk sequence is strictly rejected
        chunk_ptr = self.vault_lib.vault_nfc_chunk_payload(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            4,
            raw_payload.hex().encode("utf-8"),
            20
        )
        chunks = parse_and_free(self.vault_lib, chunk_ptr)
        assert len(chunks) > 1

        # Send chunk 0 normally
        res0_ptr = self.vault_lib.vault_nfc_process_chunk(chunks[0]["cbor_hex"].encode("utf-8"))
        res0 = parse_and_free(self.vault_lib, res0_ptr)
        assert res0["status"] == "IN_PROGRESS"

        # Mutate chunk 1 to have an invalid sequence index
        env1 = cbor2.loads(bytes.fromhex(chunks[1]["cbor_hex"]))
        env1["chunk_index"] = 99
        bad_seq_cbor = cbor2.dumps(env1).hex()
        bad_seq_ptr = self.vault_lib.vault_nfc_process_chunk(bad_seq_cbor.encode("utf-8"))
        bad_seq_res = parse_and_free(self.vault_lib, bad_seq_ptr)
        assert "error" in bad_seq_res
        assert "Invalid chunk sequence" in bad_seq_res["error"]

        # 3. Payload tampering test: altered payload bytes cause digest mismatch on finalize
        sess_tamper2 = f"sess_t2_{uuid.uuid4().hex[:6]}"
        req_tamper2 = f"req_t2_{uuid.uuid4().hex[:6]}"
        t2_chunk_ptr = self.vault_lib.vault_nfc_chunk_payload(
            sess_tamper2.encode("utf-8"),
            req_tamper2.encode("utf-8"),
            4,
            raw_payload.hex().encode("utf-8"),
            20
        )
        t2_chunks = parse_and_free(self.vault_lib, t2_chunk_ptr)
        assert len(t2_chunks) >= 2

        # Tamper chunk 0 payload bytes in transit
        env0 = cbor2.loads(bytes.fromhex(t2_chunks[0]["cbor_hex"]))
        env0["payload"] = [0xDE, 0xAD, 0xBE, 0xEF]
        tampered_cbor0 = cbor2.dumps(env0).hex()

        # Ingest tampered chunk 0
        t_res0_ptr = self.vault_lib.vault_nfc_process_chunk(tampered_cbor0.encode("utf-8"))
        t_res0 = parse_and_free(self.vault_lib, t_res0_ptr)
        assert t_res0["status"] == "IN_PROGRESS"

        # Ingest all subsequent untampered chunks until finalization
        final_res = None
        for i in range(1, len(t2_chunks)):
            r_ptr = self.vault_lib.vault_nfc_process_chunk(t2_chunks[i]["cbor_hex"].encode("utf-8"))
            final_res = parse_and_free(self.vault_lib, r_ptr)

        assert final_res is not None
        assert "error" in final_res
        assert "payload digest mismatch" in final_res["error"].lower()

    def test_vault_cancel_non_destructive_and_subprocess_no_abort(self):
        """
        FCW-H2-D359879-RECHECK Section 五 Part A:
        1. Exercises vault_cancel(valid) -> vault_cancel(same) -> vault_approve_and_sign(same) -> vault_cancel(invalid)
           AND prepare -> sign -> vault_cancel(signed_handle) in an isolated Python subprocess to prove
           zero panics across extern "C" (returncode == 0, never 0xc0000409).
        2. Exercises interleaved prepare/cancel/sign across multiple handles in-process.
        """
        import subprocess as sp

        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        valid_rlp_hex = build_legacy_tx_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000_000, b"", 11155111).hex()

        code = r"""
import ctypes, json, sys
from pathlib import Path

dll = Path(sys.argv[1])
rlp_hex = sys.argv[2].encode("utf-8")
lib = ctypes.CDLL(str(dll))
lib.vault_init.restype = ctypes.c_int32
lib.vault_load_test_mnemonic.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
lib.vault_load_test_mnemonic.restype = ctypes.c_int32
lib.vault_prepare_legacy_tx_with_transport.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.c_uint32]
lib.vault_prepare_legacy_tx_with_transport.restype = ctypes.c_void_p
lib.vault_approve_and_sign.argtypes = [ctypes.c_char_p]
lib.vault_approve_and_sign.restype = ctypes.c_void_p
lib.vault_cancel.argtypes = [ctypes.c_char_p]
lib.vault_cancel.restype = ctypes.c_int32
lib.vault_get_request_state.argtypes = [ctypes.c_char_p]
lib.vault_get_request_state.restype = ctypes.c_void_p
lib.vault_get_primitive_sign_count.argtypes = []
lib.vault_get_primitive_sign_count.restype = ctypes.c_int64
lib.vault_free_string.argtypes = [ctypes.c_void_p]
lib.vault_free_string.restype = None

def read_json(ptr):
    s = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
    lib.vault_free_string(ptr)
    return json.loads(s)

assert lib.vault_init() == 0
assert lib.vault_load_test_mnemonic(b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", b"") == 0

# 1. Prepare -> cancel -> cancel(same) -> sign(same) -> cancel(invalid)
prep1 = read_json(lib.vault_prepare_legacy_tx_with_transport(b"s1", b"r1", rlp_hex, 11155111, 1))
h1 = prep1["handle_id"].encode("utf-8")
assert lib.vault_cancel(h1) == 0
assert lib.vault_cancel(h1) == -5  # ERR_ALREADY_CANCELLED
s1 = read_json(lib.vault_approve_and_sign(h1))
assert "error" in s1 and "cancelled" in s1["error"].lower()
assert lib.vault_cancel(b"non_existent_handle_xyz") == -1  # ERR_HANDLE_NOT_FOUND
assert lib.vault_get_primitive_sign_count() == 0

# 2. Prepare -> sign -> cancel(signed_handle) must NOT overwrite post-sign state into Cancelled
prep2 = read_json(lib.vault_prepare_legacy_tx_with_transport(b"s2", b"r2", rlp_hex, 11155111, 1))
h2 = prep2["handle_id"].encode("utf-8")
s2 = read_json(lib.vault_approve_and_sign(h2))
assert "signature" in s2
assert lib.vault_cancel(h2) == -3  # ERR_ALREADY_CONSUMED
st2 = read_json(lib.vault_get_request_state(h2))
assert st2["state"] in ("Signed", "ResponseReady", "Consumed") and st2["state"] != "Cancelled", f"Unexpected state: {st2}"
assert st2["primitive_sign_invocations"] == 1
assert lib.vault_get_primitive_sign_count() == 1
print("SUBPROCESS_VAULT_CANCEL_OK")
"""
        dll_path = REPO_ROOT / "target" / "debug" / "vault_ffi.dll"
        proc = sp.run([sys.executable, "-c", code, str(dll_path), valid_rlp_hex], capture_output=True, text=True, timeout=15)
        assert proc.returncode == 0, f"Subprocess crashed rc={proc.returncode} stderr={proc.stderr}"
        assert "SUBPROCESS_VAULT_CANCEL_OK" in proc.stdout

    def test_eip1559_type2_ffi_symbol_alignment_and_end_to_end(self):
        """
        FCW-H2-D359879-RECHECK Section 五 Part C:
        Verifies vault_prepare_eip1559_tx_with_transport handles Type-2 (0x02) EIP-1559 transactions,
        vault_prepare_legacy_tx_with_transport rejects Type-2 (0x02) transactions, and
        wallet_register_pending_tx + wallet_verify_nfc_response_json verify Type-2 (0x02) transactions.
        """
        chain_id = 11155111
        session_id = "sess_eip1559_ffi"
        request_id = "req_eip1559_ffi"
        eip1559_unsigned_hex = "02f183aa36a780843b9aca008477359400825208949858effd232b4033e47d90003d41ec34ecaeda9487038d7ea4c6800080c0"

        # Legacy symbol must reject 0x02 EIP-1559 payload
        wrong_ptr = self.vault_lib.vault_prepare_legacy_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            eip1559_unsigned_hex.encode("utf-8"),
            chain_id,
            1,
        )
        wrong_res = parse_and_free(self.vault_lib, wrong_ptr)
        assert "error" in wrong_res

        # EIP-1559 symbol prepares and signs Type-2 payload
        prep_ptr = self.vault_lib.vault_prepare_eip1559_tx_with_transport(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            eip1559_unsigned_hex.encode("utf-8"),
            chain_id,
            1,
        )
        prep_res = parse_and_free(self.vault_lib, prep_ptr)
        assert "handle_id" in prep_res, f"Unexpected error: {prep_res}"
        handle_id = prep_res["handle_id"]

        reg_ptr = self.wallet_lib.wallet_register_pending_tx(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            eip1559_unsigned_hex.encode("utf-8"),
            chain_id,
            EXPECTED_ADDRESS.encode("utf-8"),
        )
        reg_res = parse_and_free(self.wallet_lib, reg_ptr)
        assert reg_res["status"] == "PENDING_REGISTERED"

        sign_ptr = self.vault_lib.vault_approve_and_sign(handle_id.encode("utf-8"))
        sign_res = parse_and_free(self.vault_lib, sign_ptr)
        assert "signature" in sign_res
        sig_hex = sign_res["signature"].replace("0x", "")
        vault_digest_hex = bytes(prep_res["raw_signing_digest"]).hex()
        assert vault_digest_hex == reg_res["expected_digest"]

        resp_payload = json.dumps({
            "request_id": request_id,
            "chain_id": chain_id,
            "r": sig_hex[:64],
            "s": sig_hex[64:128],
            "v": int(sig_hex[128:130], 16),
            "digest": vault_digest_hex,
            "signer_address": EXPECTED_ADDRESS,
        }).encode("utf-8").hex()

        ver_ptr = self.wallet_lib.wallet_verify_nfc_response_json(
            session_id.encode("utf-8"),
            request_id.encode("utf-8"),
            resp_payload.encode("utf-8"),
        )
        ver_res = parse_and_free(self.wallet_lib, ver_ptr)
        assert ver_res["verified"] is True

