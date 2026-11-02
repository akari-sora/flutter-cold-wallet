"""Real Bitcoin Core regtest + production QR FFI, isolated disposable test data."""
import base64
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid

import pytest
from tests.integration.test_qr_real_node import Native, ROOT, PASSWORD


@pytest.fixture
def bitcoin(tmp_path):
    exe = Path(os.environ.get("BITCOIND_PATH", ROOT / "target/test-tools/bitcoin-31.1/bin/bitcoind.exe"))
    assert exe.exists(), "Verified Bitcoin Core regtest executable required"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    data = tmp_path / "node"
    data.mkdir()
    password = uuid.uuid4().hex
    process = subprocess.Popen([str(exe), "-regtest", "-server", "-listen=0", "-connect=0", "-dnsseed=0", "-txindex=1", "-fallbackfee=0.0001", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1", f"-rpcport={port}", "-rpcuser=fcw-test", f"-rpcpassword={password}", f"-datadir={data}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    auth = "Basic " + base64.b64encode(("fcw-test:" + password).encode()).decode()

    def rpc(method, params=(), wallet=None):
        endpoint = f"http://127.0.0.1:{port}" + ("/wallet/" + wallet if wallet else "")
        req = urllib.request.Request(endpoint, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode(), headers={"Content-Type": "application/json", "Authorization": auth})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            result = json.load(error)
        if result.get("error"):
            raise RuntimeError(str(result["error"]))
        return result["result"]

    try:
        for _ in range(150):
            try:
                assert rpc("getblockchaininfo")["chain"] == "regtest"
                break
            except (OSError, RuntimeError):
                assert process.poll() is None, "Bitcoin Core startup failed"
                time.sleep(0.1)
        else:
            pytest.fail("Bitcoin Core startup timed out")
        yield rpc
    finally:
        try:
            rpc("stop")
            process.wait(timeout=15)
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            process.terminate()
            process.wait(timeout=10)


def test_real_regtest_qr_approved_sign_finalize_broadcast(bitcoin, tmp_path):
    vault, wallet = Native("vault_ffi"), Native("wallet_ffi")
    vault.init()
    wallet.init()
    generated = vault.call("generate_mnemonic_json", 12)
    mnemonic = generated["mnemonic"]
    preview = vault.call("preview_mnemonic_json", mnemonic, b"")
    account = preview["btc_account_0"]
    assert account["receive_address"].startswith("bcrt1")
    assert account["derivation_path"].startswith("m/84'/1'/")
    created = vault.call("activate_and_save_mnemonic_json", mnemonic, b"", str(tmp_path / "vault.json"), PASSWORD)
    assert created["status"] == "SUCCESS", created
    bitcoin("createwallet", ["fcw-miner"])
    mining = bitcoin("getnewaddress", [], "fcw-miner")
    bitcoin("generatetoaddress", [101, mining])
    funding_tx = bitcoin("sendtoaddress", [account["receive_address"], "1.0"], "fcw-miner")
    bitcoin("generatetoaddress", [1, mining])
    prev = bitcoin("getrawtransaction", [funding_tx, True])
    output = next(item for item in prev["vout"] if item["scriptPubKey"].get("address") == account["receive_address"])
    recipient = bitcoin("getnewaddress", [], "fcw-miner")
    request = {
        "account_xpub": account["account_xpub"], "master_fingerprint": account["master_fingerprint"],
        "recipient_address": recipient, "amount_sat": "12345678", "fee_sat": "1000", "change_index": 0,
        "utxos": [{"txid": funding_tx, "vout": output["n"], "previous_tx_hex": prev["hex"], "branch": 0, "address_index": 0}],
    }
    built = wallet.call("build_regtest_psbt_json", json.dumps(request))
    assert built["status"] == "SUCCESS", built
    prepared = vault.call("prepare_ur_request", "regtest-real-qr", json.dumps(built["ur_frames"]))
    assert prepared["status"] == "SUCCESS", prepared
    # This is the exact production JSON consumed by the Vault review card.
    # Amounts exclude change and may not be fabricated from missing fields.
    assert prepared["inputs_count"] == len(request["utxos"]) == 1
    assert prepared["network"] == "regtest"
    assert prepared["session_id"] == "regtest-real-qr"
    assert prepared["request_id"]
    assert prepared["signing_digest"] == built["expected_digest"]
    assert prepared["recipient_amount_sats"] == int(request["amount_sat"])
    assert prepared["destinations"] == [
        {"address": recipient, "amount_sat": 12345678, "is_change": False}
    ]
    assert prepared["changes"] == [
        {"address": account["change_address"], "amount_sat": 87653322, "is_change": True}
    ]
    assert prepared["total_output_sat"] == sum(
        row["amount_sat"] for row in prepared["destinations"] + prepared["changes"]
    )
    assert prepared["total_input_sat"] == prepared["total_output_sat"] + prepared["fee_sat"]
    signed = vault.call("approve_and_sign", prepared["handle_id"])
    assert signed["status"] == "SUCCESS", signed
    vault.lib.vault_get_primitive_sign_count.restype = ctypes.c_int64
    primitive_count = vault.lib.vault_get_primitive_sign_count()
    assert primitive_count == 1
    rescanned = vault.call("prepare_ur_request", "regtest-rescan", json.dumps(built["ur_frames"]))
    assert rescanned["status"] == "SUCCESS"
    assert rescanned["handle_id"] != prepared["handle_id"]
    assert rescanned["request_id"] == prepared["request_id"]
    cached = vault.call("approve_and_sign", rescanned["handle_id"])
    assert cached["signed_psbt_ur"] == signed["signed_psbt_ur"]
    assert vault.lib.vault_get_primitive_sign_count() == primitive_count
    verification = {"original_psbt_hex": built["psbt_hex"], "expected_digest": built["expected_digest"], "response_ur": json.dumps(signed["signed_psbt_ur_frames"])}
    wrong = {**verification, "expected_digest": "00" * 32}
    assert wallet.call("verify_regtest_psbt_response_json", json.dumps(wrong))["status"] != "VERIFIED"
    final = wallet.call("verify_regtest_psbt_response_json", json.dumps(verification))
    assert final["status"] == "VERIFIED", final
    accepted = bitcoin("testmempoolaccept", [[final["tx_hex"]]])
    assert accepted[0]["allowed"] is True, accepted
    txid = bitcoin("sendrawtransaction", [final["tx_hex"]])
    assert txid == final["txid"]
    bitcoin("generatetoaddress", [1, mining])
    confirmed = bitcoin("getrawtransaction", [txid, True])
    assert confirmed["confirmations"] >= 1
    assert any(out["scriptPubKey"].get("address") == recipient for out in confirmed["vout"])
    evidence = {"level": "host_ffi_and_real_regtest_node", "node_version": bitcoin("getnetworkinfo")["subversion"], "network": "regtest", "txid": txid, "confirmations": confirmed["confirmations"], "blockhash": confirmed["blockhash"], "mempool_accepted": True, "amount_sat": request["amount_sat"], "fee_sat": request["fee_sat"]}
    path = ROOT / "target/test-evidence/bitcoin-regtest.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(evidence, indent=2))
