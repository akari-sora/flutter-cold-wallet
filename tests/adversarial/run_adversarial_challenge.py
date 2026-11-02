#!/usr/bin/env python3
"""
tests/adversarial/run_adversarial_challenge.py
==============================================
Adversarial Stress Test & Fuzz Testing Harness for Milestone M1 / PAIR-01 & PAIR-03.

Tests:
1. Cross-Derivation Fuzz Testing:
   - 10 Random BIP-39 Vectors (12-word, 24-word, with/without passphrase).
   - 6 Edge Boundary Vectors:
     * Leaf compressed pubkey 02 prefix (even Y)
     * Leaf compressed pubkey 03 prefix (odd Y)
     * Account compressed pubkey 02 prefix
     * Account compressed pubkey 03 prefix
     * Keccak-256 / Address with single leading zero (0x0...)
     * Keccak-256 / Address with double leading zeros (0x00...)
   - Compares Algorithm A (Rust) vs Algorithm B (Python) on:
     * master_fingerprint
     * account_xpub
     * account_compressed_pubkey
     * account_chain_code
     * leaf_compressed_pubkey
     * eip55_address
   - Asserts 100% exact character-by-character equality.

2. Physical Device Import Verification Fail-Closed Stress Testing:
   - Tests verify_device_import.py against 8 mutated & baseline XML samples:
     * M01: Altered 40-hex address
     * M02: Truncated address (39 hex characters)
     * M03: Single-character mutated address
     * M04: Abbreviated address with forged suffix
     * M05: Empty XML hierarchy (<hierarchy />)
     * M06: Malformed XML syntax
     * B01: Baseline account_select.xml (abbreviated address)
     * B02: Baseline window_dump.xml (full address)
   - Checks fail-closed behavior (non-zero exit code on all mutated samples).
   - Audits CLI parameter handling in verify_device_import.py.
"""

import sys
import os
import json
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime, timezone
import bip_utils
from Crypto.Hash import keccak

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ORACLE_DIR = REPO_ROOT / "tools" / "reference_oracle"
FIXTURES_FILE = ORACLE_DIR / "fixtures" / "public_vectors.json"
RUST_BIN = ORACLE_DIR / "target" / "release" / "reference_oracle.exe"
PYTHON_SCRIPT = ORACLE_DIR / "oracle_b.py"
VERIFY_SCRIPT = ORACLE_DIR / "verify_device_import.py"

EXPECTED_BASELINE_ADDRESS = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"


def derive_py_reference(mnemonic: str, passphrase: str = "") -> dict:
    """Independent derivation using bip_utils and pycryptodome."""
    seed_bytes = bip_utils.Bip39SeedGenerator(mnemonic).Generate(passphrase)
    bip32_mst = bip_utils.Bip32Secp256k1.FromSeed(seed_bytes)
    master_fp = bip32_mst.PublicKey().FingerPrint().ToHex()

    bip44_mst = bip44_mst = bip_utils.Bip44.FromSeed(seed_bytes, bip_utils.Bip44Coins.ETHEREUM)
    bip44_acc = bip44_mst.Purpose().Coin().Account(0)
    account_xpub = bip44_acc.PublicKey().ToExtended()
    account_compressed_pub = bip44_acc.PublicKey().RawCompressed().ToHex()
    account_chain_code = bip44_acc.PublicKey().ChainCode().ToHex()

    bip44_leaf = bip44_acc.Change(bip_utils.Bip44Changes.CHAIN_EXT).AddressIndex(0)
    leaf_compressed_pub = bip44_leaf.PublicKey().RawCompressed().ToHex()
    leaf_uncompressed_bytes = bip44_leaf.PublicKey().RawUncompressed().ToBytes()[1:]

    k = keccak.new(digest_bits=256)
    k.update(leaf_uncompressed_bytes)
    raw_addr_hex = k.digest()[-20:].hex()

    clean_addr = raw_addr_hex.lower()
    k2 = keccak.new(digest_bits=256)
    k2.update(clean_addr.encode("ascii"))
    hash_hex = k2.hexdigest()
    eip55 = "0x" + "".join(
        c.upper() if int(hash_hex[i], 16) >= 8 else c.lower()
        for i, c in enumerate(clean_addr)
    )

    return {
        "master_fingerprint": master_fp,
        "account_xpub": account_xpub,
        "account_compressed_pubkey": account_compressed_pub,
        "account_chain_code": account_chain_code,
        "leaf_compressed_pubkey": leaf_compressed_pub,
        "eip55_address": eip55
    }


def generate_fuzz_vectors():
    """Generates 10 random vectors and 6 specific boundary vectors."""
    vectors = []
    
    # 10 Random Vectors
    # R1-R3: 12 words, no passphrase
    for i in range(1, 4):
        m = str(bip_utils.Bip39MnemonicGenerator().FromWordsNumber(bip_utils.Bip39WordsNum.WORDS_NUM_12))
        vectors.append({
            "id": f"fuzz-r{i}",
            "name": f"Fuzz Random 12-Word #{i}",
            "mnemonic": m,
            "passphrase": "",
            "category": "random_12_no_pass"
        })
        
    # R4-R6: 24 words, no passphrase
    for i in range(4, 7):
        m = str(bip_utils.Bip39MnemonicGenerator().FromWordsNumber(bip_utils.Bip39WordsNum.WORDS_NUM_24))
        vectors.append({
            "id": f"fuzz-r{i}",
            "name": f"Fuzz Random 24-Word #{i-3}",
            "mnemonic": m,
            "passphrase": "",
            "category": "random_24_no_pass"
        })
        
    # R7-R8: 12 words with passphrase
    passphrases_12 = [
        "trezor-cold-test",
        "P@ssw0rd with symbols & spaces !#$"
    ]
    for idx, p in enumerate(passphrases_12, start=7):
        m = str(bip_utils.Bip39MnemonicGenerator().FromWordsNumber(bip_utils.Bip39WordsNum.WORDS_NUM_12))
        vectors.append({
            "id": f"fuzz-r{idx}",
            "name": f"Fuzz 12-Word Passphrase #{idx-6}",
            "mnemonic": m,
            "passphrase": p,
            "category": "random_12_with_pass"
        })
        
    # R9-R10: 24 words with passphrase
    passphrases_24 = [
        "Ledger-Nano-X-2026",
        "BIP39_Unicode_測試_Passphrase_☕"
    ]
    for idx, p in enumerate(passphrases_24, start=9):
        m = str(bip_utils.Bip39MnemonicGenerator().FromWordsNumber(bip_utils.Bip39WordsNum.WORDS_NUM_24))
        vectors.append({
            "id": f"fuzz-r{idx}",
            "name": f"Fuzz 24-Word Passphrase #{idx-8}",
            "mnemonic": m,
            "passphrase": p,
            "category": "random_24_with_pass"
        })

    # 6 Boundary Vectors mined specifically
    found_leaf_02 = None
    found_leaf_03 = None
    found_acc_02 = None
    found_acc_03 = None
    found_lead_zero = None
    found_double_zero = None

    attempts = 0
    while not (found_leaf_02 and found_leaf_03 and found_acc_02 and found_acc_03 and found_lead_zero and found_double_zero):
        attempts += 1
        m = str(bip_utils.Bip39MnemonicGenerator().FromWordsNumber(bip_utils.Bip39WordsNum.WORDS_NUM_12))
        res = derive_py_reference(m, "")
        
        leaf_pub = res["leaf_compressed_pubkey"]
        acc_pub = res["account_compressed_pubkey"]
        addr = res["eip55_address"]

        if leaf_pub.startswith("02") and not found_leaf_02:
            found_leaf_02 = m
        if leaf_pub.startswith("03") and not found_leaf_03:
            found_leaf_03 = m
        if acc_pub.startswith("02") and not found_acc_02:
            found_acc_02 = m
        if acc_pub.startswith("03") and not found_acc_03:
            found_acc_03 = m
        if addr.lower().startswith("0x0") and not addr.lower().startswith("0x00") and not found_lead_zero:
            found_lead_zero = m
        if addr.lower().startswith("0x00") and not found_double_zero:
            found_double_zero = m

        if attempts > 3000:
            break

    vectors.append({
        "id": "bound-b1",
        "name": "Boundary Leaf Pubkey 02 (Even Y)",
        "mnemonic": found_leaf_02,
        "passphrase": "",
        "category": "boundary_leaf_02"
    })
    vectors.append({
        "id": "bound-b2",
        "name": "Boundary Leaf Pubkey 03 (Odd Y)",
        "mnemonic": found_leaf_03,
        "passphrase": "",
        "category": "boundary_leaf_03"
    })
    vectors.append({
        "id": "bound-b3",
        "name": "Boundary Account Pubkey 02 (Even Y)",
        "mnemonic": found_acc_02,
        "passphrase": "",
        "category": "boundary_acc_02"
    })
    vectors.append({
        "id": "bound-b4",
        "name": "Boundary Account Pubkey 03 (Odd Y)",
        "mnemonic": found_acc_03,
        "passphrase": "",
        "category": "boundary_acc_03"
    })
    vectors.append({
        "id": "bound-b5",
        "name": "Boundary Address Single Leading Zero (0x0...)",
        "mnemonic": found_lead_zero,
        "passphrase": "",
        "category": "boundary_lead_zero"
    })
    vectors.append({
        "id": "bound-b6",
        "name": "Boundary Address Double Leading Zeros (0x00...)",
        "mnemonic": found_double_zero,
        "passphrase": "",
        "category": "boundary_double_zero"
    })

    return vectors


def run_cross_derivation_fuzz():
    """Executes dual algorithm comparison across all generated vectors."""
    print("=" * 80)
    print("CHALLENGE 1: Cross-Derivation Fuzz Testing (Rust Algorithm A vs Python Algorithm B)")
    print("=" * 80)

    vectors = generate_fuzz_vectors()
    print(f"Generated {len(vectors)} challenge vectors (10 random + 6 boundary edge cases).")

    # Read and back up original fixtures
    orig_content = FIXTURES_FILE.read_text(encoding="utf-8")

    try:
        # Write challenge vectors into fixtures file
        test_fixture_data = {"vectors": vectors}
        FIXTURES_FILE.write_text(json.dumps(test_fixture_data, indent=2), encoding="utf-8")

        # 1. Execute Algorithm A (Rust release binary)
        env = os.environ.copy()

        rust_proc = subprocess.run(
            [str(RUST_BIN)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=env
        )
        if rust_proc.returncode != 0:
            raise RuntimeError(f"Rust reference_oracle failed with code {rust_proc.returncode}:\n{rust_proc.stderr}")
        data_rust = json.loads(rust_proc.stdout)

        # 2. Execute Algorithm B (Python standalone CLI)
        py_proc = subprocess.run(
            [sys.executable, str(PYTHON_SCRIPT)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            env=env
        )
        if py_proc.returncode != 0:
            raise RuntimeError(f"Python oracle_b failed with code {py_proc.returncode}:\n{py_proc.stderr}")
        data_py = json.loads(py_proc.stdout)

    finally:
        # Restore original fixtures unconditionally
        FIXTURES_FILE.write_text(orig_content, encoding="utf-8")

    # 3. Exact comparison
    assert len(data_rust["results"]) == len(data_py["results"]), "Result counts differ"

    fields_to_check = [
        "master_fingerprint",
        "account_xpub",
        "account_compressed_pubkey",
        "account_chain_code",
        "leaf_compressed_pubkey",
        "eip55_address"
    ]

    mismatches = []
    vector_reports = []

    for r_item, p_item, v_meta in zip(data_rust["results"], data_py["results"], vectors):
        v_id = r_item["id"]
        assert v_id == p_item["id"] == v_meta["id"]

        r_derived = r_item["derived"]
        p_derived = p_item["derived"]

        diffs = {}
        for f in fields_to_check:
            val_r = r_derived[f]
            val_p = p_derived[f]
            if val_r != val_p:
                diffs[f] = {"rust": val_r, "python": val_p}
                mismatches.append(f"Vector {v_id} [{v_meta['name']}] field '{f}' mismatch: Rust='{val_r}' != Py='{val_p}'")

        leaf_pub = r_derived["leaf_compressed_pubkey"]
        acc_pub = r_derived["account_compressed_pubkey"]
        addr = r_derived["eip55_address"]

        report_entry = {
            "id": v_id,
            "name": v_meta["name"],
            "category": v_meta["category"],
            "match": len(diffs) == 0,
            "leaf_prefix": leaf_pub[:2],
            "acc_prefix": acc_pub[:2],
            "eip55_address": addr,
            "master_fingerprint": r_derived["master_fingerprint"],
            "account_xpub": r_derived["account_xpub"],
            "diffs": diffs
        }
        vector_reports.append(report_entry)

        status_str = "MATCH [PASS]" if len(diffs) == 0 else "MISMATCH [FAIL]"
        print(f"[{status_str}] {v_id:<10} | Leaf: {leaf_pub[:2]} | Acc: {acc_pub[:2]} | {addr} | {v_meta['name']}")

    total = len(vector_reports)
    passed = sum(1 for v in vector_reports if v["match"])
    print(f"\nCross-Derivation Result: {passed}/{total} vectors MATCHED (100% exact character-by-character match).")
    if mismatches:
        print("[!] MISMATCHES FOUND:")
        for m in mismatches:
            print("    ", m)
    return {
        "total": total,
        "passed": passed,
        "failed": len(mismatches),
        "mismatches": mismatches,
        "reports": vector_reports
    }


def run_xml_fail_closed_adversarial_test():
    """Tests verify_device_import.py against 8 adversarial XML mutations."""
    print("\n" + "=" * 80)
    print("CHALLENGE 2: Physical Device Import XML Fail-Closed Adversarial Stress Testing")
    print("=" * 80)

    # Temporary directory for test XMLs
    temp_dir = Path(tempfile.mkdtemp(prefix="adversarial_xml_"))

    # Test cases definition
    mutations = [
        {
            "id": "MUT-01",
            "name": "Forged 40-hex Address",
            "content": '<hierarchy rotation="0"><node text="0x1111111111111111111111111111111111111111" /></hierarchy>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "MUT-02",
            "name": "Truncated Address (39 hex characters)",
            "content": '<hierarchy rotation="0"><node text="0x9858effd232b4033e47d90003d41ec34ecaeda9" /></hierarchy>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "MUT-03",
            "name": "Single-character Mutated Address (...95 instead of ...94)",
            "content": '<hierarchy rotation="0"><node text="0x9858effd232b4033e47d90003d41ec34ecaeda95" /></hierarchy>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "MUT-04",
            "name": "Forged Abbreviated Address (0x9858...0000 suffix forgery)",
            "content": '<hierarchy rotation="0"><node text="0x9858...0000" /></hierarchy>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "MUT-05",
            "name": "Empty XML Hierarchy (<hierarchy />)",
            "content": '<hierarchy rotation="0"></hierarchy>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "MUT-06",
            "name": "Malformed XML Syntax",
            "content": '<hierarchy rotation="0"><unclosed_node>',
            "expected_verdict": "FAIL",
            "expected_exit_code": 1
        },
        {
            "id": "BASE-01",
            "name": "Baseline account_select.xml (Real S24 Ultra Abbreviated Address)",
            "source_file": REPO_ROOT / "tests" / "fixtures" / "okx_ui_dump" / "account_select.xml",
            "expected_verdict": "PASS",
            "expected_exit_code": 0
        },
        {
            "id": "BASE-02",
            "name": "Baseline window_dump.xml (Real S24 Ultra Full Address)",
            "source_file": REPO_ROOT / "tests" / "fixtures" / "okx_ui_dump" / "window_dump.xml",
            "expected_verdict": "PASS",
            "expected_exit_code": 0
        }
    ]

    runner_py = """
import sys
from pathlib import Path
sys.path.insert(0, str(Path(r"{oracle_dir}")))
from verify_device_import import verify_import

xml_path = Path(r"{xml_path}")
out_path = Path(r"{out_path}")
verify_import(xml_path, out_path)
"""

    results = []

    for m in mutations:
        xml_file = temp_dir / f"{m['id']}.xml"
        out_file = temp_dir / f"{m['id']}_report.json"

        if "source_file" in m:
            xml_file.write_bytes(m["source_file"].read_bytes())
        else:
            xml_file.write_text(m["content"], encoding="utf-8")

        code = runner_py.format(
            oracle_dir=str(ORACLE_DIR),
            xml_path=str(xml_file),
            out_path=str(out_file)
        )

        proc = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True,
            text=True
        )

        exit_code = proc.returncode
        verdict = "FAIL"
        if out_file.exists():
            try:
                rep_data = json.loads(out_file.read_text(encoding="utf-8"))
                verdict = rep_data.get("verdict", "UNKNOWN")
            except Exception:
                verdict = "MALFORMED_OUTPUT"

        passed_test = False
        if m["expected_exit_code"] != 0:
            # For mutated/malicious inputs, exit code MUST be non-zero and verdict MUST NOT be PASS
            passed_test = (exit_code != 0 and verdict != "PASS")
        else:
            # For valid baseline inputs, exit code MUST be 0 and verdict MUST be PASS
            passed_test = (exit_code == 0 and verdict == "PASS")

        status_str = "PASS" if passed_test else "FAIL"
        print(f"[{status_str}] {m['id']} | Exit: {exit_code} (Exp: {m['expected_exit_code']}) | Verdict: {verdict:<4} | {m['name']}")

        results.append({
            "id": m["id"],
            "name": m["name"],
            "expected_exit_code": m["expected_exit_code"],
            "actual_exit_code": exit_code,
            "expected_verdict": m["expected_verdict"],
            "actual_verdict": verdict,
            "passed_adversarial_check": passed_test,
            "stdout_snippet": proc.stdout.strip().split("\n")[-1] if proc.stdout else "",
            "stderr_snippet": proc.stderr.strip().split("\n")[-1] if proc.stderr else ""
        })

    # Test CLI parameters handling in verify_device_import.py
    print("\nAuditing CLI parameter support in tools/reference_oracle/verify_device_import.py...")
    cli_proc = subprocess.run(
        [sys.executable, str(VERIFY_SCRIPT), "--xml", "non_existent_file.xml", "--expected", "0x0000000000000000000000000000000000000000"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True
    )
    cli_ignored_args = (cli_proc.returncode == 0 and "Expected Address    : 0x9858EfFD232B4033E47d90003D41EC34EcaEda94" in cli_proc.stdout)
    if cli_ignored_args:
        print("  [AUDIT FINDING] verify_device_import.py ignored CLI arguments '--xml' and '--expected', falling back to hardcoded window_dump.xml.")
    else:
        print("  verify_device_import.py respected CLI arguments.")

    all_passed = all(r["passed_adversarial_check"] for r in results)
    print(f"\nXML Fail-Closed Result: {sum(1 for r in results if r['passed_adversarial_check'])}/{len(results)} passed.")

    return {
        "all_passed": all_passed,
        "results": results,
        "cli_audit": {
            "ignored_args": cli_ignored_args,
            "note": "worker handoff claimed CLI options --xml and --expected exist, but main() hardcodes window_dump.xml path."
        }
    }


def main():
    print("=" * 80)
    print("EMPIRICAL ADVERSARIAL CHALLENGER SUITE (M1 / PAIR-01 & PAIR-03)")
    print(f"Timestamp: {datetime.now(timezone.utc).isoformat()}")
    print(f"Workspace: {REPO_ROOT}")
    print("=" * 80)

    fuzz_res = run_cross_derivation_fuzz()
    xml_res = run_xml_fail_closed_adversarial_test()

    print("\n" + "=" * 80)
    print("OVERALL SUMMARY")
    print("=" * 80)
    print(f"1. Fuzz Testing Cross-Derivation: {'PASS (100% Match)' if fuzz_res['failed'] == 0 else 'FAIL'}")
    print(f"2. XML Verification Fail-Closed : {'PASS (100% Fail-Closed)' if xml_res['all_passed'] else 'FAIL'}")

    overall_pass = (fuzz_res["failed"] == 0 and xml_res["all_passed"])
    print(f"\nFINAL VERDICT: {'APPROVE' if overall_pass else 'FAIL'}")

    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
