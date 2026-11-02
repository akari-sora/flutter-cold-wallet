#!/usr/bin/env python3
"""
tools/reference_oracle/cross_verify.py
======================================
Cross-Verification Validator for Reference Oracle Algorithms (PAIR-01).

Runs Algorithm A (Rust) and Algorithm B (Python), asserts 100% character-by-character
exact match across all public standard vectors, and generates derivation_report.json.
"""

import sys
import os
import json
import subprocess
import hashlib
from datetime import datetime, timezone
from pathlib import Path


def run_cmd(cmd, cwd=None, env=None):
    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, shell=isinstance(cmd, str))
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {proc.returncode}:\nSTDERR:\n{proc.stderr}\nSTDOUT:\n{proc.stdout}")
    return proc.stdout.strip()


def compute_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main():
    repo_root = Path(__file__).resolve().parent.parent.parent
    oracle_dir = repo_root / "tools" / "reference_oracle"
    reports_dir = oracle_dir / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    
    print("=" * 70)
    print("Milestone M1 / PAIR-01: Independent Dual-Algorithm Cross-Verification")
    print("=" * 70)
    
    # cargo is resolved from PATH
    env = os.environ.copy()

    # 1. Run Algorithm A (Rust)
    print("[1/3] Executing Algorithm A (Rust Native)...")
    rust_bin_exe = oracle_dir / "target" / "release" / "reference_oracle.exe"
    if rust_bin_exe.is_file():
        stdout_a = run_cmd([str(rust_bin_exe)], cwd=repo_root, env=env)
    else:
        stdout_a = run_cmd("cargo run --release --manifest-path tools/reference_oracle/Cargo.toml", cwd=repo_root, env=env)
    data_a = json.loads(stdout_a)
    print(f"      Algorithm A returned {len(data_a['results'])} vector results.")
    
    # 2. Run Algorithm B (Python)
    print("[2/3] Executing Algorithm B (Python Standalone)...")
    stdout_b = run_cmd([sys.executable, str(oracle_dir / "oracle_b.py")], cwd=repo_root, env=env)
    data_b = json.loads(stdout_b)
    print(f"      Algorithm B returned {len(data_b['results'])} vector results.")
    
    # 3. Exact character-by-character diff
    print("[3/3] Cross-verifying Algorithm A vs Algorithm B...")
    assert len(data_a["results"]) == len(data_b["results"]), "Vector counts differ"
    
    comparison_results = []
    mismatches = []
    
    for res_a, res_b in zip(data_a["results"], data_b["results"]):
        vec_id = res_a["id"]
        assert vec_id == res_b["id"], f"Vector ID mismatch: {vec_id} != {res_b['id']}"
        
        diffs = {}
        for key in ["master_fingerprint", "account_xpub", "account_compressed_pubkey", "account_chain_code", "leaf_compressed_pubkey", "eip55_address"]:
            val_a = res_a["derived"][key]
            val_b = res_b["derived"][key]
            if val_a != val_b:
                diffs[key] = {"alg_a": val_a, "alg_b": val_b}
                mismatches.append(f"Vector {vec_id} field '{key}' mismatch: '{val_a}' != '{val_b}'")
                
        comparison_results.append({
            "id": vec_id,
            "name": res_a["name"],
            "match": len(diffs) == 0,
            "derived": res_a["derived"],
            "diffs": diffs
        })
        print(f"      Vector '{vec_id}': eip55_address = {res_a['derived']['eip55_address']} [MATCH: {len(diffs) == 0}]")
        
    report = {
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "work_package": "FCW-OKX-20261012",
        "case_id": "PAIR-01",
        "verdict": "PASS" if len(mismatches) == 0 else "FAIL",
        "algorithm_a": data_a["algorithm"],
        "algorithm_b": data_b["algorithm"],
        "vector_count": len(comparison_results),
        "all_match": len(mismatches) == 0,
        "results": comparison_results
    }
    
    report_file = reports_dir / "derivation_report.json"
    report_content = json.dumps(report, indent=2)
    report_file.write_text(report_content, encoding="utf-8")
    report_sha = compute_sha256(report_content.encode("utf-8"))
    
    print(f"\nReport written to: {report_file.relative_to(repo_root)}")
    print(f"Report SHA-256   : {report_sha}")
    
    if mismatches:
        print("\n[!] VERIFICATION FAILED:")
        for m in mismatches:
            print(f"  - {m}")
        sys.exit(1)
        
    print("\n[+] PAIR-01 PASSED: 100% exact character-by-character match across all vectors.")
    sys.exit(0)


if __name__ == "__main__":
    main()
