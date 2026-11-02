"""
tests/test_nfc_probe_runner.py
==============================
Boundary tests for tools/nfc_probe/run_nfc_probe.py exercising the real `execute_probe`,
`launch_probe_activity`, `parse_control_ack`, `poll_probe_completion`,
`read_all_logs_with_unparsed` and `verify_phase_execution` functions by replacing ONLY the
lowest-level `run_adb` boundary (and `time.sleep`).

Includes the full 13-counterexample matrix from FCW-H2-D359879-RECHECK Section 四 plus
ADB log observation error handling (`FAIL_LOG_OBSERVATION`).

Nothing here touches a device or RF; a PASS in this file is a runner-logic result only.
"""

import io
import sys
import copy
import json
import random
import hashlib
import subprocess
import contextlib
from pathlib import Path
from unittest.mock import patch
import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "tools" / "nfc_probe"))
import run_nfc_probe  # noqa: E402


def _line(evt):
    return "10-14 14:00:00.000 100 100 I FCW_NFC_PROBE: " + json.dumps(evt)


class SyntheticApp:
    """Synthetic ADB boundary for two devices running the probe App."""

    def __init__(self, mode: str = "valid_full_contract"):
        self.mode = mode
        self.calls = []
        self.dev = {}  # device_id -> dict(role, run_id, phase, gen, token, seq)
        self.rng = random.Random(1234)
        self.phase_count = 0

    # -- helpers -----------------------------------------------------------------------------
    def result(self, args, stdout="", stderr="", rc=0):
        return subprocess.CompletedProcess(args, rc, stdout, stderr)

    def _seq(self, d):
        d["seq"] += 1
        return d["seq"]

    def _evt(self, d, name, **fields):
        e = {"event": name, "run_id": d["run_id"], "phase": d["phase"], "role": d["role"],
             "generation": d["gen"], "token": d["token"], "event_seq": self._seq(d)}
        e.update(fields)
        return e

    # -- ADB entry point ---------------------------------------------------------------------
    def __call__(self, args, device_id=None, timeout=30.0):
        self.calls.append({"device": device_id, "args": list(args), "timeout": timeout})
        m = self.mode
        if m == "adb_not_found":
            raise FileNotFoundError("synthetic missing adb executable")
        if args == ["devices"]:
            return self.result(args, "List of devices attached\nD1\tdevice\nD2\tdevice\n")
        if args[:3] == ["shell", "getprop", "ro.product.model"]:
            if m == "missing_second_device" and device_id == "D2":
                return self.result(args, "", stderr="error: device 'D2' not found", rc=1)
            return self.result(args, f"LAB_{device_id}\n")
        if args[:3] == ["shell", "getprop", "ro.serialno"]:
            return self.result(args, "SHARED_HW_SERIAL\n" if m == "same_hw_serial_alias" else f"HW_SER_{device_id}\n")
        if args[:3] == ["shell", "dumpsys", "nfc"]:
            return self.result(args, "mState=off\n" if (m == "nfc_disabled" and device_id == "D1") else "mState=on\n")
        if args[:4] == ["shell", "pm", "list", "features"]:
            return self.result(args, "feature:android.hardware.nfc\nfeature:android.hardware.nfc.hce\n")
        if args[:3] == ["shell", "am", "force-stop"]:
            # Process restart: ProbeSessionState counters start at 1 again.
            self.dev[device_id] = {"role": None, "run_id": "initial-random", "phase": "local_ui",
                                   "gen": 1, "token": 1, "seq": 0, "log": []}
            return self.result(args)
        if args[:3] == ["shell", "logcat", "-c"]:
            self.dev[device_id]["log"] = []
            return self.result(args)
        if args[:3] == ["shell", "am", "start"]:
            if m == "am_stderr_error":
                return self.result(args, stderr="Error: Activity not started, unable to resolve Intent")
            assert "-n" in args and args[args.index("-n") + 1] == "com.mobilecoldwallet.nfc_probe/.MainActivity"
            assert not any(a in args for a in ("--es", "-e", "--ei")), "runner must not pass intent extras"
            d = self.dev[device_id]
            d["log"].append(self._evt(d, "PROBE_APP_STARTED", initial_run_id=d["run_id"]))
            return self.result(args, "Starting: Intent { cmp=com.mobilecoldwallet.nfc_probe/.MainActivity }\nStatus: ok\n")
        if args[:3] == ["shell", "content", "call"]:
            return self._content_call(args, device_id)
        if args[:3] == ["shell", "logcat", "-d"]:
            return self._logcat(args, device_id)
        return self.result(args)

    # -- controller --------------------------------------------------------------------------
    def _content_call(self, args, device_id):
        m = self.mode
        extras = {}
        for i, a in enumerate(args):
            if a == "--extra":
                k, _, v = args[i + 1].split(":", 2)
                extras[k] = v
        assert args[args.index("--uri") + 1] == "content://com.mobilecoldwallet.nfc_probe.testcontrol"
        assert args[args.index("--method") + 1] == "activate_run"
        if m == "content_security_exception":
            return self.result(args, "", stderr="java.lang.SecurityException: Permission Denial: opening provider", rc=1)
        d = self.dev[device_id]
        if m == "controller_rejected":
            ack = {"ack": False, "reason": "UNAUTHORIZED_CALLER_UID_10999_DUMP_false", "calling_uid": 10999}
            return self.result(args, "Result: Bundle[{ack_json=" + json.dumps(ack) + "}]\n")
        d["gen"] += 1
        d["token"] += 1
        d["role"] = extras["role"]
        d["phase"] = extras["phase"]
        d["run_id"] = ("app-generated-" + device_id) if m == "app_generates_own_run_id" else extras["run_id"]
        d["log"].append(self._evt(d, "PROBE_CONTROL_ACK", ack=True, trigger_source="TEST_CONTROL_PROVIDER_UID_2000"))
        ack = {"ack": True, "method": "activate_run", "run_id": d["run_id"], "phase": d["phase"], "role": d["role"],
               "generation": d["gen"], "token": d["token"], "calling_uid": 2000,
               "applied_to_activity": m != "ack_not_applied", "activity_resumed": True,
               "reader_mode_active": d["role"] == "READER", "vault_armed": d["role"] == "HCE",
               "session_stable": True}
        if d["role"] == "READER":
            self.phase_count += 1
        return self.result(args, "Result: Bundle[{ack_json=" + json.dumps(ack) + "}]\n")

    # -- RF simulation -----------------------------------------------------------------------
    def _rf_exchange(self, reader, hce):
        """Appends the events a real successful RF probe produces on both devices."""
        m = self.mode
        rgen = reader["gen"]
        if m == "wrong_generation":
            reader["gen"] = -999
        elif m == "stale_generation_events":
            reader["gen"] = rgen - 1
        hce["log"].append(self._evt(hce, "HCE_SELECT_AID", status="OK", aid="F046435701", max_chunk=128))
        reader["log"].append(self._evt(reader, "TAG_DISCOVERED"))
        reader["log"].append(self._evt(reader, "ISODEP_CONNECTED", maxTransceiveLength=253))
        reader["log"].append(self._evt(reader, "SELECT_AID_RESULT", sw="9000", version_major=1, version_minor=0,
                                       version_ok=True, max_chunk=128, max_chunk_ok=True, pass_=None))
        reader["log"][-1].pop("pass_")
        reader["log"][-1]["pass"] = True

        vectors = [("TEST_32B", 32, 1), ("TEST_512B", 512, 4), ("TEST_4KIB", 4096, 32)]
        for name, nbytes, nchunks in vectors:
            data = bytes(self.rng.getrandbits(8) for _ in range(nbytes))
            sha = hashlib.sha256(data).hexdigest()
            if not (m == "hce_missing_chunks" and name != "TEST_32B"):
                acc = 0
                for i in range(nchunks):
                    size = min(128, nbytes)
                    if m == "hce_chunk_zero_or_negative_bytes" and name == "TEST_512B" and i == 1:
                        size = 0
                    if m == "hce_chunk_mismatch_with_digest_total" and name == "TEST_4KIB" and i == 0:
                        size = 64
                    acc += size
                    hce["log"].append(self._evt(hce, "HCE_CHUNK_RECEIVED", chunk_index=i + 1, bytes=size, total_accumulated=acc))
            hsha = sha
            if m == "hce_digest_mismatch" and name == "TEST_512B":
                hsha = "d" * 64
            if m == "synthetic_digest_string":
                hsha = "synthetic-digest"
            htotal = nbytes + (1 if (m == "hce_wrong_total_bytes" and name == "TEST_4KIB") else 0)
            hchunks = 99 if (m == "hce_digest_chunks_field_mismatch" and name == "TEST_512B") else nchunks
            hce["log"].append(self._evt(hce, "HCE_DIGEST_REQUESTED", total_bytes=htotal, chunks=hchunks, sha256=hsha))
            ev = {"bytes": nbytes, "chunks": nchunks, "digest_sw": "9000", "digest_match": True, "sha256": sha,
                  "rtt_ms": 5, "pass": True}
            if m == "float_byte_counts" and name == "TEST_32B":
                ev["bytes"] = 32.0
                ev["chunks"] = 1.0
            if name == "TEST_32B":
                ev.update({"chunk_sw": "9000", "chunk_echo_ok": True})
                if m in ("false_intermediate", "failed_tests_and_startup"):
                    ev.update({"pass": False, "chunk_sw": "6f00", "chunk_echo_ok": False, "digest_match": False})
                if m == "missing_sw_fields":
                    for k in ("chunk_sw", "digest_sw", "sha256", "bytes"):
                        ev.pop(k)
                if m == "synthetic_digest_string":
                    ev.pop("sha256")
            else:
                ev["chunk_echoes_ok"] = True
            reader["log"].append(self._evt(reader, name, **ev))
            if m == "duplicate_event" and name == "TEST_512B":
                reader["log"].append(self._evt(reader, name, **ev))

        if m == "hce_select_aid_failed_after_ok":
            hce["log"].append(self._evt(hce, "HCE_SELECT_AID", status="FAILED", aid="F046435701", max_chunk=128))
        else:
            hce["log"].append(self._evt(hce, "HCE_SELECT_AID", status="OK", aid="F046435701", max_chunk=128))

        for name, sw in run_nfc_probe.EXPECTED_NEGATIVE_SW.items():
            ev = {"expected_sw": sw, "actual_sw": sw, "pass": True}
            if m == "negative_sw_missing" and name == "TEST_NEGATIVE_SERVICE_INVALID_P1":
                ev.pop("actual_sw")
            reader["log"].append(self._evt(reader, name, **ev))

        if m == "out_of_order_events":
            names = [e["event"] for e in reader["log"]]
            i, j = names.index("SELECT_AID_RESULT"), names.index("TEST_32B")
            reader["log"][i], reader["log"][j] = reader["log"][j], reader["log"][i]

        if m == "hce_missing_or_zero_event_seq":
            for e in hce["log"]:
                if e["event"] == "HCE_DIGEST_REQUESTED":
                    e["event_seq"] = 0

        if m == "hce_digest_event_seq_swapped":
            dig_indices = [idx for idx, e in enumerate(hce["log"]) if e["event"] == "HCE_DIGEST_REQUESTED"]
            i0, i1 = dig_indices[0], dig_indices[1]
            hce["log"][i0]["event_seq"], hce["log"][i1]["event_seq"] = (
                hce["log"][i1]["event_seq"],
                hce["log"][i0]["event_seq"],
            )

        if m == "reader_event_seq_non_monotonic":
            for e in reader["log"]:
                if e["event"] == "TEST_4KIB":
                    e["event_seq"] = 1

        if m == "token_mismatch_within_run":
            for e in reader["log"]:
                if e["event"] == "TEST_512B":
                    e["token"] = reader["token"] + 77

        if m == "phase_or_role_mismatch_in_events":
            for e in reader["log"]:
                if e["event"] == "TEST_32B":
                    e["phase"] = "phase2"

        summary = {"status": "PASSED", "total_duration_ms": 900, "all_passed": True}
        for flag in run_nfc_probe.SUMMARY_FLAGS:
            summary[flag] = True
        if m == "numeric_one":
            summary["all_passed"] = 1
        if m == "summary_flag_missing":
            summary.pop("neg_ins_passed")

        if m == "duplicate_probe_run_complete_with_first_failed":
            failed_summary = dict(summary, status="FAILED", all_passed=False)
            reader["log"].append(self._evt(reader, "PROBE_RUN_COMPLETE", **failed_summary))

        comp = self._evt(reader, "PROBE_RUN_COMPLETE", **summary)
        comp["generation"] = rgen if m not in ("wrong_generation",) else -999
        if m == "stale_generation_events":
            comp["generation"] = rgen - 1
        reader["log"].append(comp)

        if m == "trailing_failure_event_after_complete":
            reader["log"].append(self._evt(reader, "ISODEP_EXCEPTION", status="FAILED_EXCEPTION", all_passed=False))

        if m == "missing_generation_field":
            for e in reader["log"]:
                if e["event"] in run_nfc_probe.REQUIRED_PROBE_EVENTS:
                    e.pop("generation")

        if m == "float_generation":
            for e in reader["log"]:
                if e.get("run_id") == reader["run_id"]:
                    e["generation"] = float(rgen)

    def _logcat(self, args, device_id):
        m = self.mode
        if m == "logcat_read_failed_rc" and device_id == "D2":
            return self.result(args, "", stderr="adb: device offline during logcat", rc=1)
        d = self.dev[device_id]
        other_id = "D2" if device_id == "D1" else "D1"
        o = self.dev.get(other_id)
        phase2 = self.phase_count >= 2
        if d["role"] == "READER" and not d.get("rf_done") and o is not None and o["role"] == "HCE" \
                and o["run_id"] == d["run_id"]:
            no_rf = m == "no_rf" or (m == "phase2_no_rf" and phase2)
            if m == "rf_interrupted":
                d["log"].append(self._evt(d, "TAG_DISCOVERED"))
                d["log"].append(self._evt(d, "ISODEP_EXCEPTION", message="Tag was lost."))
            elif m == "summary_only":
                comp = self._evt(d, "PROBE_RUN_COMPLETE", all_passed=True)
                d["log"].append(comp)
            elif not no_rf:
                self._rf_exchange(d, o)
            d["rf_done"] = True
            if m == "startup_only_hce" or m == "failed_tests_and_startup":
                o["log"] = [e for e in o["log"] if e["event"] == "PROBE_CONTROL_ACK"]
                o["log"].append({"event": "PROBE_APP_STARTED", "initial_run_id": "unrelated"})
            if m == "empty_hce":
                o["log"] = [e for e in o["log"] if e["event"] == "PROBE_CONTROL_ACK"]
            if m == "hce_log_missing_ack":
                o["log"] = [e for e in o["log"] if e["event"] != "PROBE_CONTROL_ACK"]
            if m == "bad_control_ack":
                d["log"].append({"event": "PROBE_CONTROL_ACK", "run_id": "wrong-ack-id", "ack": False})
        lines = [_line(e) for e in d["log"]]
        if m == "duplicate_identical_log_lines" and d["role"] == "READER" and lines:
            # Duplicate an identical TEST_32B log line in raw logcat stdout
            for line in list(lines):
                if '"TEST_32B"' in line:
                    lines.insert(lines.index(line) + 1, line)
                    break
        text = "\n".join(lines)
        if m == "malformed_event" and d["role"] == "READER":
            text = '10-14 14:00:00.000 I FCW_NFC_PROBE: {"event":BROKEN}\n' + text
        return self.result(args, text)


def _run_case(tmp_path: Path, mode: str, boundary=None):
    boundary = boundary or SyntheticApp(mode)
    report_path = tmp_path / f"runner-{mode}.json"
    # Stale PASS sentinel must never survive any exit path.
    report_path.write_text('{"verdict":"OLD_PASS_SENTINEL","all_passed":true}', encoding="utf-8")
    stdout = io.StringIO()
    exit_code = 0
    with patch.object(run_nfc_probe, "run_adb", side_effect=boundary), \
            patch.object(run_nfc_probe.time, "sleep", return_value=None), contextlib.redirect_stdout(stdout):
        try:
            run_nfc_probe.execute_probe("D1", "D2", skip_install=True, deadline_sec=0.05,
                                        verify_mode=True, output_path=report_path)
        except SystemExit as e:
            exit_code = e.code
    report = json.loads(report_path.read_text(encoding="utf-8"))
    return exit_code, report, boundary


CASES = [
    # positive control: the full contract
    ("valid_full_contract", "PASS", 0),
    # reviewer recheck_runner.py scenarios (31ff59c work package), adapted to the provider ACK flow
    ("numeric_one", "FAIL_PHASE_1_ASSERTIONS", 1),
    ("empty_hce", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("summary_only", "FAIL_INCOMPLETE_EVENTS", 1),
    ("no_rf", "BLOCKED_NO_RF_TOUCH", 2),
    ("am_stderr_error", "FAIL_AM_START", 1),
    ("app_generates_own_run_id", "FAIL_CONTROL_ACK", 1),
    ("false_intermediate", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("startup_only_hce", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("failed_tests_and_startup", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("wrong_generation", "FAIL_GENERATION_MISMATCH", 1),
    ("hce_digest_mismatch", "FAIL_HCE_DIGEST_MISMATCH", 1),
    ("malformed_event", "FAIL_MALFORMED_PROBE_LOG", 1),
    ("adb_not_found", "FAIL_ADB_NOT_FOUND", 1),
    # cases the previous candidate (3f1d947) accepted as PASS or never checked
    ("missing_sw_fields", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("missing_generation_field", "FAIL_GENERATION_MISMATCH", 1),
    ("stale_generation_events", "FAIL_GENERATION_MISMATCH", 1),
    ("synthetic_digest_string", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("hce_wrong_total_bytes", "FAIL_HCE_DIGEST_MISMATCH", 1),
    ("hce_missing_chunks", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("duplicate_event", "FAIL_INCOMPLETE_EVENTS", 1),
    ("negative_sw_missing", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("summary_flag_missing", "FAIL_PHASE_1_ASSERTIONS", 1),
    ("hce_log_missing_ack", "FAIL_CONTROL_ACK", 1),
    ("controller_rejected", "FAIL_CONTROL_ACK", 1),
    ("ack_not_applied", "FAIL_CONTROL_ACK", 1),
    ("content_security_exception", "FAIL_CONTROL_ACK", 1),
    # FCW-H2-D359879-RECHECK Section 四 13 counterexamples + logcat failure
    ("hce_select_aid_failed_after_ok", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("hce_chunk_zero_or_negative_bytes", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("hce_chunk_mismatch_with_digest_total", "FAIL_MISSING_HCE_EVIDENCE", 1),
    ("hce_digest_chunks_field_mismatch", "FAIL_HCE_DIGEST_MISMATCH", 1),
    ("hce_missing_or_zero_event_seq", "FAIL_EVENT_ORDER_VIOLATION", 1),
    ("hce_digest_event_seq_swapped", "FAIL_EVENT_ORDER_VIOLATION", 1),
    ("float_generation", "FAIL_CONTROL_ACK", 1),
    ("float_byte_counts", "FAIL_INTERMEDIATE_EVENT_ASSERTION", 1),
    ("duplicate_probe_run_complete_with_first_failed", "FAIL_INCOMPLETE_EVENTS", 1),
    ("trailing_failure_event_after_complete", "FAIL_PHASE_1_ASSERTIONS", 1),
    ("reader_event_seq_non_monotonic", "FAIL_EVENT_ORDER_VIOLATION", 1),
    ("token_mismatch_within_run", "FAIL_CONTROL_ACK", 1),
    ("phase_or_role_mismatch_in_events", "FAIL_RUN_ID_CONTRACT_MISMATCH", 1),
    ("duplicate_identical_log_lines", "FAIL_EVENT_ORDER_VIOLATION", 1),
    ("logcat_read_failed_rc", "FAIL_LOG_OBSERVATION", 1),
    # environment / configuration
    ("rf_interrupted", "FAIL_RF_INTERRUPTED", 1),
    ("phase2_no_rf", "BLOCKED_NO_RF_TOUCH", 2),
    ("missing_second_device", "BLOCKED_DEVICE_ABSENCE", 2),
    ("nfc_disabled", "BLOCKED_NFC_DISABLED", 2),
    ("same_hw_serial_alias", "INVALID_DEVICE_CONFIGURATION", 1),
    ("out_of_order_events", "FAIL_EVENT_ORDER_VIOLATION", 1),
    ("bad_control_ack", "FAIL_RUN_ID_CONTRACT_MISMATCH", 1),
]


@pytest.mark.parametrize("mode,expected_verdict,expected_exit", CASES)
def test_runner_adb_boundary_matrix(tmp_path, mode, expected_verdict, expected_exit):
    exit_code, report, boundary = _run_case(tmp_path, mode)
    assert report["verdict"] == expected_verdict, f"mode={mode} report={json.dumps(report)[:1500]}"
    assert exit_code == expected_exit, f"mode={mode} exit={exit_code}"
    assert report["all_passed"] is (expected_verdict == "PASS")
    assert report["verdict"] != "OLD_PASS_SENTINEL"


def _build_valid_phase_fixture():
    app = SyntheticApp("valid_full_contract")
    run_id = "run-fixture-01"
    app.dev["D1"] = {"role": "READER", "run_id": run_id, "phase": "phase1", "gen": 2, "token": 2, "seq": 0, "log": []}
    app.dev["D2"] = {"role": "HCE", "run_id": run_id, "phase": "phase1", "gen": 2, "token": 2, "seq": 0, "log": []}
    app.dev["D1"]["log"].append(app._evt(app.dev["D1"], "PROBE_CONTROL_ACK", ack=True))
    app.dev["D2"]["log"].append(app._evt(app.dev["D2"], "PROBE_CONTROL_ACK", ack=True))
    app._rf_exchange(app.dev["D1"], app.dev["D2"])
    reader_events = copy.deepcopy(app.dev["D1"]["log"])
    hce_events = copy.deepcopy(app.dev["D2"]["log"])
    completion = copy.deepcopy(reader_events[-1])
    reader_ack = {"ack": True, "run_id": run_id, "phase": "phase1", "role": "READER", "generation": 2, "token": 2}
    hce_ack = {"ack": True, "run_id": run_id, "phase": "phase1", "role": "HCE", "generation": 2, "token": 2}
    return run_id, completion, reader_events, hce_events, reader_ack, hce_ack


def test_verify_phase_execution_direct_13_counterexample_matrix():
    """Directly exercises verify_phase_execution on the 13 counterexamples from FCW-H2-D359879-RECHECK Section 四."""
    run_id, comp, r_evts, h_evts, r_ack, h_ack = _build_valid_phase_fixture()
    assert run_nfc_probe.verify_phase_execution(
        1, run_id, comp, r_evts, [], h_evts, [], True, r_ack, h_ack
    ) == (None, None)

    # 1. HCE_SELECT_AID failed after an earlier OK
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    h[-1]["status"] = "REJECTED_UNKNOWN_AID"
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 2. HCE_CHUNK_RECEIVED with zero or negative bytes
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    first_chunk = next(e for e in h if e["event"] == "HCE_CHUNK_RECEIVED")
    first_chunk["bytes"] = 0
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 3. HCE_CHUNK_RECEIVED bytes/accumulated mismatch with HCE_DIGEST_REQUESTED total_bytes
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    first_chunk = next(e for e in h if e["event"] == "HCE_CHUNK_RECEIVED")
    first_chunk["total_accumulated"] = 16
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 4. HCE_DIGEST_REQUESTED chunks field mismatch
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    first_dig = next(e for e in h if e["event"] == "HCE_DIGEST_REQUESTED")
    first_dig["chunks"] = 99
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 5. HCE missing or zero event_seq
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    h[3].pop("event_seq")
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 6. HCE digest event_seq swapped so sorting vs emission order diverges
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    digs = [e for e in h if e["event"] == "HCE_DIGEST_REQUESTED"]
    digs[0]["event_seq"], digs[1]["event_seq"] = digs[1]["event_seq"], digs[0]["event_seq"]
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 7. Float generation / byte counts (1.0 == 1 in Python unless type(v) is int is checked)
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    r[2]["generation"] = 2.0
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] == "FAIL_GENERATION_MISMATCH"
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    next(e for e in r if e["event"] == "TEST_32B")["bytes"] = 32.0
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] == "FAIL_INTERMEDIATE_EVENT_ASSERTION"

    # 8. Duplicate PROBE_RUN_COMPLETE where first failed and second passed
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    failed_comp = copy.deepcopy(c)
    failed_comp["all_passed"] = False
    failed_comp["status"] = "FAILED"
    failed_comp["event_seq"] = c["event_seq"]
    c["event_seq"] += 1
    r.insert(-1, failed_comp)
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 9. Trailing failure/abort event after PROBE_RUN_COMPLETE
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    r.append({
        "event": "ISODEP_EXCEPTION",
        "run_id": run_id,
        "phase": "phase1",
        "role": "READER",
        "generation": 2,
        "token": 2,
        "event_seq": c["event_seq"] + 1,
        "all_passed": False,
    })
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] is not None

    # 10. Reader event_seq non-monotonic
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    r[4]["event_seq"] = r[3]["event_seq"]
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] == "FAIL_EVENT_ORDER_VIOLATION"

    # 11. Token mismatch within the same run/generation
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    r[4]["token"] = 999
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] == "FAIL_CONTROL_ACK"

    # 12. Phase or role mismatch inside events of the run
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    r[4]["phase"] = "phase2"
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, r, [], h, [], True, ra, ha)[0] == "FAIL_RUN_ID_CONTRACT_MISMATCH"

    # 13. Duplicate identical log lines preserved by _parse_probe_logcat and rejected
    _, c, r, h, ra, ha = _build_valid_phase_fixture()
    raw_lines = [_line(e) for e in r]
    raw_lines.insert(4, raw_lines[3])  # exact duplicate log line
    parsed_r, unparsed_r = run_nfc_probe._parse_probe_logcat("\n".join(raw_lines))
    assert len(parsed_r) == len(r) + 1
    assert run_nfc_probe.verify_phase_execution(1, run_id, c, parsed_r, unparsed_r, h, [], True, ra, ha)[0] is not None


def test_valid_contract_uses_plain_launch_then_provider_and_records_acks(tmp_path):
    exit_code, report, boundary = _run_case(tmp_path, "valid_full_contract")
    assert exit_code == 0 and report["verdict"] == "PASS"
    starts = [c for c in boundary.calls if c["args"][:3] == ["shell", "am", "start"]]
    calls = [c for c in boundary.calls if c["args"][:3] == ["shell", "content", "call"]]
    assert len(starts) == 4 and len(calls) == 4
    for c in starts:
        assert c["args"][-1] == "com.mobilecoldwallet.nfc_probe/.MainActivity"
    for ph in ("phase1", "phase2"):
        r, h = report[ph]["reader_ack"], report[ph]["hce_ack"]
        assert r["role"] == "READER" and h["role"] == "HCE"
        assert r["run_id"] == h["run_id"] == report[ph]["run_id"]
        assert r["generation"] > 0 and h["generation"] > 0
    assert report["phase1"]["reader_device"] == "D1" and report["phase2"]["reader_device"] == "D2"


def test_parse_control_ack_handles_real_bundle_format_and_garbage():
    ack = {"ack": True, "run_id": "r", "nested": {"a": 1}}
    out = "Result: Bundle[{ack_json=" + json.dumps(ack) + "}]\n"
    assert run_nfc_probe.parse_control_ack(out) == ack
    assert run_nfc_probe.parse_control_ack("Result: Bundle[mParcelledData.dataSize=120]") is None
    assert run_nfc_probe.parse_control_ack("Result: null") is None
    assert run_nfc_probe.parse_control_ack("Result: Bundle[{ack_json={not json}}]") is None


class ReviewerOriginalBoundary:
    """
    Compact copy of the 31ff59c reviewer harness `AdbBoundary` (results/runner-observations.json):
    it answers `am start` with intent extras and logcat with minimal events that carry no SW,
    byte counts or hashes. None of its scenarios may PASS the current runner.
    """

    def __init__(self, mode):
        self.mode = mode
        self.roles = {}

    def result(self, args, stdout="", stderr="", rc=0):
        return subprocess.CompletedProcess(args, rc, stdout, stderr)

    def __call__(self, args, device_id=None, timeout=30):
        if self.mode == "adb_not_found":
            raise FileNotFoundError("synthetic missing adb executable")
        if args == ["devices"]:
            return self.result(args, "List of devices attached\nD1\tdevice\nD2\tdevice\n")
        if args[:3] == ["shell", "getprop", "ro.product.model"]:
            return self.result(args, "LAB_" + device_id + "\n")
        if args[:3] == ["shell", "dumpsys", "nfc"]:
            return self.result(args, "mState=on\n")
        if args[:4] == ["shell", "pm", "list", "features"]:
            return self.result(args, "feature:android.hardware.nfc\nfeature:android.hardware.nfc.hce\n")
        if args[:3] == ["shell", "am", "start"]:
            return self.result(args, "Starting: Intent { synthetic }\n")
        if args[:3] == ["shell", "logcat", "-d"]:
            rid = "unknown"
            events = [{"event": n, "run_id": rid, "generation": 2, "pass": True} for n in run_nfc_probe.REQUIRED_PROBE_EVENTS]
            events.append({"event": "PROBE_RUN_COMPLETE", "run_id": rid, "generation": 2, "all_passed": True})
            return self.result(args, "\n".join(_line(e) for e in events))
        return self.result(args)


@pytest.mark.parametrize("mode", ["control_synthetic_valid", "false_intermediate", "startup_only_hce",
                                  "wrong_generation", "hce_digest_mismatch", "adb_not_found"])
def test_reviewer_original_fixtures_never_pass(tmp_path, mode):
    exit_code, report, _ = _run_case(tmp_path, mode, boundary=ReviewerOriginalBoundary(mode))
    assert report["verdict"] != "PASS" and report["all_passed"] is False
    assert exit_code != 0


def test_runner_rejects_same_device_in_both_slots(tmp_path):
    report_file = tmp_path / "same_dev.json"
    report = run_nfc_probe.execute_probe(device1_id="D1", device2_id="D1", skip_install=True,
                                         deadline_sec=0.1, verify_mode=False, output_path=report_file)
    assert report["verdict"] == "INVALID_DEVICE_CONFIGURATION"
    assert report["all_passed"] is False
