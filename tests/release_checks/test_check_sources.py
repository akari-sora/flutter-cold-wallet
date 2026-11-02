"""
tests/release_checks/test_check_sources.py
Unit and regression test suite for tools/release_checks/check_sources.py
"""

import sys
import pytest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "tools" / "release_checks"))
import check_sources


def test_audit_nonexistent_file_fails(tmp_path):
    fake_path = tmp_path / "nonexistent.md"
    res = check_sources.audit_sources(fake_path)
    assert res["success"] is False
    assert any("File not found" in v for v in res["violations"])


def test_audit_catches_gpl_injection(tmp_path):
    base_file = PROJECT_ROOT / "docs" / "sources.md"
    content = base_file.read_text(encoding="utf-8")
    poisoned = content + "\n| **S99** | evil | Crate | https://evil | 1.0 | `0123456789abcdef0123456789abcdef01234567` | GPL-3.0 | Bad |\n"
    tmp_file = tmp_path / "sources_gpl.md"
    tmp_file.write_text(poisoned, encoding="utf-8")
    
    res = check_sources.audit_sources(tmp_file)
    assert res["success"] is False
    assert any("prohibited copyleft license 'GPL'" in v or "copyleft license specification" in v for v in res["violations"])


def test_audit_catches_head_injection(tmp_path):
    base_file = PROJECT_ROOT / "docs" / "sources.md"
    content = base_file.read_text(encoding="utf-8")
    poisoned = content + "\n| **S99** | evil | Crate | https://evil | HEAD | `0123456789abcdef0123456789abcdef01234567` | MIT | Bad |\n"
    tmp_file = tmp_path / "sources_head.md"
    tmp_file.write_text(poisoned, encoding="utf-8")
    
    res = check_sources.audit_sources(tmp_file)
    assert res["success"] is False
    assert any("prohibited dynamic reference 'HEAD'" in v for v in res["violations"])


def test_audit_requires_exact_14_shas(tmp_path):
    # Verify that if one SHA is missing or fake, it fails
    base_file = PROJECT_ROOT / "docs" / "sources.md"
    content = base_file.read_text(encoding="utf-8")
    # Replace one 40-hex SHA with crates.io pinned
    tampered = content.replace("7d64aa9012a04b54b7d5a40bb5999d869f92fb6f", "crates.io pinned")
    tmp_file = tmp_path / "sources_tampered_sha.md"
    tmp_file.write_text(tampered, encoding="utf-8")
    
    res = check_sources.audit_sources(tmp_file)
    assert res["success"] is False
    assert any("lacks valid 40-hex commit hash" in v for v in res["violations"])


def test_no_dead_code_prohibited():
    code = (PROJECT_ROOT / "tools" / "release_checks" / "check_sources.py").read_text(encoding="utf-8")
    import re
    matches = list(re.finditer(r"\bprohibited\b", code))
    assert len(matches) > 1, "Variable 'prohibited' must be referenced and evaluated, not dead code!"
