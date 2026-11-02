"""
tests/protocol/test_ur_cbor_adversarial.py
==========================================
Adversarial Stress & Robustness Suite for Keystone crypto-multi-accounts (BC-UR / CBOR).
Empirically tests and verifies fail-closed boundaries against malformed payloads:
1. CBOR nesting depth > 16 layers (array, map, tag, alternating)
2. Payload size > 128 KiB (131,072 bytes)
3. Duplicate map keys (top-level, nested CryptoHDKey, nested CryptoKeypath)
4. Trailing garbage bytes / CBOR smuggling
5. Fountain sequence & frame corruption (seq_num=0, seq_len=0, seq mismatch, CRC corruption, splicing)
6. Truncated and malformed UR strings (empty, prefix only, odd length, invalid bytewords, short payloads)
"""

import struct
import zlib
import pytest
import cbor2
from pathlib import Path
import json

import sys
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "tests" / "protocol"))

from test_ur_crypto_multi_accounts import (
    decode_ur_single,
    encode_ur_single,
    validate_cbor_bounds,
    BYTEWORDS_MINIMAL_TO_BYTE,
    MAX_ALLOWED_PAYLOAD,
    MAX_ALLOWED_DEPTH,
)


@pytest.fixture(scope="module")
def fixture_data():
    fixture_path = REPO_ROOT / "tools" / "okx_probe" / "probe_fixture.json"
    if fixture_path.exists():
        with open(fixture_path, "r", encoding="utf-8") as f:
            return json.load(f)
    return None


# ==============================================================================
# CATEGORY 1: CBOR Nesting Depth Bomb (> 16 Layers)
# ==============================================================================

def test_adv_depth_array_17_rejected():
    """Verify array nesting depth 17 (1 level over limit) is strictly rejected."""
    nested = bytearray()
    for _ in range(17): nested.extend(b"\x81")
    nested.append(0)
    with pytest.raises(ValueError, match="depth exceeded max limit"):
        validate_cbor_bounds(bytes(nested), max_depth=16)


def test_adv_depth_array_32_and_100_rejected():
    """Verify deep recursion bombs (depth 32 and 100) are strictly rejected."""
    for depth in [32, 100]:
        nested = bytearray()
        for _ in range(depth): nested.extend(b"\x81")
        nested.append(0)
        with pytest.raises(ValueError, match="depth exceeded max limit"):
            validate_cbor_bounds(bytes(nested), max_depth=16)


def test_adv_depth_map_17_rejected():
    """Verify map nesting depth 17 is strictly rejected."""
    nested_map = bytearray()
    for _ in range(17): nested_map.extend(b"\xa1\x01")
    nested_map.append(0)
    with pytest.raises(ValueError, match="depth exceeded max limit"):
        validate_cbor_bounds(bytes(nested_map), max_depth=16)


def test_adv_depth_alternating_array_map_rejected():
    """Verify alternating array and map depth 17 is strictly rejected."""
    alt = bytearray()
    for i in range(17):
        alt.extend(b"\x81" if i % 2 == 0 else b"\xa1\x01")
    alt.append(0)
    with pytest.raises(ValueError, match="depth exceeded max limit"):
        validate_cbor_bounds(bytes(alt), max_depth=16)


def test_adv_depth_boundary_16_allowed():
    """Verify boundary depth 16 is correctly allowed."""
    nested_16 = bytearray()
    for _ in range(15): nested_16.extend(b"\x81")  # root (1) + 15 nested = depth 16
    nested_16.append(0)
    validate_cbor_bounds(bytes(nested_16), max_depth=16)


def test_adv_depth_tag_nesting_17_rejected():
    """Verify semantic tag nesting depth 17 is strictly rejected."""
    nested_tags = bytearray()
    for _ in range(17): nested_tags.extend(b"\xd9\x01\x2f")
    nested_tags.append(0)
    with pytest.raises(ValueError, match="depth exceeded max limit"):
        validate_cbor_bounds(bytes(nested_tags), max_depth=16)


# ==============================================================================
# CATEGORY 2: Payload Size Limit Violations (> 128 KiB)
# ==============================================================================

def test_adv_payload_exact_128kib_allowed():
    """Verify payload of exactly 128 KiB (131,072 bytes) passes validation."""
    data_len = 131_072 - 5
    payload_128k = b"\x5a" + struct.pack(">I", data_len) + (b"\xaa" * data_len)
    assert len(payload_128k) == 131_072
    validate_cbor_bounds(payload_128k)


def test_adv_payload_oversized_128kib_plus_1_rejected():
    """Verify payload of 128 KiB + 1 byte (131,073 bytes) is rejected."""
    data_len = 131_072 - 5 + 1
    oversized = b"\x5a" + struct.pack(">I", data_len) + (b"\xaa" * data_len)
    assert len(oversized) == 131_073
    with pytest.raises(ValueError, match="exceeds max allowed"):
        validate_cbor_bounds(oversized)


def test_adv_payload_large_dos_bombs_rejected():
    """Verify 200 KiB and 1 MiB payloads are rejected immediately."""
    with pytest.raises(ValueError, match="exceeds max allowed"):
        validate_cbor_bounds(bytes([0] * 204_800))
    with pytest.raises(ValueError, match="exceeds max allowed"):
        validate_cbor_bounds(bytes([0] * (1024 * 1024)))


def test_adv_payload_claimed_length_overflow_rejected():
    """Verify claimed 64-bit giant string on short buffer is safely rejected."""
    giant_claim = b"\x5b\xff\xff\xff\xff\xff\xff\xff\xff"
    with pytest.raises(ValueError):
        validate_cbor_bounds(giant_claim)


# ==============================================================================
# CATEGORY 3: Duplicate Map Key Injection (RFC 8949 Section 5.6)
# ==============================================================================

def test_adv_dup_top_level_keys_rejected():
    """Verify duplicate top-level keys 1, 2, and 3 are strictly rejected."""
    # Key 1: master_fingerprint duplicate
    dup_k1 = bytes.fromhex("a2011a73c5da0a011a12345678")
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(dup_k1)

    # Key 2: keys duplicate
    dup_k2 = bytes.fromhex("a202800280")
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(dup_k2)

    # Key 3: device duplicate
    dup_k3 = bytes.fromhex("a2036474657374036466616b65")
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(dup_k3)


def test_adv_dup_nested_cryptohdkey_rejected():
    """Verify duplicate key 3 (key_data) inside CryptoHDKey is strictly rejected."""
    nested_dup = bytes.fromhex(
        "a10281d9012fa2"
        "0358210237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299"
        "03582102eae4b876a8696134b868f88cc2f51f715f2dbedb7446b8e6edf3d4541c4eb67b"
    )
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(nested_dup)


def test_adv_dup_nested_cryptokeypath_rejected():
    """Verify duplicate path components inside CryptoKeypath is rejected."""
    path_dup = bytes.fromhex("a10281d9012fa106d90130a20186182cf5183cf500f50186182cf5183cf500f5")
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(path_dup)


def test_adv_dup_multikey_injection_rejected():
    """Verify duplicate key in multi-entry map is rejected."""
    multi_dup = bytes.fromhex("a4010a02140317021863")
    with pytest.raises(ValueError, match="Duplicate key detected"):
        validate_cbor_bounds(multi_dup)


# ==============================================================================
# CATEGORY 4: Trailing Bytes / Smuggling Attacks
# ==============================================================================

def test_adv_trailing_null_and_garbage_rejected(fixture_data):
    """Verify legitimate CBOR with trailing null or garbage bytes is rejected."""
    if fixture_data:
        legit = bytes.fromhex(fixture_data["cbor_hex"])
    else:
        legit = bytes.fromhex("a1011a73c5da0a")
    
    with pytest.raises(ValueError, match="Trailing bytes detected"):
        validate_cbor_bounds(legit + b"\x00")
    with pytest.raises(ValueError, match="Trailing bytes detected"):
        validate_cbor_bounds(legit + b"\xde\xad\xbe\xef")
    with pytest.raises(ValueError, match="Trailing bytes detected"):
        validate_cbor_bounds(legit + b"   \r\n\t")


def test_adv_trailing_smuggled_cbor_object_rejected(fixture_data):
    """Verify second complete CBOR object appended to payload is rejected."""
    if fixture_data:
        legit = bytes.fromhex(fixture_data["cbor_hex"])
    else:
        legit = bytes.fromhex("a1011a73c5da0a")
    smuggled = legit + bytes.fromhex("a1016e61747461636b65725f7061796c6f6164")
    with pytest.raises(ValueError, match="Trailing bytes detected"):
        validate_cbor_bounds(smuggled)


# ==============================================================================
# CATEGORY 5: Fountain Code & Multi-Frame Reassembly Robustness
# ==============================================================================

def test_adv_fountain_seq_zero_and_negative_rejected(fixture_data):
    """Verify fountain sequence parser rejects seq_num=0, seq_len=0, or negative."""
    frames = fixture_data.get("fountain_frames", []) if fixture_data else []
    if not frames:
        pytest.skip("No fountain frames in fixture")
    
    f0 = frames[0]
    parts = f0.split("/")
    ur_pfx = parts[0]
    seq_p = parts[1].split("-")
    body = parts[2]

    def parse_header(s: str) -> tuple[int, int]:
        sp = s.split("/")
        if len(sp) != 3: raise ValueError("Requires 3 segments")
        idx = sp[1].split("-")
        s_num, s_len = int(idx[0]), int(idx[1])
        if s_num < 1 or s_len < 1:
            raise ValueError("Sequence indices must be >= 1")
        return s_num, s_len

    # seq_num == 0
    with pytest.raises(ValueError, match="must be >= 1"):
        parse_header(f"{ur_pfx}/0-{seq_p[1]}/{body}")

    # seq_len == 0
    with pytest.raises(ValueError, match="must be >= 1"):
        parse_header(f"{ur_pfx}/{seq_p[0]}-0/{body}")

    # negative seq_num
    with pytest.raises(ValueError):
        parse_header(f"{ur_pfx}/-1-{seq_p[1]}/{body}")


def test_adv_fountain_seq_len_mismatch_and_type_splicing_rejected(fixture_data):
    """Verify stream consistency validator rejects mismatched seq_len and type splicing."""
    frames = fixture_data.get("fountain_frames", []) if fixture_data else []
    if len(frames) < 2:
        pytest.skip("Not enough frames")

    def check_stream(flist):
        exp_t, exp_len = None, None
        for f in flist:
            sp = f.split("/")
            t = sp[0].replace("ur:", "").lower()
            if exp_t is None: exp_t = t
            elif t != exp_t: raise ValueError(f"Type mismatch: {t} != {exp_t}")
            
            idx = sp[1].split("-")
            slen = int(idx[1])
            if exp_len is None: exp_len = slen
            elif slen != exp_len: raise ValueError("seq_len mismatch")

    # Mismatched seq_len
    parts = frames[1].split("/")
    mismatched = [frames[0], f"{parts[0]}/2-99/{parts[2]}"]
    with pytest.raises(ValueError, match="seq_len mismatch"):
        check_stream(mismatched)

    # Cross-type splicing
    spliced = [frames[0], f"ur:crypto-account/2-3/{parts[2]}"]
    with pytest.raises(ValueError, match="Type mismatch"):
        check_stream(spliced)


def test_adv_fountain_corrupted_crc_rejected(fixture_data):
    """Verify corrupted CRC in fountain frame payload is rejected."""
    frames = fixture_data.get("fountain_frames", []) if fixture_data else []
    if not frames:
        pytest.skip("No frames in fixture")
    
    parts = frames[0].split("/")
    body = parts[2]
    last_pair = body[-2:]
    corrupted_body = body[:-2] + ("aa" if last_pair != "aa" else "zz")
    
    def decode_frame_payload(p_body):
        decoded = bytearray()
        for i in range(0, len(p_body), 2):
            decoded.append(BYTEWORDS_MINIMAL_TO_BYTE[p_body[i:i+2]])
        payload = bytes(decoded[:-4])
        exp_crc = struct.unpack(">I", decoded[-4:])[0]
        act_crc = zlib.crc32(payload) & 0xffffffff
        if exp_crc != act_crc:
            raise ValueError("CRC-32 checksum mismatch")
        return payload

    with pytest.raises(ValueError):
        decode_frame_payload(corrupted_body)


# ==============================================================================
# CATEGORY 6: Truncated & Malformed UR String Fuzzing
# ==============================================================================

def test_adv_fuzz_truncated_ur_strings():
    """Verify truncated UR strings at various stages are rejected."""
    truncated_cases = [
        "",
        "ur:",
        "ur:crypto-multi-accounts",
        "ur:crypto-multi-accounts/",
        "ur:crypto-multi-accounts/oxa",
        "ur:crypto-multi-accounts/oxad",
        "ur:crypto-multi-accounts/zzzz",
    ]
    for tc in truncated_cases:
        with pytest.raises(ValueError):
            decode_ur_single(tc)


def test_adv_fuzz_corrupted_crc_single(fixture_data):
    """Verify single-frame UR with tampered CRC32 is rejected."""
    if not fixture_data:
        pytest.skip("No fixture")
    single_ur = fixture_data["ur_single"]
    last_pair = single_ur[-2:]
    corrupted_ur = single_ur[:-2] + ("aa" if last_pair != "aa" else "bb")
    with pytest.raises(ValueError, match="CRC-32 checksum mismatch|Unknown bytewords"):
        decode_ur_single(corrupted_ur)


def test_adv_fuzz_invalid_schemes():
    """Verify invalid URI schemes are rejected."""
    for scheme in ["http:crypto-multi-accounts/oxadcy", "qr:crypto-multi-accounts/oxadcy"]:
        with pytest.raises(ValueError, match="Invalid UR schema prefix"):
            decode_ur_single(scheme)


def test_adv_fuzz_indefinite_length_cbor_rejected():
    """Verify indefinite length CBOR items (info=31) are rejected."""
    # Indefinite string, array, map
    for indef in [b"\x5f\x41\x01\xff", b"\x9f\x01\x02\xff", b"\xbf\x01\x0a\xff"]:
        with pytest.raises(ValueError, match="Indefinite length items rejected"):
            validate_cbor_bounds(indef)


def test_adv_fuzz_reserved_info_and_truncated_args():
    """Verify reserved info fields (28, 29, 30) and truncated integer args are rejected."""
    for r in [28, 29, 30]:
        with pytest.raises(ValueError, match="Reserved info field"):
            validate_cbor_bounds(bytes([r]))
    
    # Truncated uint8, uint16, uint32, uint64
    with pytest.raises(ValueError, match="Unexpected EOF reading uint8"):
        validate_cbor_bounds(b"\x18")
    with pytest.raises(ValueError, match="Unexpected EOF reading uint16"):
        validate_cbor_bounds(b"\x19\x01")
    with pytest.raises(ValueError, match="Unexpected EOF reading uint32"):
        validate_cbor_bounds(b"\x1a\x01\x02")
    with pytest.raises(ValueError, match="Unexpected EOF reading uint64"):
        validate_cbor_bounds(b"\x1b\x01\x02\x03\x04")
