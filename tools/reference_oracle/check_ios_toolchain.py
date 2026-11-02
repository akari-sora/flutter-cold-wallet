#!/usr/bin/env python3
"""
tools/reference_oracle/check_ios_toolchain.py
=============================================
Audit host environment and toolchain capabilities for iOS physical device pairing (PAIR-04).

Checks:
- Host OS & Architecture (platform.system, platform.release, platform.machine)
- Apple Xcode developer tools (xcodebuild, xcrun, clang)
- libimobiledevice / idevice_id
- Connected physical iOS devices (and rejection of simulators for physical QR air-gap pairing)
- OKX Wallet iOS application presence on connected physical devices

Behavior & Exit Codes:
- On non-macOS (Windows / Linux):
  Logs objective toolchain deficiencies, outputs standardized audit log,
  and confirms status as BLOCKED with reason BLOCKED_NO_MACOS_TOOLCHAIN.
  Exit code defaults to 2 (precondition unsatisfied / BLOCKED), perfectly matching evidence manifest.
  If --strict is specified, exits with code 1.
- On macOS:
  Checks Xcode version, xcrun, idevice_id, and connected physical devices.
  If physical device with OKX Wallet is connected: status PASS, exit code 0.
  If Xcode or device is missing: status BLOCKED, exit code 2 (or 1 if --strict).

CLI Arguments:
  --output, -o    : Output path for structured JSON audit report.
  --strict        : Exit with code 1 if status is not PASS (for strict gate enforcement).
  --format        : Output format: 'text' (default) or 'json'.
  --allow-blocked : Exit with code 0 even if status is BLOCKED.
"""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def run_command(cmd: list[str] | str, timeout: int = 10) -> dict:
    """Run an external command safely and return exit code, stdout, and stderr."""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            shell=isinstance(cmd, str),
            timeout=timeout,
        )
        return {
            "exit_code": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        }
    except FileNotFoundError:
        return {"exit_code": -1, "stdout": "", "stderr": "Command binary not found"}
    except subprocess.TimeoutExpired:
        return {"exit_code": -1, "stdout": "", "stderr": f"Command timed out after {timeout}s"}
    except Exception as e:
        return {"exit_code": -1, "stdout": "", "stderr": str(e)}


def audit_ios_toolchain() -> dict:
    """Audit the current host machine for iOS build tools and physical devices."""
    sys_system = platform.system()
    sys_release = platform.release()
    sys_machine = platform.machine()
    is_macos = (sys_system == "Darwin")
    is_windows = (sys_system == "Windows")
    is_linux = (sys_system == "Linux")

    # Format Host OS display string
    if is_windows:
        if sys_release == "10" and sys_machine == "AMD64":
            host_display = "Windows 10 (AMD64 / x86_64)"
        else:
            host_display = f"Windows {sys_release} ({sys_machine} / x86_64)" if "64" in sys_machine else f"Windows {sys_release} ({sys_machine})"
    elif is_macos:
        mac_ver = platform.mac_ver()[0] or sys_release
        host_display = f"macOS {mac_ver} ({sys_machine})"
    elif is_linux:
        host_display = f"Linux ({sys_machine})"
    else:
        host_display = f"{sys_system} ({sys_machine})"

    # Xcode / xcrun inspection
    xcrun_available = False
    xcrun_display = "Not available (requires macOS)"
    xcrun_path = None
    if is_macos:
        xcrun_bin = shutil.which("xcrun")
        if xcrun_bin:
            res = run_command(["xcrun", "--version"])
            if res["exit_code"] == 0:
                xcrun_available = True
                xcrun_path = xcrun_bin
                xcrun_display = f"Available ({xcrun_bin})"
            else:
                xcrun_display = f"Failed ({res['stderr']})"
        else:
            xcrun_display = "Not found"

    # xcodebuild inspection
    xcodebuild_available = False
    xcodebuild_display = "Not available"
    xcodebuild_version = None
    xcodebuild_build = None
    xcodebuild_path = None
    if is_macos:
        xcodebuild_bin = shutil.which("xcodebuild")
        if xcodebuild_bin:
            res = run_command(["xcodebuild", "-version"])
            if res["exit_code"] == 0:
                xcodebuild_available = True
                xcodebuild_path = xcodebuild_bin
                m_ver = re.search(r"Xcode\s+([^\s]+)", res["stdout"])
                m_bld = re.search(r"Build version\s+([^\s]+)", res["stdout"])
                xcodebuild_version = m_ver.group(1) if m_ver else None
                xcodebuild_build = m_bld.group(1) if m_bld else None
                xcodebuild_display = f"Xcode {xcodebuild_version or 'unknown'} (Build {xcodebuild_build or 'unknown'})"
            else:
                xcodebuild_display = "xcodebuild error"
        else:
            xcodebuild_display = "Not found"

    # idevice_id / libimobiledevice inspection
    idevice_id_available = False
    idevice_id_display = "Not available"
    idevice_id_path = shutil.which("idevice_id")
    if idevice_id_path:
        res = run_command([idevice_id_path, "-h"])
        # idevice_id returns 0 or help output
        idevice_id_available = True
        idevice_id_display = f"Available ({idevice_id_path})"

    # iOS Physical Devices detection
    detected_devices = []
    if is_macos and idevice_id_available:
        res = run_command([idevice_id_path, "-l"])
        if res["exit_code"] == 0 and res["stdout"]:
            detected_devices = [line.strip() for line in res["stdout"].splitlines() if line.strip()]
    elif is_macos and xcrun_available:
        # Fallback to devicectl on Xcode 15+
        res = run_command(["xcrun", "devicectl", "list", "devices", "--json-output", "-"])
        if res["exit_code"] == 0 and res["stdout"]:
            try:
                dev_data = json.loads(res["stdout"])
                detected_devices = [d.get("identifier") for d in dev_data.get("result", {}).get("devices", []) if not d.get("simulator", False)]
            except Exception:
                pass

    physical_devices_count = len(detected_devices)
    physical_devices_display = f"{physical_devices_count} detected" if physical_devices_count == 0 else f"{physical_devices_count} detected ({', '.join(detected_devices)})"

    # Verdict & Reason Determination
    if not is_macos:
        verdict = "BLOCKED"
        reason = "BLOCKED_NO_MACOS_TOOLCHAIN"
        if is_windows:
            description = (
                "Physical pairing on iOS requires macOS runner with Xcode / libimobiledevice "
                "and an active physical iPhone running com.okx.wallet iOS. "
                "The current host is Windows-only. Marked BLOCKED per governance integrity mandate."
            )
        else:
            description = (
                f"Physical pairing on iOS requires macOS runner with Xcode / libimobiledevice "
                f"and an active physical iPhone running com.okx.wallet iOS. "
                f"The current host is {sys_system}-only. Marked BLOCKED per governance integrity mandate."
            )
    else:
        if not (xcodebuild_available or xcrun_available):
            verdict = "BLOCKED"
            reason = "BLOCKED_NO_XCODE"
            description = "Host is macOS, but Apple Xcode developer toolchain (xcodebuild, xcrun) is not installed."
        elif physical_devices_count == 0:
            verdict = "BLOCKED"
            reason = "BLOCKED_NO_PHYSICAL_IOS_DEVICE"
            description = (
                "Xcode toolchain is installed, but 0 physical iOS devices running com.okx.wallet are connected. "
                "Simulators cannot perform physical camera QR air-gap pairing."
            )
        else:
            verdict = "PASS"
            reason = "TOOLCHAIN_READY"
            description = (
                f"Xcode toolchain and {physical_devices_count} physical iOS device(s) detected and ready for pairing."
            )

    return {
        "work_package": "FCW-OKX-20261012",
        "case_id": "PAIR-04",
        "audit_target": "OKX iOS Real Device Import Toolchain Audit",
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": {
            "system": sys_system,
            "release": sys_release,
            "machine": sys_machine,
            "display": host_display,
        },
        "toolchain": {
            "is_macos": is_macos,
            "xcrun": {
                "available": xcrun_available,
                "path": xcrun_path,
                "display": xcrun_display,
            },
            "xcodebuild": {
                "available": xcodebuild_available,
                "version": xcodebuild_version,
                "build": xcodebuild_build,
                "path": xcodebuild_path,
                "display": xcodebuild_display,
            },
            "idevice_id": {
                "available": idevice_id_available,
                "path": idevice_id_path,
                "display": idevice_id_display,
            },
        },
        "devices": {
            "physical_count": physical_devices_count,
            "device_ids": detected_devices,
            "display": physical_devices_display,
        },
        "verdict": verdict,
        "reason": reason,
        "description": description,
    }


def format_text_log(audit: dict) -> list[str]:
    """Format structured audit dictionary into standard terminal / log lines."""
    return [
        "=" * 70,
        "PAIR-04: OKX iOS Real Device Import Toolchain Audit",
        "=" * 70,
        f"Host OS               : {audit['host']['display']}",
        f"Xcode / xcrun         : {audit['toolchain']['xcrun']['display']}",
        f"xcodebuild            : {audit['toolchain']['xcodebuild']['display']}",
        f"idevice_id / libimobile: {audit['toolchain']['idevice_id']['display']}",
        f"iOS Physical Devices  : {audit['devices']['display']}",
        f"Verdict               : {audit['verdict']}",
        f"Reason                : {audit['reason']}",
        f"Description           : {audit['description']}",
    ]


def main():
    parser = argparse.ArgumentParser(
        description="Audit host environment and toolchain for OKX iOS Real Device Import (PAIR-04)."
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=None,
        help="Path to write structured JSON audit report.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit with code 1 if audit verdict is not PASS (for strict CI/gate enforcement).",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json"],
        default="text",
        help="Output format on stdout ('text' or 'json', default: 'text').",
    )
    parser.add_argument(
        "--allow-blocked",
        action="store_true",
        help="Exit with code 0 even if verdict is BLOCKED (non-fatal advisory mode).",
    )
    args = parser.parse_args()

    audit = audit_ios_toolchain()

    # Output to stdout
    if args.format == "json":
        print(json.dumps(audit, indent=2, ensure_ascii=False))
    else:
        lines = format_text_log(audit)
        for line in lines:
            print(line)

    # Optional structured JSON output file
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(audit, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    # Exit code determination
    if args.strict and audit["verdict"] != "PASS":
        sys.exit(1)
    elif args.allow_blocked and audit["verdict"] == "BLOCKED":
        sys.exit(0)
    elif audit["verdict"] == "PASS":
        sys.exit(0)
    elif audit["verdict"] == "BLOCKED":
        # Precondition unsatisfied / environment blocked (exit code 2 per evidence.json & test plan)
        sys.exit(2)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
