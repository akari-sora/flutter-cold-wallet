"""Host FFI contracts for the QR-first Wallet/Vault protocol.

Evidence level: native DLLs in one Python host process. The HTTP server below is
an explicitly controlled JSON-RPC contract stub. It does not execute transactions,
validate a chain, mine blocks, or prove broadcast/confirmation in either App.

Real Anvil node coverage lives in test_qr_real_node.py; Bitcoin Core regtest
coverage lives in test_qr_bitcoin_regtest.py. Those independent tests replace the
old fixture-only BTC case. No camera, device authentication, Flutter UI, iOS, or
stock OKX interoperability result is inferred from this host suite.
"""

import ctypes
import http.server
import json
import os
import socketserver
import tempfile
import threading
import urllib.request
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _load_dll(name: str) -> ctypes.CDLL:
    release_path = REPO_ROOT / "target" / "release" / name
    debug_path = REPO_ROOT / "target" / "debug" / name
    override = os.environ.get(name.removesuffix(".dll").upper() + "_PATH")
    target = Path(override) if override else (release_path if release_path.exists() else debug_path)
    assert target.exists(), f"Build the production native library before running host contracts: {target}"
    return ctypes.CDLL(str(target))


def get_vault_ffi() -> ctypes.CDLL:
    lib = _load_dll("vault_ffi.dll")
    lib.vault_init.restype = ctypes.c_int32
    lib.vault_lock.restype = ctypes.c_int32
    lib.vault_generate_mnemonic_json.argtypes = [ctypes.c_uint32]
    lib.vault_generate_mnemonic_json.restype = ctypes.c_void_p
    lib.vault_preview_mnemonic_json.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_preview_mnemonic_json.restype = ctypes.c_void_p
    lib.vault_activate_and_save_mnemonic_json.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
    ]
    lib.vault_activate_and_save_mnemonic_json.restype = ctypes.c_void_p
    lib.vault_check_storage_status_json.argtypes = [ctypes.c_char_p]
    lib.vault_check_storage_status_json.restype = ctypes.c_void_p
    lib.vault_unlock_from_storage_json.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_unlock_from_storage_json.restype = ctypes.c_void_p
    lib.vault_export_multi_accounts_json.argtypes = [ctypes.c_uint32]
    lib.vault_export_multi_accounts_json.restype = ctypes.c_void_p
    lib.vault_export_encrypted_backup_json.argtypes = [ctypes.c_char_p]
    lib.vault_export_encrypted_backup_json.restype = ctypes.c_void_p
    lib.vault_restore_from_encrypted_backup_json.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
    ]
    lib.vault_restore_from_encrypted_backup_json.restype = ctypes.c_void_p
    lib.vault_prepare_ur_request.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_prepare_ur_request.restype = ctypes.c_void_p
    lib.vault_approve_and_sign.argtypes = [ctypes.c_char_p]
    lib.vault_approve_and_sign.restype = ctypes.c_void_p
    lib.vault_preview_encrypted_backup_json.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.vault_preview_encrypted_backup_json.restype = ctypes.c_void_p
    lib.vault_free_string.argtypes = [ctypes.c_void_p]
    lib.vault_free_string.restype = None
    return lib


def get_wallet_ffi() -> ctypes.CDLL:
    lib = _load_dll("wallet_ffi.dll")
    lib.wallet_init.restype = ctypes.c_int32
    lib.wallet_verify_pubkey_address.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.wallet_verify_pubkey_address.restype = ctypes.c_int32
    lib.wallet_decode_and_verify_multi_accounts_ur.argtypes = [
        ctypes.c_char_p,
        ctypes.c_uint64,
    ]
    lib.wallet_decode_and_verify_multi_accounts_ur.restype = ctypes.c_void_p
    lib.wallet_build_eth_sign_request_ur.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_uint32,
    ]
    lib.wallet_build_eth_sign_request_ur.restype = ctypes.c_void_p
    lib.wallet_verify_and_assemble_eth_signature_ur.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
    ]
    lib.wallet_verify_and_assemble_eth_signature_ur.restype = ctypes.c_void_p
    lib.wallet_free_string.argtypes = [ctypes.c_void_p]
    lib.wallet_free_string.restype = None
    return lib


def _read_vault_json(lib: ctypes.CDLL, ptr: int) -> dict:
    assert ptr, "Vault FFI returned null pointer"
    try:
        raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
        return json.loads(raw)
    finally:
        lib.vault_free_string(ptr)


def _read_wallet_json(lib: ctypes.CDLL, ptr: int) -> dict:
    assert ptr, "Wallet FFI returned null pointer"
    try:
        raw = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
        return json.loads(raw)
    finally:
        lib.wallet_free_string(ptr)


class TestHostQrFfiContracts:
    """Native onboarding, encrypted restore and cryptographic QR contracts only."""

    @pytest.mark.parametrize("passphrase", [b"", b"isolated-BIP39-passphrase-2026"])
    def test_onboarding_backup_restore_and_public_pairing(self, passphrase):
        vault = get_vault_ffi()
        wallet = get_wallet_ffi()
        vault.vault_init()
        vault.vault_lock()
        wallet.wallet_init()

        with tempfile.TemporaryDirectory() as tmpdir:
            storage_path = str(Path(tmpdir) / "vault_protected_envelope.json").encode("utf-8")

            # 1. Empty initial state
            st0 = _read_vault_json(vault, vault.vault_check_storage_status_json(storage_path))
            assert st0["status"] == "EMPTY"
            assert st0["initialized"] is False

            # 2. Generate 12-word and 24-word mnemonics via OS CSPRNG
            gen12 = _read_vault_json(vault, vault.vault_generate_mnemonic_json(12))
            assert gen12["status"] == "SUCCESS"
            assert len(gen12["mnemonic"].split()) == 12

            gen24 = _read_vault_json(vault, vault.vault_generate_mnemonic_json(24))
            assert gen24["status"] == "SUCCESS"
            assert len(gen24["mnemonic"].split()) == 24

            # Synthetic vault generated solely for this test, through production CSPRNG API.
            phrase = gen12["mnemonic"].encode("utf-8")
            preview = _read_vault_json(vault, vault.vault_preview_mnemonic_json(phrase, passphrase))
            alternate = _read_vault_json(vault, vault.vault_preview_mnemonic_json(phrase, passphrase + b"-different"))
            assert preview["status"] == alternate["status"] == "SUCCESS"
            assert preview["evm_account_0"]["address"] != alternate["evm_account_0"]["address"]
            expected_fp = preview["master_fingerprint"]
            expected_address = preview["evm_account_0"]["address"]
            act = _read_vault_json(
                vault,
                vault.vault_activate_and_save_mnemonic_json(
                    phrase, passphrase, storage_path, b"isolated-vault-password-8899"
                ),
            )
            assert act["status"] == "SUCCESS"
            assert act["master_fingerprint"] == expected_fp

            # 4. Export multi-accounts with small fragment length to exercise fountain frames
            exp = _read_vault_json(vault, vault.vault_export_multi_accounts_json(45))
            assert exp["status"] == "SUCCESS"
            multi = exp["multi_accounts"]
            fountain_frames_json = json.dumps(multi["fountain_frames"]).encode("utf-8")
            assert len(multi["fountain_frames"]) > 1

            # 5. Wallet decodes fountain frames and cryptographically verifies pubkeys & addresses
            paired = _read_wallet_json(
                wallet,
                wallet.wallet_decode_and_verify_multi_accounts_ur(fountain_frames_json, 11155111),
            )
            assert paired["status"] == "SUCCESS"
            assert paired["master_fingerprint"] == expected_fp
            assert len(paired["evm_accounts"]) >= 2
            acc0 = paired["evm_accounts"][0]
            assert acc0["address"].lower() == expected_address.lower()
            assert (
                wallet.wallet_verify_pubkey_address(
                    acc0["compressed_pubkey_hex"].encode("utf-8"),
                    acc0["address"].encode("utf-8"),
                )
                == 1
            )

            # Backup export rejects weak passwords and succeeds with >=12 nonnumeric characters
            short_bk = _read_vault_json(vault, vault.vault_export_encrypted_backup_json(b"1234"))
            assert short_bk["status"] == "ERROR"

            good_bk = _read_vault_json(
                vault, vault.vault_export_encrypted_backup_json(b"StrongBackupPass#2026")
            )
            assert good_bk["status"] == "SUCCESS"
            backup_json = good_bk["backup_json"].encode("utf-8")

            # 7. Lock, fail on wrong PIN, unlock on right PIN
            vault.vault_lock()
            bad_unlock = _read_vault_json(
                vault, vault.vault_unlock_from_storage_json(storage_path, b"wrong-strong-password-2026")
            )
            assert bad_unlock["status"] == "ERROR"
            assert bad_unlock["error_code"] == "ERR_AUTH_FAILED"

            ok_unlock = _read_vault_json(
                vault, vault.vault_unlock_from_storage_json(storage_path, b"isolated-vault-password-8899")
            )
            assert ok_unlock["status"] == "UNLOCKED"
            assert ok_unlock["master_fingerprint"] == expected_fp
            vault.vault_lock()
            restored_path = str(Path(tmpdir) / "restored_envelope.json").encode("utf-8")
            restored_preview = _read_vault_json(vault, vault.vault_preview_encrypted_backup_json(backup_json, b"StrongBackupPass#2026"))
            assert restored_preview["status"] == "SUCCESS"
            assert restored_preview["master_fingerprint"] == expected_fp
            assert restored_preview["multi_accounts"]["evm_accounts"][0]["address"] == expected_address
            assert not Path(restored_path.decode()).exists()
            assert _read_vault_json(vault, vault.vault_export_multi_accounts_json(120))["status"] == "ERROR"
            wrong_backup = _read_vault_json(vault, vault.vault_preview_encrypted_backup_json(backup_json, b"WrongBackupPass#2026"))
            assert wrong_backup["status"] == "ERROR"
            restored = _read_vault_json(vault, vault.vault_restore_from_encrypted_backup_json(backup_json, b"StrongBackupPass#2026", restored_path, b"new-local-password-2026"))
            assert restored["status"] == "RESTORED"
            assert restored["multi_accounts"]["evm_accounts"][0]["address"] == expected_address
            assert restored["has_passphrase_hint"] == bool(passphrase)
            vault.vault_lock()
            # All corruption/overwrite checks operate on this newly created temp vault.
            original = Path(restored_path.decode()).read_bytes()
            overwrite = _read_vault_json(vault, vault.vault_restore_from_encrypted_backup_json(backup_json, b"StrongBackupPass#2026", restored_path, b"another-password-2026"))
            assert overwrite["status"] == "ERROR"
            assert Path(restored_path.decode()).read_bytes() == original
            Path(storage_path.decode()).write_text("{corrupt-test-envelope", encoding="utf-8")
            corrupt = _read_vault_json(vault, vault.vault_check_storage_status_json(storage_path))
            assert corrupt["status"] == "STORAGE_CORRUPTED"

    def test_legacy_qr_signature_assembly_and_http_rpc_contract_stub(self):
        """Cryptographic assembly plus stub HTTP serialization; no chain acceptance evidence."""
        vault = get_vault_ffi()
        wallet = get_wallet_ffi()
        vault.vault_init()
        wallet.wallet_init()

        with tempfile.TemporaryDirectory() as tmpdir:
            storage_path = str(Path(tmpdir) / "vault_env.json").encode("utf-8")
            generated = _read_vault_json(vault, vault.vault_generate_mnemonic_json(12))
            assert generated["status"] == "SUCCESS"
            activated = _read_vault_json(vault, vault.vault_activate_and_save_mnemonic_json(generated["mnemonic"].encode("utf-8"), b"", storage_path, b"isolated-signing-password-2026"))
            assert activated["status"] == "SUCCESS"
            acc0_addr = activated["multi_accounts"]["evm_accounts"][0]["address"].encode("utf-8")
            master_fp = activated["master_fingerprint"].encode("utf-8")

            # Fixed unsigned Legacy RLP is a protocol test vector, never a product default.
            # RLP fields are predetermined fixture data; this host test does not estimate fees/nonce.
            legacy_rlp_hex = b"ef808504a817c800825208949858effd232b4033e47d90003d41ec34ecaeda9488016345785d8a00008083aa36a78080"
            req_id_1 = b"00112233445566778899aabbccddeeff"

            built_legacy = _read_wallet_json(
                wallet,
                wallet.wallet_build_eth_sign_request_ur(
                    b"sess-e2e-1",
                    req_id_1,
                    legacy_rlp_hex,
                    11155111,
                    b"m/44'/60'/0'/0/0",
                    master_fp,
                    acc0_addr,
                    60,
                ),
            )
            assert built_legacy["status"] == "PENDING_REGISTERED"
            ur_frames_1 = json.dumps(built_legacy["fountain_frames"]).encode("utf-8")

            # Vault scans UR fountain frames and prepares review
            prep_1 = _read_vault_json(
                vault, vault.vault_prepare_ur_request(b"sess-e2e-1", ur_frames_1)
            )
            assert "error" not in prep_1
            handle_1 = prep_1["handle_id"].encode("utf-8")

            # Vault approves and signs -> returns eth-signature UR frames
            sig_1 = _read_vault_json(vault, vault.vault_approve_and_sign(handle_1))
            assert sig_1["status"] == "SUCCESS"
            sig_frames_1 = json.dumps(sig_1["signature_ur_frames"]).encode("utf-8")

            # Mismatched request_id is rejected; this does not stand in for wrong-signer or replay coverage.
            wrong_req = _read_wallet_json(
                wallet,
                wallet.wallet_verify_and_assemble_eth_signature_ur(
                    b"sess-e2e-1", b"ffffffffffffffffffffffffffffffff", sig_frames_1
                ),
            )
            assert wrong_req["verified"] is False
            assert wrong_req["error_code"] == "ERR_UNKNOWN_REQUEST_ID"

            # Positive check: matching request_id verifies ECDSA recovery and assembles signed raw tx
            assembled_1 = _read_wallet_json(
                wallet,
                wallet.wallet_verify_and_assemble_eth_signature_ur(
                    b"sess-e2e-1", req_id_1, sig_frames_1
                ),
            )
            assert assembled_1["verified"] is True
            assert assembled_1["status"] == "SIGNED_TX_READY"
            assert assembled_1["signed_raw_tx_hex"].startswith("0x")
            assert assembled_1["local_tx_hash"].startswith("0x")
            assert len(assembled_1["local_tx_hash"]) == 66

            # HTTP RPC contract stub: responses are deliberately fabricated, with no chain execution.
            stub_received_txs = []

            class RpcContractStubHandler(http.server.BaseHTTPRequestHandler):
                def log_message(self, format, *args):
                    pass

                def do_POST(self):
                    length = int(self.headers.get("Content-Length", 0))
                    body = json.loads(self.rfile.read(length).decode("utf-8"))
                    method = body.get("method")
                    req_id = body.get("id", 1)
                    if method == "eth_chainId":
                        resp = {"jsonrpc": "2.0", "id": req_id, "result": hex(11155111)}
                    elif method == "eth_sendRawTransaction":
                        raw_tx = body["params"][0]
                        stub_received_txs.append(raw_tx)
                        resp = {"jsonrpc": "2.0", "id": req_id, "result": assembled_1["local_tx_hash"]}
                    elif method == "eth_getTransactionReceipt":
                        resp = {
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "result": {
                                "transactionHash": assembled_1["local_tx_hash"],
                                "status": "0x1",
                                "blockNumber": "0x10",
                            },
                        }
                    else:
                        resp = {
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "error": {"code": -32601, "message": "Method not found"},
                        }
                    out = json.dumps(resp).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(out)))
                    self.end_headers()
                    self.wfile.write(out)

            with socketserver.TCPServer(("127.0.0.1", 0), RpcContractStubHandler) as httpd:
                port = httpd.server_address[1]
                server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
                server_thread.start()

                rpc_url = f"http://127.0.0.1:{port}"

                def rpc_call(method, params):
                    req = urllib.request.Request(
                        rpc_url,
                        data=json.dumps(
                            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
                        ).encode("utf-8"),
                        headers={"Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(req, timeout=5) as r:
                        return json.loads(r.read().decode("utf-8"))

                cid_res = rpc_call("eth_chainId", [])
                assert int(cid_res["result"], 16) == 11155111

                send_res = rpc_call("eth_sendRawTransaction", [assembled_1["signed_raw_tx_hex"]])
                assert send_res["result"] == assembled_1["local_tx_hash"]
                assert stub_received_txs == [assembled_1["signed_raw_tx_hex"]]

                stub_receipt = rpc_call("eth_getTransactionReceipt", [assembled_1["local_tx_hash"]])
                assert stub_receipt["result"]["status"] == "0x1"  # Scripted value, not a mined receipt.
                stub_error = rpc_call("unsupported_stub_method", [])
                assert "result" not in stub_error
                assert stub_error["error"]["code"] == -32601
                httpd.shutdown()
                server_thread.join(timeout=5)
                assert not server_thread.is_alive()
            vault.vault_lock()
