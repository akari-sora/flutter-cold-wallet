#!/usr/bin/env python3
"""
tools/nfc_probe/run_nfc_probe.py
================================
Bidirectional NFC Hardware Probe between two Android devices (e.g. S24 Ultra and S8).

Features:
- Audits device connectivity, distinct hardware serials, and NFC hardware features
  (android.hardware.nfc, android.hardware.nfc.hce).
- Gated execution: Verifies exit codes and stderr of all ADB, PM, and AM commands.
- Brings the plain launcher Activity to the foreground, then activates the run through the
  debug-only, Binder-authenticated `TestControlProvider` (`adb shell content call`) and reads back
  the ACK the App actually adopted (run_id/role/phase/generation/token); a missing, rejected or
  unapplied ACK fails the run (`FAIL_CONTROL_ACK`).
- Bounded monotonic deadline polling for RF events strictly isolated by `target_run_id`,
  with per-call ADB timeouts bounded to remaining deadline.
- Strict verification with mandatory fields: every intermediate Reader event (`pass is True`,
  SWs, strict-int byte/chunk counts, echo flags, SHA-256), generation and token equal to each
  device's ACK, exact event order/multiplicity, strictly increasing positive `event_seq` on both
  Reader and HCE without fallback sorting, terminal `PROBE_RUN_COMPLETE` uniqueness/finality,
  and per-chunk + per-digest HCE interaction verification (37 chunk events segmented as 1x32B,
  4x128B, 32x128B with exact `chunk_index`, `bytes`, `total_accumulated`, and 3 digests whose
  `total_bytes`, `chunks`, and `sha256` match the Reader's in order).
- Preserves duplicate log lines in snapshots (no silent deduplication), reports ADB logcat
  failures as `FAIL_LOG_OBSERVATION`, rejects malformed JSON log lines (`FAIL_MALFORMED_PROBE_LOG`),
  and clears/overwrites any pre-existing report before execution so stale `PASS` sentinels can
  never survive ADB errors.
"""

import sys
import os
import re
import time
import json
import uuid
import argparse
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple, Set

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
# Automation needs the debug APK: only it contains the Binder-authenticated TestControlProvider.
# The release/offline APK is operated manually from its UI (see tools/nfc_probe/README.md).
DEFAULT_APK_PATH = PROJECT_ROOT / "tools" / "nfc_probe" / "build" / "app" / "outputs" / "flutter-apk" / "app-debug.apk"
DEFAULT_EVIDENCE_DIR = PROJECT_ROOT / "target" / "nfc_probe" / "run-01"

REQUIRED_PROBE_EVENTS = [
    "SELECT_AID_RESULT",
    "TEST_32B",
    "TEST_512B",
    "TEST_4KIB",
    "TEST_NEGATIVE_ROUTING_UNKNOWN_AID",
    "TEST_NEGATIVE_SERVICE_INVALID_INS",
    "TEST_NEGATIVE_SERVICE_INVALID_P1",
    "TEST_NEGATIVE_SERVICE_OVERSIZED_CHUNK",
]

REQUIRED_HCE_EVENTS = [
    "HCE_SELECT_AID",
    "HCE_CHUNK_RECEIVED",
    "HCE_DIGEST_REQUESTED",
]

FORBIDDEN_READER_FAILURE_EVENTS = {
    "ISODEP_EXCEPTION",
    "STALE_SESSION_ABORTED",
    "PROBE_CANCELLED",
    "PROBE_RUN_DISCARDED_STALE",
}

HEX64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def run_adb(cmd_args: List[str], device_id: Optional[str] = None, timeout: float = 30.0) -> subprocess.CompletedProcess:
    full_cmd = ["adb"]
    if device_id:
        full_cmd.extend(["-s", device_id])
    full_cmd.extend(cmd_args)
    try:
        return subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(
            args=full_cmd,
            returncode=-1,
            stdout="",
            stderr=f"ADB command timed out after {timeout}s: {e}"
        )


def get_connected_devices() -> List[str]:
    res = run_adb(["devices"])
    if res.returncode != 0:
        return []
    devices = []
    for line in res.stdout.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(parts[0])
    return devices


def check_device_nfc_state(device_id: str) -> Dict[str, Any]:
    res_model = run_adb(["shell", "getprop", "ro.product.model"], device_id=device_id)
    if res_model.returncode != 0 or not res_model.stdout.strip():
        return {
            "device_id": device_id,
            "connected": False,
            "model": "UNKNOWN",
            "hardware_serial": "",
            "nfc_state_on": False,
            "feature_nfc": False,
            "feature_hce": False,
            "error": res_model.stderr.strip() or "Device offline or unresponsive"
        }

    model = res_model.stdout.strip()
    res_serial = run_adb(["shell", "getprop", "ro.serialno"], device_id=device_id)
    hw_serial = res_serial.stdout.strip() if res_serial.returncode == 0 else ""

    res_dumpsys = run_adb(["shell", "dumpsys", "nfc"], device_id=device_id)
    out_dumpsys = res_dumpsys.stdout
    state_on = ("mState=on" in out_dumpsys or "mState=ON" in out_dumpsys)

    res_feat = run_adb(["shell", "pm", "list", "features"], device_id=device_id)
    out_feat = res_feat.stdout
    has_nfc = "android.hardware.nfc" in out_feat
    has_hce = "android.hardware.nfc.hce" in out_feat

    return {
        "device_id": device_id,
        "connected": True,
        "model": model,
        "hardware_serial": hw_serial,
        "nfc_state_on": state_on,
        "feature_nfc": has_nfc,
        "feature_hce": has_hce,
    }


def install_probe_apk(apk_path: Path, device_id: str) -> Tuple[bool, str]:
    if not apk_path.is_file():
        return False, f"APK file not found at {apk_path}"
    print(f"[*] Installing probe APK to {device_id}...")
    res = run_adb(["install", "-r", str(apk_path)], device_id=device_id, timeout=90.0)
    if res.returncode == 0 and "Success" in res.stdout:
        print(f"[+] Installed successfully on {device_id}")
        return True, "SUCCESS"
    else:
        err = res.stderr.strip() or res.stdout.strip()
        print(f"[-] Installation failed on {device_id}: {err}")
        return False, err


PACKAGE = "com.mobilecoldwallet.nfc_probe"
CONTROL_URI = "content://com.mobilecoldwallet.nfc_probe.testcontrol"
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
ACK_JSON_RE = re.compile(r"ack_json=(\{.*\})\}\]\s*$", re.DOTALL)


def _is_strict_int(val: Any) -> bool:
    return type(val) is int


def _is_positive_int(val: Any) -> bool:
    return type(val) is int and val > 0


def _int_equals(val: Any, expected: int) -> bool:
    return type(val) is int and val == expected


def _is_strict_true(val: Any) -> bool:
    return type(val) is bool and val is True


def _is_valid_sha256_hex(val: Any) -> bool:
    return isinstance(val, str) and bool(HEX64_RE.match(val))


def parse_control_ack(stdout: str) -> Optional[Dict[str, Any]]:
    """Parses `adb shell content call` output: `Result: Bundle[{ack_json={...}}]`."""
    text = stdout.strip()
    m = ACK_JSON_RE.search(text)
    if not m:
        return None
    try:
        ack = json.loads(m.group(1))
    except json.JSONDecodeError:
        return None
    return ack if isinstance(ack, dict) else None


def validate_control_ack(ack: Optional[Dict[str, Any]], role: str, run_id: str, phase: str) -> Optional[str]:
    """Returns None if the App-reported ACK proves it adopted exactly the requested run, else a reason."""
    if ack is None or not isinstance(ack, dict):
        return "no parseable ack_json in content call output"
    if not _is_strict_true(ack.get("ack")):
        return f"controller rejected request: {ack.get('reason')}"
    for key, expected in (("run_id", run_id), ("role", role), ("phase", phase)):
        if ack.get(key) != expected:
            return f"ack {key}={ack.get(key)!r} != requested {expected!r}"
    if not _is_positive_int(ack.get("generation")) or not _is_positive_int(ack.get("token")):
        return f"ack generation/token not positive integers: {ack.get('generation')!r}/{ack.get('token')!r}"
    for flag in ("applied_to_activity", "activity_resumed", "session_stable"):
        if not _is_strict_true(ack.get(flag)):
            return f"ack {flag} is not True"
    if role == "READER" and not _is_strict_true(ack.get("reader_mode_active")):
        return "ack reader_mode_active is not True for READER"
    if role == "HCE" and not _is_strict_true(ack.get("vault_armed")):
        return "ack vault_armed is not True for HCE"
    return None


def launch_probe_activity(
    device_id: str, role: str, run_id: str, phase: str = "phase1"
) -> Tuple[bool, str, Optional[Dict[str, Any]]]:
    """
    1. force-stop + clear logcat,
    2. bring the plain launcher MainActivity to the foreground (no extras; MainActivity rejects any),
    3. activate the run through the debug-only, Binder-authenticated TestControlProvider and read
       back the ACK the App actually adopted (run_id/role/phase/generation/token).
    Returns (ok, error_kind_or_OK, ack).
    """
    if role not in ("READER", "HCE") or not SAFE_ID_RE.match(run_id) or not SAFE_ID_RE.match(phase):
        return False, "FAIL_CONTROL_ACK: invalid role/run_id/phase requested by runner", None

    stop_res = run_adb(["shell", "am", "force-stop", PACKAGE], device_id=device_id)
    if stop_res.returncode != 0:
        return False, f"FAIL_AM_START: force-stop failed: {stop_res.stderr.strip()}", None

    clear_res = run_adb(["shell", "logcat", "-c"], device_id=device_id)
    if clear_res.returncode != 0:
        return False, f"FAIL_AM_START: logcat -c failed: {clear_res.stderr.strip()}", None

    start_res = run_adb(["shell", "am", "start", "-W", "-n", f"{PACKAGE}/.MainActivity"], device_id=device_id)
    combined = (start_res.stdout or "") + (start_res.stderr or "")
    if start_res.returncode != 0 or "Error" in combined or "Exception" in combined:
        return False, f"FAIL_AM_START: am start failed: {combined.strip()}", None

    # Give the Flutter activity time to reach RESUMED before activating the run.
    time.sleep(1.5)

    call_res = run_adb([
        "shell", "content", "call",
        "--uri", CONTROL_URI,
        "--method", "activate_run",
        "--extra", f"role:s:{role}",
        "--extra", f"run_id:s:{run_id}",
        "--extra", f"phase:s:{phase}",
    ], device_id=device_id)
    call_out = (call_res.stdout or "") + (call_res.stderr or "")
    if call_res.returncode != 0 or "Exception" in call_out:
        return False, f"FAIL_CONTROL_ACK: content call failed: {call_out.strip()}", None

    ack = parse_control_ack(call_res.stdout or "")
    reason = validate_control_ack(ack, role, run_id, phase)
    if reason is not None:
        return False, f"FAIL_CONTROL_ACK: {reason}", ack

    print(f"[*] {device_id}: role={role} run_id={run_id} phase={phase} ACK generation={ack['generation']} token={ack['token']}")
    return True, "OK", ack


def _parse_probe_logcat(raw_stdout: str) -> Tuple[List[Dict[str, Any]], List[str]]:
    """
    Parses all `FCW_NFC_PROBE:` lines in snapshot order WITHOUT deduplicating identical events.
    Preserving duplicates ensures repeated identical log lines are caught by multiplicity and
    strictly increasing `event_seq` validation.
    """
    parsed_events: List[Dict[str, Any]] = []
    unparsed_lines: List[str] = []
    for line in raw_stdout.splitlines():
        if "FCW_NFC_PROBE:" in line:
            parts = line.split("FCW_NFC_PROBE:", 1)
            if len(parts) > 1:
                json_str = parts[1].strip()
                if json_str.startswith("{") and json_str.endswith("}"):
                    try:
                        evt = json.loads(json_str)
                        if isinstance(evt, dict):
                            parsed_events.append(evt)
                        else:
                            unparsed_lines.append(line)
                    except json.JSONDecodeError:
                        unparsed_lines.append(line)
                else:
                    unparsed_lines.append(line)
    return parsed_events, unparsed_lines


def poll_probe_completion_checked(
    reader_device_id: str,
    target_run_id: str,
    deadline_sec: float = 10.0,
    poll_interval_sec: float = 0.5
) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]], List[str], bool, Optional[str]]:
    """
    Polls logcat on the Reader device for PROBE_RUN_COMPLETE event strictly matching target_run_id.
    Uses time.monotonic() and bounds each ADB invocation timeout to the remaining deadline.
    Each `logcat -d` call is treated as a full non-deduplicated snapshot of the buffer since `logcat -c`.
    Returns (completion_event, all_parsed_events, raw_unparsed_lines, rf_seen_for_target_run, log_error).
    """
    start_mono = time.monotonic()
    deadline_mono = start_mono + max(0.001, float(deadline_sec))
    parsed_events: List[Dict[str, Any]] = []
    unparsed_lines: List[str] = []
    completion_event: Optional[Dict[str, Any]] = None
    rf_seen = False
    last_log_error: Optional[str] = None
    any_poll_succeeded = False

    first_iter = True
    while first_iter or (time.monotonic() < deadline_mono):
        first_iter = False
        remaining = max(0.05, min(5.0, deadline_mono - time.monotonic()))
        res = run_adb(
            ["shell", "logcat", "-d", "-s", "FCW_NFC_PROBE:I"],
            device_id=reader_device_id,
            timeout=remaining
        )
        if res.returncode == 0:
            any_poll_succeeded = True
            last_log_error = None
            batch_events, batch_unparsed = _parse_probe_logcat(res.stdout)
            parsed_events = batch_events
            for uline in batch_unparsed:
                if uline not in unparsed_lines:
                    unparsed_lines.append(uline)
            for evt in batch_events:
                evt_name = evt.get("event")
                evt_run_id = evt.get("run_id")

                # Strictly scope rf_seen to the active target_run_id (A1)
                if (
                    evt_run_id == target_run_id
                    and evt_name in ("TAG_DISCOVERED", "ISODEP_CONNECTED", "ISODEP_EXCEPTION")
                ):
                    rf_seen = True

                # Record the first PROBE_RUN_COMPLETE for target_run_id; verify_phase_execution
                # checks that PROBE_RUN_COMPLETE appears at most once and is the final event.
                if evt_name == "PROBE_RUN_COMPLETE" and evt_run_id == target_run_id and completion_event is None:
                    completion_event = evt

            if completion_event is not None:
                return completion_event, parsed_events, unparsed_lines, rf_seen, None
        else:
            err_detail = (res.stderr or res.stdout or "").strip()
            last_log_error = f"Reader logcat -d failed on {reader_device_id} (rc={res.returncode}): {err_detail}"

        if time.monotonic() >= deadline_mono:
            break
        time.sleep(min(poll_interval_sec, max(0.0, deadline_mono - time.monotonic())))

    if not any_poll_succeeded and last_log_error is not None:
        return None, parsed_events, unparsed_lines, rf_seen, last_log_error
    return None, parsed_events, unparsed_lines, rf_seen, last_log_error


def poll_probe_completion(
    reader_device_id: str,
    target_run_id: str,
    deadline_sec: float = 10.0,
    poll_interval_sec: float = 0.5
) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]], List[str], bool]:
    comp, evts, unparsed, rf_seen, _ = poll_probe_completion_checked(
        reader_device_id, target_run_id, deadline_sec=deadline_sec, poll_interval_sec=poll_interval_sec
    )
    return comp, evts, unparsed, rf_seen


def read_all_logs_checked(device_id: str, timeout: float = 5.0) -> Tuple[List[Dict[str, Any]], List[str], Optional[str]]:
    res = run_adb(["shell", "logcat", "-d", "-s", "FCW_NFC_PROBE:I"], device_id=device_id, timeout=timeout)
    if res.returncode != 0:
        err_detail = (res.stderr or res.stdout or "").strip()
        return [], [], f"logcat -d failed on {device_id} (rc={res.returncode}): {err_detail}"
    evts, unparsed = _parse_probe_logcat(res.stdout)
    return evts, unparsed, None


def read_all_logs_with_unparsed(device_id: str, timeout: float = 5.0) -> Tuple[List[Dict[str, Any]], List[str]]:
    evts, unparsed, _ = read_all_logs_checked(device_id, timeout=timeout)
    return evts, unparsed


def read_all_logs(device_id: str) -> List[Dict[str, Any]]:
    events, _ = read_all_logs_with_unparsed(device_id)
    return events


EXPECTED_NEGATIVE_SW = {
    "TEST_NEGATIVE_ROUTING_UNKNOWN_AID": "6a82",
    "TEST_NEGATIVE_SERVICE_INVALID_INS": "6d00",
    "TEST_NEGATIVE_SERVICE_INVALID_P1": "6a86",
    "TEST_NEGATIVE_SERVICE_OVERSIZED_CHUNK": "6700",
}

# (event, bytes, chunks, echo flag)
EXPECTED_TRANSFER_VECTORS = [
    ("TEST_32B", 32, 1, "chunk_echo_ok"),
    ("TEST_512B", 512, 4, "chunk_echoes_ok"),
    ("TEST_4KIB", 4096, 32, "chunk_echoes_ok"),
]
EXPECTED_HCE_CHUNK_EVENTS = 1 + 4 + 32

SUMMARY_FLAGS = (
    "select_passed",
    "test_32b_passed",
    "test_512b_passed",
    "test_4kib_passed",
    "neg_routing_passed",
    "neg_ins_passed",
    "neg_p1_passed",
    "neg_oversized_passed",
)


def _sw_equals(val: Any, expected: str) -> bool:
    return isinstance(val, str) and val.lower() == expected


def verify_phase_execution(
    phase_num: int,
    target_run_id: str,
    completion: Optional[Dict[str, Any]],
    reader_events: List[Dict[str, Any]],
    reader_unparsed: List[str],
    hce_events: List[Dict[str, Any]],
    hce_unparsed: List[str],
    rf_seen: bool,
    reader_ack: Optional[Dict[str, Any]] = None,
    hce_ack: Optional[Dict[str, Any]] = None,
    reader_log_error: Optional[str] = None,
    hce_log_error: Optional[str] = None,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Validates all Reader and HCE logs for a single phase against the shared run contract.
    Every field is mandatory (a missing SW/length/hash/flag is a failure, never a pass), all
    integers use strict `type(v) is int` checks (rejecting bool/float), `event_seq` must be
    present and strictly increasing on both Reader and HCE without fallback sorting, and all
    37 HCE chunk events + 3 HCE digest events are verified per-chunk and per-vector.
    Returns (None, None) if all checks pass, or (verdict, error_reason) on failure/block.
    """
    label = f"Phase {phase_num}"
    expected_phase = f"phase{phase_num}"
    phase_fail = "FAIL_PHASE_1_ASSERTIONS" if phase_num == 1 else "FAIL_PHASE_2_ASSERTIONS"

    # -1. Explicit ADB logcat observation errors must fail with FAIL_LOG_OBSERVATION
    if reader_log_error or hce_log_error:
        return (
            "FAIL_LOG_OBSERVATION",
            f"{label}: ADB log observation failed (reader={reader_log_error!r}, hce={hce_log_error!r})",
        )

    # 0. The runner must hold both App-reported ACKs with strict positive int generation/token.
    if not isinstance(reader_ack, dict) or not isinstance(hce_ack, dict):
        return "FAIL_CONTROL_ACK", f"{label}: missing control ACK (reader={reader_ack is not None}, hce={hce_ack is not None})"
    reader_gen = reader_ack.get("generation")
    hce_gen = hce_ack.get("generation")
    if not _is_positive_int(reader_gen) or not _is_positive_int(hce_gen):
        return "FAIL_CONTROL_ACK", f"{label}: ACK generations invalid reader={reader_gen!r} hce={hce_gen!r}"

    reader_ack_token = reader_ack.get("token") if "token" in reader_ack else None
    hce_ack_token = hce_ack.get("token") if "token" in hce_ack else None
    if reader_ack_token is not None and not _is_positive_int(reader_ack_token):
        return "FAIL_CONTROL_ACK", f"{label}: reader ACK token invalid: {reader_ack_token!r}"
    if hce_ack_token is not None and not _is_positive_int(hce_ack_token):
        return "FAIL_CONTROL_ACK", f"{label}: hce ACK token invalid: {hce_ack_token!r}"

    for dev_label, ack_obj, expected_role in (("reader", reader_ack, "READER"), ("hce", hce_ack, "HCE")):
        if "ack" in ack_obj and not _is_strict_true(ack_obj.get("ack")):
            return "FAIL_CONTROL_ACK", f"{label}: {dev_label} ACK not True: {ack_obj}"
        if "run_id" in ack_obj and ack_obj.get("run_id") != target_run_id:
            return "FAIL_CONTROL_ACK", f"{label}: {dev_label} ACK run_id={ack_obj.get('run_id')!r} != {target_run_id!r}"
        if "role" in ack_obj and ack_obj.get("role") != expected_role:
            return "FAIL_CONTROL_ACK", f"{label}: {dev_label} ACK role={ack_obj.get('role')!r} != {expected_role!r}"
        if "phase" in ack_obj and ack_obj.get("phase") != expected_phase:
            return "FAIL_CONTROL_ACK", f"{label}: {dev_label} ACK phase={ack_obj.get('phase')!r} != {expected_phase!r}"

    # 1. Reject any malformed JSON log lines on Reader or HCE
    if reader_unparsed or hce_unparsed:
        return (
            "FAIL_MALFORMED_PROBE_LOG",
            f"{label}: Malformed JSON log lines detected (reader={len(reader_unparsed)}, hce={len(hce_unparsed)}).",
        )

    # 2. Logged ACK events must exist (exactly 1 per device for target_run_id) and agree with the content-call ACK.
    for dev, events, ack_obj, expected_gen, expected_tok, expected_role in (
        ("reader", reader_events, reader_ack, reader_gen, reader_ack_token, "READER"),
        ("hce", hce_events, hce_ack, hce_gen, hce_ack_token, "HCE"),
    ):
        acks = [e for e in events if e.get("event") == "PROBE_CONTROL_ACK"]
        bad = [e for e in acks if e.get("run_id") != target_run_id or not _is_strict_true(e.get("ack"))]
        if bad:
            return "FAIL_RUN_ID_CONTRACT_MISMATCH", f"{label}: {dev} PROBE_CONTROL_ACK mismatch: {bad[0]}"
        run_acks = [e for e in acks if e.get("run_id") == target_run_id]
        if len(run_acks) != 1:
            return "FAIL_CONTROL_ACK", f"{label}: {dev} log has {len(run_acks)} PROBE_CONTROL_ACK events for {target_run_id} (expected 1)"
        ack_evt = run_acks[0]
        if not _int_equals(ack_evt.get("generation"), expected_gen):
            return "FAIL_CONTROL_ACK", f"{label}: {dev} log PROBE_CONTROL_ACK generation {ack_evt.get('generation')!r} != ACK {expected_gen}"
        if expected_tok is not None and not _int_equals(ack_evt.get("token"), expected_tok):
            return "FAIL_CONTROL_ACK", f"{label}: {dev} log PROBE_CONTROL_ACK token {ack_evt.get('token')!r} != ACK {expected_tok}"
        if "token" in ack_evt and not _is_positive_int(ack_evt.get("token")):
            return "FAIL_CONTROL_ACK", f"{label}: {dev} log PROBE_CONTROL_ACK has invalid token {ack_evt.get('token')!r}"

    # 3. Completion for target_run_id
    if completion is None:
        foreign_run_ids: Set[str] = set()
        for evt in reader_events:
            rid = evt.get("run_id")
            if (
                isinstance(rid, str)
                and rid
                and rid != target_run_id
                and evt.get("event") in ("TAG_DISCOVERED", "SELECT_AID_RESULT", "PROBE_RUN_COMPLETE")
            ):
                foreign_run_ids.add(rid)
        if foreign_run_ids:
            return (
                "FAIL_RUN_ID_CONTRACT_MISMATCH",
                f"{label}: App emitted foreign run_id(s) {sorted(foreign_run_ids)} instead of {target_run_id}",
            )
        if rf_seen:
            return "FAIL_RF_INTERRUPTED", f"{label}: RF contact started for run_id={target_run_id} but did not complete."
        return "BLOCKED_NO_RF_TOUCH", f"{label}: Devices were not brought into physical RF contact within deadline."

    # 4. Reader events of this run: strict generation/token/phase/role/event_seq + required set + order + terminal finality
    run_reader_events = [e for e in reader_events if e.get("run_id") == target_run_id]
    if not run_reader_events:
        return "FAIL_INCOMPLETE_EVENTS", f"{label}: No reader events found for run_id={target_run_id}"

    # Determine expected reader token from ACK or from the single PROBE_CONTROL_ACK event
    reader_control_ack_evt = next(e for e in run_reader_events if e.get("event") == "PROBE_CONTROL_ACK")
    expected_reader_token = reader_ack_token if reader_ack_token is not None else reader_control_ack_evt.get("token")

    # 4a. Check generation first across completion and all run_reader_events
    if not _int_equals(completion.get("generation"), reader_gen):
        return "FAIL_GENERATION_MISMATCH", f"{label}: completion generation {completion.get('generation')!r} != reader ACK {reader_gen}"
    for evt in run_reader_events:
        if not _int_equals(evt.get("generation"), reader_gen):
            return (
                "FAIL_GENERATION_MISMATCH",
                f"{label}: Reader event {evt.get('event')} generation {evt.get('generation')!r} != ACK {reader_gen}",
            )

    # 4b. Check token, phase, role, and strictly increasing positive event_seq across run_reader_events
    if expected_reader_token is not None and not _is_positive_int(expected_reader_token):
        return "FAIL_CONTROL_ACK", f"{label}: Reader token is not a positive int: {expected_reader_token!r}"
    if expected_reader_token is not None and not _int_equals(completion.get("token"), expected_reader_token):
        return "FAIL_CONTROL_ACK", f"{label}: completion token {completion.get('token')!r} != reader token {expected_reader_token}"
    if "phase" in completion and completion.get("phase") != expected_phase:
        return "FAIL_RUN_ID_CONTRACT_MISMATCH", f"{label}: completion phase {completion.get('phase')!r} != {expected_phase!r}"
    if "role" in completion and completion.get("role") != "READER":
        return "FAIL_RUN_ID_CONTRACT_MISMATCH", f"{label}: completion role {completion.get('role')!r} != 'READER'"

    prev_reader_seq: Optional[int] = None
    for evt in run_reader_events:
        if expected_reader_token is not None and not _int_equals(evt.get("token"), expected_reader_token):
            return (
                "FAIL_CONTROL_ACK",
                f"{label}: Reader event {evt.get('event')} token {evt.get('token')!r} != expected {expected_reader_token}",
            )
        if "phase" in evt and evt.get("phase") != expected_phase:
            return (
                "FAIL_RUN_ID_CONTRACT_MISMATCH",
                f"{label}: Reader event {evt.get('event')} phase {evt.get('phase')!r} != {expected_phase!r}",
            )
        if "role" in evt and evt.get("role") != "READER":
            return (
                "FAIL_RUN_ID_CONTRACT_MISMATCH",
                f"{label}: Reader event {evt.get('event')} role {evt.get('role')!r} != 'READER'",
            )
        rseq = evt.get("event_seq")
        if not _is_positive_int(rseq):
            return (
                "FAIL_EVENT_ORDER_VIOLATION",
                f"{label}: Reader event {evt.get('event')} missing or non-positive int event_seq: {rseq!r}",
            )
        if prev_reader_seq is not None and rseq <= prev_reader_seq:
            return (
                "FAIL_EVENT_ORDER_VIOLATION",
                f"{label}: Reader event_seq not strictly increasing ({prev_reader_seq} -> {rseq}) at {evt.get('event')}",
            )
        prev_reader_seq = rseq

    # 4c. Reject any failure/abort/cancellation event and enforce single terminal PROBE_RUN_COMPLETE
    names = [e.get("event") for e in run_reader_events]
    for evt in run_reader_events:
        ename = evt.get("event")
        if ename in FORBIDDEN_READER_FAILURE_EVENTS:
            return (
                phase_fail,
                f"{label}: Reader emitted failure/abort event {ename} during run_id={target_run_id}: {evt}",
            )

    complete_events = [e for e in run_reader_events if e.get("event") == "PROBE_RUN_COMPLETE"]
    if len(complete_events) != 1:
        return (
            "FAIL_INCOMPLETE_EVENTS",
            f"{label}: PROBE_RUN_COMPLETE appears {len(complete_events)} times for run_id={target_run_id} (expected exactly 1)",
        )
    if run_reader_events[-1].get("event") != "PROBE_RUN_COMPLETE":
        return (
            "FAIL_EVENT_ORDER_VIOLATION",
            f"{label}: PROBE_RUN_COMPLETE is not the final Reader event (trailing event: {run_reader_events[-1].get('event')})",
        )
    if complete_events[0] != completion:
        return (
            phase_fail,
            f"{label}: Provided completion event does not match the logged PROBE_RUN_COMPLETE event",
        )

    missing = [req for req in REQUIRED_PROBE_EVENTS if req not in names]
    if missing:
        return "FAIL_INCOMPLETE_EVENTS", f"{label} missing required events: {missing}"
    ack_idx = names.index("PROBE_CONTROL_ACK")
    complete_idx = names.index("PROBE_RUN_COMPLETE")
    last_idx = ack_idx
    for req in REQUIRED_PROBE_EVENTS:
        idx = names.index(req)
        if idx < last_idx or idx > complete_idx:
            return "FAIL_EVENT_ORDER_VIOLATION", f"{label}: Required event {req} appeared out of sequence order."
        last_idx = idx
    for req in REQUIRED_PROBE_EVENTS:
        if names.count(req) != 1:
            return "FAIL_INCOMPLETE_EVENTS", f"{label}: event {req} appears {names.count(req)} times (expected exactly 1)"

    by_name = {e.get("event"): e for e in run_reader_events}

    # 6. Every intermediate Reader event: pass === True and all result fields present and strict-int / valid
    for req in REQUIRED_PROBE_EVENTS:
        if not _is_strict_true(by_name[req].get("pass")):
            return "FAIL_INTERMEDIATE_EVENT_ASSERTION", f"{label}: Intermediate event {req} failed pass check: {by_name[req]}"

    sel = by_name["SELECT_AID_RESULT"]
    if not (
        _sw_equals(sel.get("sw"), "9000")
        and _is_strict_true(sel.get("version_ok"))
        and _is_strict_true(sel.get("max_chunk_ok"))
        and _int_equals(sel.get("max_chunk"), 128)
    ):
        return "FAIL_INTERMEDIATE_EVENT_ASSERTION", f"{label}: SELECT_AID_RESULT fields invalid/missing: {sel}"

    reader_vectors: List[Tuple[int, int, str]] = []
    for name, nbytes, nchunks, echo_flag in EXPECTED_TRANSFER_VECTORS:
        evt = by_name[name]
        problems = []
        if not _int_equals(evt.get("bytes"), nbytes):
            problems.append(f"bytes={evt.get('bytes')!r}")
        if not _int_equals(evt.get("chunks"), nchunks):
            problems.append(f"chunks={evt.get('chunks')!r}")
        if not _is_strict_true(evt.get(echo_flag)):
            problems.append(f"{echo_flag}={evt.get(echo_flag)!r}")
        if name == "TEST_32B" and not _sw_equals(evt.get("chunk_sw"), "9000"):
            problems.append(f"chunk_sw={evt.get('chunk_sw')!r}")
        if not _sw_equals(evt.get("digest_sw"), "9000"):
            problems.append(f"digest_sw={evt.get('digest_sw')!r}")
        if not _is_strict_true(evt.get("digest_match")):
            problems.append(f"digest_match={evt.get('digest_match')!r}")
        if not _is_valid_sha256_hex(evt.get("sha256")):
            problems.append(f"sha256={evt.get('sha256')!r}")
        if problems:
            return "FAIL_INTERMEDIATE_EVENT_ASSERTION", f"{label}: {name} invalid/missing fields: {', '.join(problems)}"
        reader_vectors.append((nbytes, nchunks, evt["sha256"].lower()))

    for name, expected_sw in EXPECTED_NEGATIVE_SW.items():
        evt = by_name[name]
        if not (_sw_equals(evt.get("expected_sw"), expected_sw) and _sw_equals(evt.get("actual_sw"), expected_sw)):
            return (
                "FAIL_INTERMEDIATE_EVENT_ASSERTION",
                f"{label}: {name} expected/actual SW must both be {expected_sw}: {evt.get('expected_sw')!r}/{evt.get('actual_sw')!r}",
            )

    # 7. HCE evidence for the same run_id: preserve observed order (no 0-default sorting),
    # verify generation, token, phase, role, strictly increasing positive event_seq,
    # all HCE_SELECT_AID events, and per-chunk + per-digest alignment across all 37 chunks and 3 digests.
    run_hce_events = [e for e in hce_events if e.get("run_id") == target_run_id]
    hce_names = {e.get("event") for e in run_hce_events}
    missing_hce = [req for req in REQUIRED_HCE_EVENTS if req not in hce_names]
    if not run_hce_events or missing_hce:
        return (
            "FAIL_MISSING_HCE_EVIDENCE",
            f"{label}: HCE device missing required interaction events for run_id={target_run_id}: {missing_hce}",
        )

    hce_control_ack_evt = next(e for e in run_hce_events if e.get("event") == "PROBE_CONTROL_ACK")
    expected_hce_token = hce_ack_token if hce_ack_token is not None else hce_control_ack_evt.get("token")
    if expected_hce_token is not None and not _is_positive_int(expected_hce_token):
        return "FAIL_CONTROL_ACK", f"{label}: HCE token is not a positive int: {expected_hce_token!r}"

    prev_hce_seq: Optional[int] = None
    for hevt in run_hce_events:
        if not _int_equals(hevt.get("generation"), hce_gen):
            return (
                "FAIL_GENERATION_MISMATCH",
                f"{label}: HCE event {hevt.get('event')} generation {hevt.get('generation')!r} != HCE ACK {hce_gen}",
            )
        if expected_hce_token is not None and not _int_equals(hevt.get("token"), expected_hce_token):
            return (
                "FAIL_CONTROL_ACK",
                f"{label}: HCE event {hevt.get('event')} token {hevt.get('token')!r} != expected {expected_hce_token}",
            )
        if "phase" in hevt and hevt.get("phase") != expected_phase:
            return (
                "FAIL_RUN_ID_CONTRACT_MISMATCH",
                f"{label}: HCE event {hevt.get('event')} phase {hevt.get('phase')!r} != {expected_phase!r}",
            )
        if "role" in hevt and hevt.get("role") != "HCE":
            return (
                "FAIL_RUN_ID_CONTRACT_MISMATCH",
                f"{label}: HCE event {hevt.get('event')} role {hevt.get('role')!r} != 'HCE'",
            )
        hseq = hevt.get("event_seq")
        if not _is_positive_int(hseq):
            return (
                "FAIL_EVENT_ORDER_VIOLATION",
                f"{label}: HCE event {hevt.get('event')} missing or non-positive int event_seq: {hseq!r}",
            )
        if prev_hce_seq is not None and hseq <= prev_hce_seq:
            return (
                "FAIL_EVENT_ORDER_VIOLATION",
                f"{label}: HCE event_seq not strictly increasing ({prev_hce_seq} -> {hseq}) at {hevt.get('event')}",
            )
        prev_hce_seq = hseq

    # Every HCE_SELECT_AID event for the probe AID must have status == "OK", and the first
    # HCE_SELECT_AID must precede the first HCE_CHUNK_RECEIVED.
    hce_select_events = [e for e in run_hce_events if e.get("event") == "HCE_SELECT_AID"]
    if not hce_select_events:
        return "FAIL_MISSING_HCE_EVIDENCE", f"{label}: HCE did not record any HCE_SELECT_AID event."
    for sel_evt in hce_select_events:
        # Only unknown-AID negative test might log REJECTED_UNKNOWN_AID for a non-F046435701 AID;
        # any other non-OK status (or non-OK on the probe AID) is a failure.
        status_val = sel_evt.get("status")
        aid_val = str(sel_evt.get("aid", "F046435701")).upper()
        if status_val != "OK":
            if not (status_val == "REJECTED_UNKNOWN_AID" and "received_aid" in sel_evt and str(sel_evt.get("received_aid")).upper() != "F046435701"):
                return (
                    "FAIL_MISSING_HCE_EVIDENCE",
                    f"{label}: HCE recorded failed HCE_SELECT_AID event: {sel_evt}",
                )
        elif aid_val != "F046435701":
            return (
                "FAIL_MISSING_HCE_EVIDENCE",
                f"{label}: HCE_SELECT_AID OK for unexpected AID: {sel_evt}",
            )
    ok_select_indices = [
        idx for idx, e in enumerate(run_hce_events)
        if e.get("event") == "HCE_SELECT_AID" and e.get("status") == "OK"
    ]
    first_chunk_idx = next(
        (idx for idx, e in enumerate(run_hce_events) if e.get("event") == "HCE_CHUNK_RECEIVED"),
        -1,
    )
    if not ok_select_indices or (first_chunk_idx != -1 and ok_select_indices[0] > first_chunk_idx):
        return (
            "FAIL_MISSING_HCE_EVIDENCE",
            f"{label}: HCE did not record a successful HCE_SELECT_AID before HCE_CHUNK_RECEIVED.",
        )

    chunk_events = [e for e in run_hce_events if e.get("event") == "HCE_CHUNK_RECEIVED"]
    if len(chunk_events) != EXPECTED_HCE_CHUNK_EVENTS:
        return (
            "FAIL_MISSING_HCE_EVIDENCE",
            f"{label}: HCE recorded {len(chunk_events)} HCE_CHUNK_RECEIVED events, expected {EXPECTED_HCE_CHUNK_EVENTS}",
        )

    hce_digest_events = [e for e in run_hce_events if e.get("event") == "HCE_DIGEST_REQUESTED"]
    if len(hce_digest_events) != len(reader_vectors):
        return (
            "FAIL_HCE_DIGEST_MISMATCH",
            f"{label}: HCE recorded {len(hce_digest_events)} digests, expected {len(reader_vectors)}",
        )

    # Verify the interleaved stream of HCE_CHUNK_RECEIVED and HCE_DIGEST_REQUESTED events
    # segment by segment: 1x32B -> digest(32B, 1), 4x128B -> digest(512B, 4), 32x128B -> digest(4096B, 32)
    transfer_stream = [
        e for e in run_hce_events if e.get("event") in ("HCE_CHUNK_RECEIVED", "HCE_DIGEST_REQUESTED")
    ]
    stream_cursor = 0
    for nbytes, nchunks, rsha in reader_vectors:
        expected_chunk_size = nbytes // nchunks
        running_total = 0
        for expected_idx in range(1, nchunks + 1):
            if stream_cursor >= len(transfer_stream):
                return (
                    "FAIL_MISSING_HCE_EVIDENCE",
                    f"{label}: HCE transfer stream ended early before chunk {expected_idx}/{nchunks} of {nbytes}B vector",
                )
            cevt = transfer_stream[stream_cursor]
            stream_cursor += 1
            if cevt.get("event") != "HCE_CHUNK_RECEIVED":
                return (
                    "FAIL_EVENT_ORDER_VIOLATION",
                    f"{label}: Expected HCE_CHUNK_RECEIVED at chunk {expected_idx}/{nchunks} of {nbytes}B vector, got {cevt.get('event')}",
                )
            c_idx = cevt.get("chunk_index")
            c_bytes = cevt.get("bytes")
            c_acc = cevt.get("total_accumulated")
            if not _is_positive_int(c_bytes) or c_bytes > 128 or not _int_equals(c_bytes, expected_chunk_size):
                return (
                    "FAIL_MISSING_HCE_EVIDENCE",
                    f"{label}: HCE_CHUNK_RECEIVED invalid bytes={c_bytes!r} (expected {expected_chunk_size}) in {nbytes}B vector: {cevt}",
                )
            running_total += c_bytes
            if not _int_equals(c_idx, expected_idx):
                return (
                    "FAIL_MISSING_HCE_EVIDENCE",
                    f"{label}: HCE_CHUNK_RECEIVED chunk_index={c_idx!r} != expected {expected_idx} in {nbytes}B vector: {cevt}",
                )
            if not _int_equals(c_acc, running_total):
                return (
                    "FAIL_MISSING_HCE_EVIDENCE",
                    f"{label}: HCE_CHUNK_RECEIVED total_accumulated={c_acc!r} != expected {running_total} in {nbytes}B vector: {cevt}",
                )

        if stream_cursor >= len(transfer_stream):
            return (
                "FAIL_HCE_DIGEST_MISMATCH",
                f"{label}: HCE transfer stream missing HCE_DIGEST_REQUESTED after {nbytes}B chunks",
            )
        devt = transfer_stream[stream_cursor]
        stream_cursor += 1
        if devt.get("event") != "HCE_DIGEST_REQUESTED":
            return (
                "FAIL_EVENT_ORDER_VIOLATION",
                f"{label}: Expected HCE_DIGEST_REQUESTED after {nchunks} chunks of {nbytes}B vector, got {devt.get('event')}",
            )
        hsha = devt.get("sha256")
        if not _is_valid_sha256_hex(hsha) or hsha.lower() != rsha:
            return "FAIL_HCE_DIGEST_MISMATCH", f"{label}: HCE digest {hsha!r} != Reader digest {rsha} for {nbytes}B"
        if not _int_equals(devt.get("total_bytes"), nbytes) or running_total != nbytes:
            return (
                "FAIL_HCE_DIGEST_MISMATCH",
                f"{label}: HCE total_bytes {devt.get('total_bytes')!r} != Reader {nbytes}B for digest {rsha}",
            )
        if not _int_equals(devt.get("chunks"), nchunks):
            return (
                "FAIL_HCE_DIGEST_MISMATCH",
                f"{label}: HCE digest chunks {devt.get('chunks')!r} != expected {nchunks} for {nbytes}B",
            )

    if stream_cursor != len(transfer_stream):
        return (
            "FAIL_MISSING_HCE_EVIDENCE",
            f"{label}: Trailing HCE chunk/digest events after expected vectors: {len(transfer_stream) - stream_cursor}",
        )

    # 8. Strict boolean completion summary; every flag mandatory
    if "status" in completion and completion.get("status") != "PASSED":
        return phase_fail, f"{label}: Completion status is {completion.get('status')!r}, expected 'PASSED'"
    if not _is_strict_true(completion.get("all_passed")):
        return phase_fail, f"{label}: Completion all_passed is not boolean True: {completion}"
    for flag in SUMMARY_FLAGS:
        if not _is_strict_true(completion.get(flag)):
            return phase_fail, f"{label}: Summary flag {flag} is missing or not True in completion: {completion}"

    return None, None


def write_atomic_report(output_path: Optional[Path], report: Dict[str, Any]) -> None:
    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = output_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp_path.replace(output_path)


def execute_probe(
    device1_id: str,
    device2_id: str,
    apk_path: Optional[Path] = None,
    skip_install: bool = False,
    deadline_sec: float = 10.0,
    verify_mode: bool = False,
    output_path: Optional[Path] = None
) -> Dict[str, Any]:
    print("=" * 70)
    print("Mobile Cold Wallet - NFC Hardware Probe Runner (H2 / FCW-HW-NFC-20261013)")
    print("=" * 70)

    report: Dict[str, Any] = {
        "work_package": "FCW-HW-NFC-20261013",
        "probe_version": "2.4.0",
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "devices": {
            "device1": {"device_id": device1_id},
            "device2": {"device_id": device2_id},
        },
        "phase1": None,
        "phase2": None,
        "verdict": "FAIL_INCOMPLETE_EXECUTION",
        "all_passed": False,
        "blocking_reasons": []
    }

    # Immediately overwrite any stale report sentinel before invoking ADB (A1)
    write_atomic_report(output_path, report)

    try:
        # Configuration guard: Must use two distinct physical devices (A1)
        if device1_id == device2_id:
            report["verdict"] = "INVALID_DEVICE_CONFIGURATION"
            report["blocking_reasons"].append(f"Reader and HCE cannot be the same device: {device1_id}")
            print(f"[-] Error: Device 1 and Device 2 are identical ({device1_id}). Two distinct devices required.")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        connected_devices = get_connected_devices()
        print(f"[*] Connected ADB devices: {connected_devices}")

        # Check device availability
        d1_status = check_device_nfc_state(device1_id)
        d2_status = check_device_nfc_state(device2_id)
        report["devices"]["device1"] = d1_status
        report["devices"]["device2"] = d2_status

        print(f"[*] Device 1 ({device1_id}): connected={d1_status['connected']}, model={d1_status['model']}, nfc_on={d1_status.get('nfc_state_on')}")
        print(f"[*] Device 2 ({device2_id}): connected={d2_status['connected']}, model={d2_status['model']}, nfc_on={d2_status.get('nfc_state_on')}")

        # Reject USB + Wi-Fi alias pointing to the same physical hardware serial
        hw1 = d1_status.get("hardware_serial", "").strip()
        hw2 = d2_status.get("hardware_serial", "").strip()
        if hw1 and hw2 and hw1.lower() not in ("unknown", "null") and hw1 == hw2:
            report["verdict"] = "INVALID_DEVICE_CONFIGURATION"
            report["blocking_reasons"].append(
                f"Device 1 ({device1_id}) and Device 2 ({device2_id}) share the same hardware serial ({hw1})."
            )
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        # Blocker check 1: Device connectivity
        if not d1_status["connected"] or not d2_status["connected"]:
            missing = []
            if not d1_status["connected"]:
                missing.append(device1_id)
            if not d2_status["connected"]:
                missing.append(device2_id)
            report["verdict"] = "BLOCKED_DEVICE_ABSENCE"
            report["blocking_reasons"].append(f"Missing required devices: {missing}. Requires two physical Android devices.")
            print(f"[-] Blocked: Missing device(s) {missing}")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(2)
            return report

        # Blocker check 2: NFC enabled
        if not d1_status.get("nfc_state_on") or not d2_status.get("nfc_state_on"):
            report["verdict"] = "BLOCKED_NFC_DISABLED"
            report["blocking_reasons"].append("NFC setting is disabled on one or both devices.")
            print("[-] Blocked: NFC is disabled on one or both devices.")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(2)
            return report

        # Install APK if requested
        if not skip_install and apk_path:
            ok1, err1 = install_probe_apk(apk_path, device1_id)
            ok2, err2 = install_probe_apk(apk_path, device2_id)
            if not ok1 or not ok2:
                report["verdict"] = "FAIL_INSTALLATION"
                report["blocking_reasons"].append(f"APK install failed: d1={err1}, d2={err2}")
                write_atomic_report(output_path, report)
                if verify_mode:
                    sys.exit(1)
                return report

        # --- Phase 1: Device 1 = Reader, Device 2 = Vault HCE ---
        phase1_run_id = str(uuid.uuid4())
        print(f"\n[*] --- Phase 1: Device 1 (Reader) <-> Device 2 (Vault HCE) [run_id={phase1_run_id}] ---")
        hce_ok, hce_err, p1_hce_ack = launch_probe_activity(device2_id, "HCE", phase1_run_id, phase="phase1")
        if not hce_ok:
            report["verdict"] = hce_err.split(":", 1)[0]
            report["blocking_reasons"].append(f"Phase 1 HCE launch failed: {hce_err}")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        time.sleep(0.5)
        rdr_ok, rdr_err, p1_reader_ack = launch_probe_activity(device1_id, "READER", phase1_run_id, phase="phase1")
        if not rdr_ok:
            report["verdict"] = rdr_err.split(":", 1)[0]
            report["blocking_reasons"].append(f"Phase 1 Reader launch failed: {rdr_err}")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        print(f"[*] Waiting up to {deadline_sec}s for physical RF touch...")
        p1_completion, p1_events, p1_unparsed, p1_rf_seen, p1_rdr_log_err = poll_probe_completion_checked(
            device1_id, phase1_run_id, deadline_sec=deadline_sec
        )
        p1_hce_events, p1_hce_unparsed, p1_hce_log_err = read_all_logs_checked(device2_id)
        p1_run_hce_events = [e for e in p1_hce_events if e.get("run_id") == phase1_run_id]

        phase1_result = {
            "run_id": phase1_run_id,
            "reader_ack": p1_reader_ack,
            "hce_ack": p1_hce_ack,
            "reader_device": device1_id,
            "hce_device": device2_id,
            "rf_seen": p1_rf_seen,
            "rf_completed": p1_completion is not None,
            "completion_event": p1_completion,
            "reader_events_count": len(p1_events),
            "hce_events_count": len(p1_run_hce_events),
            "unparsed_lines": p1_unparsed + p1_hce_unparsed,
            "reader_log_error": p1_rdr_log_err,
            "hce_log_error": p1_hce_log_err,
        }
        report["phase1"] = phase1_result

        p1_verdict, p1_err = verify_phase_execution(
            phase_num=1,
            target_run_id=phase1_run_id,
            completion=p1_completion,
            reader_events=p1_events,
            reader_unparsed=p1_unparsed,
            hce_events=p1_hce_events,
            hce_unparsed=p1_hce_unparsed,
            rf_seen=p1_rf_seen,
            reader_ack=p1_reader_ack,
            hce_ack=p1_hce_ack,
            reader_log_error=p1_rdr_log_err,
            hce_log_error=p1_hce_log_err,
        )
        if p1_verdict is not None:
            print(f"[-] {p1_err}")
            report["verdict"] = p1_verdict
            if p1_err:
                report["blocking_reasons"].append(p1_err)
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(2 if p1_verdict.startswith("BLOCKED_") else 1)
            return report

        print(f"[+] Phase 1 Passed: {p1_completion}")

        # --- Phase 2: Role Swap: Device 2 = Reader, Device 1 = Vault HCE ---
        phase2_run_id = str(uuid.uuid4())
        print(f"\n[*] --- Phase 2: Role Swap: Device 2 (Reader) <-> Device 1 (Vault HCE) [run_id={phase2_run_id}] ---")
        hce2_ok, hce2_err, p2_hce_ack = launch_probe_activity(device1_id, "HCE", phase2_run_id, phase="phase2")
        if not hce2_ok:
            report["verdict"] = hce2_err.split(":", 1)[0]
            report["blocking_reasons"].append(f"Phase 2 HCE launch failed: {hce2_err}")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        time.sleep(0.5)
        rdr2_ok, rdr2_err, p2_reader_ack = launch_probe_activity(device2_id, "READER", phase2_run_id, phase="phase2")
        if not rdr2_ok:
            report["verdict"] = rdr2_err.split(":", 1)[0]
            report["blocking_reasons"].append(f"Phase 2 Reader launch failed: {rdr2_err}")
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(1)
            return report

        print(f"[*] Waiting up to {deadline_sec}s for physical RF touch...")
        p2_completion, p2_events, p2_unparsed, p2_rf_seen, p2_rdr_log_err = poll_probe_completion_checked(
            device2_id, phase2_run_id, deadline_sec=deadline_sec
        )
        p2_hce_events, p2_hce_unparsed, p2_hce_log_err = read_all_logs_checked(device1_id)
        p2_run_hce_events = [e for e in p2_hce_events if e.get("run_id") == phase2_run_id]

        phase2_result = {
            "run_id": phase2_run_id,
            "reader_ack": p2_reader_ack,
            "hce_ack": p2_hce_ack,
            "reader_device": device2_id,
            "hce_device": device1_id,
            "rf_seen": p2_rf_seen,
            "rf_completed": p2_completion is not None,
            "completion_event": p2_completion,
            "reader_events_count": len(p2_events),
            "hce_events_count": len(p2_run_hce_events),
            "unparsed_lines": p2_unparsed + p2_hce_unparsed,
            "reader_log_error": p2_rdr_log_err,
            "hce_log_error": p2_hce_log_err,
        }
        report["phase2"] = phase2_result

        p2_verdict, p2_err = verify_phase_execution(
            phase_num=2,
            target_run_id=phase2_run_id,
            completion=p2_completion,
            reader_events=p2_events,
            reader_unparsed=p2_unparsed,
            hce_events=p2_hce_events,
            hce_unparsed=p2_hce_unparsed,
            rf_seen=p2_rf_seen,
            reader_ack=p2_reader_ack,
            hce_ack=p2_hce_ack,
            reader_log_error=p2_rdr_log_err,
            hce_log_error=p2_hce_log_err,
        )
        if p2_verdict is not None:
            print(f"[-] {p2_err}")
            report["verdict"] = p2_verdict
            if p2_err:
                report["blocking_reasons"].append(p2_err)
            write_atomic_report(output_path, report)
            if verify_mode:
                sys.exit(2 if p2_verdict.startswith("BLOCKED_") else 1)
            return report

        print(f"[+] Phase 2 Passed: {p2_completion}")

        report["all_passed"] = True
        report["verdict"] = "PASS"

        write_atomic_report(output_path, report)
        if output_path:
            print(f"\n[+] Full probe report written to: {output_path}")

        return report

    except (FileNotFoundError, OSError, subprocess.SubprocessError) as e:
        err_msg = f"ADB execution failure ({type(e).__name__}): {e}"
        print(f"[-] {err_msg}")
        report["verdict"] = "FAIL_ADB_NOT_FOUND"
        report["all_passed"] = False
        report["blocking_reasons"].append(err_msg)
        write_atomic_report(output_path, report)
        if verify_mode:
            sys.exit(1)
        return report


def main():
    parser = argparse.ArgumentParser(description="Run NFC Hardware Probe on physical devices")
    parser.add_argument("--apk", type=Path, default=DEFAULT_APK_PATH, help="Path to probe APK")
    device_a = os.environ.get("FCW_NFC_DEVICE_A")
    device_b = os.environ.get("FCW_NFC_DEVICE_B")
    parser.add_argument("--device1", "--device-a", dest="device1", type=str, default=device_a, required=device_a is None,
                        help="Device A (Wallet / reader) adb serial; defaults to $FCW_NFC_DEVICE_A")
    parser.add_argument("--device2", "--device-b", dest="device2", type=str, default=device_b, required=device_b is None,
                        help="Device B (Vault / HCE) adb serial; defaults to $FCW_NFC_DEVICE_B")
    parser.add_argument("--skip-install", action="store_true", help="Skip APK installation")
    parser.add_argument("--deadline", type=float, default=10.0, help="Deadline in seconds to wait for physical touch")
    parser.add_argument("--verify", action="store_true", help="Verification mode: exit non-zero if not fully passed")
    parser.add_argument("--output", type=Path, default=DEFAULT_EVIDENCE_DIR / "nfc_probe_report.json")

    args = parser.parse_args()

    execute_probe(
        device1_id=args.device1,
        device2_id=args.device2,
        apk_path=args.apk,
        skip_install=args.skip_install,
        deadline_sec=args.deadline,
        verify_mode=args.verify,
        output_path=args.output
    )


if __name__ == "__main__":
    main()
