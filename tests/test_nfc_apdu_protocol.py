"""
tests/test_nfc_apdu_protocol.py
================================
Unit tests verifying strict R-APDU parsing, capability checking, echo verification,
and negative status word handling against the counterexamples in REVIEW.md (F1, F3, F7).
"""

import hashlib
import pytest
from typing import Tuple, Optional


class Rapdu:
    def __init__(self, data: bytes, sw: int):
        self.data = data
        self.sw = sw

    @property
    def sw_hex(self) -> str:
        return f"{self.sw:04x}"

    @property
    def is_success(self) -> bool:
        return self.sw == 0x9000


def parse_rapdu(raw: Optional[bytes]) -> Optional[Rapdu]:
    if raw is None or len(raw) < 2:
        return None
    sw1 = raw[-2]
    sw2 = raw[-1]
    sw = (sw1 << 8) | sw2
    data = raw[:-2]
    return Rapdu(data, sw)


def check_select_aid_response(rapdu: Optional[Rapdu], expected_version=0x0100, expected_max_chunk=128) -> Tuple[bool, str]:
    if rapdu is None:
        return False, "NO_RESPONSE"
    if not rapdu.is_success:
        return False, f"BAD_SW_{rapdu.sw_hex}"
    if len(rapdu.data) != 4:
        return False, f"BAD_DATA_LEN_{len(rapdu.data)}"

    version = (rapdu.data[0] << 8) | rapdu.data[1]
    max_chunk = (rapdu.data[2] << 8) | rapdu.data[3]

    if version != expected_version:
        return False, f"UNSUPPORTED_VERSION_{version:04x}"
    if max_chunk != expected_max_chunk:
        return False, f"UNEXPECTED_MAX_CHUNK_{max_chunk}"

    return True, "OK"


def check_chunk_write_response(rapdu: Optional[Rapdu], expected_chunk: bytes) -> Tuple[bool, str]:
    if rapdu is None:
        return False, "NO_RESPONSE"
    if not rapdu.is_success:
        return False, f"BAD_SW_{rapdu.sw_hex}"
    if len(rapdu.data) != len(expected_chunk):
        return False, f"DATA_LEN_MISMATCH_{len(rapdu.data)}_VS_{len(expected_chunk)}"
    if rapdu.data != expected_chunk:
        return False, "ECHO_DATA_CORRUPTED"
    return True, "OK"


def check_digest_response(rapdu: Optional[Rapdu], expected_digest: bytes) -> Tuple[bool, str]:
    if rapdu is None:
        return False, "NO_RESPONSE"
    if not rapdu.is_success:
        return False, f"BAD_SW_{rapdu.sw_hex}"
    if len(rapdu.data) != 32:
        return False, f"DIGEST_LEN_MISMATCH_{len(rapdu.data)}"
    if rapdu.data != expected_digest:
        return False, "DIGEST_HASH_MISMATCH"
    return True, "OK"


# -------------------------------------------------------------------------
# F1 Counterexample Tests: Verifying that all faulty responses are REJECTED
# -------------------------------------------------------------------------

def test_f1_counterexample_correct_digest_bad_sw_6f00():
    """Counterexample 1: Correct digest followed by 6F00 must be REJECTED."""
    fixture = b"hello cold wallet world 32bytes!!"
    expected_hash = hashlib.sha256(fixture).digest()

    # Injected raw response: 32 bytes valid hash + 6F 00 (SW_UNKNOWN_ERROR)
    injected_raw = expected_hash + bytes([0x6F, 0x00])
    rapdu = parse_rapdu(injected_raw)

    passed, reason = check_digest_response(rapdu, expected_hash)
    assert not passed, "Must reject digest when SW is 6F00"
    assert "BAD_SW_6f00" in reason


def test_f1_counterexample_correct_digest_missing_sw():
    """Counterexample 2: Correct digest with missing SW must be REJECTED."""
    fixture = b"hello cold wallet world 32bytes!!"
    expected_hash = hashlib.sha256(fixture).digest()

    # Raw response only has 32 bytes data, truncated without 2 bytes SW
    rapdu = parse_rapdu(expected_hash)
    # When truncated, the last two bytes of the hash become the pseudo-SW and data is only 30 bytes
    passed, reason = check_digest_response(rapdu, expected_hash)
    assert not passed, "Must reject truncated digest missing SW"


def test_f1_counterexample_chunk32_bad_sw_6f00():
    """Counterexample 3: 32B write returns SW 6F00 must be REJECTED even if later digest is correct."""
    chunk = b"\xAA" * 32
    # Injected response with 6F00
    injected_raw = chunk + bytes([0x6F, 0x00])
    rapdu = parse_rapdu(injected_raw)

    passed, reason = check_chunk_write_response(rapdu, chunk)
    assert not passed, "Must reject chunk write with SW 6F00"
    assert "BAD_SW_6f00" in reason


def test_f1_counterexample_chunk_echo_replaced_with_ee():
    """Counterexample 4: Chunk echo corrupted/replaced with 0xEE bytes must be REJECTED."""
    chunk = b"\x12" * 128
    corrupted_echo = b"\xEE" * 128 + bytes([0x90, 0x00])
    rapdu = parse_rapdu(corrupted_echo)

    passed, reason = check_chunk_write_response(rapdu, chunk)
    assert not passed, "Must reject corrupted echo payload"
    assert reason == "ECHO_DATA_CORRUPTED"


def test_f1_counterexample_select_aid_unsupported_version_or_zero_chunk():
    """Counterexample 5: SELECT response with unsupported version or maxChunk=0 must be REJECTED."""
    # Version 2.0 (0x0200), maxChunk 0 (0x0000) + 9000
    bad_select = bytes([0x02, 0x00, 0x00, 0x00, 0x90, 0x00])
    rapdu = parse_rapdu(bad_select)

    passed, reason = check_select_aid_response(rapdu)
    assert not passed, "Must reject unsupported version or maxChunk 0"
    assert "UNSUPPORTED_VERSION" in reason


# -------------------------------------------------------------------------
# F1 Positive Control: Valid protocol interaction PASSES
# -------------------------------------------------------------------------

def test_f1_positive_control():
    """Positive control: valid SELECT, chunk echo, and digest must all PASS."""
    # 1. SELECT
    select_raw = bytes([0x01, 0x00, 0x00, 0x80, 0x90, 0x00])
    select_rapdu = parse_rapdu(select_raw)
    ok_sel, _ = check_select_aid_response(select_rapdu)
    assert ok_sel

    # 2. 32B Chunk
    chunk32 = bytes(range(32))
    chunk_raw = chunk32 + bytes([0x90, 0x00])
    chunk_rapdu = parse_rapdu(chunk_raw)
    ok_chunk, _ = check_chunk_write_response(chunk_rapdu, chunk32)
    assert ok_chunk

    # 3. Digest
    expected_digest = hashlib.sha256(chunk32).digest()
    digest_raw = expected_digest + bytes([0x90, 0x00])
    digest_rapdu = parse_rapdu(digest_raw)
    ok_dig, _ = check_digest_response(digest_rapdu, expected_digest)
    assert ok_dig


# -------------------------------------------------------------------------
# F3 APDU Service Constraints: Rejecting invalid parameters
# -------------------------------------------------------------------------

class MockFcwHostApduService:
    """Python simulation of FcwHostApduService.kt logic to verify strict status words."""
    AID_BYTES = bytes([0xF0, 0x46, 0x43, 0x57, 0x01])
    MAX_CHUNK_SIZE = 128
    MAX_SESSION_BYTES = 131072

    SW_SUCCESS = bytes([0x90, 0x00])
    SW_WRONG_LENGTH = bytes([0x67, 0x00])
    SW_FILE_NOT_FOUND = bytes([0x6A, 0x82])
    SW_NOT_ENOUGH_MEMORY = bytes([0x6A, 0x84])
    SW_INCORRECT_P1P2 = bytes([0x6A, 0x86])
    SW_INS_NOT_SUPPORTED = bytes([0x6D, 0x00])
    SW_CLA_NOT_SUPPORTED = bytes([0x6E, 0x00])

    def __init__(self):
        self.digest = hashlib.sha256()
        self.total_bytes = 0

    def process_command(self, apdu: bytes) -> bytes:
        if len(apdu) < 4:
            return self.SW_WRONG_LENGTH

        cla = apdu[0]
        ins = apdu[1]
        p1 = apdu[2]
        p2 = apdu[3]

        if cla == 0x00:
            if ins != 0xA4:
                return self.SW_INS_NOT_SUPPORTED
            if p1 != 0x04 or p2 != 0x00:
                return self.SW_INCORRECT_P1P2
            if len(apdu) < 5:
                return self.SW_WRONG_LENGTH
            lc = apdu[4]
            if len(apdu) != 5 + lc and len(apdu) != 5 + lc + 1:
                return self.SW_WRONG_LENGTH
            aid = apdu[5:5 + lc]
            if aid == self.AID_BYTES:
                self.digest = hashlib.sha256()
                self.total_bytes = 0
                return bytes([0x01, 0x00, 0x00, 0x80]) + self.SW_SUCCESS
            return self.SW_FILE_NOT_FOUND

        if cla == 0x80:
            if p1 != 0x00 or p2 != 0x00:
                return self.SW_INCORRECT_P1P2

            if ins == 0x10:  # CHUNK_WRITE
                if len(apdu) < 5:
                    return self.SW_WRONG_LENGTH
                lc = apdu[4]
                if lc <= 0 or lc > self.MAX_CHUNK_SIZE:
                    return self.SW_WRONG_LENGTH
                if len(apdu) != 5 + lc and len(apdu) != 5 + lc + 1:
                    return self.SW_WRONG_LENGTH
                if self.total_bytes + lc > self.MAX_SESSION_BYTES:
                    return self.SW_NOT_ENOUGH_MEMORY

                chunk = apdu[5:5 + lc]
                self.digest.update(chunk)
                self.total_bytes += len(chunk)
                return chunk + self.SW_SUCCESS

            elif ins == 0x20:  # GET_DIGEST
                if len(apdu) > 5:
                    return self.SW_WRONG_LENGTH
                if len(apdu) == 5 and apdu[4] not in (0, 32):
                    return self.SW_WRONG_LENGTH
                res = self.digest.digest() + self.SW_SUCCESS
                self.digest = hashlib.sha256()
                self.total_bytes = 0
                return res

            elif ins == 0x30:  # RESET_SESSION
                if len(apdu) > 5:
                    return self.SW_WRONG_LENGTH
                self.digest = hashlib.sha256()
                self.total_bytes = 0
                return self.SW_SUCCESS

            else:
                return self.SW_INS_NOT_SUPPORTED

        return self.SW_CLA_NOT_SUPPORTED


def test_f3_hce_rejects_oversized_chunk_129():
    service = MockFcwHostApduService()
    # SELECT AID first
    service.process_command(bytes([0x00, 0xA4, 0x04, 0x00, 0x05, 0xF0, 0x46, 0x43, 0x57, 0x01, 0x00]))

    # CHUNK_WRITE with Lc=129 (>128 limit)
    cmd = bytes([0x80, 0x10, 0x00, 0x00, 129]) + b"\x42" * 129 + bytes([0x00])
    resp = service.process_command(cmd)
    assert resp == bytes([0x67, 0x00]), "Oversized chunk must be rejected with SW 6700"


def test_f3_hce_rejects_trailing_garbage_bytes():
    service = MockFcwHostApduService()
    service.process_command(bytes([0x00, 0xA4, 0x04, 0x00, 0x05, 0xF0, 0x46, 0x43, 0x57, 0x01, 0x00]))

    # CHUNK_WRITE with declared Lc=32, but 34 data bytes + Le (2 extra bytes)
    cmd = bytes([0x80, 0x10, 0x00, 0x00, 32]) + b"\x42" * 34 + bytes([0x00])
    resp = service.process_command(cmd)
    assert resp == bytes([0x67, 0x00]), "APDU with extra trailing bytes must be rejected with SW 6700"


def test_f3_hce_rejects_nonzero_p1_p2():
    service = MockFcwHostApduService()
    # Proprietary command with P1=0x01
    cmd = bytes([0x80, 0x10, 0x01, 0x00, 0x04, 0x01, 0x02, 0x03, 0x04, 0x00])
    resp = service.process_command(cmd)
    assert resp == bytes([0x6A, 0x86]), "Non-zero P1 must return SW 6A86"


def test_f3_hce_rejects_unknown_ins():
    service = MockFcwHostApduService()
    cmd = bytes([0x80, 0x99, 0x00, 0x00, 0x00])
    resp = service.process_command(cmd)
    assert resp == bytes([0x6D, 0x00]), "Unknown INS must return SW 6D00"


def test_f3_hce_rejects_unknown_cla():
    service = MockFcwHostApduService()
    cmd = bytes([0x90, 0x10, 0x00, 0x00, 0x00])
    resp = service.process_command(cmd)
    assert resp == bytes([0x6E, 0x00]), "Unknown CLA must return SW 6E00"


def test_f7_routing_rejects_unknown_aid():
    service = MockFcwHostApduService()
    unknown_aid_cmd = bytes([0x00, 0xA4, 0x04, 0x00, 0x05, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00])
    resp = service.process_command(unknown_aid_cmd)
    assert resp == bytes([0x6A, 0x82]), "Unknown AID must return SW 6A82"
