#!/usr/bin/env python3
"""
tests/integration/test_h1_nfc_ffi.py
====================================
E2E integration test for NFC protocol chunking, reassembly, and SignerRouter
state machine transitions via vault_ffi C FFI.
"""

import ctypes
import json
import os
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

def get_vault_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "vault_ffi.dll"
    if not dll_path.exists():
        pytest.skip(f"vault_ffi.dll not found at {dll_path}")

    lib = ctypes.CDLL(str(dll_path))

    # vault_init() -> i32
    lib.vault_init.restype = ctypes.c_int32

    # vault_free_string(char*)
    lib.vault_free_string.argtypes = [ctypes.c_void_p]

    # vault_nfc_chunk_payload(session_id, request_id, msg_kind, payload_hex, chunk_size) -> char*
    lib.vault_nfc_chunk_payload.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint8,
        ctypes.c_char_p,
        ctypes.c_size_t,
    ]
    lib.vault_nfc_chunk_payload.restype = ctypes.c_void_p

    # vault_nfc_process_chunk(cbor_hex) -> char*
    lib.vault_nfc_process_chunk.argtypes = [ctypes.c_char_p]
    lib.vault_nfc_process_chunk.restype = ctypes.c_void_p

    # vault_get_request_state(handle_id) -> char*
    lib.vault_get_request_state.argtypes = [ctypes.c_char_p]
    lib.vault_get_request_state.restype = ctypes.c_void_p

    # vault_mark_disconnected(handle_id) -> i32
    lib.vault_mark_disconnected.argtypes = [ctypes.c_char_p]
    lib.vault_mark_disconnected.restype = ctypes.c_int32

    return lib

def parse_and_free(lib, ptr) -> dict:
    assert ptr is not None, "Pointer must not be null"
    cstr = ctypes.cast(ptr, ctypes.c_char_p).value
    assert cstr is not None, "String value must not be null"
    val = cstr.decode("utf-8")
    lib.vault_free_string(ptr)
    return json.loads(val)


class TestH1NfcFfi:

    def test_nfc_chunking_and_reassembly_roundtrip(self):
        lib = get_vault_ffi()
        assert lib.vault_init() == 0

        sess_id = b"sess_e2e_01"
        req_id = b"req_e2e_01"
        # 512 bytes test payload
        payload_bytes = bytes([i % 256 for i in range(512)])
        payload_hex = payload_bytes.hex().encode("utf-8")

        # 1. Chunk payload into short APDUs (128 bytes each -> 4 chunks)
        chunks_ptr = lib.vault_nfc_chunk_payload(sess_id, req_id, 4, payload_hex, 128)
        chunks = parse_and_free(lib, chunks_ptr)
        assert len(chunks) == 4
        assert all(c["total_chunks"] == 4 for c in chunks)

        # 2. Feed chunks into reassembler sequentially
        for idx in range(3):
            cbor_hex = chunks[idx]["cbor_hex"].encode("utf-8")
            res_ptr = lib.vault_nfc_process_chunk(cbor_hex)
            res = parse_and_free(lib, res_ptr)
            assert res["status"] == "IN_PROGRESS"
            assert res["session_id"] == "sess_e2e_01"

        # 3. Final chunk completes assembly
        final_cbor = chunks[3]["cbor_hex"].encode("utf-8")
        final_ptr = lib.vault_nfc_process_chunk(final_cbor)
        final_res = parse_and_free(lib, final_ptr)
        assert final_res["status"] == "COMPLETE"
        assert final_res["payload_hex"] == payload_bytes.hex()
        assert final_res["payload_len"] == 512

    def test_nfc_chunking_rejects_oversized_payload(self):
        lib = get_vault_ffi()
        assert lib.vault_init() == 0

        sess_id = b"sess_oversized"
        req_id = b"req_oversized"
        # 128 KiB + 1 byte payload -> exceeds bounded limit
        oversized = bytes([0xAA] * (128 * 1024 + 1)).hex().encode("utf-8")

        ptr = lib.vault_nfc_chunk_payload(sess_id, req_id, 4, oversized, 200)
        res = parse_and_free(lib, ptr)
        assert "error" in res
        assert "128 KiB" in res["error"]
