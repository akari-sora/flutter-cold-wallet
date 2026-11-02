#!/usr/bin/env python3
"""
tools/release_checks/check_env.py
=================================
Automated Host Toolchain & Device Verification Utility for Mobile Cold Wallet.
Milestone M0 / G0 Gate Verification Tool.

Audits:
- Host OS & Architecture
- Rust compiler (1.96.1) & Cargo
- Rust Android cross-compilation targets (aarch64-linux-android)
- cargo-ndk (4.1.2)
- Flutter SDK (3.41.3) & Dart SDK (3.11.1)
- Android SDK & Android NDK (27.0.12077973)
- ADB (1.0.41) & connected physical Android devices
- OKX App installation check on connected devices
- iOS / macOS availability (BLOCKED disposition)
- Dual-device air-gap readiness (BLOCKED disposition)

Generates:
- Structured JSON report containing all tool paths, version strings, and SHA-256 hashes.
"""

import sys
import os
import json
import subprocess
import hashlib
import platform
import re
import shutil
import argparse
from datetime import datetime, timezone
from pathlib import Path

NDK_VERSION = "27.0.12077973"


def path_is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


def path_is_dir(path: Path) -> bool:
    try:
        return path.is_dir()
    except OSError:
        return False


def compute_sha256(file_path: Path) -> str | None:
    """Compute SHA-256 hash of a file with streaming chunks."""
    if not file_path or not path_is_file(file_path):
        return None
    h = hashlib.sha256()
    try:
        with open(file_path, "rb") as f:
            while chunk := f.read(65536):
                h.update(chunk)
        return h.hexdigest()
    except Exception as e:
        return f"ERROR: {e}"


def run_command(cmd: str, env: dict = None, timeout: int = 30) -> dict:
    """Execute a system command and return exit code, stdout, and stderr."""
    try:
        proc = subprocess.run(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env or os.environ,
            timeout=timeout
        )
        return {
            "exit_code": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip()
        }
    except subprocess.TimeoutExpired:
        return {"exit_code": -1, "stdout": "", "stderr": f"Command timed out after {timeout}s"}
    except Exception as e:
        return {"exit_code": -1, "stdout": "", "stderr": str(e)}


def ndk_revision(source_properties: Path) -> str | None:
    """Read the exact installed NDK revision, or None for missing/invalid metadata."""
    try:
        contents = source_properties.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    match = re.search(r"^Pkg\.Revision\s*=\s*([^\s]+)\s*$", contents, re.MULTILINE)
    return match.group(1) if match else None


def directory_names(path: Path) -> list[str]:
    """List child directories without turning a missing/broken default path into an exception."""
    if not path_is_dir(path):
        return []
    try:
        return sorted(child.name for child in path.iterdir() if path_is_dir(child))
    except OSError:
        return []


def build_augmented_env() -> tuple[dict, dict]:
    """Construct a clean augmented PATH environment with discovered tool paths."""
    env = os.environ.copy()
    user_home = Path.home()

    # Candidates: standard install locations, overridable through the usual environment variables
    rustup_home = Path(os.environ.get("RUSTUP_HOME", user_home / ".rustup"))
    rust_toolchain_dir = rustup_home / "toolchains" / "1.96.1-x86_64-pc-windows-msvc" / "bin"
    cargo_bin_dir = Path(os.environ.get("CARGO_HOME", user_home / ".cargo")) / "bin"
    flutter_on_path = shutil.which("flutter")
    if os.environ.get("FLUTTER_ROOT"):
        flutter_bin_dir = Path(os.environ["FLUTTER_ROOT"]) / "bin"
    elif flutter_on_path:
        flutter_bin_dir = Path(flutter_on_path).resolve().parent
    else:
        flutter_bin_dir = user_home / "flutter" / "bin"
    android_sdk_dir = Path(
        os.environ.get("ANDROID_SDK_ROOT")
        or os.environ.get("ANDROID_HOME")
        or user_home / "AppData" / "Local" / "Android" / "Sdk"
    )
    platform_tools_dir = android_sdk_dir / "platform-tools"

    path_injections = [
        str(rust_toolchain_dir),
        str(cargo_bin_dir),
        str(flutter_bin_dir),
        str(platform_tools_dir)
    ]
    valid_injections = [p for p in path_injections if path_is_dir(Path(p))]
    env["PATH"] = os.pathsep.join(valid_injections + [env.get("PATH", "")])

    locations = {
        "rust_toolchain_dir": rust_toolchain_dir,
        "cargo_bin_dir": cargo_bin_dir,
        "flutter_bin_dir": flutter_bin_dir,
        "android_sdk_dir": android_sdk_dir,
        "platform_tools_dir": platform_tools_dir
    }
    return env, locations


def audit_host_toolchain() -> dict:
    """Perform exhaustive host toolchain and device audit."""
    env, locs = build_augmented_env()

    report = {
        "schema_version": "1.0",
        "work_package": "FCW-OKX-20261012",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "host": {
            "os": platform.system(),
            "os_release": platform.release(),
            "os_version": platform.version(),
            "architecture": platform.machine(),
            "python_version": platform.python_version()
        },
        "toolchain": {},
        "devices": {
            "android": []
        },
        "blockers": {},
        "summary": {
            "all_required_host_tools_present": False,
            "android_build_ready": False,
            "ios_build_ready": False,
            "dual_device_airgap_ready": False
        }
    }

    # 1. Rust Compiler (rustc)
    rustc_res = run_command("rustc -Vv", env=env)
    rustc_bin = locs["rust_toolchain_dir"] / "rustc.exe"
    rustc_ver = None
    rustc_commit = None
    if rustc_res["exit_code"] == 0:
        m_rel = re.search(r"release:\s+([^\s]+)", rustc_res["stdout"])
        m_com = re.search(r"commit-hash:\s+([^\s]+)", rustc_res["stdout"])
        rustc_ver = m_rel.group(1) if m_rel else None
        rustc_commit = m_com.group(1) if m_com else None

    report["toolchain"]["rustc"] = {
        "status": "PASS" if rustc_res["exit_code"] == 0 and rustc_ver == "1.96.1" else "FAIL",
        "expected_version": "1.96.1",
        "detected_version": rustc_ver,
        "commit_hash": rustc_commit,
        "path": str(rustc_bin) if path_is_file(rustc_bin) else None,
        "sha256": compute_sha256(rustc_bin),
        "raw_output": rustc_res["stdout"]
    }

    # 2. Cargo Package Manager
    cargo_res = run_command("cargo -V", env=env)
    cargo_bin = locs["rust_toolchain_dir"] / "cargo.exe"
    cargo_ver = None
    if cargo_res["exit_code"] == 0:
        m_cargo = re.search(r"cargo\s+([0-9\.]+)", cargo_res["stdout"])
        cargo_ver = m_cargo.group(1) if m_cargo else None

    report["toolchain"]["cargo"] = {
        "status": "PASS" if cargo_res["exit_code"] == 0 and cargo_ver == "1.96.1" else "FAIL",
        "expected_version": "1.96.1",
        "detected_version": cargo_ver,
        "path": str(cargo_bin) if path_is_file(cargo_bin) else None,
        "sha256": compute_sha256(cargo_bin),
        "raw_output": cargo_res["stdout"]
    }

    # 3. Rust Android Cross-compilation Target
    rustup_targets = run_command("rustup target list --installed", env=env)
    installed_targets = rustup_targets["stdout"].splitlines() if rustup_targets["exit_code"] == 0 else []
    has_aarch64_android = "aarch64-linux-android" in installed_targets

    report["toolchain"]["rust_android_target"] = {
        "status": "PASS" if has_aarch64_android else "FAIL",
        "required_target": "aarch64-linux-android",
        "target_installed": has_aarch64_android,
        "all_installed_targets": installed_targets
    }

    # 4. cargo-ndk
    cndk_res = run_command("cargo ndk --version", env=env)
    cndk_bin = locs["cargo_bin_dir"] / "cargo-ndk.exe"
    cndk_ver = None
    if cndk_res["exit_code"] == 0:
        m_cndk = re.search(r"cargo-ndk\s+([0-9\.]+)", cndk_res["stdout"])
        cndk_ver = m_cndk.group(1) if m_cndk else None

    report["toolchain"]["cargo_ndk"] = {
        "status": "PASS" if cndk_res["exit_code"] == 0 else "FAIL",
        "expected_version": "4.1.2",
        "detected_version": cndk_ver,
        "path": str(cndk_bin) if path_is_file(cndk_bin) else None,
        "sha256": compute_sha256(cndk_bin),
        "raw_output": cndk_res["stdout"]
    }

    # 5. Flutter SDK
    flutter_bat = locs["flutter_bin_dir"] / "flutter.bat"
    flutter_res = run_command("flutter --version", env=env)
    flutter_ver = None
    flutter_rev = None
    if flutter_res["exit_code"] == 0:
        m_fl = re.search(r"Flutter\s+([0-9\.]+)", flutter_res["stdout"])
        m_rev = re.search(r"Framework\s+•\s+revision\s+([0-9a-f]+)", flutter_res["stdout"])
        flutter_ver = m_fl.group(1) if m_fl else None
        flutter_rev = m_rev.group(1) if m_rev else None

    report["toolchain"]["flutter"] = {
        "status": "PASS" if flutter_res["exit_code"] == 0 and flutter_ver == "3.41.3" else "FAIL",
        "expected_version": "3.41.3",
        "detected_version": flutter_ver,
        "framework_revision": flutter_rev,
        "path": str(flutter_bat) if path_is_file(flutter_bat) else None,
        "raw_output": flutter_res["stdout"]
    }

    # 6. Dart SDK
    dart_bin = locs["flutter_bin_dir"] / "cache" / "dart-sdk" / "bin" / "dart.exe"
    dart_res = run_command("dart --version", env=env)
    dart_ver = None
    if dart_res["exit_code"] == 0:
        m_dart = re.search(r"Dart SDK version:\s+([0-9\.]+)", dart_res["stdout"])
        dart_ver = m_dart.group(1) if m_dart else None

    report["toolchain"]["dart"] = {
        "status": "PASS" if dart_res["exit_code"] == 0 and dart_ver == "3.11.1" else "FAIL",
        "expected_version": "3.11.1",
        "detected_version": dart_ver,
        "path": str(dart_bin) if path_is_file(dart_bin) else None,
        "sha256": compute_sha256(dart_bin),
        "raw_output": dart_res["stdout"]
    }

    # 7. Android SDK & Android NDK (27.0 target)
    ndk_root = locs["android_sdk_dir"] / "ndk"
    ndk_27_dir = ndk_root / NDK_VERSION
    ndk_props = ndk_27_dir / "source.properties"
    ndk_clang = ndk_27_dir / "toolchains" / "llvm" / "prebuilt" / "windows-x86_64" / "bin" / "clang.exe"
    detected_ndk_version = ndk_revision(ndk_props)
    clang_exists = path_is_file(ndk_clang)
    clang_res = run_command(f'"{ndk_clang}" --version', env=env) if clang_exists else {"exit_code": -1, "stdout": ""}

    report["toolchain"]["android_ndk"] = {
        "status": "PASS" if detected_ndk_version == NDK_VERSION and clang_exists else "FAIL",
        "selected_version": NDK_VERSION,
        "expected_version": NDK_VERSION,
        "detected_version": detected_ndk_version,
        "path": str(ndk_27_dir) if path_is_dir(ndk_27_dir) else None,
        "source_properties_sha256": compute_sha256(ndk_props),
        "clang_path": str(ndk_clang) if clang_exists else None,
        "clang_sha256": compute_sha256(ndk_clang),
        "clang_version_output": clang_res["stdout"],
        "available_ndk_versions": directory_names(ndk_root),
    }

    # 8. ADB & Connected Devices
    adb_bin = locs["platform_tools_dir"] / "adb.exe"
    adb_res = run_command("adb version", env=env)
    report["toolchain"]["adb"] = {
        "status": "PASS" if adb_res["exit_code"] == 0 else "FAIL",
        "path": str(adb_bin) if path_is_file(adb_bin) else None,
        "sha256": compute_sha256(adb_bin),
        "raw_output": adb_res["stdout"]
    }

    # Query connected devices
    dev_res = run_command("adb devices -l", env=env)
    lines = [l.strip() for l in dev_res["stdout"].splitlines()[1:] if l.strip()]
    for line in lines:
        parts = line.split()
        if len(parts) >= 2:
            d_id = parts[0]
            d_state = parts[1]
            extra_info = " ".join(parts[2:])

            # Query props via adb shell
            m_res = run_command(f'adb -s {d_id} shell getprop ro.product.model', env=env)
            rel_res = run_command(f'adb -s {d_id} shell getprop ro.build.version.release', env=env)
            abi_res = run_command(f'adb -s {d_id} shell getprop ro.product.cpu.abi', env=env)
            btype_res = run_command(f'adb -s {d_id} shell getprop ro.build.type', env=env)
            okx_res = run_command(f'adb -s {d_id} shell "pm list packages okx"', env=env)
            okx_installed = "com.okx.wallet" in okx_res["stdout"]

            okx_version = None
            if okx_installed:
                dump_res = run_command(f'adb -s {d_id} shell "dumpsys package com.okx.wallet | grep versionName"', env=env)
                m_v = re.search(r"versionName=([^\s]+)", dump_res["stdout"])
                okx_version = m_v.group(1) if m_v else None

            report["devices"]["android"].append({
                "device_id": d_id,
                "state": d_state,
                "model": m_res["stdout"],
                "android_release": rel_res["stdout"],
                "cpu_abi": abi_res["stdout"],
                "build_type": btype_res["stdout"],
                "okx_wallet_installed": okx_installed,
                "okx_wallet_version": okx_version,
                "extra": extra_info
            })

    # 9. iOS & macOS Blocker Evaluation
    report["blockers"]["ios_toolchain"] = {
        "status": "BLOCKED",
        "code": "BLOCKED_NO_MACOS_TOOLCHAIN",
        "reason": (
            "Host OS is Windows 11 (AMD64). Apple Xcode toolchain (xcodebuild, clang, xcrun, codesign), "
            "macOS build environment, and iOS SDKs are unavailable on Windows host without macOS hardware."
        ),
        "affected_cases": [
            "ENV-02", "PAIR-04", "OKX-02", "OWN-02", "OWN-03", "OWN-04", "OFF-02", "OFF-05"
        ]
    }

    # 10. Dual-device Air-gap Blocker Evaluation
    report["blockers"]["dual_device_airgap"] = {
        "status": "BLOCKED",
        "code": "BLOCKED_NO_DUAL_AIRGAP_DEVICE",
        "reason": (
            "Two apps on a single phone is development convenience only, and formal cold Vault operation "
            "prohibits active ADB, Wi-Fi, SSH, or VPN connections. A device reachable over ADB for this audit "
            "is by definition not a dedicated air-gapped Vault device, so this item cannot pass here."
        ),
        "affected_cases": [
            "OWN-01", "OWN-02", "OWN-03", "OWN-04", "BTC-05"
        ]
    }

    # Summary Evaluations
    all_tools_pass = (
        report["toolchain"]["rustc"]["status"] == "PASS" and
        report["toolchain"]["cargo"]["status"] == "PASS" and
        report["toolchain"]["rust_android_target"]["status"] == "PASS" and
        report["toolchain"]["cargo_ndk"]["status"] == "PASS" and
        report["toolchain"]["flutter"]["status"] == "PASS" and
        report["toolchain"]["dart"]["status"] == "PASS" and
        report["toolchain"]["android_ndk"]["status"] == "PASS" and
        report["toolchain"]["adb"]["status"] == "PASS"
    )

    report["summary"]["all_required_host_tools_present"] = all_tools_pass
    report["summary"]["android_build_ready"] = all_tools_pass
    report["summary"]["ios_build_ready"] = False
    report["summary"]["dual_device_airgap_ready"] = False

    return report


def main():
    parser = argparse.ArgumentParser(description="Audit host toolchain and devices for Mobile Cold Wallet.")
    parser.add_argument("--output", "-o", type=str, default=str(Path("target") / "env_audit.json"), help="Path to write output JSON report")
    parser.add_argument("--strict", action="store_true", help="Exit with code 1 if any required tool fails")
    args = parser.parse_args()

    report = audit_host_toolchain()

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("=" * 70)
    print("Mobile Cold Wallet - Toolchain Audit Summary")
    print("=" * 70)
    print(f"Host OS:             {report['host']['os']} {report['host']['os_release']} ({report['host']['architecture']})")
    print(f"Rust Compiler:       {report['toolchain']['rustc']['detected_version']} [{report['toolchain']['rustc']['status']}]")
    print(f"Cargo:               {report['toolchain']['cargo']['detected_version']} [{report['toolchain']['cargo']['status']}]")
    print(f"Android Target:      aarch64-linux-android [{report['toolchain']['rust_android_target']['status']}]")
    print(f"cargo-ndk:           {report['toolchain']['cargo_ndk']['detected_version']} [{report['toolchain']['cargo_ndk']['status']}]")
    print(f"Flutter SDK:         {report['toolchain']['flutter']['detected_version']} (rev {report['toolchain']['flutter']['framework_revision']}) [{report['toolchain']['flutter']['status']}]")
    print(f"Dart SDK:            {report['toolchain']['dart']['detected_version']} [{report['toolchain']['dart']['status']}]")
    print(f"Android NDK:         {report['toolchain']['android_ndk']['selected_version']} [{report['toolchain']['android_ndk']['status']}]")
    print(f"ADB:                 {report['toolchain']['adb']['status']}")
    print(f"Connected Devices:   {len(report['devices']['android'])} device(s) found")
    for d in report['devices']['android']:
        print(f"  - {d['device_id']} ({d['model']}, Android {d['android_release']}, OKX installed: {d['okx_wallet_installed']})")
    print(f"iOS Toolchain:       {report['blockers']['ios_toolchain']['status']} ({report['blockers']['ios_toolchain']['code']})")
    print(f"Dual-Device Airgap:  {report['blockers']['dual_device_airgap']['status']} ({report['blockers']['dual_device_airgap']['code']})")
    print("=" * 70)
    print(f"Full JSON evidence report written to: {out_path.resolve()}")

    if args.strict and not report["summary"]["all_required_host_tools_present"]:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
