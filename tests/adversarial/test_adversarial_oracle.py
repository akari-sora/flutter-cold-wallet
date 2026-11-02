#!/usr/bin/env python3
"""
tests/adversarial/test_adversarial_oracle.py
============================================
Pytest integration for Adversarial Stress & Fuzz Testing (Milestone M1).
"""

import sys
import os
import json
import subprocess
import tempfile
from pathlib import Path
import pytest
import bip_utils
from Crypto.Hash import keccak

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ORACLE_DIR = REPO_ROOT / "tools" / "reference_oracle"
FIXTURES_FILE = ORACLE_DIR / "fixtures" / "public_vectors.json"
RUST_BIN = ORACLE_DIR / "target" / "release" / "reference_oracle.exe"
PYTHON_SCRIPT = ORACLE_DIR / "oracle_b.py"
VERIFY_SCRIPT = ORACLE_DIR / "verify_device_import.py"


@pytest.fixture(scope="module")
def env_with_rust():
    # The Rust toolchain is resolved from PATH.
    return os.environ.copy()


def test_dual_algorithm_cross_derivation_fuzz(env_with_rust):
    """Fuzz testing with 10 random vectors + 6 boundary vectors."""
    # Add tests/adversarial to path
    sys.path.insert(0, str(Path(__file__).parent))
    from run_adversarial_challenge import generate_fuzz_vectors

    vectors = generate_fuzz_vectors()
    orig_content = FIXTURES_FILE.read_text(encoding="utf-8")

    try:
        FIXTURES_FILE.write_text(json.dumps({"vectors": vectors}, indent=2), encoding="utf-8")

        rust_proc = subprocess.run([str(RUST_BIN)], cwd=REPO_ROOT, capture_output=True, text=True, env=env_with_rust)
        assert rust_proc.returncode == 0, f"Rust oracle failed: {rust_proc.stderr}"
        data_rust = json.loads(rust_proc.stdout)

        py_proc = subprocess.run([sys.executable, str(PYTHON_SCRIPT)], cwd=REPO_ROOT, capture_output=True, text=True, env=env_with_rust)
        assert py_proc.returncode == 0, f"Python oracle failed: {py_proc.stderr}"
        data_py = json.loads(py_proc.stdout)
    finally:
        FIXTURES_FILE.write_text(orig_content, encoding="utf-8")

    assert len(data_rust["results"]) == len(data_py["results"]) == len(vectors)

    fields = [
        "master_fingerprint",
        "account_xpub",
        "account_compressed_pubkey",
        "account_chain_code",
        "leaf_compressed_pubkey",
        "eip55_address"
    ]

    for r_item, p_item in zip(data_rust["results"], data_py["results"]):
        for f in fields:
            assert r_item["derived"][f] == p_item["derived"][f], (
                f"Vector {r_item['id']} mismatch on field '{f}': {r_item['derived'][f]} != {p_item['derived'][f]}"
            )


@pytest.mark.parametrize("test_case", [
    ("MUT-01", '<hierarchy rotation="0"><node text="0x1111111111111111111111111111111111111111" /></hierarchy>', 1, "FAIL"),
    ("MUT-02", '<hierarchy rotation="0"><node text="0x9858effd232b4033e47d90003d41ec34ecaeda9" /></hierarchy>', 1, "FAIL"),
    ("MUT-03", '<hierarchy rotation="0"><node text="0x9858effd232b4033e47d90003d41ec34ecaeda95" /></hierarchy>', 1, "FAIL"),
    ("MUT-04", '<hierarchy rotation="0"><node text="0x9858...0000" /></hierarchy>', 1, "FAIL"),
    ("MUT-05", '<hierarchy rotation="0"></hierarchy>', 1, "FAIL"),
    ("MUT-06", '<hierarchy rotation="0"><unclosed>', 1, "FAIL"),
])
def test_verify_device_import_fail_closed_mutations(test_case):
    """Asserts that verify_device_import.py fails closed with non-zero exit code on all mutated XML inputs."""
    case_id, content, exp_code, exp_verdict = test_case
    temp_dir = Path(tempfile.mkdtemp(prefix="adv_test_"))
    xml_file = temp_dir / f"{case_id}.xml"
    out_file = temp_dir / f"{case_id}_out.json"
    xml_file.write_text(content, encoding="utf-8")

    runner_code = f"""
import sys
from pathlib import Path
sys.path.insert(0, r"{ORACLE_DIR}")
from verify_device_import import verify_import

verify_import(Path(r"{xml_file}"), Path(r"{out_file}"))
"""
    proc = subprocess.run([sys.executable, "-c", runner_code], capture_output=True, text=True)
    assert proc.returncode != 0, f"Expected non-zero exit code for {case_id}, got 0"
    if out_file.exists():
        data = json.loads(out_file.read_text(encoding="utf-8"))
        assert data.get("verdict") == "FAIL", f"Expected FAIL verdict for {case_id}, got {data.get('verdict')}"


def test_verify_device_import_baseline_success():
    """Asserts that verify_device_import.py succeeds on real device baseline XML files."""
    for fname in ["account_select.xml", "window_dump.xml"]:
        src = REPO_ROOT / "tests" / "fixtures" / "okx_ui_dump" / fname
        temp_dir = Path(tempfile.mkdtemp(prefix="adv_base_"))
        out_file = temp_dir / f"{fname}_out.json"

        runner_code = f"""
import sys
from pathlib import Path
sys.path.insert(0, r"{ORACLE_DIR}")
from verify_device_import import verify_import

verify_import(Path(r"{src}"), Path(r"{out_file}"))
"""
        proc = subprocess.run([sys.executable, "-c", runner_code], capture_output=True, text=True)
        assert proc.returncode == 0, f"Expected code 0 for {fname}, got {proc.returncode}:\n{proc.stderr}"
        data = json.loads(out_file.read_text(encoding="utf-8"))
        assert data.get("verdict") == "PASS", f"Expected PASS verdict for {fname}, got {data.get('verdict')}"
