"""
tests/release_checks/test_check_ios_toolchain.py
================================================
Test suite for tools/reference_oracle/check_ios_toolchain.py.
Covers CLI flags, exit code mappings, log SHA-256 reproducibility, and macOS mock branches.
"""

import hashlib
import json
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT_PATH = PROJECT_ROOT / "tools" / "reference_oracle" / "check_ios_toolchain.py"

# Import dynamically
import importlib.util
spec = importlib.util.spec_from_file_location("check_ios_toolchain", SCRIPT_PATH)
check_ios_toolchain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_ios_toolchain)

# Evidence hash of the Windows 10 AMD64 blocked audit log, CRLF text-mode stdout.
WINDOWS_BLOCKED_LOG_SHA256 = "8ed089112f392c04e4fca32dd3a421fad5e52b457b3cfad6f82c1bf8c5c2ea0a"


@contextmanager
def simulated_windows_10_amd64():
    """Windows 10 AMD64 with no Xcode and no libimobiledevice on PATH.

    check_ios_toolchain reads platform and shutil at call time, so patching
    those modules is the simulated host. Command output is stubbed so a
    developer machine cannot satisfy the audit by accident.
    """
    with patch("platform.system", return_value="Windows"), \
         patch("platform.release", return_value="10"), \
         patch("platform.machine", return_value="AMD64"), \
         patch("shutil.which", return_value=None), \
         patch.object(
             check_ios_toolchain,
             "run_command",
             return_value={"exit_code": -1, "stdout": "", "stderr": "stubbed"},
         ):
        yield


def invoke_ios_cli(argv):
    with simulated_windows_10_amd64(), patch.object(sys, "argv", argv):
        with pytest.raises(SystemExit) as caught:
            check_ios_toolchain.main()
    return caught.value.code


def windows_text_mode_stdout(text: str) -> bytes:
    """Bytes Python text-mode print() emits on Windows (LF translated to CRLF)."""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    return normalized.replace("\n", "\r\n").encode("utf-8")


def test_cli_help():
    """Verify --help flag works cleanly and exits 0."""
    res = subprocess.run([sys.executable, str(SCRIPT_PATH), "--help"], capture_output=True, text=True)
    assert res.returncode == 0
    assert "PAIR-04" in res.stdout


def test_cli_unknown_argument_fails():
    """Verify unrecognized arguments trigger exit code 2."""
    res = subprocess.run([sys.executable, str(SCRIPT_PATH), "--bogus-flag"], capture_output=True, text=True)
    assert res.returncode == 2


def test_windows_default_exit_code_and_log(capsys):
    """Simulated Windows 10 host: no flags exits 2 and prints the blocked audit log."""
    code = invoke_ios_cli([str(SCRIPT_PATH)])
    stdout = capsys.readouterr().out
    assert code == 2
    assert "Verdict               : BLOCKED" in stdout
    assert "Reason                : BLOCKED_NO_MACOS_TOOLCHAIN" in stdout


def test_windows_strict_exit_code_one(capsys):
    """With --strict on a simulated Windows host, status BLOCKED must exit with code 1."""
    code = invoke_ios_cli([str(SCRIPT_PATH), "--strict"])
    stdout = capsys.readouterr().out
    assert code == 1
    assert "Reason                : BLOCKED_NO_MACOS_TOOLCHAIN" in stdout


def test_windows_allow_blocked_exit_code_zero(capsys):
    """With --allow-blocked on a simulated Windows host, status BLOCKED must exit with code 0."""
    code = invoke_ios_cli([str(SCRIPT_PATH), "--allow-blocked"])
    stdout = capsys.readouterr().out
    assert code == 0
    assert "Verdict               : BLOCKED" in stdout
    assert "Reason                : BLOCKED_NO_MACOS_TOOLCHAIN" in stdout


def test_structured_json_output(tmp_path):
    """Verify --output writes valid JSON matching evidence contract on a non-macOS host."""
    json_path = tmp_path / "ios_audit.json"
    code = invoke_ios_cli([str(SCRIPT_PATH), "--output", str(json_path)])
    assert code == 2
    assert json_path.exists()
    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data["case_id"] == "PAIR-04"
    assert data["verdict"] == "BLOCKED"
    assert data["reason"] == "BLOCKED_NO_MACOS_TOOLCHAIN"
    assert data["host"]["system"] == "Windows"
    assert data["host"]["release"] == "10"
    assert data["host"]["machine"] == "AMD64"


def test_log_sha256_reproducibility(capsys):
    """Stdout bytes match the evidence SHA-256 of the Windows 10 AMD64 CRLF log."""
    code = invoke_ios_cli([str(SCRIPT_PATH)])
    stdout = capsys.readouterr().out
    assert code == 2
    payload = windows_text_mode_stdout(stdout)
    calc_sha = hashlib.sha256(payload).hexdigest()
    assert calc_sha == WINDOWS_BLOCKED_LOG_SHA256, f"Calculated {calc_sha} != Expected {WINDOWS_BLOCKED_LOG_SHA256}"


def test_mock_macos_success():
    """Verify macOS environment with Xcode and physical iPhone returns PASS."""
    with patch("platform.system", return_value="Darwin"), \
         patch("platform.release", return_value="23.5.0"), \
         patch("platform.machine", return_value="arm64"), \
         patch("platform.mac_ver", return_value=("14.5", ("", "", ""), "arm64")), \
         patch("shutil.which", return_value="/usr/bin/xcodebuild"), \
         patch.object(check_ios_toolchain, "run_command", side_effect=lambda cmd, timeout=10: {
             "exit_code": 0,
             "stdout": "Xcode 15.4\nBuild version 15F31d" if "xcodebuild" in cmd else ("00008101-0012345678" if "-l" in cmd else ""),
             "stderr": ""
         }):
        audit = check_ios_toolchain.audit_ios_toolchain()
        assert audit["verdict"] == "PASS"
        assert audit["reason"] == "TOOLCHAIN_READY"
        assert audit["devices"]["physical_count"] == 1


def test_mock_macos_no_device():
    """Verify macOS environment with Xcode but no connected iPhone returns BLOCKED."""
    with patch("platform.system", return_value="Darwin"), \
         patch("platform.release", return_value="23.5.0"), \
         patch("platform.machine", return_value="arm64"), \
         patch("platform.mac_ver", return_value=("14.5", ("", "", ""), "arm64")), \
         patch("shutil.which", return_value="/usr/bin/xcodebuild"), \
         patch.object(check_ios_toolchain, "run_command", side_effect=lambda cmd, timeout=10: {
             "exit_code": 0,
             "stdout": "Xcode 15.4\nBuild version 15F31d" if "xcodebuild" in cmd else "",
             "stderr": ""
         }):
        audit = check_ios_toolchain.audit_ios_toolchain()
        assert audit["verdict"] == "BLOCKED"
        assert audit["reason"] == "BLOCKED_NO_PHYSICAL_IOS_DEVICE"
