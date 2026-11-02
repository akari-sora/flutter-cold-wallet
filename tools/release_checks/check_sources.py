#!/usr/bin/env python3
"""
tools/release_checks/check_sources.py
====================================
Automated verification utility for docs/sources.md (ENV-01).

Audits:
- Presence of all S01~S30 and AUX-01~AUX-04 dependencies (34 total).
- Zero Dynamic HEAD rule: exactly 14 code repositories have valid 40-hex commit hashes.
- Clean Licensing rule: per-row and global check ensuring no copyleft contamination (0% GPL/AGPL/LGPL/SSPL).
- Dynamic Reference Prohibition: rejects HEAD, main pinned, master pinned, latest, branch =.
- Accurate license attribution: S17 ML Kit must not be attributed as Apache-2.0.
- URL integrity: no truncated URLs with literal '...'.
- Generates structured verification log.
"""

import sys
import re
import hashlib
from pathlib import Path
from typing import Dict, List, Any


EXPECTED_CODE_DEPENDENCY_IDS = [
    "S05", "S06", "S07", "S08", "S09", "S10", "S11",
    "S23", "S24", "S25",
    "AUX-01", "AUX-02", "AUX-03", "AUX-04"
]

ALL_REQUIRED_IDS = [f"S{i:02d}" for i in range(1, 31)] + [
    "AUX-01", "AUX-02", "AUX-03", "AUX-04"
]


def audit_sources(sources_path: Path) -> dict:
    if not sources_path.is_file():
        return {
            "success": False,
            "error": f"File not found: {sources_path}",
            "sources_sha256": "",
            "total_required_ids": len(ALL_REQUIRED_IDS),
            "missing_ids": ALL_REQUIRED_IDS,
            "found_commit_hexes": 0,
            "violations": [f"File not found: {sources_path}"]
        }

    content = sources_path.read_text(encoding="utf-8")
    sha256 = hashlib.sha256(content.encode("utf-8")).hexdigest()

    # Check for prohibited dynamic branches in pinned SHA column
    prohibited = ["HEAD", "main pinned", "master pinned", "latest", "branch ="]
    violations: List[str] = []

    # 1. Global presence check for all 34 required IDs
    missing_ids = []
    for rid in ALL_REQUIRED_IDS:
        if f"**{rid}**" not in content and f"| {rid} |" not in content:
            missing_ids.append(rid)

    # 2. Parse all markdown table rows in the file
    table_rows = []
    for line_idx, line in enumerate(content.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("|") and not stripped.startswith("|---"):
            cols = [c.strip() for c in stripped.split("|")[1:-1]]
            if cols and not any(header in cols[0] for header in ["ID", "Platform Component", "Name"]):
                table_rows.append((line_idx, stripped, cols))

    # 3. Check for prohibited dynamic references and licenses in all table rows
    prohibited_licenses = ["GPL", "AGPL", "LGPL", "SSPL"]
    for line_idx, raw_line, cols in table_rows:
        row_id = cols[0].replace("*", "").strip()
        
        # Enforce prohibition of dynamic branch tracking tokens
        for term in prohibited:
            if re.search(r"\b" + re.escape(term) + r"\b", raw_line, re.IGNORECASE):
                violations.append(
                    f"Line {line_idx} ({row_id}) contains prohibited dynamic reference '{term}'"
                )

        # Enforce prohibition of viral copyleft licenses
        for lic in prohibited_licenses:
            if re.search(r"\b" + re.escape(lic) + r"(-[\d.]+|\b)", raw_line, re.IGNORECASE):
                violations.append(
                    f"Line {line_idx} ({row_id}) contains prohibited copyleft license '{lic}'"
                )

    # 4. Check Section 2: Upstream Code Repositories table
    # Expected format: | ID | Module / Crate | Type | Authoritative Repository | Pinned Version / Tag | Pinned Commit SHA (40-hex) | SPDX License | Purpose & Boundary Constraints |
    sha_pattern = re.compile(r"^[0-9a-f]{40}$")
    sec2_rows = {}
    in_sec2 = False
    
    for line in content.splitlines():
        if "## 2. Upstream Code Repositories" in line:
            in_sec2 = True
            continue
        if in_sec2 and line.startswith("## "):
            break
        if in_sec2 and line.strip().startswith("|") and not line.strip().startswith("|---"):
            cols = [c.strip() for c in line.strip().split("|")[1:-1]]
            if len(cols) >= 6 and not any(h in cols[0] for h in ["ID"]):
                dep_id = cols[0].replace("*", "").strip()
                sec2_rows[dep_id] = {
                    "name": cols[1],
                    "repo": cols[3],
                    "version": cols[4],
                    "sha": cols[5].replace("`", "").strip(),
                    "license": cols[6] if len(cols) > 6 else ""
                }

    # Verify each of the 14 mandatory code dependencies
    verified_shas = {}
    for dep_id in EXPECTED_CODE_DEPENDENCY_IDS:
        if dep_id not in sec2_rows:
            violations.append(f"Missing mandatory code dependency {dep_id} in Section 2 table")
            continue
        
        info = sec2_rows[dep_id]
        sha = info["sha"]
        
        if not sha_pattern.match(sha):
            violations.append(
                f"Dependency {dep_id} ({info['name']}) lacks valid 40-hex commit hash. Found: '{sha}'"
            )
        else:
            verified_shas[dep_id] = sha

    # Enforce exact count of 14 code dependencies with valid 40-hex SHA
    if len(verified_shas) != 14:
        violations.append(
            f"Expected exactly 14 valid 40-hex commit hashes in Section 2, but verified {len(verified_shas)}"
        )

    # Check for any unexpected / injected table entries in Section 2
    for dep_id in sec2_rows:
        if dep_id not in EXPECTED_CODE_DEPENDENCY_IDS:
            violations.append(f"Unexpected code dependency '{dep_id}' found in Section 2 table")

    # 5. Check ML Kit proprietary licensing
    for line_idx, line in enumerate(content.splitlines(), 1):
        if "ML Kit" in line and "Apache-2.0" in line:
            violations.append(f"Line {line_idx}: ML Kit misattributed as Apache-2.0 (must be proprietary Google ToS)")

    # 6. Check for truncated/broken URLs with literal '...'
    for line_idx, line in enumerate(content.splitlines(), 1):
        if "..." in line and ("http://" in line or "https://" in line):
            violations.append(f"Line {line_idx}: Truncated URL with literal '...' found: {line.strip()[:60]}")

    # 7. Global Copyleft Search across entire document
    for line_idx, line in enumerate(content.splitlines(), 1):
        if re.search(r"\b(GPL-\d|AGPL-\d|LGPL-\d|SSPL)\b", line, re.IGNORECASE):
            violations.append(f"Line {line_idx} contains copyleft license specification: '{line.strip()}'")

    success = (len(missing_ids) == 0) and (len(violations) == 0) and (len(verified_shas) == 14)

    return {
        "success": success,
        "sources_sha256": sha256,
        "total_required_ids": len(ALL_REQUIRED_IDS),
        "missing_ids": missing_ids,
        "found_commit_hexes": len(verified_shas),
        "violations": violations
    }


def main():
    repo_root = Path(__file__).resolve().parent.parent.parent
    sources_path = repo_root / "docs" / "sources.md"
    
    print("=" * 70)
    print("Mobile Cold Wallet - Upstream Sources Audit (ENV-01)")
    print("=" * 70)
    print(f"Auditing file: {sources_path}")
    
    res = audit_sources(sources_path)
    if not res["success"]:
        print(f"FAILED: Upstream sources audit failed with {len(res['violations'])} violations:")
        for v in res["violations"]:
            print(f"  [!] {v}")
        if res["missing_ids"]:
            print(f"  [!] Missing required IDs: {res['missing_ids']}")
        sys.exit(1)

    print(f"Status:             PASS")
    print(f"SHA-256:            {res['sources_sha256']}")
    print(f"Required IDs:       {res['total_required_ids']} checked, 0 missing")
    print(f"Immutable SHAs:     {res['found_commit_hexes']} 40-hex commit hashes verified (exact 14/14)")
    print(f"License rows:       no copyleft identifiers found (internal check, not a legal review)")
    print("=" * 70)
    sys.exit(0)


if __name__ == "__main__":
    main()
