"""Inspect actual Wallet/Vault QR APKs and their native exports; no device needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import zipfile

if __package__:
    from .android_sdk import ToolError, discover_build_tools, discover_sdk, executable
else:
    from android_sdk import ToolError, discover_build_tools, discover_sdk, executable

# Certificate of the debug keystore the local test APKs have been signed with.
DEBUG_CERT_SHA256 = "fde363bec8539d5e03afca6620fa8265c28bc7445840cf3b4d821fc36f59b011"

# ML Kit's bundled datatransport uploads diagnostics and usage data to Google.
# Both release overlays remove it; the privacy policy says neither app sends it.
TRANSPORT_COMPONENTS = (
    "com.google.android.datatransport.runtime.backends.TransportBackendDiscovery",
    "com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoSchedulerService",
    "com.google.android.datatransport.runtime.scheduling.jobscheduling.AlarmManagerSchedulerBroadcastReceiver",
)
NDK_VERSION = "27.0.12077973"
REQUIRED_FLUTTER_PLUGINS = (
    ("mobile_scanner", "dev.steenbakker.mobile_scanner.MobileScannerPlugin"),
    ("package_info_plus", "dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin"),
    ("wakelock_plus", "dev.fluttercommunity.plus.wakelock.WakelockPlusPlugin"),
)


def require(condition, message):
    """An audit check that `python -O` cannot strip, unlike assert."""
    if not condition:
        raise SystemExit(message)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, encoding="utf-8")


def pubspec_version(root, app):
    text = (Path(root) / "apps" / app / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", text, re.M)
    require(match, f"apps/{app}/pubspec.yaml needs a name+code version")
    return match.group(1), match.group(2)


def normalized_sha256(value):
    """Accept apksigner (lowercase hex) or keytool (colon-separated) digests."""
    digest = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"not a SHA-256 digest: {value!r}")
    return digest


def certificate_pins(shared=None, *, wallet=None, vault=None):
    """Resolve legacy shared and per-app certificate pins."""
    return {
        "wallet": normalized_sha256(wallet or shared) if wallet or shared else None,
        "vault": normalized_sha256(vault or shared) if vault or shared else None,
    }


def discover_apk_tools(sdk=None, build_tools=None, ndk=None, *, env=None, system=None, home=None):
    """Find aapt, apksigner and llvm-nm in an already installed SDK/NDK."""
    env = os.environ if env is None else env
    system = system or platform.system()
    sdk_path = discover_sdk(sdk, env=env, system=system, home=home)
    build_tools_path = discover_build_tools(sdk_path, build_tools)
    suffix = ".exe" if system == "Windows" else ""
    apksigner_name = "apksigner.bat" if system == "Windows" else "apksigner"
    analyzer_name = "apkanalyzer.bat" if system == "Windows" else "apkanalyzer"
    host_tags = {"Darwin": "darwin-x86_64", "Windows": "windows-x86_64", "Linux": "linux-x86_64"}
    if system not in host_tags:
        raise ToolError(f"unsupported NDK host platform: {system}")
    ndk_path = Path(ndk or env.get("ANDROID_NDK_HOME") or sdk_path / "ndk" / NDK_VERSION).expanduser().resolve()
    if not ndk_path.is_dir():
        raise ToolError(f"Android NDK {NDK_VERSION} missing: {ndk_path}")
    nm = ndk_path / "toolchains" / "llvm" / "prebuilt" / host_tags[system] / "bin" / f"llvm-nm{suffix}"
    analyzer_candidates = [sdk_path / "cmdline-tools" / "latest" / "bin" / analyzer_name]
    cmdline_tools = sdk_path / "cmdline-tools"
    if cmdline_tools.is_dir():
        analyzer_candidates.extend(
            path / "bin" / analyzer_name for path in sorted(cmdline_tools.iterdir(), reverse=True)
            if path.name != "latest" and path.is_dir()
        )
    analyzer_candidates.append(sdk_path / "tools" / "bin" / analyzer_name)
    analyzer = next((candidate for candidate in analyzer_candidates if candidate.is_file()), analyzer_candidates[0])
    return {
        "sdk": str(sdk_path),
        "build_tools_version": build_tools_path.name,
        "aapt": executable(build_tools_path / f"aapt{suffix}", "aapt", system),
        "apksigner": executable(build_tools_path / apksigner_name, "apksigner", system),
        "apkanalyzer": executable(analyzer, "apkanalyzer", system),
        "ndk": str(ndk_path),
        "llvm_nm": executable(nm, "llvm-nm", system),
    }


def signer_certificate(apksigner_output, expected_sha256=None):
    """Signer certificate SHA-256, DN and label from `apksigner verify --print-certs`."""
    digests = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})\s*$", apksigner_output, re.M)
    require(len(digests) == 1, f"expected exactly one APK signer, found {len(digests)}")
    names = re.findall(r"^Signer #\d+ certificate DN: (.*?)\s*$", apksigner_output, re.M)
    require(len(names) == 1, f"expected exactly one APK signer DN, found {len(names)}")
    digest, dn = digests[0], names[0]
    if expected_sha256 is not None:
        expected = normalized_sha256(expected_sha256)
        require(digest == expected, f"APK signer certificate {digest} differs from the expected {expected}")
    # Every SDK install creates its own debug keystore, all named CN=Android Debug;
    # any other certificate is only reported, never vouched for.
    if digest == DEBUG_CERT_SHA256:
        label = "local development (debug) certificate"
    elif "CN=Android Debug" in (part.strip() for part in dn.split(",")):
        label = "debug certificate"
    else:
        label = "unrecognised certificate"
    return {"signer_certificate_sha256": digest, "signer_certificate_dn": dn, "signing": label}


def transport_components(xmltree):
    """datatransport components declared in `aapt dump xmltree <apk> AndroidManifest.xml`."""
    names = re.findall(r'^\s*A: android:name\([^)]*\)="([^"]+)"', xmltree, re.M)
    return sorted({name for name in names if name.startswith("com.google.android.datatransport.")})


def allow_backup_disabled(xmltree):
    """Whether aapt reports exactly one boolean false allowBackup value."""
    values = re.findall(
        r"^\s*A: android:allowBackup\([^)]*\)=\(type 0x12\)(0x[0-9a-fA-F]+)(?:\s.*)?$",
        xmltree,
        re.M,
    )
    return len(values) == 1 and int(values[0], 16) == 0


def _dex_registers(text):
    """Normalize ordinary and /range register lists from apkanalyzer smali."""
    text = text.strip()
    range_match = re.fullmatch(r"([vp])(\d+)\s+\.\.\s+\1(\d+)", text)
    if range_match:
        prefix, first, last = range_match.groups()
        require(int(first) <= int(last), f"invalid DEX register range: {text}")
        return [f"{prefix}{index}" for index in range(int(first), int(last) + 1)]
    registers = [item.strip() for item in text.split(",") if item.strip()]
    require(all(re.fullmatch(r"[vp]\d+", register) for register in registers),
            f"invalid DEX register list: {text}")
    return registers


def _directly_adds_plugin(method, class_name):
    """Require the bounded generated new -> constructor -> registry.add sequence."""
    descriptor = "L" + class_name.replace(".", "/") + ";"
    instructions = []
    for raw_line in method.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ".", ":")):
            continue
        instructions.append(line)
    new_pattern = re.compile(rf"new-instance\s+([vp]\d+),\s+{re.escape(descriptor)}")
    constructor_pattern = re.compile(
        rf"invoke-direct(?:/range)?\s+\{{([^}}]+)\}},\s+{re.escape(descriptor)}-><init>\(\)V"
    )
    registration_pattern = re.compile(
        r"invoke-virtual(?:/range)?\s+\{([^}]+)\},\s+"
        r"Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->"
        r"add\(Lio/flutter/embedding/engine/plugins/FlutterPlugin;\)V"
    )
    for new_line, constructor_line, registration_line in zip(
            instructions, instructions[1:], instructions[2:]):
        new_instance = new_pattern.fullmatch(new_line)
        if new_instance is None:
            continue
        plugin_register = new_instance.group(1)
        constructor = constructor_pattern.fullmatch(constructor_line)
        registration = registration_pattern.fullmatch(registration_line)
        if constructor is None or registration is None:
            continue
        if _dex_registers(constructor.group(1)) != [plugin_register]:
            continue
        registers = _dex_registers(registration.group(1))
        if len(registers) == 2 and registers[1] == plugin_register:
            return True
    return False


def flutter_plugin_registration(apk, apkanalyzer, *, mapping=None, runner=run):
    """Structurally verify every DEX and the generated registrant bytecode."""
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        dex_like = [name for name in names if re.fullmatch(r"classes[^/]*\.dex", name)]
        dex_entries = [name for name in dex_like if re.fullmatch(r"classes(?:[2-9]|[1-9]\d+)?\.dex", name)]
        require(dex_entries, "APK has no classes.dex entries")
        require(len(dex_entries) == len(set(dex_entries)), "APK has a duplicate DEX entry")
        require(len(dex_like) == len(dex_entries), "APK has a non-canonical DEX entry")
        require("classes.dex" in dex_entries, "APK DEX sequence must start with classes.dex")
        ordered = ["classes.dex", *(f"classes{index}.dex" for index in range(2, len(dex_entries) + 1))]
        require(sorted(dex_entries, key=lambda name: (len(name), name)) == ordered,
                "APK DEX entries must use contiguous classes.dex, classes2.dex numbering")
        require(archive.testzip() is None, "APK has a corrupt ZIP entry")
    mapping_args = []
    mapping_sha256 = None
    if mapping is not None:
        mapping = Path(mapping)
        require(mapping.is_file(), f"R8 mapping is not a file: {mapping}")
        mapping_sha256 = hashlib.sha256(mapping.read_bytes()).hexdigest()
        mapping_args = ["--proguard-mappings", mapping]
    try:
        analyzer_entries = [line.strip() for line in runner(apkanalyzer, "dex", "list", apk).splitlines()
                            if line.strip()]
        packages = runner(apkanalyzer, "dex", "packages", "--defined-only", *mapping_args, apk)
    except (subprocess.CalledProcessError, OSError) as error:
        detail = (getattr(error, "stderr", None) or str(error)).strip().splitlines()[-1]
        raise SystemExit(f"apkanalyzer failed to parse every DEX: {detail}") from error
    require(sorted(analyzer_entries, key=lambda name: (len(name), name)) == ordered,
            f"apkanalyzer DEX list differs from canonical APK entries: {analyzer_entries}")
    require(re.search(r"^C\s+d\b.*\bio\.flutter\.plugins\.GeneratedPluginRegistrant$", packages, re.M),
            "APK DEX lacks the GeneratedPluginRegistrant class definition")
    require(re.search(
        r"^M\s+d\b.*\bio\.flutter\.plugins\.GeneratedPluginRegistrant\s+void\s+registerWith\([^)]*\)$",
        packages, re.M), "GeneratedPluginRegistrant lacks a defined registerWith method")
    for plugin, class_name in REQUIRED_FLUTTER_PLUGINS:
        require(re.search(rf"^C\s+d\b.*\b{re.escape(class_name)}$", packages, re.M),
                f"APK DEX lacks the concrete {plugin} class definition ({class_name})")
    try:
        code = runner(apkanalyzer, "dex", "code", "--class",
                      "io.flutter.plugins.GeneratedPluginRegistrant", *mapping_args, apk)
    except (subprocess.CalledProcessError, OSError) as error:
        detail = (getattr(error, "stderr", None) or str(error)).strip().splitlines()[-1]
        raise SystemExit(f"apkanalyzer could not decompile GeneratedPluginRegistrant: {detail}") from error
    require(re.search(r"^\.class\b.*\sLio/flutter/plugins/GeneratedPluginRegistrant;$", code, re.M),
            "apkanalyzer returned the wrong registrant class")
    methods = re.findall(r"^\.method\b[^\n]*\sregisterWith\([^)]*\)V\s*$([\s\S]*?)^\.end method\s*$",
                         code, re.M)
    require(len(methods) == 1, f"expected one GeneratedPluginRegistrant.registerWith body, found {len(methods)}")
    method = methods[0]
    for plugin, class_name in REQUIRED_FLUTTER_PLUGINS:
        require(_directly_adds_plugin(method, class_name),
                f"GeneratedPluginRegistrant.registerWith does not directly add {plugin} ({class_name})")
    return {
        "registrant_class": "io.flutter.plugins.GeneratedPluginRegistrant",
        "registration_method": "registerWith",
        "required_plugins": [plugin for plugin, _ in REQUIRED_FLUTTER_PLUGINS],
        "dex_entries": ordered,
        "analysis": "apkanalyzer structural DEX parse and mapped registrant bytecode",
        "mapping_sha256": mapping_sha256,
    }


def audit(root, apk_directory, expected_cert_sha256=None, *, expected_cert_sha256_by_app=None,
          mappings_by_app=None, tools=None):
    resolved_tools = discover_apk_tools() if tools is None else tools
    pins = certificate_pins(expected_cert_sha256, **(expected_cert_sha256_by_app or {}))
    records = []
    for app, package in [("wallet", "com.coldwallet.watch"), ("vault", "com.coldwallet.vault")]:
        apk = apk_directory / f"{app}-qr-local-test.apk"
        permissions = run(resolved_tools["aapt"], "dump", "permissions", apk)
        manifest = run(resolved_tools["aapt"], "dump", "xmltree", apk, "AndroidManifest.xml")
        badging = run(resolved_tools["aapt"], "dump", "badging", apk)
        # Fails on a missing or invalid signature as well.
        signer = signer_certificate(run(resolved_tools["apksigner"], "verify", "--print-certs", apk), pins[app])
        version_name, version_code = pubspec_version(root, app)
        require(f"versionCode='{version_code}'" in badging and f"versionName='{version_name}'" in badging,
                f"{app} APK version differs from apps/{app}/pubspec.yaml ({version_name}+{version_code})")
        require(f"package: {package}" in permissions, f"{app} APK package is not {package}")
        require("android.permission.CAMERA" in permissions, f"{app} APK lacks android.permission.CAMERA")
        require("android.permission.NFC" not in permissions, f"{app} APK requests android.permission.NFC")
        require(allow_backup_disabled(manifest), "Public xpubs/history also require explicit backup")
        require("TestControlProvider" not in manifest, f"{app} APK manifest has TestControlProvider")
        require("HostApduService" not in manifest, f"{app} APK manifest has HostApduService")
        leaked = transport_components(manifest)
        require(not leaked, f"{app} APK still declares ML Kit telemetry transport: {', '.join(leaked)}")
        if app == "vault":
            require("android.permission.INTERNET" not in permissions, "vault APK requests android.permission.INTERNET")
            require("android.permission.ACCESS_NETWORK_STATE" not in permissions, "vault APK requests android.permission.ACCESS_NETWORK_STATE")
            require("JobInfoSchedulerService" not in manifest, "vault APK manifest has JobInfoSchedulerService")
            require("AlarmManagerSchedulerBroadcastReceiver" not in manifest, "vault APK manifest has AlarmManagerSchedulerBroadcastReceiver")
        plugin_registration = flutter_plugin_registration(
            apk, resolved_tools["apkanalyzer"], mapping=(mappings_by_app or {}).get(app))
        with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as temporary:
            names = archive.namelist()
            models = [name for name in names if name.startswith("assets/mlkit_barcode_models/") and name.endswith(".tflite")]
            require(models, "First offline scan requires bundled barcode models")
            require("assets/flutter_assets/fonts/MaterialIcons-Regular.otf" in names, "Material icons must be bundled")
            native = []
            for abi in ("arm64-v8a", "x86_64"):
                name = f"lib/{abi}/lib{app}_ffi.so"
                binary = archive.read(name)
                extracted = Path(temporary) / (abi + ".so")
                extracted.write_bytes(binary)
                symbols = run(resolved_tools["llvm_nm"], "-D", "--defined-only", extracted)
                require(f" {app}_init" in symbols, f"{name} does not export {app}_init")
                require(" fcw_decode_ur_frames" in symbols, f"{name} does not export fcw_decode_ur_frames")
                require("vault_load_test_mnemonic" not in symbols, f"{name} exports vault_load_test_mnemonic")
                require("vault_create_test_psbt" not in symbols, f"{name} exports vault_create_test_psbt")
                require("Java_com_mobilecoldwallet_nfc" not in symbols, f"{name} exports Java_com_mobilecoldwallet_nfc")
                if app == "wallet":
                    require(" vault_" not in symbols, f"{name} exports vault_ symbols")
                    require(" wallet_verify_regtest_account_json" in symbols, f"{name} does not export wallet_verify_regtest_account_json")
                    require(" wallet_build_regtest_psbt_json" in symbols, f"{name} does not export wallet_build_regtest_psbt_json")
                native.append({"entry": name, "sha256": hashlib.sha256(binary).hexdigest(), "fixture_exports_absent": True})
        records.append({
            "app": app, "package": package, "path": str(apk),
            "version_name": version_name, "version_code": int(version_code),
            "expected_signer_certificate_sha256": pins[app],
            "bytes": apk.stat().st_size, "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
            "permissions": re.findall(r"uses-permission: name='([^']+)'", permissions),
            "bundled_barcode_models": models, "flutter_plugin_registration": plugin_registration,
            "native_libraries": native,
            **signer,
        })
    return {
        "scope": "QR core local/testnet Android subset; not full original product acceptance",
        "source_commit": run("git", "-C", root, "rev-parse", "HEAD").strip(),
        "source_dirty": bool(run("git", "-C", root, "status", "--porcelain").strip()),
        "expected_signer_certificate_sha256": expected_cert_sha256,
        "expected_signer_certificates_sha256": pins,
        "artifacts": records,
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=Path("target/qr-core"))
    parser.add_argument("--output", type=Path, default=Path("target/qr-core/artifact-manifest.json"))
    parser.add_argument("--expect-cert-sha256", type=normalized_sha256,
                        help="SHA-256 of the certificate every APK must be signed with")
    parser.add_argument("--expect-cert-sha256-wallet", type=normalized_sha256,
                        help="SHA-256 of the Wallet APK signing certificate")
    parser.add_argument("--expect-cert-sha256-vault", type=normalized_sha256,
                        help="SHA-256 of the Vault APK signing certificate")
    parser.add_argument("--mapping-wallet", type=Path,
                        help="R8 mapping.txt produced by the same Wallet build (required if plugin classes were obfuscated)")
    parser.add_argument("--mapping-vault", type=Path,
                        help="R8 mapping.txt produced by the same Vault build (required if plugin classes were obfuscated)")
    parser.add_argument("--sdk", type=Path,
                        help="Android SDK (otherwise ANDROID_HOME, ANDROID_SDK_ROOT, platform default)")
    parser.add_argument("--build-tools", help="Installed build-tools version (otherwise highest installed)")
    parser.add_argument("--ndk", type=Path,
                        help=f"Android NDK (otherwise ANDROID_NDK_HOME or SDK ndk/{NDK_VERSION})")
    arguments = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    tools = discover_apk_tools(arguments.sdk, arguments.build_tools, arguments.ndk)
    result = audit(
        root,
        arguments.directory.resolve(),
        arguments.expect_cert_sha256,
        expected_cert_sha256_by_app={
            "wallet": arguments.expect_cert_sha256_wallet,
            "vault": arguments.expect_cert_sha256_vault,
        },
        mappings_by_app={"wallet": arguments.mapping_wallet, "vault": arguments.mapping_vault},
        tools=tools,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({"result": "PASS", "artifacts": [{"app": row["app"], "sha256": row["sha256"]} for row in result["artifacts"]]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
