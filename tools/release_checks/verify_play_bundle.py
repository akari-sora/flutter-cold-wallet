"""Audit FCW Play AABs locally; no device, network, or production keystore needed."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

if __package__:
    from .android_sdk import ToolError, add_tool_arguments, discover_tools
else:
    from android_sdk import ToolError, add_tool_arguments, discover_tools


DEBUG_CERT_SHA256 = "fde363bec8539d5e03afca6620fa8265c28bc7445840cf3b4d821fc36f59b011"
ANDROID = "{http://schemas.android.com/apk/res/android}"
EXPECTED_ABIS = {"arm64-v8a", "x86_64"}
PACKAGES = {"wallet": "com.coldwallet.watch", "vault": "com.coldwallet.vault"}
MIN_SDK = {"wallet": 24, "vault": 28}
TRANSPORT_COMPONENTS = {
    "com.google.android.datatransport.runtime.backends.TransportBackendDiscovery",
    "com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService",
    "com.google.android.datatransport.runtime.scheduling.jobscheduling.AlarmManagerSchedulerBroadcastReceiver",
}
# ML Kit's telemetry transport must be absent from both apps. The offline Vault
# also drops the exported profile-installer receiver; the Wallet keeps it, since
# it only installs baseline profiles and sends nothing.
FORBIDDEN_COMPONENTS = {
    "wallet": TRANSPORT_COMPONENTS,
    "vault": TRANSPORT_COMPONENTS | {"androidx.profileinstaller.ProfileInstallReceiver"},
}


class CheckError(RuntimeError):
    def __init__(self, detail):
        self.detail = detail
        super().__init__(detail if isinstance(detail, str) else json.dumps(detail))


def require(condition, detail):
    if not condition:
        raise CheckError(detail)


def normalized_sha256(value):
    digest = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("expected a SHA-256 certificate digest (64 hex digits, optionally colon-separated)")
    return digest


def run_command(command, *, accepted_codes=(0,), timeout=180):
    command = [str(arg) for arg in command]
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        # Do not include argv: signing commands may contain credential arguments.
        raise ToolError(f"{Path(command[0]).name} could not run: {type(error).__name__}") from error
    if result.returncode not in accepted_codes:
        detail = (result.stderr.strip() or result.stdout.strip())[-4000:]
        raise ToolError(f"{Path(command[0]).name} exited {result.returncode}: {detail}")
    return result.stdout


def pubspec_version(repo, app):
    text = (Path(repo) / "apps" / app / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*['\"]?(\d+\.\d+\.\d+)\+(\d+)['\"]?\s*(?:#.*)?$", text, re.M)
    if match is None:
        raise CheckError(f"apps/{app}/pubspec.yaml needs version: x.y.z+N")
    return {"version_name": match.group(1), "version_code": int(match.group(2))}


def permission_allowlist(app):
    package = PACKAGES[app]
    permissions = {
        "android.permission.CAMERA": "Main manifest; bundled QR scanner via packages/qr_ui",
        f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION":
            "AndroidX core signature permission for non-exported dynamic receivers (transitive camera dependency)",
    }
    if app == "wallet":
        permissions["android.permission.INTERNET"] = "Wallet main manifest; online watch-only companion"
        permissions["android.permission.ACCESS_NETWORK_STATE"] = (
            "ML Kit transport-runtime AAR uses-permission; removing transport components does not remove this permission")
    else:
        permissions["android.permission.USE_BIOMETRIC"] = "Vault main manifest; local device authentication"
    return permissions


def parse_manifest(xml):
    root = ET.fromstring(xml)
    require(root.tag == "manifest", "bundletool did not return a manifest XML document")
    require(bool(root.get("package")), "manifest must contain a package name")
    applications = root.findall("application")
    sdk = root.findall("uses-sdk")
    require(len(applications) == 1, "manifest must contain exactly one application")
    require(len(sdk) == 1, "manifest must contain exactly one uses-sdk")
    permissions = []
    for child in root:
        if child.tag.startswith("uses-permission"):
            permissions.append({"name": child.get(ANDROID + "name"),
                                "max_sdk": child.get(ANDROID + "maxSdkVersion")})
    return {
        "package": root.get("package"),
        "version_name": root.get(ANDROID + "versionName"),
        "version_code": root.get(ANDROID + "versionCode"),
        "min_sdk": sdk[0].get(ANDROID + "minSdkVersion"),
        "target_sdk": sdk[0].get(ANDROID + "targetSdkVersion"),
        "debuggable": applications[0].get(ANDROID + "debuggable", "false"),
        "test_only": applications[0].get(ANDROID + "testOnly", "false"),
        "permissions": permissions,
        "component_names": [element.get(ANDROID + "name") for element in applications[0].iter()
                            if element.get(ANDROID + "name")],
    }


def check_package(manifest, app):
    require(manifest["package"] == PACKAGES[app],
            f"package {manifest['package']!r} differs from {PACKAGES[app]}")
    return {"package": manifest["package"]}


def check_version(manifest, repo, app):
    expected = pubspec_version(repo, app)
    actual = {"version_name": manifest["version_name"], "version_code": manifest["version_code"]}
    require(actual["version_name"] == expected["version_name"]
            and actual["version_code"] == str(expected["version_code"]),
            {"error": "manifest version differs from pubspec.yaml", "expected": expected, "actual": actual})
    return expected


def check_sdk_levels(manifest, app):
    expected = {"min_sdk": str(MIN_SDK[app]), "target_sdk": "36"}
    actual = {name: manifest[name] for name in expected}
    require(actual == expected, {"error": "unexpected SDK levels", "expected": expected, "actual": actual})
    return actual


def check_release_flags(manifest):
    flags = {name: manifest[name] for name in ("debuggable", "test_only")}
    require(all(value in ("false", "0", "0x0") for value in flags.values()),
            {"error": "debuggable and testOnly must be false or absent", "actual": flags})
    return flags


def check_permissions(manifest, app):
    allowlist = permission_allowlist(app)
    permissions = manifest["permissions"]
    actual = {row["name"] for row in permissions}
    detail = {"actual": sorted(actual, key=str), "allowlist": allowlist,
              "missing": sorted(set(allowlist) - actual),
              "unexpected": sorted(actual - set(allowlist), key=str),
              "restricted": [row for row in permissions if row["max_sdk"] is not None]}
    require(actual == set(allowlist) and not detail["restricted"], detail)
    return detail


def check_components(manifest, app):
    forbidden = FORBIDDEN_COMPONENTS[app]
    names = []
    for name in manifest["component_names"]:
        if name.startswith("."):
            name = manifest["package"] + name
        elif "." not in name:
            name = manifest["package"] + "." + name
        if name in forbidden or name.startswith("com.google.android.datatransport."):
            names.append(name)
    require(not names, {"error": "forbidden transport/profileinstaller components", "components": sorted(names)})
    return {"forbidden_components_absent": sorted(forbidden)}


def elf_load_alignments(binary):
    require(len(binary) >= 64 and binary[:4] == b"\x7fELF", "not a complete ELF header")
    require(binary[4:7] == b"\x02\x01\x01", "native library must be ELF64 little-endian, version 1")
    header = struct.unpack_from("<HHIQQQIHHHHHH", binary, 16)
    _, _, version, _, phoff, _, _, ehsize, phentsize, phnum, _, _, _ = header
    require(version == 1 and ehsize == 64, "invalid ELF64 header version or size")
    require(phnum not in (0, 0xffff) and phentsize == 56 and phoff >= 64,
            "missing or unsupported ELF64 program header table")
    require(phoff + phnum * phentsize <= len(binary), "truncated ELF64 program header table")
    alignments = []
    for index in range(phnum):
        program = struct.unpack_from("<IIQQQQQQ", binary, phoff + index * phentsize)
        if program[0] == 1:
            alignments.append(program[7])
    require(alignments, "ELF has no PT_LOAD segment")
    require(all(value >= 16384 and value & (value - 1) == 0 for value in alignments),
            {"error": "each PT_LOAD p_align must be a power of two >= 16384", "pt_load_alignments": alignments})
    return alignments


def check_bundle_layout(bundle):
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
    modules = sorted(name.split("/", 1)[0] for name in names
                     if re.fullmatch(r"[^/]+/manifest/AndroidManifest\.xml", name))
    required = {"BundleConfig.pb", "base/manifest/AndroidManifest.xml"}
    detail = {"modules": modules, "missing_entries": sorted(required - set(names)),
              "duplicate_entries": len(names) != len(set(names))}
    # These Flutter apps have no dynamic features. An unchecked feature manifest
    # must not silently add permissions or components outside the base audit.
    require(modules == ["base"] and not detail["missing_entries"] and not detail["duplicate_entries"], detail)
    return detail


def check_native_libraries(bundle):
    libraries, abis, errors = [], set(), []
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            errors.append("duplicate ZIP entries")
        for entry in archive.infolist():
            if not entry.filename.startswith("base/lib/") or not entry.filename.endswith(".so"):
                continue
            match = re.fullmatch(r"base/lib/([^/]+)/([^/]+\.so)", entry.filename)
            if match is None or match.group(1) in (".", ".."):
                errors.append(f"invalid native library path: {entry.filename}")
                continue
            abis.add(match.group(1))
            binary = archive.read(entry)
            row = {"entry": entry.filename, "sha256": hashlib.sha256(binary).hexdigest()}
            try:
                row["pt_load_alignments"] = elf_load_alignments(binary)
                row["status"] = "PASS"
            except CheckError as error:
                row.update(status="FAIL", detail=error.detail)
            libraries.append(row)
    if abis != EXPECTED_ABIS:
        errors.append("ABI set must be exactly arm64-v8a and x86_64")
    detail = {"abis": sorted(abis), "expected_abis": sorted(EXPECTED_ABIS), "libraries": libraries, "errors": errors}
    require(not errors and libraries and all(row["status"] == "PASS" for row in libraries), detail)
    return detail


def signer_certificate(output, expected_sha256=None):
    signers = re.split(r"(?m)^Signer #\d+:\s*\r?$", output)[1:]
    require(len(signers) == 1, f"expected exactly one JAR signer, found {len(signers)}")
    # Certificate #2 and later belong to a certificate chain, not extra signers.
    # JDK 8's keytool heads the chain with "Signature:" instead of numbering it;
    # either way the first certificate after the header is the signer's.
    leaf = re.split(r"(?m)^(?:Certificate #\d+|Signature):\s*\r?$", signers[0])
    require(len(leaf) >= 2, "keytool output has no signer certificate")
    match = re.search(r"(?m)^\s*SHA256:\s*([0-9A-Fa-f:]+)\s*\r?$", leaf[1])
    if match is None:
        raise CheckError("keytool output has no signer certificate SHA-256")
    digest = normalized_sha256(match.group(1))
    owner = re.search(r"(?m)^Owner:\s*(.*?)\s*\r?$", leaf[1])
    require(owner is not None, "keytool output has no signer certificate owner")
    owner = owner.group(1)
    # Every SDK install creates its own debug keystore, all named CN=Android
    # Debug, so the subject is refused whatever the digest or the pin.
    require(digest != DEBUG_CERT_SHA256 and not is_android_debug_owner(owner),
            {"error": "debug certificate is forbidden for Play uploads", "owner": owner, "actual": digest})
    if expected_sha256 is not None:
        expected_sha256 = normalized_sha256(expected_sha256)
        require(digest == expected_sha256,
                {"error": "upload certificate mismatch", "actual": digest, "expected": expected_sha256})
    return {"signer_count": 1, "certificate_sha256": digest, "certificate_owner": owner,
            "expected_upload_certificate_sha256": expected_sha256,
            "upload_certificate_pinned": expected_sha256 is not None}


def is_android_debug_owner(owner):
    return "CN=Android Debug" in (part.strip() for part in owner.split(","))


def verify_jar_signature(bundle, tools, expected_sha256=None):
    language = ["-J-Duser.language=en", "-J-Duser.country=US"]
    # Exit bit 4 permits an untrusted/self-signed upload certificate. Other bits,
    # including unsigned entries (16), still fail. No revocation/network lookup.
    output = run_command([tools["jarsigner"], *language, "-verify", "-strict", "-verbose:all", bundle],
                         accepted_codes=(0, 4))
    require(re.search(r"(?m)^jar verified[.,]", output) is not None,
            "jarsigner did not verify the JAR signature (unsigned or disabled signature)")
    certificate = run_command([tools["keytool"], *language, "-printcert", "-jarfile", bundle])
    return signer_certificate(certificate, expected_sha256)


def build_apks_and_check_alignment(bundle, tools):
    with tempfile.TemporaryDirectory(prefix="fcw-play-check-") as temporary:
        directory = Path(temporary)
        keystore = directory / "throwaway.p12"
        password_file = directory / "password.txt"
        password_file.touch(mode=0o600)
        password_file.write_text(secrets.token_hex(24), encoding="utf-8")
        run_command([tools["keytool"], "-genkeypair", "-noprompt", "-storetype", "PKCS12",
                     "-keystore", keystore, "-storepass:file", password_file,
                     "-keypass:file", password_file, "-alias", "alignment-check",
                     "-dname", "CN=FCW temporary alignment check", "-keyalg", "RSA",
                     "-keysize", "2048", "-validity", "1"])
        apk_set = directory / "generated.apks"
        run_command([*tools["bundletool"], "build-apks", f"--bundle={bundle}", f"--output={apk_set}",
                     f"--aapt2={tools['aapt2']}", f"--ks={keystore}", "--ks-key-alias=alignment-check",
                     f"--ks-pass=file:{password_file}", f"--key-pass=file:{password_file}"], timeout=600)
        records = []
        with zipfile.ZipFile(apk_set) as archive:
            for index, entry in enumerate(archive.infolist()):
                if not entry.filename.endswith(".apk"):
                    continue
                apk = directory / f"split-{index}.apk"
                apk.write_bytes(archive.read(entry))
                row: dict = {"entry": entry.filename}
                try:
                    with zipfile.ZipFile(apk) as contents:
                        row["uncompressed_native_libraries"] = [
                            info.filename for info in contents.infolist()
                            if info.filename.startswith("lib/") and info.filename.endswith(".so")
                            and info.compress_type == zipfile.ZIP_STORED]
                    run_command([tools["zipalign"], "-c", "-P", "16", "4", apk])
                    row["status"] = "PASS"
                except (ToolError, zipfile.BadZipFile) as error:
                    row.update(status="FAIL", detail=str(error))
                records.append(row)
        detail = {"temporary_signer": True, "apks": records}
        require(records and all(row["status"] == "PASS" for row in records), detail)
        return detail


def evaluate(checks, name, operation):
    try:
        detail = operation()
    except CheckError as error:
        checks.append({"name": name, "status": "FAIL", "detail": error.detail})
        return None
    except (ToolError, OSError, ValueError, ET.ParseError, zipfile.BadZipFile, struct.error) as error:
        checks.append({"name": name, "status": "FAIL", "detail": str(error)})
        return None
    checks.append({"name": name, "status": "PASS", "detail": detail})
    return detail


def audit_bundle(bundle, app, repo, tools, expected_upload_cert_sha256=None, *, build_apks=False):
    bundle = Path(bundle).resolve()
    checks: list[dict] = []
    evaluate(checks, "bundle_layout", lambda: check_bundle_layout(bundle))
    evaluate(checks, "bundletool_validate",
             lambda: {"output": run_command([*tools["bundletool"], "validate", f"--bundle={bundle}"]).strip()})
    manifest = evaluate(checks, "manifest_dump", lambda: parse_manifest(run_command(
        [*tools["bundletool"], "dump", "manifest", f"--bundle={bundle}", "--module=base"])))
    manifest_checks = [
        ("package", lambda: check_package(manifest, app)),
        ("version", lambda: check_version(manifest, repo, app)),
        ("sdk_levels", lambda: check_sdk_levels(manifest, app)),
        ("release_flags", lambda: check_release_flags(manifest)),
        ("permissions", lambda: check_permissions(manifest, app)),
        ("components", lambda: check_components(manifest, app)),
    ]
    for name, operation in manifest_checks:
        if manifest is None:
            checks.append({"name": name, "status": "FAIL", "detail": "cannot check: manifest_dump failed"})
        else:
            evaluate(checks, name, operation)
    evaluate(checks, "native_libraries", lambda: check_native_libraries(bundle))
    evaluate(checks, "jar_signature", lambda: verify_jar_signature(bundle, tools, expected_upload_cert_sha256))
    if expected_upload_cert_sha256 is None:
        # Without a pin the signer is only described, never accepted as the
        # upload key, so this bundle cannot PASS.
        checks.append({"name": "upload_certificate_pin", "status": "MISSING",
                       "detail": f"no --expect-upload-cert-sha256-{app}; the signer was not matched to the upload certificate"})
    if build_apks:
        evaluate(checks, "apk_zipalign", lambda: build_apks_and_check_alignment(bundle, tools))
    return {"app": app, "path": str(bundle), "status": overall_status(row["status"] for row in checks),
            "checks": checks, "build_apks_requested": build_apks}


def overall_status(statuses):
    """FAIL if anything failed, DIAGNOSTIC if a pin is missing, else PASS."""
    statuses = list(statuses)
    if any(status not in ("PASS", "MISSING", "DIAGNOSTIC") for status in statuses):
        return "FAIL"
    return "PASS" if all(status == "PASS" for status in statuses) else "DIAGNOSTIC"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wallet", type=Path, help="Wallet Android App Bundle")
    parser.add_argument("--vault", type=Path, help="Vault Android App Bundle")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2], help="Repository with app pubspecs")
    for app in PACKAGES:
        parser.add_argument(f"--expect-upload-cert-sha256-{app}", type=normalized_sha256,
                            help=f"Expected {app} upload certificate SHA-256 (plain hex or keytool colon "
                                 "format); required for PASS, otherwise the report is DIAGNOSTIC")
    parser.add_argument("--out", type=Path, help="Also write the JSON report here")
    parser.add_argument("--build-apks", action="store_true", help="Build splits with a temporary key and check 16 KB ZIP alignment")
    parser.add_argument("--discover-tools", action="store_true", help="Only discover local tools; no AAB needed")
    add_tool_arguments(parser)
    args = parser.parse_args(argv)
    if not (args.wallet or args.vault or args.discover_tools):
        parser.error("provide --wallet, --vault or --discover-tools")
    if args.discover_tools and (args.wallet or args.vault or args.build_apks):
        parser.error("--discover-tools cannot be combined with AABs or --build-apks")
    for app in PACKAGES:
        if getattr(args, f"expect_upload_cert_sha256_{app}") and not getattr(args, app):
            parser.error(f"--expect-upload-cert-sha256-{app} requires --{app}")
    report: dict = {"schema_version": 1, "checks": [], "artifacts": []}
    tools = evaluate(report["checks"], "tool_discovery", lambda: discover_tools(args.sdk, args.build_tools, args.bundletool))
    if tools is not None:
        for app in PACKAGES:
            bundle = getattr(args, app)
            if bundle:
                report["artifacts"].append(audit_bundle(
                    bundle, app, args.repo, tools, getattr(args, f"expect_upload_cert_sha256_{app}"),
                    build_apks=args.build_apks))
    report["status"] = overall_status([row["status"] for row in report["checks"]]
                                      + [row["status"] for row in report["artifacts"]])
    output = json.dumps(report, indent=2) + "\n"
    if args.out:
        try:
            # A mistaken --out must never overwrite the artifact being audited.
            require(args.out.resolve() not in [path.resolve() for path in (args.wallet, args.vault) if path],
                    "--out must differ from the input AAB paths")
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(output, encoding="utf-8")
        except (CheckError, OSError) as error:
            report["checks"].append({"name": "write_report", "status": "FAIL", "detail": str(error)})
            report["status"] = "FAIL"
            output = json.dumps(report, indent=2) + "\n"
    print(output, end="")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
