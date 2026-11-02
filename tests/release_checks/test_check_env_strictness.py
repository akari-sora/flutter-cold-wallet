import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from unittest.mock import patch
import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
CHECK_ENV_PATH = PROJECT_ROOT / "tools" / "release_checks" / "check_env.py"

# Dynamically import check_env module
spec = importlib.util.spec_from_file_location("check_env", CHECK_ENV_PATH)
check_env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_env)

# Pinned strings from check_env.audit_host_toolchain. A matching host report
# must PASS; each case below overrides exactly one command so that pin fails.
PINNED_COMMANDS = {
    "rustc -Vv": {
        "exit_code": 0,
        "stdout": "rustc 1.96.1\nrelease: 1.96.1\ncommit-hash: abc",
        "stderr": "",
    },
    "cargo -V": {"exit_code": 0, "stdout": "cargo 1.96.1", "stderr": ""},
    "rustup target list --installed": {
        "exit_code": 0,
        "stdout": "aarch64-linux-android\nx86_64-pc-windows-msvc",
        "stderr": "",
    },
    "cargo ndk --version": {"exit_code": 0, "stdout": "cargo-ndk 4.1.2", "stderr": ""},
    "flutter --version": {
        "exit_code": 0,
        "stdout": "Flutter 3.41.3 • channel stable\nFramework • revision abcdef1234",
        "stderr": "",
    },
    "dart --version": {"exit_code": 0, "stdout": "Dart SDK version: 3.11.1 (stable)", "stderr": ""},
    "adb version": {"exit_code": 0, "stdout": "Android Debug Bridge version 1.0.41", "stderr": ""},
    "adb devices -l": {"exit_code": 0, "stdout": "List of devices attached", "stderr": ""},
}


def isolated_tool_env(dummy_profile: Path) -> dict:
    """Process environment with no real home and no toolchain on PATH.

    PATH stays on the Windows system directory so a Windows Python can still
    start, but that directory does not contain rustc, flutter, or adb.
    HOME and USERPROFILE both point at an empty directory so POSIX Path.home()
    (HOME) and Windows Path.home() (USERPROFILE) cannot see the developer's tools.
    """
    system_root = os.environ.get("SYSTEMROOT", "C:\\Windows")
    return {
        "SYSTEMROOT": system_root,
        "PATH": system_root + "\\System32",
        "HOME": str(dummy_profile),
        "USERPROFILE": str(dummy_profile),
    }


def install_fake_release_sdk(monkeypatch, tmp_path: Path) -> None:
    """Discovery inputs for a passing Android NDK check, under tmp_path only."""
    home = tmp_path / "home"
    home.mkdir()
    sdk = tmp_path / "sdk"
    ndk = sdk / "ndk" / "27.0.12077973"
    props = ndk / "source.properties"
    clang = ndk / "toolchains" / "llvm" / "prebuilt" / "windows-x86_64" / "bin" / "clang.exe"
    props.parent.mkdir(parents=True)
    props.write_text("Pkg.Revision = 27.0.12077973\n", encoding="utf-8")
    clang.parent.mkdir(parents=True)
    clang.write_bytes(b"MZ")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    monkeypatch.setenv("ANDROID_SDK_ROOT", str(sdk))
    monkeypatch.delenv("ANDROID_HOME", raising=False)
    monkeypatch.delenv("FLUTTER_ROOT", raising=False)
    monkeypatch.delenv("RUSTUP_HOME", raising=False)
    monkeypatch.delenv("CARGO_HOME", raising=False)
    monkeypatch.setenv("PATH", str(tmp_path / "empty-path"))


def scripted_runner(commands: dict):
    """Return check_env.run_command stand-in. Never executes the host shell."""

    def run_command(cmd, env=None, timeout=30):
        if cmd in commands:
            return dict(commands[cmd])
        # NDK clang is invoked with its absolute path only when that file exists.
        if "clang" in cmd and cmd.endswith("--version"):
            return {"exit_code": 0, "stdout": "clang version 18.0.1", "stderr": ""}
        raise AssertionError(f"unmocked command would have hit the host: {cmd}")

    return run_command


def test_check_env_help():
    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--help"],
        capture_output=True,
        text=True
    )
    assert res.returncode == 0
    assert "Audit host toolchain and devices" in res.stdout


def test_check_env_unknown_argument_fails_closed():
    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--nonexistent-flag-xyz"],
        capture_output=True,
        text=True
    )
    # argparse returns code 2 on unrecognized arguments
    assert res.returncode != 0
    assert "unrecognized arguments" in res.stderr


def test_check_env_missing_output_value_fails_closed():
    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--output"],
        capture_output=True,
        text=True
    )
    assert res.returncode != 0
    assert "expected one argument" in res.stderr


@pytest.mark.skipif(
    os.environ.get("FCW_STRICT_HOST_CHECK") != "1",
    reason=(
        "Opt-in smoke check of the real host toolchain. "
        "Set FCW_STRICT_HOST_CHECK=1 to require --strict to pass on this machine."
    ),
)
def test_check_env_strict_success_on_current_host(tmp_path):
    report_file = tmp_path / "env_audit.json"
    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--output", str(report_file), "--strict"],
        capture_output=True,
        text=True
    )
    assert res.returncode == 0
    assert report_file.exists()


def test_check_env_isolated_env_with_strict_fails_closed(tmp_path):
    """When required tools are missing and --strict is passed, check_env must exit with code 1."""
    report_file = tmp_path / "isolated_audit.json"
    dummy_profile = tmp_path / "dummy_profile"
    dummy_profile.mkdir()

    isolated_env = isolated_tool_env(dummy_profile)

    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--output", str(report_file), "--strict"],
        env=isolated_env,
        capture_output=True,
        text=True
    )
    assert res.returncode == 1, f"Expected exit code 1 under missing tools, got {res.returncode}"


def test_check_env_isolated_env_without_strict_exits_zero(tmp_path):
    """Documenting that check_env without --strict defaults to exit code 0 even when tools fail."""
    report_file = tmp_path / "isolated_audit.json"
    dummy_profile = tmp_path / "dummy_profile"
    dummy_profile.mkdir()

    isolated_env = isolated_tool_env(dummy_profile)

    res = subprocess.run(
        [sys.executable, str(CHECK_ENV_PATH), "--output", str(report_file)],
        env=isolated_env,
        capture_output=True,
        text=True
    )
    assert res.returncode == 0, "Without --strict, check_env exits 0 (warning behavior)"


def test_check_env_pinned_toolchain_passes_with_scripted_commands(tmp_path, monkeypatch):
    """A full set of pinned command outputs and an NDK 27 tree passes --strict."""
    install_fake_release_sdk(monkeypatch, tmp_path)
    report_file = tmp_path / "env_audit.json"
    with patch.object(check_env, "run_command", side_effect=scripted_runner(PINNED_COMMANDS)), \
         patch.object(sys, "argv", [str(CHECK_ENV_PATH), "--output", str(report_file), "--strict"]):
        with pytest.raises(SystemExit) as caught:
            check_env.main()
    assert caught.value.code == 0
    assert report_file.exists()
    report = json.loads(report_file.read_text(encoding="utf-8"))
    assert report["toolchain"]["rustc"]["detected_version"] == "1.96.1"
    assert report["toolchain"]["cargo"]["detected_version"] == "1.96.1"
    assert report["toolchain"]["flutter"]["detected_version"] == "3.41.3"
    assert report["toolchain"]["dart"]["detected_version"] == "3.11.1"
    assert report["toolchain"]["rust_android_target"]["target_installed"] is True
    for key, info in report["toolchain"].items():
        assert info["status"] == "PASS", key
    assert report["summary"]["all_required_host_tools_present"] is True


@pytest.mark.parametrize("target_cmd, mock_ret, tool_key, expected_status", [
    (
        "rustc -Vv",
        {"exit_code": 0, "stdout": "rustc 1.95.0\nrelease: 1.95.0\ncommit-hash: abc", "stderr": ""},
        "rustc",
        "FAIL"
    ),
    (
        "cargo -V",
        {"exit_code": 0, "stdout": "cargo 1.95.0", "stderr": ""},
        "cargo",
        "FAIL"
    ),
    (
        "flutter --version",
        {"exit_code": 0, "stdout": "Flutter 3.40.0 • channel stable", "stderr": ""},
        "flutter",
        "FAIL"
    ),
    (
        "dart --version",
        {"exit_code": 0, "stdout": "Dart SDK version: 3.10.0 (stable)", "stderr": ""},
        "dart",
        "FAIL"
    ),
    (
        "rustup target list --installed",
        {"exit_code": 0, "stdout": "x86_64-pc-windows-msvc\n", "stderr": ""},
        "rust_android_target",
        "FAIL"
    ),
    (
        "adb version",
        {"exit_code": 1, "stdout": "", "stderr": "adb not installed"},
        "adb",
        "FAIL"
    ),
])
def test_check_env_tampered_versions_trigger_fail(target_cmd, mock_ret, tool_key, expected_status, tmp_path, monkeypatch):
    install_fake_release_sdk(monkeypatch, tmp_path)
    commands = {key: dict(value) for key, value in PINNED_COMMANDS.items()}
    commands[target_cmd] = mock_ret

    with patch.object(check_env, "run_command", side_effect=scripted_runner(commands)):
        report = check_env.audit_host_toolchain()
        assert report["toolchain"][tool_key]["status"] == expected_status
        assert report["summary"]["all_required_host_tools_present"] is False
        for key, info in report["toolchain"].items():
            if key != tool_key:
                assert info["status"] == "PASS", key


def _remove_pinned_ndk_piece(defect: str) -> None:
    """Delete one input of the android_ndk existence check.

    check_env.py PASSes only when both of these files exist under
    ``$ANDROID_SDK_ROOT/ndk/27.0.12077973``:
    ``source.properties`` and
    ``toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe``.
    It records a SHA-256 of source.properties but does not read Pkg.Revision.
    """
    ndk_dir = Path(os.environ["ANDROID_SDK_ROOT"]) / "ndk" / "27.0.12077973"
    source_properties = ndk_dir / "source.properties"
    clang = ndk_dir / "toolchains" / "llvm" / "prebuilt" / "windows-x86_64" / "bin" / "clang.exe"
    if defect == "missing_directory":
        shutil.rmtree(ndk_dir)
    elif defect == "missing_clang":
        clang.unlink()
    elif defect == "missing_source_properties":
        source_properties.unlink()
    else:
        raise AssertionError(defect)


@pytest.mark.parametrize("defect", [
    "missing_directory",
    "missing_clang",
    "missing_source_properties",
])
def test_check_env_ndk_defects_trigger_fail(defect, tmp_path, monkeypatch):
    """A missing pinned NDK directory, clang.exe, or source.properties fails closed."""
    install_fake_release_sdk(monkeypatch, tmp_path)
    _remove_pinned_ndk_piece(defect)

    with patch.object(check_env, "run_command", side_effect=scripted_runner(PINNED_COMMANDS)):
        report = check_env.audit_host_toolchain()
        assert report["toolchain"]["android_ndk"]["status"] == "FAIL"
        assert report["summary"]["all_required_host_tools_present"] is False
        for key, info in report["toolchain"].items():
            if key != "android_ndk":
                assert info["status"] == "PASS", key


def test_check_env_non_directory_ndk_root_reports_fail_instead_of_raising(tmp_path, monkeypatch):
    install_fake_release_sdk(monkeypatch, tmp_path)
    ndk_root = Path(os.environ["ANDROID_SDK_ROOT"]) / "ndk"
    shutil.rmtree(ndk_root)
    ndk_root.write_text("not a directory", encoding="utf-8")

    with patch.object(check_env, "run_command", side_effect=scripted_runner(PINNED_COMMANDS)):
        report = check_env.audit_host_toolchain()

    assert report["toolchain"]["android_ndk"]["status"] == "FAIL"
    assert report["toolchain"]["android_ndk"]["available_ndk_versions"] == []
    assert report["summary"]["all_required_host_tools_present"] is False


@pytest.mark.parametrize("contents,detected", [
    ("Pkg.Revision = 26.3.11579264\n", "26.3.11579264"),
    ("Pkg.Desc = Android NDK\n", None),
])
def test_check_env_ndk_source_properties_revision_must_match(contents, detected, tmp_path, monkeypatch):
    install_fake_release_sdk(monkeypatch, tmp_path)
    props = Path(os.environ["ANDROID_SDK_ROOT"]) / "ndk" / "27.0.12077973" / "source.properties"
    props.write_text(contents, encoding="utf-8")

    with patch.object(check_env, "run_command", side_effect=scripted_runner(PINNED_COMMANDS)):
        report = check_env.audit_host_toolchain()

    ndk = report["toolchain"]["android_ndk"]
    assert ndk["status"] == "FAIL"
    assert ndk["detected_version"] == detected
    assert ndk["expected_version"] == "27.0.12077973"
    assert report["summary"]["all_required_host_tools_present"] is False
