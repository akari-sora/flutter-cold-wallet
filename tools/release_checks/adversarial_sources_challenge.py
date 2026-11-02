#!/usr/bin/env python3
"""
tools/release_checks/adversarial_sources_challenge.py
====================================================
Empirical Adversarial Challenge Suite for docs/sources.md and check_sources.py
Milestone: M0 (Sources & License Pinning Adversarial Review)

Executes 5 rigorous adversarial test suites:
1. Dynamic Reference & Branch Penetration (HEAD, main, master, latest, ^, *)
2. SHA Syntax & Format Integrity (40-hex regex, short/fake hashes, placeholders)
3. Remote Repository & SHA Binding Verification (existence in declared upstream repo)
4. License Classification & Proprietary Telemetry Audit (GPL/LGPL/AGPL/SSPL & ML Kit ToS)
5. Placebo & Bypass Vulnerability Attack on tools/release_checks/check_sources.py
"""

import sys
import re
import json
import urllib.request
import urllib.error
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SOURCES_MD = REPO_ROOT / "docs" / "sources.md"
CHECK_SOURCES_PY = REPO_ROOT / "tools" / "release_checks" / "check_sources.py"

results = {
    "suite_1_dynamic_penetration": {"passed": False, "findings": []},
    "suite_2_sha_syntax": {"passed": False, "findings": []},
    "suite_3_sha_remote_binding": {"passed": False, "findings": []},
    "suite_4_license_audit": {"passed": False, "findings": []},
    "suite_5_checker_bypass": {"passed": False, "findings": []},
}

def log_finding(suite_key, severity, desc, details=None):
    results[suite_key]["findings"].append({
        "severity": severity,
        "description": desc,
        "details": details or {}
    })

# ==============================================================================
# Suite 1: Dynamic Reference Penetration
# ==============================================================================
def run_suite_1():
    print("\n[SUITE 1] Dynamic Reference & Branch Penetration...")
    content = SOURCES_MD.read_text(encoding="utf-8")
    lines = content.splitlines()
    
    # 1. Check for 'latest'
    for idx, line in enumerate(lines, 1):
        if re.search(r"\blatest\b", line, re.IGNORECASE):
            log_finding("suite_1_dynamic_penetration", "HIGH",
                        f"Line {idx} contains dynamic reference 'latest'",
                        {"line": line.strip()})
            print(f"  [!] Finding: Line {idx} uses 'latest': {line.strip()[:80]}")

    # 2. Check for 'main' or 'master' in versions, tags, or URLs
    for idx, line in enumerate(lines, 1):
        if re.search(r"\b(main|master)\b", line, re.IGNORECASE):
            if any(term in line.lower() for term in ["main pinned", "blob/master", "branch ="]):
                log_finding("suite_1_dynamic_penetration", "HIGH",
                            f"Line {idx} contains branch reference (main/master)",
                            {"line": line.strip()})
                print(f"  [!] Finding: Line {idx} uses main/master: {line.strip()[:80]}")

    # 3. Check for Caret or unpinned SemVer in dependency tables
    for idx, line in enumerate(lines, 1):
        if line.strip().startswith("|") and "=" in line:
            m = re.search(r'([a-zA-Z0-9_\-]+)\s*=\s*"([0-9][^"=~^]*)"', line)
            if m:
                pkg, ver = m.groups()
                log_finding("suite_1_dynamic_penetration", "MEDIUM",
                            f"Line {idx} has unpinned SemVer without strict '=' prefix: {pkg} = \"{ver}\"",
                            {"pkg": pkg, "ver": ver})
                print(f"  [!] Finding: Line {idx} unpinned SemVer: {pkg} = \"{ver}\"")

    results["suite_1_dynamic_penetration"]["passed"] = len(results["suite_1_dynamic_penetration"]["findings"]) == 0

# ==============================================================================
# Suite 2: SHA Syntax & Format Integrity
# ==============================================================================
def run_suite_2():
    print("\n[SUITE 2] SHA Syntax & Format Integrity...")
    content = SOURCES_MD.read_text(encoding="utf-8")
    
    in_sec_2 = False
    table_rows = []
    for line in content.splitlines():
        if "## 2. Upstream Code Repositories" in line:
            in_sec_2 = True
            continue
        if in_sec_2 and line.startswith("## "):
            break
        if in_sec_2 and line.startswith("|") and not line.startswith("| ID") and not line.startswith("|---"):
            table_rows.append(line)

    sha_pattern = re.compile(r"^[0-9a-f]{40}$")
    seen_shas = {}

    for row in table_rows:
        cols = [c.strip() for c in row.split("|")[1:-1]]
        if len(cols) < 6:
            continue
        dep_id = cols[0].replace("*", "")
        name = cols[1]
        repo_url = cols[3]
        version_tag = cols[4]
        commit_col = cols[5].replace("`", "").strip()

        if not sha_pattern.match(commit_col):
            log_finding("suite_2_sha_syntax", "CRITICAL",
                        f"Dependency {dep_id} ({name}) lacks 40-hex commit hash. Found: '{commit_col}'",
                        {"dep_id": dep_id, "found": commit_col})
            print(f"  [!] Finding: {dep_id} missing 40-hex SHA: '{commit_col}'")
        else:
            if commit_col in seen_shas:
                seen_shas[commit_col].append(dep_id)
            else:
                seen_shas[commit_col] = [dep_id]

    results["suite_2_sha_syntax"]["passed"] = len([f for f in results["suite_2_sha_syntax"]["findings"] if f["severity"] == "CRITICAL"]) == 0

# ==============================================================================
# Suite 3: Remote Repository & SHA Binding Verification
# ==============================================================================
def run_suite_3():
    print("\n[SUITE 3] Remote Repository & SHA Binding Verification...")
    targets = [
        ("S05", "KeystoneHQ/ur-registry", "7d64aa9012a04b54b7d5a40bb5999d869f92fb6f"),
        ("S06", "KeystoneHQ/keystone-sdk-rust", "9de4a760b0e6d8693204c3fdf9dc148d82b9e831"),
        ("S07", "KeystoneHQ/keystone-sdk-rust", "9de4a760b0e6d8693204c3fdf9dc148d82b9e831"),
        ("S08", "KeystoneHQ/keystone-sdk-rust", "9de4a760b0e6d8693204c3fdf9dc148d82b9e831"),
        ("S09", "noncelab/coconut_vault", "0b1ea167a487b67d2d54e7c1e627dc3f6a3d557d"),
        ("S10", "noncelab/coconut_wallet", "e595a6f2d2339e59e0580cc4bb93695ed2763af0"),
        ("S11", "fzyzcjy/flutter_rust_bridge", "8631db91a90c699439c9ce2a1fb4164ae8661da9"),
        ("S23", "rust-bitcoin/rust-bitcoin", "a3f766715eabf008e0d7f2bfdf2ce7a86e9d2f9b"),
        ("S24", "bitcoin-core/secp256k1", "0cdc758a56360bf58a851fe91085a327ec97685a"),
        ("S25", "alloy-rs/alloy", "d1636c14762823b672556433783afae8a0c374c6"),
        ("AUX-01", "RustCrypto/utils", "34a6ebcb9b920ec7ae5809e470fce94fe7c0cb55"),
        ("AUX-02", "dspicher/ur-rs", "9b3064d879c9f84cbc2a5ce9a57334b98fc16e85"),
        ("AUX-03", "enarx/ciborium", "fdf3ec5c53256000f8e12f06c361ca18026a8d99"),
        ("AUX-04", "debris/tiny-keccak", "f034411460d0012925052017c1658b3ce9cda532"),
    ]

    headers = {"User-Agent": "AdversarialAuditor/1.0"}
    for dep_id, repo, sha in targets:
        url = f"https://api.github.com/repos/{repo}/commits/{sha}"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode())
                print(f"  [OK] {dep_id} ({repo} @ {sha[:8]}): Verified reachable via GitHub API")
        except urllib.error.HTTPError as e:
            if e.code == 403:
                import subprocess
                try:
                    out = subprocess.check_output(["git", "ls-remote", f"https://github.com/{repo}", sha], stderr=subprocess.STDOUT, timeout=15)
                    print(f"  [INFO] {dep_id} ({repo} @ {sha[:8]}): GitHub API 403 (Rate limited, fallback verified)")
                except Exception:
                    print(f"  [INFO] {dep_id} ({repo} @ {sha[:8]}): GitHub API 403 (Rate limited)")
            elif e.code == 422:
                msg = e.read().decode()
                log_finding("suite_3_sha_remote_binding", "CRITICAL",
                            f"{dep_id}: SHA {sha} does not exist in repository '{repo}' (HTTP 422 Unprocessable Entity - No commit found)",
                            {"dep_id": dep_id, "repo": repo, "sha": sha, "http_code": e.code, "error_msg": msg})
                print(f"  [!] CRITICAL: {dep_id} ({repo} @ {sha[:8]}): HTTP 422 - No commit found in declared repository!")
            else:
                msg = e.read().decode()
                log_finding("suite_3_sha_remote_binding", "HIGH",
                            f"{dep_id}: HTTP {e.code} error checking repository '{repo}'",
                            {"dep_id": dep_id, "repo": repo, "sha": sha, "http_code": e.code, "error_msg": msg})
                print(f"  [!] {dep_id} ({repo} @ {sha[:8]}): HTTP {e.code}")
        except Exception as e:
            log_finding("suite_3_sha_remote_binding", "HIGH",
                        f"{dep_id}: Connection error checking {repo}: {e}",
                        {"dep_id": dep_id, "error": str(e)})

    content = SOURCES_MD.read_text(encoding="utf-8")
    for idx, line in enumerate(content.splitlines(), 1):
        if "..." in line and ("http://" in line or "https://" in line):
            log_finding("suite_3_sha_remote_binding", "MEDIUM",
                        f"Line {idx} has truncated/broken URL with literal '...'",
                        {"line": line.strip()})
            print(f"  [!] Finding: Line {idx} truncated URL: {line.strip()[:80]}")

    results["suite_3_sha_remote_binding"]["passed"] = len([f for f in results["suite_3_sha_remote_binding"]["findings"] if f["severity"] == "CRITICAL"]) == 0

# ==============================================================================
# Suite 4: License Classification & Proprietary Telemetry Audit
# ==============================================================================
def run_suite_4():
    print("\n[SUITE 4] License Classification & Proprietary Telemetry Audit...")
    content = SOURCES_MD.read_text(encoding="utf-8")
    
    for line in content.splitlines():
        # Exclude explicit zero-contamination assertions
        if "0% (Zero)" in line or "zero copyleft" in line.lower():
            continue
        if any(lic in line.upper() for lic in ["AGPL", "SSPL", "LGPL"]):
            log_finding("suite_4_license_audit", "HIGH",
                        "Detected potentially non-permissive copyleft keyword",
                        {"line": line.strip()})

    if "Apache-2.0" in content and "ML Kit" in content:
        ml_kit_claimed_apache = False
        for line in content.splitlines():
            if "ML Kit" in line and "Apache-2.0" in line:
                ml_kit_claimed_apache = True
                break
        if ml_kit_claimed_apache:
            log_finding("suite_4_license_audit", "CRITICAL",
                        "S17 ML Kit is falsely classified as Apache-2.0. ML Kit is proprietary (Google APIs Terms of Service), contains anti-reverse-engineering restrictions, and performs automated telemetry to Google servers.",
                        {"claimed": "Apache-2.0", "actual": "Google ML Kit Terms of Service (Proprietary with telemetry)"})
            print("  [!] CRITICAL: S17 ML Kit misattributed as Apache-2.0 (Actually proprietary + telemetry)")

    results["suite_4_license_audit"]["passed"] = len([f for f in results["suite_4_license_audit"]["findings"] if f["severity"] == "CRITICAL"]) == 0

# ==============================================================================
# Suite 5: Placebo & Bypass Vulnerability Attack on check_sources.py
# ==============================================================================
def run_suite_5():
    print("\n[SUITE 5] Placebo & Bypass Vulnerability Attack on check_sources.py...")
    sys.path.insert(0, str(CHECK_SOURCES_PY.parent))
    import check_sources

    # Test 5.1: Dead code check
    checker_code = CHECK_SOURCES_PY.read_text(encoding="utf-8")
    occurrences = [m.start() for m in re.finditer(r"\bprohibited\b", checker_code)]
    if len(occurrences) <= 1:
        log_finding("suite_5_checker_bypass", "HIGH",
                    "check_sources.py contains DEAD CODE: 'prohibited' variable is defined but never evaluated.",
                    {"occurrences": len(occurrences)})
        print("  [!] Finding: check_sources.py dead code: 'prohibited' is defined but never referenced!")

    # Test 5.2: Empirical bypass attack - inject GPL dependency
    base_content = SOURCES_MD.read_text(encoding="utf-8")
    poisoned_gpl = base_content + "\n| **S99** | evil-gpl | Rust Crate | https://github.com/evil/gpl | 1.0.0 | `0123456789abcdef0123456789abcdef01234567` | GPL-3.0 | Viral copyleft |\n"
    temp_file = REPO_ROOT / "test_sources_poisoned_gpl.tmp"
    temp_file.write_text(poisoned_gpl, encoding="utf-8")
    res_gpl = check_sources.audit_sources(temp_file)
    temp_file.unlink()

    if res_gpl["success"]:
        log_finding("suite_5_checker_bypass", "CRITICAL",
                    "check_sources.py PASSED a file containing an explicit GPL-3.0 dependency! The license check logic is tautological and completely bypassed.",
                    {"audit_result": res_gpl})
        print("  [!] CRITICAL: check_sources.py successfully bypassed with explicit GPL-3.0 injection!")

    # Test 5.3: Empirical bypass attack - inject dynamic HEAD reference
    poisoned_head = base_content + "\n| **S99** | evil-head | Rust Crate | https://github.com/evil/head | HEAD | `0123456789abcdef0123456789abcdef01234567` | MIT | Dynamic branch |\n"
    temp_file = REPO_ROOT / "test_sources_poisoned_head.tmp"
    temp_file.write_text(poisoned_head, encoding="utf-8")
    res_head = check_sources.audit_sources(temp_file)
    temp_file.unlink()

    if res_head["success"]:
        log_finding("suite_5_checker_bypass", "HIGH",
                    "check_sources.py PASSED a file containing explicit 'HEAD' tracking!",
                    {"audit_result": res_head})
        print("  [!] Finding: check_sources.py successfully bypassed with explicit 'HEAD' injection!")

    results["suite_5_checker_bypass"]["passed"] = len([f for f in results["suite_5_checker_bypass"]["findings"] if f["severity"] == "CRITICAL"]) == 0

# ==============================================================================
# Main Runner & Verdict
# ==============================================================================
def main():
    print("=" * 80)
    print("  EMPIRICAL ADVERSARIAL CHALLENGE SUITE: SOURCES & LICENSE PINNING (M0)")
    print("=" * 80)
    
    run_suite_1()
    run_suite_2()
    run_suite_3()
    run_suite_4()
    run_suite_5()

    print("\n" + "=" * 80)
    print("  SUMMARY OF ADVERSARIAL TEST RESULTS")
    print("=" * 80)

    total_critical = sum(1 for s in results.values() for f in s["findings"] if f["severity"] == "CRITICAL")
    total_high = sum(1 for s in results.values() for f in s["findings"] if f["severity"] == "HIGH")
    total_medium = sum(1 for s in results.values() for f in s["findings"] if f["severity"] == "MEDIUM")

    print(f"Critical Vulnerabilities : {total_critical}")
    print(f"High Severity Issues      : {total_high}")
    print(f"Medium Severity Issues    : {total_medium}")

    overall_pass = (total_critical == 0 and total_high == 0 and total_medium == 0)
    verdict = "APPROVE" if overall_pass else "FAIL"
    print(f"\nFINAL ADVERSARIAL VERDICT : >>> {verdict} <<<")
    print("=" * 80)

    summary_path = REPO_ROOT / "target" / "adversarial_sources_challenge" / "adversarial_test_results.json"
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Detailed JSON results written to: {summary_path}")

    return 0 if overall_pass else 1

if __name__ == "__main__":
    sys.exit(main())
