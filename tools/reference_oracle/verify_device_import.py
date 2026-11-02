#!/usr/bin/env python3
"""
tools/reference_oracle/verify_device_import.py
==============================================
Validates Samsung S24 Ultra com.okx.wallet pairing import (PAIR-03).
Parses S24 Ultra UI hierarchy XML dumps (window_dump.xml / account_select.xml),
extracts EVM addresses shown on screen, and asserts match against
Reference Oracle Vector 1 (default: 0x9858EfFD232B4033E47d90003D41EC34EcaEda94).

Supports:
- CLI flags: --xml, --expected, --output, --allow-abbreviated
- Full 42-character 0x[a-fA-F0-9]{40} EVM address extraction
- Case-insensitive & EIP-55 checksum matching
- Abbreviated address extraction (0x[a-fA-F0-9]{4}...[a-fA-F0-9]{4}) via --allow-abbreviated
- Fail-Closed design: non-zero exit code (sys.exit(1)) on file missing, malformed XML, or address mismatch.
"""

import re
import sys
import json
import argparse
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional, Dict, Any, List


DEFAULT_EXPECTED_ADDRESS = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
# Backwards compatibility alias
EXPECTED_ADDRESS = DEFAULT_EXPECTED_ADDRESS


def is_valid_evm_address(address: str) -> bool:
    """Checks if string is a valid 42-character hexadecimal EVM address."""
    if not isinstance(address, str):
        return False
    clean = address.strip()
    return bool(re.fullmatch(r"0x[a-fA-F0-9]{40}", clean))


def verify_import(
    xml_path: Path,
    output_path: Optional[Path] = None,
    expected_address: str = DEFAULT_EXPECTED_ADDRESS,
    allow_abbreviated: bool = True,
    exit_on_verdict: bool = True,
) -> Dict[str, Any]:
    """
    Parses an Android UI hierarchy XML file and verifies whether expected_address is displayed.

    Parameters:
        xml_path: Path to the XML dump file.
        output_path: Optional path to write JSON comparison report.
        expected_address: The target EVM address to match against.
        allow_abbreviated: Whether to allow matching abbreviated addresses (e.g. 0x9858...da94).
                           Defaults to True for programmatic/test API backward compatibility.
        exit_on_verdict: Whether to terminate process with sys.exit(0) on PASS or sys.exit(1) on FAIL.

    Returns:
        Dict report containing comparison metrics and verdict.
    """
    xml_path = Path(xml_path)
    if output_path is not None:
        output_path = Path(output_path)

    expected_clean = expected_address.strip() if isinstance(expected_address, str) else ""

    # Fail-closed check 1: Target XML file existence
    if not xml_path.is_file():
        err_msg = f"UI hierarchy dump not found at {xml_path}"
        report = {
            "expected_address": expected_clean,
            "allow_abbreviated": allow_abbreviated,
            "found_full_addresses": [],
            "found_abbreviated_addresses": [],
            "matched_exact": False,
            "matched_case_insensitive": False,
            "matched_abbreviated": False,
            "matched_address": None,
            "verdict": "FAIL",
            "error": err_msg,
        }
        _write_report(report, output_path)
        print(f"[!] ERROR: {err_msg}", file=sys.stderr)
        if exit_on_verdict:
            sys.exit(1)
        return report

    # Fail-closed check 2: Expected address validity
    if not is_valid_evm_address(expected_clean):
        err_msg = f"Invalid expected EVM address format: '{expected_address}' (must be 42-char hex starting with 0x)"
        report = {
            "expected_address": expected_clean,
            "allow_abbreviated": allow_abbreviated,
            "found_full_addresses": [],
            "found_abbreviated_addresses": [],
            "matched_exact": False,
            "matched_case_insensitive": False,
            "matched_abbreviated": False,
            "matched_address": None,
            "verdict": "FAIL",
            "error": err_msg,
        }
        _write_report(report, output_path)
        print(f"[!] ERROR: {err_msg}", file=sys.stderr)
        if exit_on_verdict:
            sys.exit(1)
        return report

    # Fail-closed check 3: XML syntax parsing
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except Exception as e:
        err_msg = f"Failed to parse XML hierarchy dump at {xml_path}: {e}"
        report = {
            "expected_address": expected_clean,
            "allow_abbreviated": allow_abbreviated,
            "found_full_addresses": [],
            "found_abbreviated_addresses": [],
            "matched_exact": False,
            "matched_case_insensitive": False,
            "matched_abbreviated": False,
            "matched_address": None,
            "verdict": "FAIL",
            "error": err_msg,
        }
        _write_report(report, output_path)
        print(f"[!] ERROR: {err_msg}", file=sys.stderr)
        if exit_on_verdict:
            sys.exit(1)
        return report

    found_addresses = set()
    found_abbrevs = set()
    full_addr_regex = re.compile(r"0x[a-fA-F0-9]{40}")
    # Matches 0x9858...da94, 0x9858...Eda94, or Unicode ellipsis …
    abbrev_addr_regex = re.compile(r"0x[a-fA-F0-9]{4,6}(?:\.\.\.|…)[a-fA-F0-9]{4,6}")

    # Inspect all elements in hierarchy (both 'text' and 'content-desc' attributes)
    for elem in root.iter():
        text = elem.attrib.get("text", "")
        desc = elem.attrib.get("content-desc", "")
        for target in [text, desc]:
            if not target:
                continue
            for m in full_addr_regex.findall(target):
                found_addresses.add(m)
            for m in abbrev_addr_regex.findall(target):
                found_abbrevs.add(m)

    matched_exact = False
    matched_case_insensitive = False
    matched_abbrev = False
    matched_str = None

    # Step A: Evaluate full 42-character matches
    for addr in sorted(found_addresses):
        if addr == expected_clean:
            matched_exact = True
            matched_case_insensitive = True
            matched_str = addr
            break
        elif addr.lower() == expected_clean.lower():
            matched_case_insensitive = True
            matched_str = addr

    # Step B: Evaluate abbreviated matches if enabled and full match was not found
    if not (matched_exact or matched_case_insensitive) and allow_abbreviated:
        prefix = expected_clean[:6].lower()
        suffix = expected_clean[-4:].lower()
        for abbrev in sorted(found_abbrevs):
            clean = abbrev.lower()
            if clean.startswith(prefix) and clean.endswith(suffix):
                matched_abbrev = True
                matched_str = abbrev
                break

    is_pass = matched_exact or matched_case_insensitive or (allow_abbreviated and matched_abbrev)
    verdict = "PASS" if is_pass else "FAIL"

    report = {
        "expected_address": expected_clean,
        "allow_abbreviated": allow_abbreviated,
        "found_full_addresses": sorted(list(found_addresses)),
        "found_abbreviated_addresses": sorted(list(found_abbrevs)),
        "matched_exact": matched_exact,
        "matched_case_insensitive": matched_case_insensitive,
        "matched_abbreviated": matched_abbrev,
        "matched_address": matched_str,
        "verdict": verdict,
    }

    _write_report(report, output_path)

    print("=" * 70)
    print("S24 Ultra OKX Import Verification Report (PAIR-03)")
    print("=" * 70)
    print(f"Target XML File     : {xml_path}")
    print(f"Expected Address    : {expected_clean}")
    print(f"Allow Abbreviated   : {allow_abbreviated}")
    print(f"Full Addresses Found: {report['found_full_addresses']}")
    print(f"Abbrev Addrs Found  : {report['found_abbreviated_addresses']}")
    print(f"Matched String      : {matched_str}")
    print(f"Verdict             : {report['verdict']}")
    if output_path is not None:
        print(f"Report written to   : {output_path}")

    if verdict != "PASS":
        print(f"\n[!] ERROR: Expected address {expected_clean} not found in UI dump!")
        if found_abbrevs and not allow_abbreviated:
            print("    [Hint] Abbreviated address(es) were found on screen. Re-run with --allow-abbreviated if abbreviated match is acceptable.")
        if exit_on_verdict:
            sys.exit(1)
        return report

    print("\n[+] PAIR-03 verification SUCCESS: Address matches Oracle derivation!")
    if exit_on_verdict:
        sys.exit(0)
    return report


def _write_report(report: Dict[str, Any], output_path: Optional[Path]):
    """Helper to persist JSON comparison report."""
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")


def find_repo_root() -> Path:
    """Finds the mobile_cold_wallet repo root dynamically."""
    current = Path(__file__).resolve()
    for parent in [current] + list(current.parents):
        if (parent / "Cargo.toml").is_file() and (parent / "apps").is_dir():
            return parent
    return Path(__file__).resolve().parent.parent.parent


def main():
    repo_root = find_repo_root()
    default_xml = repo_root / "tests" / "fixtures" / "okx_ui_dump" / "window_dump.xml"
    default_output = repo_root / "target" / "verify_device_import" / "address_comparison.json"

    parser = argparse.ArgumentParser(
        description="Validates Samsung S24 Ultra com.okx.wallet pairing import (PAIR-03)."
    )
    parser.add_argument(
        "--xml",
        type=Path,
        default=default_xml,
        help=f"Path to UI hierarchy XML dump (default: {default_xml})",
    )
    parser.add_argument(
        "--expected",
        type=str,
        default=DEFAULT_EXPECTED_ADDRESS,
        help=f"Expected EVM address (default: {DEFAULT_EXPECTED_ADDRESS})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=default_output,
        help=f"Path to output JSON report (default: {default_output})",
    )
    parser.add_argument(
        "--allow-abbreviated",
        action="store_true",
        default=False,
        help="Allow matching abbreviated EVM address format e.g. 0x9858...da94 (default: False)",
    )

    args = parser.parse_args()

    verify_import(
        xml_path=args.xml,
        output_path=args.output,
        expected_address=args.expected,
        allow_abbreviated=args.allow_abbreviated,
        exit_on_verdict=True,
    )


if __name__ == "__main__":
    main()
