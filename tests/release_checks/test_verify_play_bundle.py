"""Synthetic AAB/ELF fixtures and tool stubs; optional checks use local tools only."""
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

import pytest

from tools.release_checks import android_sdk
from tools.release_checks import verify_play_bundle as play


REPO = Path(__file__).resolve().parents[2]
UPLOAD_CERT = "1234567890abcdef" * 4
OTHER_CERT = "abcdef1234567890" * 4
TOOLS = {"bundletool": ["bundletool"], "jarsigner": "jarsigner", "keytool": "keytool",
         "zipalign": "zipalign", "aapt2": "aapt2"}


def elf(alignments=(16384,), *, elf_class=2, endian=1, load_type=1):
    ident = b"\x7fELF" + bytes([elf_class, endian, 1]) + b"\0" * 9
    header = struct.pack("<HHIQQQIHHHHHH", 3, 183, 1, 0, 64, 0, 0, 64, 56, len(alignments), 0, 0, 0)
    segments = b"".join(struct.pack("<IIQQQQQQ", load_type, 5, 0, 0, 0, 0, 0, align) for align in alignments)
    return ident + header + segments


def bundle_file(tmp_path, libraries=None):
    if libraries is None:
        libraries = {f"base/lib/{abi}/libapp.so": elf() for abi in ("arm64-v8a", "x86_64")}
    path = tmp_path / "synthetic.aab"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("BundleConfig.pb", b"synthetic protobuf placeholder")
        archive.writestr("base/manifest/AndroidManifest.xml", b"synthetic protobuf placeholder")
        for name, binary in libraries.items():
            archive.writestr(name, binary)
    return path


def manifest(app="wallet", *, package=None, version_name="1.2.0", version_code="4", min_sdk=None,
             target_sdk=36, flags="", extra_permission="", omit_permission=None, components=""):
    package = package or ("com.coldwallet.watch" if app == "wallet" else "com.coldwallet.vault")
    permissions = ["android.permission.CAMERA", f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]
    permissions += (["android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE"] if app == "wallet"
                    else ["android.permission.USE_BIOMETRIC"])
    uses = "".join(f'<uses-permission android:name="{name}"/>' for name in permissions if name != omit_permission)
    minimum = min_sdk if min_sdk is not None else (24 if app == "wallet" else 28)
    return (f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" '
            f'android:versionName="{version_name}" android:versionCode="{version_code}">'
            f'<uses-sdk android:minSdkVersion="{minimum}" android:targetSdkVersion="{target_sdk}"/>'
            f'{uses}{extra_permission}<application {flags}>{components}</application></manifest>')


def certificate_output(digest=UPLOAD_CERT, *, signer=1, chain=False, owner="CN=Throwaway"):
    colon = ":".join(digest[index:index + 2] for index in range(0, 64, 2)).upper()
    output = f"Signer #{signer}:\n\nCertificate #1:\nOwner: {owner}\nCertificate fingerprints:\n\tSHA256: {colon}\n"
    if chain:
        output += f"Certificate #2:\nOwner: CN=Root\n\tSHA256: {OTHER_CERT.upper()}\n"
    return output


@pytest.fixture
def repo(tmp_path):
    for app in ("wallet", "vault"):
        pubspec = tmp_path / "repo/apps" / app / "pubspec.yaml"
        pubspec.parent.mkdir(parents=True)
        pubspec.write_text("name: synthetic\nversion: 1.2.0+4\n", encoding="utf-8")
    return tmp_path / "repo"


@pytest.fixture
def stub_tools(monkeypatch):
    state = {"manifest": manifest(), "certificate": certificate_output(), "jar": "jar verified, with signer errors.\n",
             "fail": set(), "calls": [], "apks": {"splits/base-arm64_v8a.apk": True, "splits/base-x86_64.apk": True}}

    def run(command, **kwargs):
        command = [str(arg) for arg in command]
        state["calls"].append((command, kwargs))
        operation = command[1] if command[0] == "bundletool" else command[0]
        if operation in state["fail"]:
            raise android_sdk.ToolError(f"{operation} stub failure")
        if operation == "dump":
            return state["manifest"]
        if operation == "jarsigner":
            return state["jar"]
        if operation == "keytool" and "-printcert" in command:
            return state["certificate"]
        if operation == "keytool" and "-genkeypair" in command:
            keystore = Path(command[command.index("-keystore") + 1])
            keystore.write_bytes(b"throwaway keystore stub")
        if operation == "build-apks":
            output = Path(next(value.split("=", 1)[1] for value in command if value.startswith("--output=")))
            with zipfile.ZipFile(output, "w") as archive:
                for name, aligned in state["apks"].items():
                    contents = io.BytesIO()
                    with zipfile.ZipFile(contents, "w") as apk:
                        apk.writestr("lib/arm64-v8a/libapp.so", elf())
                        apk.writestr("alignment-marker", "good" if aligned else "bad")
                    archive.writestr(name, contents.getvalue())
        if operation == "zipalign":
            with zipfile.ZipFile(command[-1]) as archive:
                if archive.read("alignment-marker") == b"bad":
                    raise android_sdk.ToolError("zipalign exited 1: native library not aligned")
        return "OK\n"

    monkeypatch.setattr(play, "run_command", run)
    return state


def check_row(report, name):
    return next(row for row in report["checks"] if row["name"] == name)


@pytest.mark.parametrize("app", ["wallet", "vault"])
def test_all_bundle_checks_pass_and_record_hashes(tmp_path, repo, stub_tools, app):
    stub_tools["manifest"] = manifest(app)
    result = play.audit_bundle(bundle_file(tmp_path), app, repo, TOOLS, UPLOAD_CERT)
    assert result["status"] == "PASS"
    assert len(result["checks"]) == 11
    assert all(row["status"] == "PASS" and row["detail"] for row in result["checks"])
    native = check_row(result, "native_libraries")["detail"]
    assert native["abis"] == ["arm64-v8a", "x86_64"]
    assert len(native["libraries"]) == 2
    assert all(row["sha256"] == hashlib.sha256(elf()).hexdigest() for row in native["libraries"])
    assert check_row(result, "jar_signature")["detail"]["upload_certificate_pinned"] is True


@pytest.mark.parametrize("operation,failed_check", [("validate", "bundletool_validate"), ("dump", "manifest_dump"),
                                                    ("jarsigner", "jar_signature"), ("keytool", "jar_signature")])
def test_tool_failures_are_reported_without_short_circuit(tmp_path, repo, stub_tools, operation, failed_check):
    stub_tools["fail"].add(operation)
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS)
    assert result["status"] == "FAIL"
    assert check_row(result, failed_check)["status"] == "FAIL"
    assert check_row(result, "native_libraries")["status"] == "PASS"
    if operation == "dump":
        for name in ("package", "version", "sdk_levels", "release_flags", "permissions", "components"):
            assert "manifest_dump failed" in check_row(result, name)["detail"]


@pytest.mark.parametrize("xml,failed_check", [
    ("not XML", "manifest_dump"),
    (manifest(package="com.example.wrong"), "package"),
    (manifest(version_code="5"), "version"),
    (manifest(version_name="1.2.1"), "version"),
    (manifest(min_sdk=23), "sdk_levels"),
    (manifest(target_sdk=35), "sdk_levels"),
    (manifest(flags='android:debuggable="true"'), "release_flags"),
    (manifest(flags='android:testOnly="true"'), "release_flags"),
    (manifest(flags='android:debuggable="@bool/debuggable"'), "release_flags"),
    (manifest(omit_permission="android.permission.CAMERA"), "permissions"),
    (manifest(extra_permission='<uses-permission android:name="android.permission.NFC"/>'), "permissions"),
])
def test_manifest_failures(tmp_path, repo, stub_tools, xml, failed_check):
    stub_tools["manifest"] = xml
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS)
    assert result["status"] == "FAIL"
    assert check_row(result, failed_check)["status"] == "FAIL"


@pytest.mark.parametrize("permission", ["INTERNET", "ACCESS_NETWORK_STATE", "NFC"])
@pytest.mark.parametrize("tag", ["uses-permission", "uses-permission-sdk-23"])
def test_vault_rejects_network_and_nfc_permissions(tmp_path, repo, stub_tools, permission, tag):
    stub_tools["manifest"] = manifest("vault", extra_permission=f'<{tag} android:name="android.permission.{permission}"/>')
    result = play.audit_bundle(bundle_file(tmp_path), "vault", repo, TOOLS)
    row = check_row(result, "permissions")
    assert row["status"] == "FAIL"
    assert f"android.permission.{permission}" in row["detail"]["unexpected"]


def test_permission_max_sdk_is_not_treated_as_unconditional():
    xml = manifest().replace('android:name="android.permission.CAMERA"',
                             'android:name="android.permission.CAMERA" android:maxSdkVersion="25"')
    with pytest.raises(play.CheckError):
        play.check_permissions(play.parse_manifest(xml), "wallet")


@pytest.mark.parametrize("component, app", [
    (component, app)
    for component in [
        "com.google.android.datatransport.runtime.backends.TransportBackendDiscovery",
        "com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService",
        "com.google.android.datatransport.runtime.scheduling.jobscheduling.AlarmManagerSchedulerBroadcastReceiver",
    ]
    for app in ["wallet", "vault"]
] + [("androidx.profileinstaller.ProfileInstallReceiver", "vault")])
def test_transport_and_profileinstaller_components_are_forbidden(tmp_path, repo, stub_tools, component, app):
    stub_tools["manifest"] = manifest(app, components=f'<service android:name="{component}"/>')
    result = play.audit_bundle(bundle_file(tmp_path), app, repo, TOOLS)
    assert check_row(result, "components")["status"] == "FAIL"
    assert component in check_row(result, "components")["detail"]["components"]


def test_wallet_keeps_the_profile_installer_receiver(tmp_path, repo, stub_tools):
    stub_tools["manifest"] = manifest("wallet", components='<receiver android:name="androidx.profileinstaller.ProfileInstallReceiver"/>')
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS)
    assert check_row(result, "components")["status"] == "PASS"


@pytest.mark.parametrize("xml", ["<not-manifest/>", '<manifest><application/></manifest>',
                                  '<manifest><uses-sdk/></manifest>',
                                  '<manifest package="synthetic"><uses-sdk/><application/><application/></manifest>',
                                  '<manifest><uses-sdk/><application><activity name=".MainActivity"/></application></manifest>'])
def test_malformed_manifest_structure_is_rejected(xml):
    with pytest.raises(play.CheckError):
        play.parse_manifest(xml)


def test_vault_minimum_sdk_and_missing_pubspec(tmp_path, repo, stub_tools):
    stub_tools["manifest"] = manifest("vault", min_sdk=24)
    result = play.audit_bundle(bundle_file(tmp_path), "vault", repo, TOOLS)
    assert check_row(result, "sdk_levels")["status"] == "FAIL"
    (repo / "apps/wallet/pubspec.yaml").unlink()
    stub_tools["manifest"] = manifest()
    result = play.audit_bundle(tmp_path / "synthetic.aab", "wallet", repo, TOOLS)
    assert check_row(result, "version")["status"] == "FAIL"


@pytest.mark.parametrize("version", ["1.2.0+4", "'1.2.0+4' # release", '"1.2.0+4"'])
def test_pubspec_version_forms(repo, version):
    (repo / "apps/wallet/pubspec.yaml").write_text(f"version: {version}\n", encoding="utf-8")
    assert play.pubspec_version(repo, "wallet") == {"version_name": "1.2.0", "version_code": 4}


def test_invalid_pubspec_version_is_reported(repo):
    (repo / "apps/wallet/pubspec.yaml").write_text("version: no-build-number\n", encoding="utf-8")
    with pytest.raises(play.CheckError, match="x.y.z"):
        play.pubspec_version(repo, "wallet")


@pytest.mark.parametrize("alignments", [(16384,), (65536,), (16384, 32768)])
def test_elf64_good_alignment(alignments):
    assert play.elf_load_alignments(elf(alignments)) == list(alignments)


@pytest.mark.parametrize("binary", [b"", b"not-ELF" * 16, elf((4096,)), elf((16384, 4096)), elf((16385,)),
                                     elf((0,)), elf(elf_class=1), elf(endian=2), elf(load_type=2), elf()[:-1], elf(())])
def test_bad_elf_headers_and_alignment(binary):
    with pytest.raises(play.CheckError):
        play.elf_load_alignments(binary)


def test_four_kb_library_failure_keeps_all_library_hashes(tmp_path):
    libraries = {"base/lib/arm64-v8a/libapp.so": elf((4096,)), "base/lib/x86_64/libapp.so": elf()}
    with pytest.raises(play.CheckError) as error:
        play.check_native_libraries(bundle_file(tmp_path, libraries))
    rows = error.value.detail["libraries"]
    assert len(rows) == 2
    assert rows[0]["status"] == "FAIL"
    assert rows[0]["detail"]["pt_load_alignments"] == [4096]
    assert rows[0]["sha256"] == hashlib.sha256(elf((4096,))).hexdigest()
    assert rows[1]["status"] == "PASS"


@pytest.mark.parametrize("abis", [[], ["arm64-v8a"], ["arm64-v8a", "x86_64", "armeabi-v7a"]])
def test_empty_missing_or_extra_abi_fails(tmp_path, abis):
    libraries = {f"base/lib/{abi}/libapp.so": elf() for abi in abis}
    with pytest.raises(play.CheckError) as error:
        play.check_native_libraries(bundle_file(tmp_path, libraries))
    assert error.value.detail["abis"] == sorted(abis)
    assert error.value.detail["errors"]


def test_duplicate_zip_entries_are_rejected(tmp_path):
    path = bundle_file(tmp_path)
    with zipfile.ZipFile(path, "a") as archive:
        with pytest.warns(UserWarning, match="Duplicate name"):
            archive.writestr("base/lib/arm64-v8a/libapp.so", elf())
    with pytest.raises(play.CheckError) as error:
        play.check_native_libraries(path)
    assert "duplicate ZIP entries" in error.value.detail["errors"]


def test_invalid_native_path_is_rejected(tmp_path):
    path = bundle_file(tmp_path, {"base/lib/../libbad.so": elf(), "base/lib/x86_64/subdir/libbad.so": elf()})
    with pytest.raises(play.CheckError) as error:
        play.check_native_libraries(path)
    assert any("invalid native library path" in value for value in error.value.detail["errors"])


def test_extra_feature_manifest_cannot_bypass_the_base_audit(tmp_path, repo, stub_tools):
    bundle = bundle_file(tmp_path)
    with zipfile.ZipFile(bundle, "a") as archive:
        archive.writestr("feature/manifest/AndroidManifest.xml", b"unchecked feature")
    result = play.audit_bundle(bundle, "wallet", repo, TOOLS)
    assert result["status"] == "FAIL"
    row = check_row(result, "bundle_layout")
    assert row["status"] == "FAIL"
    assert row["detail"]["modules"] == ["base", "feature"]


def test_missing_bundle_layout_entries_are_reported(tmp_path):
    bundle = tmp_path / "empty.aab"
    with zipfile.ZipFile(bundle, "w"):
        pass
    with pytest.raises(play.CheckError) as error:
        play.check_bundle_layout(bundle)
    assert error.value.detail["missing_entries"] == ["BundleConfig.pb", "base/manifest/AndroidManifest.xml"]


def test_non_zip_aab_is_recorded_as_failure(tmp_path, repo, stub_tools):
    path = tmp_path / "bad.aab"
    path.write_bytes(b"not a ZIP")
    result = play.audit_bundle(path, "wallet", repo, TOOLS)
    assert result["status"] == "FAIL"
    assert check_row(result, "native_libraries")["status"] == "FAIL"


@pytest.mark.parametrize("expected", [UPLOAD_CERT, UPLOAD_CERT.upper(),
                                      ":".join(UPLOAD_CERT[index:index + 2] for index in range(0, 64, 2))])
def test_signer_fingerprint_forms_and_certificate_chain(expected):
    result = play.signer_certificate(certificate_output(chain=True).replace("\n", "\r\n"), expected)
    assert result["certificate_sha256"] == UPLOAD_CERT
    assert result["signer_count"] == 1


def test_jdk8_keytool_layout_is_parsed():
    # JDK 8 prints "Signature:" and then the chain, leaf first, without numbers.
    jdk8 = certificate_output(chain=True).replace("Certificate #1:\n", "Signature:\n\n").replace("Certificate #2:\n", "")
    result = play.signer_certificate(jdk8, UPLOAD_CERT)
    assert result["certificate_sha256"] == UPLOAD_CERT
    assert result["signer_count"] == 1


def test_unpinned_signer_is_explicit():
    assert play.signer_certificate(certificate_output())["upload_certificate_pinned"] is False


@pytest.mark.parametrize("output", ["", "Not a signed jar file\n", "Signer #1:\nno certificate\n",
                                    "Signer #1:\nCertificate #1:\nSHA1: AA:BB\n",
                                    certificate_output() + certificate_output(OTHER_CERT, signer=2)])
def test_unsigned_malformed_or_multiple_signers_are_rejected(output):
    with pytest.raises(play.CheckError):
        play.signer_certificate(output)


def test_debug_certificate_is_refused_even_when_expected(tmp_path, repo, stub_tools):
    stub_tools["certificate"] = certificate_output(play.DEBUG_CERT_SHA256)
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS, play.DEBUG_CERT_SHA256)
    row = check_row(result, "jar_signature")
    assert row["status"] == "FAIL"
    assert "debug certificate" in row["detail"]["error"]


@pytest.mark.parametrize("owner", ["CN=Android Debug, O=Android, C=US", "C=US, O=Android, CN=Android Debug"])
@pytest.mark.parametrize("pinned", [False, True])
def test_another_machines_debug_certificate_is_refused(tmp_path, repo, stub_tools, owner, pinned):
    # Each SDK install has its own debug keystore; only the subject is shared.
    stub_tools["certificate"] = certificate_output(OTHER_CERT, owner=owner)
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS, OTHER_CERT if pinned else None)
    row = check_row(result, "jar_signature")
    assert row["status"] == "FAIL"
    assert row["detail"]["error"] == "debug certificate is forbidden for Play uploads"
    assert row["detail"]["owner"] == owner
    assert result["status"] == "FAIL"


def test_signer_owner_is_recorded_and_lookalike_subjects_are_not_debug():
    owner = "CN=FCW upload, O=Android Debug tools"
    result = play.signer_certificate(certificate_output(owner=owner), UPLOAD_CERT)
    assert result["certificate_owner"] == owner


def test_missing_owner_is_rejected():
    with pytest.raises(play.CheckError, match="owner"):
        play.signer_certificate(certificate_output().replace("Owner: CN=Throwaway\n", ""))


def test_a_bundle_without_upload_pin_is_only_a_diagnostic(tmp_path, repo, stub_tools, monkeypatch, capsys):
    bundle = bundle_file(tmp_path)
    monkeypatch.setattr(play, "discover_tools", lambda *args: TOOLS)
    assert play.main(["--wallet", str(bundle), "--repo", str(repo)]) == 1
    report = json.loads(capsys.readouterr().out)
    assert report["status"] == "DIAGNOSTIC"
    artifact = report["artifacts"][0]
    assert artifact["status"] == "DIAGNOSTIC"
    assert check_row(artifact, "jar_signature")["status"] == "PASS"
    assert check_row(artifact, "upload_certificate_pin")["status"] == "MISSING"
    # Any real failure still outranks the missing pin.
    stub_tools["fail"].add("jarsigner")
    assert play.main(["--wallet", str(bundle), "--repo", str(repo)]) == 1
    assert json.loads(capsys.readouterr().out)["status"] == "FAIL"


def test_upload_certificate_mismatch_is_refused():
    with pytest.raises(play.CheckError) as error:
        play.signer_certificate(certificate_output(), OTHER_CERT)
    assert error.value.detail["error"] == "upload certificate mismatch"


@pytest.mark.parametrize("value", ["short", "g" * 64])
def test_invalid_expected_sha256_is_refused(value):
    with pytest.raises(ValueError, match="SHA-256"):
        play.normalized_sha256(value)


@pytest.mark.parametrize("output", ["jar is unsigned.\n", "The jar will be treated as unsigned.\n", ""])
def test_jarsigner_zero_exit_without_verification_is_refused(tmp_path, repo, stub_tools, output):
    stub_tools["jar"] = output
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS)
    assert check_row(result, "jar_signature")["status"] == "FAIL"


def test_build_apks_checks_every_split_and_removes_temporary_key(tmp_path, stub_tools):
    detail = play.build_apks_and_check_alignment(bundle_file(tmp_path), TOOLS)
    assert detail["temporary_signer"] is True
    assert len(detail["apks"]) == 2
    assert all(row["status"] == "PASS" and row["uncompressed_native_libraries"] for row in detail["apks"])
    calls = stub_tools["calls"]
    align = [command for command, _ in calls if command[0] == "zipalign"]
    assert len(align) == 2
    assert all(command[1:5] == ["-c", "-P", "16", "4"] for command in align)
    generation = next(command for command, _ in calls if "-genkeypair" in command)
    assert generation[generation.index("-storetype") + 1] == "PKCS12"
    keystore = Path(generation[generation.index("-keystore") + 1])
    assert not keystore.parent.exists()
    build = next(command for command, _ in calls if "build-apks" in command)
    assert any(value.startswith("--ks-pass=file:") for value in build)
    assert "--connected-device" not in build


def test_one_misaligned_apk_fails_but_all_apks_are_checked(tmp_path, repo, stub_tools):
    stub_tools["apks"] = {"splits/one.apk": False, "splits/two.apk": True}
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS, build_apks=True)
    row = check_row(result, "apk_zipalign")
    assert result["status"] == row["status"] == "FAIL"
    assert [apk["status"] for apk in row["detail"]["apks"]] == ["FAIL", "PASS"]


@pytest.mark.parametrize("operation", ["keytool", "build-apks"])
def test_apk_generation_tool_failures(tmp_path, repo, stub_tools, operation):
    stub_tools["fail"].add(operation)
    result = play.audit_bundle(bundle_file(tmp_path), "wallet", repo, TOOLS, build_apks=True)
    assert check_row(result, "apk_zipalign")["status"] == "FAIL"


def test_empty_generated_apk_set_fails(tmp_path, stub_tools):
    stub_tools["apks"] = {}
    with pytest.raises(play.CheckError) as error:
        play.build_apks_and_check_alignment(bundle_file(tmp_path), TOOLS)
    assert error.value.detail["apks"] == []


@pytest.mark.parametrize("exit_code", [0, 4, 16, 20])
def test_jar_strict_exit_bits_are_respected(tmp_path, monkeypatch, exit_code):
    def run(command, **kwargs):
        output = "jar verified, with signer errors.\n" if "jarsigner" in command[0] else certificate_output()
        return subprocess.CompletedProcess(command, exit_code if "jarsigner" in command[0] else 0, output, "")

    monkeypatch.setattr(play.subprocess, "run", run)
    if exit_code in (0, 4):
        assert play.verify_jar_signature(tmp_path / "fixture.aab", TOOLS)["certificate_sha256"] == UPLOAD_CERT
    else:
        with pytest.raises(android_sdk.ToolError, match=f"exited {exit_code}"):
            play.verify_jar_signature(tmp_path / "fixture.aab", TOOLS)


@pytest.mark.parametrize("error", [FileNotFoundError("missing"), subprocess.TimeoutExpired(["tool"], 1)])
def test_tool_launch_errors_do_not_echo_signing_arguments(monkeypatch, error):
    def run(*args, **kwargs):
        raise error

    monkeypatch.setattr(play.subprocess, "run", run)
    with pytest.raises(android_sdk.ToolError) as caught:
        play.run_command(["keytool", "-storepass", "never-echo-this"])
    assert "never-echo-this" not in str(caught.value)


def test_cli_both_apps_json_report_and_failure_exit(tmp_path, repo, stub_tools, monkeypatch, capsys):
    bundle = bundle_file(tmp_path)
    output = tmp_path / "report.json"
    monkeypatch.setattr(play, "discover_tools", lambda *args: TOOLS)
    # The same Wallet manifest is deliberately wrong for the Vault.
    assert play.main(["--wallet", str(bundle), "--vault", str(bundle), "--repo", str(repo), "--out", str(output)]) == 1
    report = json.loads(output.read_text())
    assert report["status"] == "FAIL"
    # Unpinned, the otherwise good Wallet bundle is only a diagnostic.
    assert [row["status"] for row in report["artifacts"]] == ["DIAGNOSTIC", "FAIL"]
    assert json.loads(capsys.readouterr().out) == report


def test_cli_single_app_success_and_tool_discovery(tmp_path, repo, stub_tools, monkeypatch, capsys):
    bundle = bundle_file(tmp_path)
    monkeypatch.setattr(play, "discover_tools", lambda *args: TOOLS)
    assert play.main(["--wallet", str(bundle), "--repo", str(repo),
                      "--expect-upload-cert-sha256-wallet", UPLOAD_CERT, "--build-apks"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "PASS"
    assert play.main(["--discover-tools"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["artifacts"] == []
    assert report["checks"][0]["detail"] == TOOLS


def test_cli_discovery_failure_still_writes_json(tmp_path, monkeypatch, capsys):
    def missing(*args):
        raise android_sdk.ToolError("zipalign missing")

    monkeypatch.setattr(play, "discover_tools", missing)
    output = tmp_path / "report.json"
    assert play.main(["--wallet", str(tmp_path / "missing.aab"), "--out", str(output)]) == 1
    report = json.loads(output.read_text())
    assert report["checks"][0]["status"] == "FAIL"
    assert "zipalign missing" in capsys.readouterr().out


def test_report_cannot_overwrite_aab(tmp_path, repo, stub_tools, monkeypatch, capsys):
    bundle = bundle_file(tmp_path)
    original = bundle.read_bytes()
    monkeypatch.setattr(play, "discover_tools", lambda *args: TOOLS)
    assert play.main(["--wallet", str(bundle), "--repo", str(repo), "--out", str(bundle)]) == 1
    assert bundle.read_bytes() == original
    assert check_row(json.loads(capsys.readouterr().out), "write_report")["status"] == "FAIL"


def test_report_write_error_is_reported(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(play, "discover_tools", lambda *args: TOOLS)
    assert play.main(["--discover-tools", "--out", str(tmp_path)]) == 1
    assert check_row(json.loads(capsys.readouterr().out), "write_report")["status"] == "FAIL"


@pytest.mark.parametrize("arguments", [[], ["--discover-tools", "--build-apks"],
                                         ["--expect-upload-cert-sha256-vault", UPLOAD_CERT, "--wallet", "x.aab"],
                                         ["--wallet", "x.aab", "--expect-upload-cert-sha256-wallet", "invalid"]])
def test_cli_invalid_arguments_fail(arguments):
    with pytest.raises(SystemExit) as error:
        play.main(arguments)
    assert error.value.code == 2


def test_direct_script_help_works():
    result = subprocess.run([sys.executable, str(REPO / "tools/release_checks/verify_play_bundle.py"), "--help"],
                            capture_output=True, text=True)
    assert result.returncode == 0
    assert "--expect-upload-cert-sha256-wallet" in result.stdout


def test_local_jdk_verifies_synthetic_jar_and_rejects_tampering(tmp_path):
    try:
        tools = {name: android_sdk.discover_java_tool(name) for name in ("keytool", "jarsigner")}
    except android_sdk.ToolError as error:
        pytest.skip(f"local JDK tools unavailable: {error}")
    keystore = tmp_path / "fixture.p12"
    password = tmp_path / "password.txt"
    password.write_text("synthetic-test-password", encoding="utf-8")
    play.run_command([tools["keytool"], "-genkeypair", "-noprompt", "-storetype", "PKCS12", "-keystore", keystore,
                      "-storepass:file", password, "-alias", "fixture", "-dname", "CN=Synthetic test",
                      "-keyalg", "RSA", "-keysize", "2048", "-validity", "1"])
    jar = bundle_file(tmp_path)
    play.run_command([tools["jarsigner"], "-keystore", keystore, "-storepass:file", password, jar, "fixture"])
    assert play.verify_jar_signature(jar, tools)["signer_count"] == 1
    signed_bytes = jar.read_bytes()
    with zipfile.ZipFile(jar, "a") as archive:
        archive.writestr("unsigned-payload.txt", b"unsigned")
    with pytest.raises(android_sdk.ToolError):
        play.verify_jar_signature(jar, tools)
    with zipfile.ZipFile(io.BytesIO(signed_bytes)) as original, zipfile.ZipFile(jar, "w") as changed:
        for entry in original.infolist():
            content = b"tampered" if entry.filename == "base/lib/arm64-v8a/libapp.so" else original.read(entry)
            changed.writestr(entry, content)
    with pytest.raises(android_sdk.ToolError):
        play.verify_jar_signature(jar, tools)


def test_local_jdk_refuses_any_android_debug_subject(tmp_path):
    # A fresh key with the debug keystore's subject, as on any other machine.
    try:
        tools = {name: android_sdk.discover_java_tool(name) for name in ("keytool", "jarsigner")}
    except android_sdk.ToolError as error:
        pytest.skip(f"local JDK tools unavailable: {error}")
    keystore = tmp_path / "debug.p12"
    password = tmp_path / "password.txt"
    password.write_text("synthetic-test-password", encoding="utf-8")
    play.run_command([tools["keytool"], "-genkeypair", "-noprompt", "-storetype", "PKCS12", "-keystore", keystore,
                      "-storepass:file", password, "-alias", "androiddebugkey",
                      "-dname", "CN=Android Debug,O=Android,C=US",
                      "-keyalg", "RSA", "-keysize", "2048", "-validity", "1"])
    jar = bundle_file(tmp_path)
    play.run_command([tools["jarsigner"], "-keystore", keystore, "-storepass:file", password, jar, "androiddebugkey"])
    with pytest.raises(play.CheckError) as unpinned:
        play.verify_jar_signature(jar, tools)
    assert unpinned.value.detail["error"] == "debug certificate is forbidden for Play uploads"
    digest = unpinned.value.detail["actual"]
    assert digest != play.DEBUG_CERT_SHA256
    with pytest.raises(play.CheckError, match="debug certificate"):
        play.verify_jar_signature(jar, tools, digest)


def test_local_zipalign_detects_synthetic_apk_alignment(tmp_path):
    try:
        sdk = android_sdk.discover_sdk()
        build_tools = android_sdk.discover_build_tools(sdk)
        filename = "zipalign.exe" if sys.platform == "win32" else "zipalign"
        tool = android_sdk.executable(build_tools / filename, "zipalign", "Windows" if sys.platform == "win32" else "Linux")
    except android_sdk.ToolError as error:
        pytest.skip(f"Android zipalign unavailable: {error}")
    source, aligned = tmp_path / "unaligned.apk", tmp_path / "aligned.apk"
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("lib/arm64-v8a/libfixture.so", elf(), compress_type=zipfile.ZIP_STORED)
    with pytest.raises(android_sdk.ToolError):
        play.run_command([tool, "-c", "-P", "16", "4", source])
    play.run_command([tool, "-P", "16", "4", source, aligned])
    play.run_command([tool, "-c", "-P", "16", "4", aligned])
