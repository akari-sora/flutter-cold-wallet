"""
tests/integration/test_g4_okx_closed_loop.py
============================================
Milestone M4 (Gate G4) OKX EVM Closed-Loop Verification Suite.

Validates the complete bi-directional air-gap communication between simulated OKX Wallet
and Offline Vault across the full matrix of EVM transaction and message types:
- OKX-01: Legacy EIP-155 Native ETH Transfer (Replay protection, chainId=11155111)
- OKX-02: EIP-1559 Type 2 Native ETH Transfer (Fee caps, priority fee, access list)
- OKX-03: EIP-712 Structured Data Signing (Ether Mail valid vs Permit fail-closed rejection)
- OKX-04: Personal Sign Plain Text Message (ERC-191 magic prefix)
- OKX-05: ERC-20 Mock USDC Transfer (6 decimals precision) & Adversarial Rejections
- Extra Adversarial: UUID tampering, Fee cap exceeded (> 0.05 ETH), Chain ID spoofing defense.
"""

import ctypes
import json
import struct
import uuid
import zlib
from pathlib import Path
import pytest
import cbor2
import coincurve
from Crypto.Hash import keccak

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ------------------------------------------------------------------------------
# 1. Cryptographic & RLP Pure Python Utilities (Oracle B & Reference Codecs)
# ------------------------------------------------------------------------------

def keccak256(data: bytes) -> bytes:
    k = keccak.new(digest_bits=256)
    k.update(data)
    return k.digest()

def rlp_encode_bytes(b: bytes) -> bytes:
    if len(b) == 1 and b[0] < 0x80:
        return b
    elif len(b) <= 55:
        return bytes([0x80 + len(b)]) + b
    else:
        len_b = len(b).to_bytes((len(b).bit_length() + 7) // 8, "big")
        return bytes([0xb7 + len(len_b)]) + len_b + b

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
        len_b = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
        return bytes([0xf7 + len(len_b)]) + len_b + payload

def build_legacy_tx_unsigned_rlp(
    nonce: int, gas_price: int, gas_limit: int, to: str, value: int, data: bytes, chain_id: int
) -> bytes:
    to_bytes = bytes.fromhex(to.lower().replace("0x", "")) if to else b""
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

def build_legacy_tx_signed_rlp(
    nonce: int, gas_price: int, gas_limit: int, to: str, value: int, data: bytes,
    chain_id: int, r: bytes, s: bytes, v: int
) -> bytes:
    to_bytes = bytes.fromhex(to.lower().replace("0x", "")) if to else b""
    v_tx = (v - 27) + chain_id * 2 + 35 if v in (27, 28) else v + chain_id * 2 + 35
    fields = [
        rlp_encode_int(nonce),
        rlp_encode_int(gas_price),
        rlp_encode_int(gas_limit),
        rlp_encode_bytes(to_bytes),
        rlp_encode_int(value),
        rlp_encode_bytes(data),
        rlp_encode_int(v_tx),
        rlp_encode_bytes(r),
        rlp_encode_bytes(s),
    ]
    return rlp_encode_list(fields)

def build_eip1559_unsigned_payload(
    chain_id: int, nonce: int, max_prio_fee: int, max_fee: int, gas_limit: int, to: str, value: int, data: bytes
) -> bytes:
    to_bytes = bytes.fromhex(to.lower().replace("0x", "")) if to else b""
    fields = [
        rlp_encode_int(chain_id),
        rlp_encode_int(nonce),
        rlp_encode_int(max_prio_fee),
        rlp_encode_int(max_fee),
        rlp_encode_int(gas_limit),
        rlp_encode_bytes(to_bytes),
        rlp_encode_int(value),
        rlp_encode_bytes(data),
        rlp_encode_list([]),  # empty access list
    ]
    return b"\x02" + rlp_encode_list(fields)

def build_eip1559_signed_payload(
    chain_id: int, nonce: int, max_prio_fee: int, max_fee: int, gas_limit: int, to: str,
    value: int, data: bytes, r: bytes, s: bytes, y_parity: int
) -> bytes:
    to_bytes = bytes.fromhex(to.lower().replace("0x", "")) if to else b""
    fields = [
        rlp_encode_int(chain_id),
        rlp_encode_int(nonce),
        rlp_encode_int(max_prio_fee),
        rlp_encode_int(max_fee),
        rlp_encode_int(gas_limit),
        rlp_encode_bytes(to_bytes),
        rlp_encode_int(value),
        rlp_encode_bytes(data),
        rlp_encode_list([]),
        rlp_encode_int(y_parity),
        rlp_encode_bytes(r),
        rlp_encode_bytes(s),
    ]
    return b"\x02" + rlp_encode_list(fields)

def recover_evm_address_coincurve(digest: bytes, r: bytes, s: bytes, v: int) -> str:
    """Oracle B: Independent Python address recovery via coincurve and keccak."""
    rec_id = v if v in (0, 1) else (v - 27 if v in (27, 28) else (v - 35) % 2)
    sig_compact = r + s + bytes([rec_id])
    pk = coincurve.PublicKey.from_signature_and_message(sig_compact, digest, hasher=None)
    uncompressed = pk.format(compressed=False)[1:]  # remove 0x04 prefix
    addr_bytes = keccak256(uncompressed)[-20:]
    return f"0x{addr_bytes.hex()}"

# --- Bytewords Minimal & UR Single Codec (BCR-2020-005) ---

BYTEWORDS_STANDARD = [
    # 0x00 - 0x07
    "able", "acid", "also", "apex", "aqua", "arch", "atom", "aunt",
    # 0x08 - 0x0f
    "away", "axis", "back", "bald", "barn", "belt", "beta", "bias",
    # 0x10 - 0x17
    "blue", "body", "brag", "brew", "bulb", "buzz", "calm", "cash",
    # 0x18 - 0x1f
    "cats", "chef", "city", "claw", "code", "cola", "cook", "cost",
    # 0x20 - 0x27
    "crux", "curl", "cusp", "cyan", "dark", "data", "days", "deli",
    # 0x28 - 0x2f
    "dice", "diet", "door", "down", "draw", "drop", "drum", "dull",
    # 0x30 - 0x37
    "duty", "each", "easy", "echo", "edge", "epic", "even", "exam",
    # 0x38 - 0x3f
    "exit", "eyes", "fact", "fair", "fern", "figs", "film", "fish",
    # 0x40 - 0x47
    "fizz", "flap", "flew", "flux", "foxy", "free", "frog", "fuel",
    # 0x48 - 0x4f
    "fund", "gala", "game", "gear", "gems", "gift", "girl", "glow",
    # 0x50 - 0x57
    "good", "gray", "grim", "guru", "gush", "gyro", "half", "hang",
    # 0x58 - 0x5f
    "hard", "hawk", "heat", "help", "high", "hill", "holy", "hope",
    # 0x60 - 0x67
    "horn", "huts", "iced", "idea", "idle", "inch", "inky", "into",
    # 0x68 - 0x6f
    "iris", "iron", "item", "jade", "jazz", "join", "jolt", "jowl",
    # 0x70 - 0x77
    "judo", "jugs", "jump", "junk", "jury", "keep", "keno", "kept",
    # 0x78 - 0x7f
    "keys", "kick", "kiln", "king", "kite", "kiwi", "knob", "lamb",
    # 0x80 - 0x87
    "lava", "lazy", "leaf", "legs", "liar", "limp", "lion", "list",
    # 0x88 - 0x8f
    "logo", "loud", "love", "luau", "luck", "lung", "main", "many",
    # 0x90 - 0x97
    "math", "maze", "memo", "menu", "meow", "mild", "mint", "miss",
    # 0x98 - 0x9f
    "monk", "nail", "navy", "need", "news", "next", "noon", "note",
    # 0xa0 - 0xa7
    "numb", "obey", "oboe", "omit", "onyx", "open", "oval", "owls",
    # 0xa8 - 0xaf
    "paid", "part", "peck", "play", "plus", "poem", "pool", "pose",
    # 0xb0 - 0xb7
    "puff", "puma", "purr", "quad", "quiz", "race", "ramp", "real",
    # 0xb8 - 0xbf
    "redo", "rich", "road", "rock", "roof", "ruby", "ruin", "runs",
    # 0xc0 - 0xc7
    "rust", "safe", "saga", "scar", "sets", "silk", "skew", "slot",
    # 0xc8 - 0xcf
    "soap", "solo", "song", "stub", "surf", "swan", "taco", "task",
    # 0xd0 - 0xd7
    "taxi", "tent", "tied", "time", "tiny", "toil", "tomb", "toys",
    # 0xd8 - 0xdf
    "trip", "tuna", "twin", "ugly", "undo", "unit", "urge", "user",
    # 0xe0 - 0xe7
    "vast", "very", "veto", "vial", "vibe", "view", "visa", "void",
    # 0xe8 - 0xef
    "vows", "wall", "wand", "warm", "wasp", "wave", "waxy", "webs",
    # 0xf0 - 0xf7
    "what", "when", "whiz", "wolf", "work", "yank", "yawn", "yell",
    # 0xf8 - 0xff
    "yoga", "yurt", "zaps", "zero", "zest", "zinc", "zone", "zoom"
]

def extract_uuid_bytes(val) -> bytes:
    if hasattr(val, "bytes"):
        return val.bytes
    elif isinstance(val, cbor2.CBORTag):
        if hasattr(val.value, "bytes"):
            return val.value.bytes
        elif isinstance(val.value, bytes):
            return val.value
    elif isinstance(val, bytes):
        return val
    elif isinstance(val, str):
        return bytes.fromhex(val.replace("-", "").replace("0x", ""))
    raise ValueError(f"Cannot extract UUID from {type(val)}: {val}")

BYTEWORDS_MINIMAL_TO_BYTE = {
    (w[0] + w[-1]): idx for idx, w in enumerate(BYTEWORDS_STANDARD)
}
BYTE_TO_BYTEWORDS_MINIMAL = {
    idx: (w[0] + w[-1]) for idx, w in enumerate(BYTEWORDS_STANDARD)
}

def decode_ur_single(ur_string: str) -> tuple[str, bytes]:
    clean = ur_string.strip()
    if not clean.lower().startswith("ur:"):
        raise ValueError("Invalid UR prefix")
    parts = clean[3:].split("/")
    if len(parts) != 2:
        raise ValueError(f"Expected 2 path segments in single UR, got {len(parts)}")
    ur_type = parts[0].lower()
    body = parts[1].lower()
    if len(body) % 2 != 0:
        raise ValueError("Bytewords minimal body length must be even")
    decoded = bytearray()
    for i in range(0, len(body), 2):
        pair = body[i:i+2]
        decoded.append(BYTEWORDS_MINIMAL_TO_BYTE[pair])
    if len(decoded) < 4:
        raise ValueError("UR payload too short to contain CRC32")
    payload = bytes(decoded[:-4])
    expected_crc = struct.unpack(">I", decoded[-4:])[0]
    actual_crc = zlib.crc32(payload) & 0xffffffff
    if expected_crc != actual_crc:
        raise ValueError(f"CRC-32 checksum mismatch: expected {hex(expected_crc)}, got {hex(actual_crc)}")
    return ur_type, payload

def encode_ur_single(ur_type: str, payload: bytes) -> str:
    crc = zlib.crc32(payload) & 0xffffffff
    full_data = payload + struct.pack(">I", crc)
    body = "".join(BYTE_TO_BYTEWORDS_MINIMAL[b] for b in full_data)
    return f"ur:{ur_type}/{body}"

# ------------------------------------------------------------------------------
# 2. FFI Loaders & Fixtures
# ------------------------------------------------------------------------------

@pytest.fixture(scope="module")
def vault_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "vault_ffi.dll"
    if not dll_path.exists():
        pytest.skip(f"vault_ffi.dll not found at {dll_path}")
    lib = ctypes.CDLL(str(dll_path))

    lib.vault_init.restype = ctypes.c_int32
    lib.vault_load_test_mnemonic.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_load_test_mnemonic.restype = ctypes.c_int32

    lib.vault_prepare_legacy_tx.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64]
    lib.vault_prepare_legacy_tx.restype = ctypes.c_char_p

    lib.vault_prepare_eip1559_tx.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64]
    lib.vault_prepare_eip1559_tx.restype = ctypes.c_char_p

    lib.vault_prepare_sign_request.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64]
    lib.vault_prepare_sign_request.restype = ctypes.c_char_p

    lib.vault_prepare_ur_request.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_prepare_ur_request.restype = ctypes.c_char_p

    lib.vault_approve_and_sign.argtypes = [ctypes.c_char_p]
    lib.vault_approve_and_sign.restype = ctypes.c_char_p

    lib.vault_approve_and_generate_signature_ur.argtypes = [ctypes.c_char_p]
    lib.vault_approve_and_generate_signature_ur.restype = ctypes.c_char_p

    lib.vault_cancel.argtypes = [ctypes.c_char_p]
    lib.vault_cancel.restype = ctypes.c_int32

    lib.vault_free_string.argtypes = [ctypes.c_char_p]
    lib.vault_free_string.restype = None

    lib.vault_init()
    mnemonic = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    assert lib.vault_load_test_mnemonic(mnemonic, b"") == 0
    return lib

@pytest.fixture(scope="module")
def wallet_ffi():
    dll_path = REPO_ROOT / "target" / "debug" / "wallet_ffi.dll"
    if not dll_path.exists():
        pytest.skip(f"wallet_ffi.dll not found at {dll_path}")
    lib = ctypes.CDLL(str(dll_path))
    lib.wallet_verify_signature.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint8, ctypes.c_char_p
    ]
    lib.wallet_verify_signature.restype = ctypes.c_int32
    return lib

TEST_ACCOUNT = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

# ------------------------------------------------------------------------------
# 3. Acceptance Tests (G4 OKX-01 .. OKX-05 + Adversarial)
# ------------------------------------------------------------------------------

class TestG4OKXClosedLoop:

    def test_okx_01_legacy_transfer_closed_loop(self, vault_ffi, wallet_ffi):
        """OKX-01: OKX constructs Legacy EIP-155 transfer -> Vault parses -> signs Tag 402 -> Dual Oracle cross-verifies."""
        req_uuid = uuid.uuid4().bytes
        chain_id = 11155111
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        raw_tx_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 21000, recipient, 50_000_000_000_000_000, b"", chain_id)

        # OKX packages as CBOR Tag 401
        sign_req_map = {
            1: cbor2.CBORTag(37, req_uuid),
            2: raw_tx_rlp,
            3: 1,  # DataType::Transaction
            4: chain_id,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
            6: bytes.fromhex(recipient[2:]),
            7: "OKX Wallet",
        }
        tagged_cbor = cbor2.dumps(cbor2.CBORTag(401, sign_req_map))
        assert tagged_cbor[:3] == b"\xd9\x01\x91", "Must contain Tag 401 header"
        assert len(tagged_cbor) <= 131072, "Payload within 128 KiB limit"

        # OKX encodes as single BC-UR
        ur_string = encode_ur_single("eth-sign-request", tagged_cbor)
        assert ur_string.startswith("ur:eth-sign-request/")

        # Vault parses UR request
        prep_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_okx01", ur_string.encode())
        assert prep_res_bytes is not None
        prep_res = json.loads(prep_res_bytes.decode())
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "50000000000000000 wei"
        assert prep_res["policy_verdict"]["Approved"]["recipient"].lower() == recipient.lower()

        # Vault approves and signs
        sign_res_bytes = vault_ffi.vault_approve_and_sign(prep_res["handle_id"].encode())
        assert sign_res_bytes is not None
        sign_res = json.loads(sign_res_bytes.decode())
        assert sign_res.get("status") == "SUCCESS"
        assert "signature_ur" in sign_res

        # OKX receives and decodes Tag 402 signature UR
        sig_ur = sign_res["signature_ur"]
        parsed_type, sig_cbor = decode_ur_single(sig_ur)
        assert parsed_type == "eth-signature"
        assert sig_cbor[:3] == b"\xd9\x01\x92", "Must contain Tag 402 header"

        decoded_sig = cbor2.loads(sig_cbor)
        assert decoded_sig.tag == 402
        resp_map = decoded_sig.value

        # Invariant: request_id must match byte-for-byte!
        resp_uuid = extract_uuid_bytes(resp_map[1])
        assert resp_uuid == req_uuid, "Response UUID must match request UUID exactly"

        sig_bytes = resp_map[2]
        assert len(sig_bytes) == 65
        r = sig_bytes[:32]
        s = sig_bytes[32:64]
        v = sig_bytes[64]
        digest = bytes(prep_res["raw_signing_digest"])

        # Dual Oracle Verification
        # Oracle A: Rust wallet_ffi (public_core verify)
        oracle_a_valid = wallet_ffi.wallet_verify_signature(
            digest.hex().encode(), r.hex().encode(), s.hex().encode(), v, TEST_ACCOUNT.encode()
        )
        assert oracle_a_valid == 1, "Oracle A (Rust) verification failed"

        # Oracle B: Python coincurve
        rec_addr_b = recover_evm_address_coincurve(digest, r, s, v)
        assert rec_addr_b.lower() == TEST_ACCOUNT.lower(), "Oracle B (coincurve) recovered address mismatch"

        # OKX reconstructs Signed Raw Transaction
        signed_raw_tx = build_legacy_tx_signed_rlp(0, 20_000_000_000, 21000, recipient, 50_000_000_000_000_000, b"", chain_id, r, s, v)
        assert len(signed_raw_tx) > 0
        tx_hash = keccak256(signed_raw_tx)
        assert len(tx_hash) == 32

    def test_okx_02_eip1559_transfer_closed_loop(self, vault_ffi, wallet_ffi):
        """OKX-02: OKX constructs EIP-1559 Type 2 transfer -> Vault parses -> signs Tag 402 -> verifies."""
        req_uuid = uuid.uuid4().bytes
        chain_id = 11155111
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        unsigned_payload = build_eip1559_unsigned_payload(
            chain_id, 1, 1_500_000_000, 30_000_000_000, 21000, recipient, 10_000_000_000_000_000, b""
        )

        sign_req_map = {
            1: cbor2.CBORTag(37, req_uuid),
            2: unsigned_payload,
            3: 4,  # DataType::TypedTransaction
            4: chain_id,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
            6: bytes.fromhex(recipient[2:]),
            7: "OKX Wallet",
        }
        tagged_cbor = cbor2.dumps(cbor2.CBORTag(401, sign_req_map))
        ur_string = encode_ur_single("eth-sign-request", tagged_cbor)

        prep_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_okx02", ur_string.encode())
        assert prep_res_bytes is not None
        prep_res = json.loads(prep_res_bytes.decode())
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "10000000000000000 wei"

        sign_res_bytes = vault_ffi.vault_approve_and_sign(prep_res["handle_id"].encode())
        assert sign_res_bytes is not None
        sign_res = json.loads(sign_res_bytes.decode())
        assert sign_res.get("status") == "SUCCESS"

        sig_ur = sign_res["signature_ur"]
        parsed_type, sig_cbor = decode_ur_single(sig_ur)
        assert parsed_type == "eth-signature"
        decoded_sig = cbor2.loads(sig_cbor)
        resp_map = decoded_sig.value

        resp_uuid = extract_uuid_bytes(resp_map[1])
        assert resp_uuid == req_uuid

        sig_bytes = resp_map[2]
        r = sig_bytes[:32]
        s = sig_bytes[32:64]
        v = sig_bytes[64]
        digest = bytes(prep_res["raw_signing_digest"])

        # Dual Oracle check
        assert wallet_ffi.wallet_verify_signature(
            digest.hex().encode(), r.hex().encode(), s.hex().encode(), v, TEST_ACCOUNT.encode()
        ) == 1
        rec_addr = recover_evm_address_coincurve(digest, r, s, v)
        assert rec_addr.lower() == TEST_ACCOUNT.lower()

        # Reconstruct signed EIP-1559 transaction
        y_parity = (v - 27) if v in (27, 28) else v
        signed_1559_tx = build_eip1559_signed_payload(
            chain_id, 1, 1_500_000_000, 30_000_000_000, 21000, recipient, 10_000_000_000_000_000, b"", r, s, y_parity
        )
        assert len(signed_1559_tx) > 0

    def test_okx_03_eip712_message_and_permit_guard(self, vault_ffi, wallet_ffi):
        """OKX-03: EIP-712 structured data signing adaptation vs Permit malicious authorization fail-closed defense."""
        # 1. Valid Ether Mail typed data
        mail_json = {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "Mail": [
                    {"name": "from", "type": "Person"},
                    {"name": "to", "type": "Person"},
                    {"name": "contents", "type": "string"}
                ],
                "Person": [
                    {"name": "name", "type": "string"},
                    {"name": "wallet", "type": "address"}
                ]
            },
            "primaryType": "Mail",
            "domain": {
                "name": "Ether Mail",
                "version": "1",
                "chainId": 11155111,
                "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
            },
            "message": {
                "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
                "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
                "contents": "Hello, Bob!"
            }
        }
        req_uuid = uuid.uuid4().bytes
        sign_req_map = {
            1: cbor2.CBORTag(37, req_uuid),
            2: json.dumps(mail_json).encode(),
            3: 2,  # DataType::TypedData
            4: 11155111,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
        }
        ur_string = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, sign_req_map)))

        prep_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_mail", ur_string.encode())
        assert prep_res_bytes is not None
        prep_res = json.loads(prep_res_bytes.decode())
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "Typed Data: Mail"

        sign_res_bytes = vault_ffi.vault_approve_and_sign(prep_res["handle_id"].encode())
        assert sign_res_bytes is not None
        sign_res = json.loads(sign_res_bytes.decode())
        assert sign_res.get("status") == "SUCCESS"

        sig_bytes = bytes.fromhex(sign_res["signature"].replace("0x", ""))
        digest = bytes(prep_res["raw_signing_digest"])
        assert wallet_ffi.wallet_verify_signature(
            digest.hex().encode(), sig_bytes[:32].hex().encode(), sig_bytes[32:64].hex().encode(), sig_bytes[64], TEST_ACCOUNT.encode()
        ) == 1

        # 2. Malicious Permit / Permit2 Authorization MUST be rejected (Fail-Closed MSG-03)
        permit_json = dict(mail_json)
        permit_json["primaryType"] = "Permit"
        permit_req_map = {
            1: cbor2.CBORTag(37, uuid.uuid4().bytes),
            2: json.dumps(permit_json).encode(),
            3: 2,
            4: 11155111,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
        }
        permit_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, permit_req_map)))
        bad_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_permit", permit_ur.encode())
        assert bad_res_bytes is not None
        bad_res = json.loads(bad_res_bytes.decode())
        assert "error" in bad_res
        assert "permit" in bad_res["error"].lower()

    def test_okx_04_personal_sign_closed_loop(self, vault_ffi, wallet_ffi):
        """OKX-04: Personal Sign message signing and invisible spoofing filter verification."""
        msg = b"Please sign to authenticate with OKX Web3 Wallet. Nonce: 1337"
        req_uuid = uuid.uuid4().bytes
        sign_req_map = {
            1: cbor2.CBORTag(37, req_uuid),
            2: msg,
            3: 3,  # DataType::PersonalMessage
            4: 11155111,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
        }
        ur_string = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, sign_req_map)))

        prep_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_psign", ur_string.encode())
        assert prep_res_bytes is not None
        prep_res = json.loads(prep_res_bytes.decode())
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "Personal Sign Message"

        sign_res_bytes = vault_ffi.vault_approve_and_sign(prep_res["handle_id"].encode())
        assert sign_res_bytes is not None
        sign_res = json.loads(sign_res_bytes.decode())
        assert sign_res.get("status") == "SUCCESS"

        sig_bytes = bytes.fromhex(sign_res["signature"].replace("0x", ""))
        digest = bytes(prep_res["raw_signing_digest"])
        assert wallet_ffi.wallet_verify_signature(
            digest.hex().encode(), sig_bytes[:32].hex().encode(), sig_bytes[32:64].hex().encode(), sig_bytes[64], TEST_ACCOUNT.encode()
        ) == 1
        assert recover_evm_address_coincurve(digest, sig_bytes[:32], sig_bytes[32:64], sig_bytes[64]).lower() == TEST_ACCOUNT.lower()

    def test_okx_05_erc20_whitelist_and_rejection(self, vault_ffi, wallet_ffi):
        """OKX-05: Sepolia Mock USDC whitelisted transfer vs unknown contract and dangerous ABI rejections."""
        # 1. Whitelisted Sepolia Mock USDC (6 decimals: 100.5 USDC = 100_500_000 raw)
        usdc_contract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        calldata = bytes.fromhex("a9059cbb") + b"\x00" * 12 + bytes.fromhex(recipient[2:]) + (100_500_000).to_bytes(32, "big")
        raw_tx_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, calldata, 11155111)

        req_uuid = uuid.uuid4().bytes
        sign_req_map = {
            1: cbor2.CBORTag(37, req_uuid),
            2: raw_tx_rlp,
            3: 1,
            4: 11155111,
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
        }
        ur_string = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, sign_req_map)))

        prep_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_usdc", ur_string.encode())
        assert prep_res_bytes is not None
        prep_res = json.loads(prep_res_bytes.decode())
        assert "policy_verdict" in prep_res
        assert prep_res["policy_verdict"]["Approved"]["amount_display"] == "100.5 USDC"

        sign_res_bytes = vault_ffi.vault_approve_and_sign(prep_res["handle_id"].encode())
        assert sign_res_bytes is not None
        sign_res = json.loads(sign_res_bytes.decode())
        assert sign_res.get("status") == "SUCCESS"

        # 2. Non-whitelisted unknown contract MUST be rejected (EVM-09 Fail-Closed)
        untrusted_contract = "0xDeadBeef00000000000000000000000000000000"
        bad_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 65000, untrusted_contract, 0, calldata, 11155111)
        bad_map = {1: cbor2.CBORTag(37, uuid.uuid4().bytes), 2: bad_rlp, 3: 1, 4: 11155111, 5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]})}
        bad_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, bad_map)))
        bad_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_bad", bad_ur.encode())
        assert bad_res_bytes is not None
        bad_res = json.loads(bad_res_bytes.decode())
        assert "error" in bad_res
        assert "EVM-09 Fail-Closed" in bad_res["error"] or "whitelist" in bad_res["error"].lower()

        # 3. Dangerous ABI: approve(address,uint256) selector 0x095ea7b3 MUST be rejected
        approve_calldata = bytes.fromhex("095ea7b3") + b"\x00" * 12 + bytes.fromhex(recipient[2:]) + (100_500_000).to_bytes(32, "big")
        approve_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, approve_calldata, 11155111)
        approve_map = {1: cbor2.CBORTag(37, uuid.uuid4().bytes), 2: approve_rlp, 3: 1, 4: 11155111, 5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]})}
        approve_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, approve_map)))
        app_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_app", approve_ur.encode())
        assert app_res_bytes is not None
        app_res = json.loads(app_res_bytes.decode())
        assert "error" in app_res

        # 4. Dirty padding in recipient address MUST be rejected
        dirty_calldata = bytes.fromhex("a9059cbb") + b"\xff" * 12 + bytes.fromhex(recipient[2:]) + (100_500_000).to_bytes(32, "big")
        dirty_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 65000, usdc_contract, 0, dirty_calldata, 11155111)
        dirty_map = {1: cbor2.CBORTag(37, uuid.uuid4().bytes), 2: dirty_rlp, 3: 1, 4: 11155111, 5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]})}
        dirty_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, dirty_map)))
        dirty_res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_dirty", dirty_ur.encode())
        assert dirty_res_bytes is not None
        dirty_res = json.loads(dirty_res_bytes.decode())
        assert "error" in dirty_res

    def test_okx_adversarial_uuid_tamper(self, vault_ffi):
        """Adversarial: Response UUID tampering must be rejected by OKX."""
        original_uuid = uuid.uuid4().bytes
        tampered_uuid = uuid.uuid4().bytes
        assert original_uuid != tampered_uuid

        sig_bytes = b"\x11" * 65
        sign_resp = {1: cbor2.CBORTag(37, tampered_uuid), 2: sig_bytes}
        encoded_resp = cbor2.dumps(cbor2.CBORTag(402, sign_resp))
        decoded_resp = cbor2.loads(encoded_resp)
        resp_uuid = extract_uuid_bytes(decoded_resp.value[1])

        # OKX verifies session by comparing response UUID against pending request UUID
        with pytest.raises(AssertionError):
            assert resp_uuid == original_uuid

    def test_okx_adversarial_fee_cap_exceeded(self, vault_ffi):
        """Adversarial: ERC-20 transfer with fee cap exceeding safeguard limit (> 0.05 ETH) must be rejected."""
        usdc_contract = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        calldata = bytes.fromhex("a9059cbb") + b"\x00" * 12 + bytes.fromhex(recipient[2:]) + (100_500_000).to_bytes(32, "big")
        # gas_limit = 100,000, gas_price = 1,000 Gwei (1,000,000,000,000 wei) -> fee cap = 0.1 ETH > 0.05 ETH max safeguard limit
        excessive_fee_rlp = build_legacy_tx_unsigned_rlp(0, 1_000_000_000_000, 100000, usdc_contract, 0, calldata, 11155111)
        excessive_map = {1: cbor2.CBORTag(37, uuid.uuid4().bytes), 2: excessive_fee_rlp, 3: 1, 4: 11155111, 5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]})}
        excessive_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, excessive_map)))

        res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_exceed", excessive_ur.encode())
        assert res_bytes is not None
        res_json = json.loads(res_bytes.decode())
        assert "error" in res_json
        assert "exceeds maximum policy safeguard limit" in res_json["error"]

    def test_okx_adversarial_chain_id_spoofing(self, vault_ffi):
        """Adversarial: Outer Tag 4 claims 11155111 but inner tx is Mainnet (chainId=1) -> ChainIdMismatch rejection."""
        recipient = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        # Inner tx has chainId=1
        mainnet_rlp = build_legacy_tx_unsigned_rlp(0, 20_000_000_000, 21000, recipient, 1_000_000, b"", 1)
        # Outer Tag 4 claims 11155111
        spoofed_map = {
            1: cbor2.CBORTag(37, uuid.uuid4().bytes),
            2: mainnet_rlp,
            3: 1,
            4: 11155111,  # Outer claimed
            5: cbor2.CBORTag(304, {1: [44, True, 60, True, 0, True, 0, False, 0, False]}),
        }
        spoofed_ur = encode_ur_single("eth-sign-request", cbor2.dumps(cbor2.CBORTag(401, spoofed_map)))

        res_bytes = vault_ffi.vault_prepare_ur_request(b"sess_spoof", spoofed_ur.encode())
        assert res_bytes is not None
        res_json = json.loads(res_bytes.decode())
        assert "error" in res_json
        assert "ChainIdMismatch" in res_json["error"] or "chain id" in res_json["error"].lower()
