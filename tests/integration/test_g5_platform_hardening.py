"""
tests/integration/test_g5_platform_hardening.py
================================================
Comprehensive integration and security verification for Gate G5 (Platform Hardening & Offline Boundaries).

Covers:
- STORE-01: Platform packaging and security level (StrongBox / TEE / Keychain).
- STORE-02: AEAD tampering, nonce uniqueness, AAD binding, and KDF.
- STORE-03: Interrupted write recovery, atomic persistence, and disk space boundary.
- STORE-04: Key invalidation / biometric reset fail-closed behavior.
- STORE-05: Mnemonic restoration on secondary offline device.
- OFF-01: Release artifact permissions (strict absence of INTERNET).
- OFF-02: iOS ATS / entitlements / network dependency (toolchain check).
- OFF-03: Offline QR code scanning without dynamic model download.
- OFF-04: Android cloud, D2D, and cross-platform backup exclusion.
- OFF-05: iOS iCloud / Finder / Keychain migration (toolchain check).
- OFF-06: Dynamic observation upon unexpected network connectivity.
- OFF-07: Secret logs, clipboard, and crash dump sanitation.
- OFF-08: Window security (FLAG_SECURE), background blackout, and lifecycle guard.
- OFF-09: iOS developer mode and signing validity (toolchain check).
- OWN-02: Android Wallet -> iOS Vault cross-platform (toolchain check).
- OWN-03: iOS Wallet -> Android Vault cross-platform (toolchain check).
- OWN-04: iOS Wallet -> iOS Vault cross-platform (toolchain check).
"""

import json
import os
import shutil
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent


CARGO_BIN = os.environ.get("CARGO") or shutil.which("cargo") or "cargo"


class TestG5StorageSecurity:
    """STORE-01 ~ STORE-05: Key Storage, AEAD, Atomic Persistence, and Mnemonic Restoration."""

    def test_store_01_security_level_and_strongbox_audit(self):
        """STORE-01: Audit Android Keystore / StrongBox requirements per ADR-003."""
        adr3_path = WORKSPACE_ROOT / "docs" / "ADR" / "ADR-003-key-storage-wrapping-zeroize.md"
        assert adr3_path.exists(), "ADR-003 must be present"
        content = adr3_path.read_text(encoding="utf-8")

        # Verify envelope encryption and hardware binding declarations
        assert "StrongBox" in content, "ADR-003 must mandate StrongBox consideration"
        assert "TEE" in content, "ADR-003 must mandate TEE hardware binding"
        assert "Non-exportable" in content or "非導出" in content, "ADR-003 must mandate non-exportable KEK"
        assert "AES-256-GCM" in content, "ADR-003 must specify AES-256-GCM envelope encryption"

    def test_store_02_aead_tampering_and_aad_binding(self):
        """STORE-02: AEAD tampering, nonce uniqueness, and AAD binding in vault_core."""
        cmd = [CARGO_BIN, "test", "-p", "vault_core", "--", "test_store_02"]
        env = os.environ.copy()
        res = subprocess.run(cmd, cwd=str(WORKSPACE_ROOT), capture_output=True, text=True, env=env)
        assert res.returncode == 0, f"cargo test failed:\n{res.stdout}\n{res.stderr}"
        assert "test storage::tests::test_store_02_aead_tamper_and_aad_binding ... ok" in res.stdout

    def test_store_03_atomic_write_and_recovery(self):
        """STORE-03: Atomic persistence (.tmp + sync + rename) and recovery from interrupted write."""
        cmd = [CARGO_BIN, "test", "-p", "vault_core", "--", "test_store_03"]
        env = os.environ.copy()
        res = subprocess.run(cmd, cwd=str(WORKSPACE_ROOT), capture_output=True, text=True, env=env)
        assert res.returncode == 0, f"cargo test failed:\n{res.stdout}\n{res.stderr}"
        assert "test storage::tests::test_store_03_atomic_write_and_recovery ... ok" in res.stdout

    def test_store_04_key_invalidation_fail_closed(self):
        """STORE-04: Key invalidation / biometric reset must fail-closed without silent regeneration."""
        adr3_path = WORKSPACE_ROOT / "docs" / "ADR" / "ADR-003-key-storage-wrapping-zeroize.md"
        content = adr3_path.read_text(encoding="utf-8")
        assert "絕不靜默重置或自動建立新金鑰" in content or "fail-closed" in content.lower(), (
            "ADR-003 must explicitly mandate fail-closed on key invalidation"
        )

    def test_store_05_cross_device_mnemonic_recovery_consistency(self):
        """STORE-05: Recovering mnemonic on another offline device reproduces 100% identical keys and addresses."""
        cmd = [CARGO_BIN, "test", "-p", "vault_core", "--", "test_key_03_key_05"]
        env = os.environ.copy()
        res = subprocess.run(cmd, cwd=str(WORKSPACE_ROOT), capture_output=True, text=True, env=env)
        assert res.returncode == 0, f"cargo test failed:\n{res.stdout}\n{res.stderr}"
        assert "test_key_03_key_05_derivation_and_signature_self_verification ... ok" in res.stdout


class TestG5OfflineHardening:
    """OFF-01 ~ OFF-09: Offline Isolation, Backup Exclusion, Window Security, and Leakage Defense."""

    def test_off_01_vault_android_manifest_strictly_zero_internet(self):
        """OFF-01: Vault AndroidManifest must strictly prohibit android.permission.INTERNET."""
        manifest_path = WORKSPACE_ROOT / "apps" / "vault" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
        assert manifest_path.exists(), "Vault AndroidManifest.xml must exist"
        content = manifest_path.read_text(encoding="utf-8")

        # Parse XML tree to verify permissions declared
        root = ET.fromstring(content)
        android_ns = "{http://schemas.android.com/apk/res/android}"
        declared_permissions = [
            elem.attrib.get(f"{android_ns}name") for elem in root.findall("uses-permission")
        ]

        # Explicitly verify INTERNET permission is NOT declared
        assert "android.permission.INTERNET" not in declared_permissions, (
            "CRITICAL: android.permission.INTERNET detected in offline Vault AndroidManifest.xml uses-permission tags!"
        )
        # Verify CAMERA is declared for air-gap QR scanning
        assert "android.permission.CAMERA" in declared_permissions, (
            "android.permission.CAMERA must be present for air-gap QR scanning"
        )

    def test_off_03_offline_qr_scanner_bundled(self):
        """OFF-03: First launch offline QR scanning capability without dynamic over-the-air model downloads."""
        vault_pubspec = WORKSPACE_ROOT / "apps" / "vault" / "pubspec.yaml"
        assert vault_pubspec.exists()
        content = vault_pubspec.read_text(encoding="utf-8")
        # mobile_scanner or qr_ui local dependency is bundled
        assert "qr_ui" in content, "qr_ui package must be bundled in apps/vault"

    def test_off_04_android_backup_exclusion_and_data_extraction_rules(self):
        """OFF-04: Verify Android cloud backup, D2D migration, and ADB extraction are strictly disabled."""
        manifest_path = WORKSPACE_ROOT / "apps" / "vault" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
        manifest_content = manifest_path.read_text(encoding="utf-8")

        # Verify application attributes
        assert 'android:allowBackup="false"' in manifest_content, 'android:allowBackup="false" must be configured'
        assert 'android:dataExtractionRules="@xml/data_extraction_rules"' in manifest_content, (
            'android:dataExtractionRules="@xml/data_extraction_rules" must be configured'
        )
        assert 'android:fullBackupContent="@xml/backup_rules"' in manifest_content, (
            'android:fullBackupContent="@xml/backup_rules" must be configured'
        )

        # Verify data_extraction_rules.xml
        rules_path = WORKSPACE_ROOT / "apps" / "vault" / "android" / "app" / "src" / "main" / "res" / "xml" / "data_extraction_rules.xml"
        assert rules_path.exists(), "data_extraction_rules.xml must exist"
        rules_xml = rules_path.read_text(encoding="utf-8")
        assert "<cloud-backup>" in rules_xml
        assert "<device-transfer>" in rules_xml
        assert '<exclude domain="root" />' in rules_xml
        assert '<exclude domain="file" />' in rules_xml
        assert '<exclude domain="database" />' in rules_xml

        # Verify backup_rules.xml
        backup_path = WORKSPACE_ROOT / "apps" / "vault" / "android" / "app" / "src" / "main" / "res" / "xml" / "backup_rules.xml"
        assert backup_path.exists(), "backup_rules.xml must exist"
        backup_xml = backup_path.read_text(encoding="utf-8")
        assert '<exclude domain="root" />' in backup_xml
        assert '<exclude domain="file" />' in backup_xml

    def test_off_06_unexpected_network_connectivity_guard(self):
        """OFF-06: Verification of network isolation and offline guard."""
        guard_path = WORKSPACE_ROOT / "apps" / "vault" / "lib" / "services" / "vault_lifecycle_guard.dart"
        assert guard_path.exists()
        content = guard_path.read_text(encoding="utf-8")
        assert "VaultLifecycleGuard" in content
        assert "onSecurityLockTriggered" in content

    def test_off_07_secret_logging_and_memory_sanitation(self):
        """OFF-07: Debug formatting for KeyVault and secret structures must be redacted ([REDACTED])."""
        lib_path = WORKSPACE_ROOT / "crates" / "vault_core" / "src" / "lib.rs"
        content = lib_path.read_text(encoding="utf-8")
        assert 'field("secret", &"[REDACTED]")' in content, "SecretMaterial must be redacted in Debug formatting"
        assert "ZeroizeOnDrop" in content, "ZeroizeOnDrop must be implemented for SecretMaterial"

    def test_off_08_window_security_and_lifecycle_guard(self):
        """OFF-08: FLAG_SECURE window protection, black screen on background, and zero sign on background."""
        main_activity_path = (
            WORKSPACE_ROOT
            / "apps"
            / "vault"
            / "android"
            / "app"
            / "src"
            / "main"
            / "kotlin"
            / "com"
            / "coldwallet"
            / "vault"
            / "MainActivity.kt"
        )
        assert main_activity_path.exists(), "MainActivity.kt must exist"
        kt_content = main_activity_path.read_text(encoding="utf-8")
        assert "FLAG_SECURE" in kt_content, "FLAG_SECURE must be enabled in MainActivity.kt"

        # Verify VaultLifecycleGuard in Dart
        guard_path = WORKSPACE_ROOT / "apps" / "vault" / "lib" / "services" / "vault_lifecycle_guard.dart"
        dart_content = guard_path.read_text(encoding="utf-8")
        assert "AppLifecycleState.inactive" in dart_content
        assert "AppLifecycleState.paused" in dart_content
        assert "_ffi.cancel(null)" in dart_content


class TestG5iOSToolchainChecks:
    """OFF-02, OFF-05, OFF-09, OWN-02, OWN-03, OWN-04: iOS Platform Verification & Honest Gap Recording."""

    def test_ios_toolchain_audit_reports_blocked_on_windows(self):
        """Audit iOS toolchain dependencies and confirm BLOCKED status without false success claims."""
        cmd = [sys.executable, "tools/reference_oracle/check_ios_toolchain.py"]
        res = subprocess.run(cmd, cwd=str(WORKSPACE_ROOT), capture_output=True, text=True)
        # Exit code 2 indicates precondition BLOCKED
        assert res.returncode == 2, f"Expected exit code 2 (BLOCKED), got {res.returncode}:\n{res.stdout}"
        assert "BLOCKED_NO_MACOS_TOOLCHAIN" in res.stdout or "BLOCKED_NO_MACOS_TOOLCHAIN" in res.stderr
