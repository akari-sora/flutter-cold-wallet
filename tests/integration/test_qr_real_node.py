"""Host FFI + real isolated Anvil evidence, never a substitute for camera/UI tests.

Run after `cargo build --release -p vault_ffi -p wallet_ffi` and
`forge build --root tests/fixtures/local_token`. All funds and keys are test-only.
No mnemonic, password, backup ciphertext, or private key is written to evidence.
"""
import ctypes
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.request
import uuid

import pytest
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
TOKEN = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
CHAIN = 11155111  # Anvil local chain with Sepolia policy, no public RPC connection.
PASSWORD = b"isolated-test-vault-2026"


def rlp(value):
    if isinstance(value, int):
        value = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if isinstance(value, list):
        payload = b"".join(rlp(item) for item in value)
        base = 0xC0
    else:
        payload = value
        if len(payload) == 1 and payload[0] < 0x80:
            return payload
        base = 0x80
    if len(payload) <= 55:
        return bytes([base + len(payload)]) + payload
    size = len(payload).to_bytes((len(payload).bit_length() + 7) // 8, "big")
    return bytes([base + 55 + len(size)]) + size + payload


class Native:
    def __init__(self, name):
        path = Path(os.environ.get(name.upper() + "_PATH", ROOT / "target" / "release" / (name + ".dll")))
        assert path.exists(), f"Required native build missing: {path}"
        self.lib = ctypes.CDLL(str(path))
        self.prefix = name.split("_")[0]
        self.free = getattr(self.lib, self.prefix + "_free_string")
        self.free.argtypes = [ctypes.c_void_p]
        self.free.restype = None

    def call(self, method, *args):
        fn = getattr(self.lib, self.prefix + "_" + method)
        fn.argtypes = [ctypes.c_uint64 if isinstance(a, int) else ctypes.c_char_p for a in args]
        fn.restype = ctypes.c_void_p
        ptr = fn(*[a.encode() if isinstance(a, str) else a for a in args])
        assert ptr, method + " returned null"
        try:
            return json.loads(ctypes.string_at(ptr))
        finally:
            self.free(ptr)

    def init(self):
        assert getattr(self.lib, self.prefix + "_init")() == 0


@pytest.fixture
def anvil():
    exe = shutil.which("anvil")
    assert exe, "Real Anvil executable is required, no mock fallback"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    process = subprocess.Popen(
        [exe, "--host", "127.0.0.1", "--port", str(port), "--chain-id", str(CHAIN), "--silent"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    url = f"http://127.0.0.1:{port}"

    def rpc(method, params=()):
        req = urllib.request.Request(url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(str(result["error"]))
        return result["result"]

    try:
        for _ in range(100):
            try:
                assert int(rpc("eth_chainId"), 16) == CHAIN
                break
            except (OSError, AssertionError):
                assert process.poll() is None, "Anvil exited before startup"
                time.sleep(0.1)
        else:
            pytest.fail("Anvil startup timed out")
        yield rpc
    finally:
        process.terminate()
        process.wait(timeout=10)


def exchange(vault, wallet, account, raw, request_id=None):
    request_id = request_id or uuid.uuid4().hex
    session = "real-node-" + uuid.uuid4().hex
    built = wallet.call("build_eth_sign_request_ur", session, request_id, raw.hex(), CHAIN,
                        account["derivation_path"], account["master_fingerprint"], account["address"], 60)
    assert built["status"] == "PENDING_REGISTERED", built
    prepared = vault.call("prepare_ur_request", session, json.dumps(built["fountain_frames"]))
    assert "error" not in prepared, prepared
    signed = vault.call("approve_and_sign", prepared["handle_id"])
    assert signed["status"] == "SUCCESS", signed
    response = json.dumps(signed["signature_ur_frames"])
    wrong = wallet.call("verify_and_assemble_eth_signature_ur", session, "ff" * 16, response)
    assert wrong.get("verified") is False
    assembled = wallet.call("verify_and_assemble_eth_signature_ur", session, request_id, response)
    assert assembled["verified"] is True, assembled
    assert assembled["local_tx_hash"].lower() == "0x" + keccak(bytes.fromhex(assembled["signed_raw_tx_hex"][2:])).hex()
    return assembled


def wait_receipt(rpc, tx_hash):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        receipt = rpc("eth_getTransactionReceipt", [tx_hash])
        if receipt is not None:
            return receipt
        time.sleep(0.05)
    pytest.fail("Node accepted transaction but did not mine a receipt within 10 seconds")


@pytest.mark.parametrize("passphrase", [b"", b"isolated BIP39 passphrase"])
def test_restore_and_real_node_legacy_type2_token(anvil, tmp_path, passphrase):
    vault, wallet = Native("vault_ffi"), Native("wallet_ffi")
    vault.init()
    wallet.init()
    generated = vault.call("generate_mnemonic_json", 12)
    assert generated["status"] == "SUCCESS"
    mnemonic = generated["mnemonic"]
    preview = vault.call("preview_mnemonic_json", mnemonic, passphrase)
    account = preview["evm_account_0"]
    created = vault.call("activate_and_save_mnemonic_json", mnemonic, passphrase, str(tmp_path / "first.json"), PASSWORD)
    assert created["status"] == "SUCCESS", created
    backup = vault.call("export_encrypted_backup_json", b"isolated-backup-password-2026")
    assert backup["status"] == "SUCCESS", backup
    backup_data = json.loads(backup["backup_json"])
    backup_data["envelope"]["ciphertext"][0] ^= 1
    corrupt = vault.call("preview_encrypted_backup_json", json.dumps(backup_data), b"isolated-backup-password-2026")
    assert corrupt["status"] == "ERROR"
    assert vault.call("preview_encrypted_backup_json", backup["backup_json"], b"incorrect-backup-password")["status"] == "ERROR"
    if passphrase:
        different = vault.call("preview_mnemonic_json", mnemonic, b"different passphrase")
        assert different["status"] == "SUCCESS"  # Valid passphrases select different wallets.
        assert different["evm_account_0"]["address"] != account["address"]
    # A clean native context + distinct empty storage file: no fixture loader.
    vault.init()
    restored = vault.call("activate_and_save_mnemonic_json", mnemonic, passphrase, str(tmp_path / "second.json"), PASSWORD)
    assert restored["status"] == "SUCCESS", restored
    assert restored["master_fingerprint"] == preview["master_fingerprint"]
    vault.lib.vault_lock()
    rejected = vault.call("unlock_from_storage_json", str(tmp_path / "second.json"), b"wrong-password-2026")
    assert rejected["status"] == "ERROR"
    unlocked = vault.call("unlock_from_storage_json", str(tmp_path / "second.json"), PASSWORD)
    assert unlocked["status"] == "UNLOCKED", unlocked
    pairing = vault.call("export_multi_accounts_json", 60)
    verified_pairing = wallet.call("decode_and_verify_multi_accounts_ur", json.dumps(pairing["multi_accounts"]["fountain_frames"]), CHAIN)
    assert verified_pairing["status"] == "SUCCESS", verified_pairing
    sender = account["address"]
    recipient = anvil("eth_accounts")[1]
    anvil("anvil_setBalance", [sender, hex(10 ** 20)])
    evidence = []
    for tx_type in ("legacy", "type2", "erc20"):
        if tx_type == "erc20":
            # Verify encrypted-file restore in a third clean environment can sign.
            vault.init()
            restored_backup = vault.call("restore_from_encrypted_backup_json", backup["backup_json"], b"isolated-backup-password-2026", str(tmp_path / "third.json"), PASSWORD)
            assert restored_backup["status"] == "RESTORED", restored_backup
            assert restored_backup["master_fingerprint"] == preview["master_fingerprint"]
        nonce = int(anvil("eth_getTransactionCount", [sender, "pending"]), 16)
        gas_price = int(anvil("eth_gasPrice"), 16)
        priority = int(anvil("eth_maxPriorityFeePerGas"), 16)
        value, calldata, to = 10 ** 15 + 123, b"", recipient
        if tx_type == "erc20":
            artifact = ROOT / "target" / "local-token" / "LocalToken.sol" / "LocalToken.json"
            assert artifact.exists(), "Run forge build --root tests/fixtures/local_token"
            code = json.loads(artifact.read_text())["deployedBytecode"]["object"]
            anvil("anvil_setCode", [TOKEN, code])
            amount = 1_000_001
            mint = keccak(text="mint(address,uint256)")[:4] + bytes.fromhex(sender[2:]).rjust(32, b"\0") + (10 ** 9).to_bytes(32, "big")
            mint_hash = anvil("eth_sendTransaction", [{"from": anvil("eth_accounts")[0], "to": TOKEN, "data": "0x" + mint.hex(), "gas": "0x30d40"}])
            assert wait_receipt(anvil, mint_hash)["status"] == "0x1"
            calldata = bytes.fromhex("a9059cbb") + bytes.fromhex(recipient[2:]).rjust(32, b"\0") + amount.to_bytes(32, "big")
            to, value = TOKEN, 0
        params = {"from": sender, "to": to, "value": hex(value), "data": "0x" + calldata.hex()}
        gas = int(anvil("eth_estimateGas", [params]), 16)
        if tx_type == "legacy":
            raw = rlp([nonce, gas_price, gas, bytes.fromhex(to[2:]), value, calldata, CHAIN, 0, 0])
        else:
            raw = b"\x02" + rlp([CHAIN, nonce, priority, gas_price * 2 + priority, gas, bytes.fromhex(to[2:]), value, calldata, []])
        before = int(anvil("eth_getBalance", [recipient, "latest"]), 16)
        assembled = exchange(vault, wallet, account, raw)
        tx_hash = anvil("eth_sendRawTransaction", [assembled["signed_raw_tx_hex"]])
        assert tx_hash.lower() == assembled["local_tx_hash"].lower()
        receipt = wait_receipt(anvil, tx_hash)
        assert receipt["status"] == "0x1", receipt
        assert receipt["transactionHash"].lower() == tx_hash.lower()
        if tx_type == "erc20":
            query = "0x70a08231" + recipient[2:].rjust(64, "0")
            assert int(anvil("eth_call", [{"to": TOKEN, "data": query}, "latest"]), 16) == amount
        else:
            assert int(anvil("eth_getBalance", [recipient, "latest"]), 16) == before + value
        evidence.append({"kind": tx_type, "transaction_hash": tx_hash, "receipt_status": receipt["status"], "block_number": receipt["blockNumber"], "gas_used": receipt["gasUsed"]})
    evidence_path = ROOT / "target" / "test-evidence" / ("anvil-passphrase.json" if passphrase else "anvil-standard.json")
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps({"level": "host_ffi_and_real_local_node", "node": anvil("web3_clientVersion"), "chain_id": CHAIN, "network": "isolated Anvil loopback (not public Sepolia)", "restored_fingerprint_matches": True, "transactions": evidence}, indent=2))
