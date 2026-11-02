"""
tests/release_checks/test_verify_qr_apks.py
===========================================
Signer parsing of tools/release_checks/verify_qr_apks.py. The full audit needs the
Windows SDK and real APKs; these cases cover the `apksigner verify --print-certs`
output it records instead of a fixed signing claim.
"""

import ast
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import warnings
import zipfile
import zlib

import pytest

from tools.release_checks import verify_qr_apks


PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT_PATH = PROJECT_ROOT / "tools" / "release_checks" / "verify_qr_apks.py"

DEBUG = verify_qr_apks.DEBUG_CERT_SHA256
# Layout of apksigner 36.0.0 output; the non-debug digest is from a throwaway key.
OTHER = "ef4c9e923dda09aa0b82369af895a59773d8174908bf025431fb2032a16606b3"


def touch_executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("stub", encoding="utf-8")
    path.chmod(0o755)
    return path


def certs(digest, dn="CN=Android Debug, O=Android, C=US", signer=1):
    return (
        f"Signer #{signer} certificate DN: {dn}\n"
        f"Signer #{signer} certificate SHA-256 digest: {digest}\n"
        f"Signer #{signer} certificate SHA-1 digest: {'0' * 40}\n"
        f"Signer #{signer} certificate MD5 digest: {'0' * 32}\n"
    )


def test_debug_certificate_is_labelled_as_local_development():
    assert verify_qr_apks.signer_certificate(certs(DEBUG)) == {
        "signer_certificate_sha256": DEBUG,
        "signer_certificate_dn": "CN=Android Debug, O=Android, C=US",
        "signing": "local development (debug) certificate",
    }


@pytest.mark.parametrize("dn", ["CN=Android Debug, O=Android, C=US", "C=US, O=Android, CN=Android Debug"])
def test_another_machines_debug_certificate_is_labelled_debug(dn):
    # Each SDK install has its own debug keystore; the DN is what they share.
    result = verify_qr_apks.signer_certificate(certs(OTHER, dn=dn))
    assert result == {"signer_certificate_sha256": OTHER, "signer_certificate_dn": dn, "signing": "debug certificate"}


def test_any_other_certificate_is_unrecognised_not_vouched_for():
    result = verify_qr_apks.signer_certificate(certs(OTHER, dn="CN=FCW throwaway, O=Android Debug"))
    assert result == {"signer_certificate_sha256": OTHER, "signer_certificate_dn": "CN=FCW throwaway, O=Android Debug",
                      "signing": "unrecognised certificate"}


def test_windows_line_endings_and_warnings_are_tolerated():
    output = "WARNING: META-INF/x.txt not protected by signature.\r\n" + certs(OTHER).replace("\n", "\r\n")
    assert verify_qr_apks.signer_certificate(output)["signer_certificate_sha256"] == OTHER


def test_source_stamp_certificate_is_not_the_signer():
    output = certs(DEBUG) + f"Source Stamp Signer certificate SHA-256 digest: {OTHER}\n"
    assert verify_qr_apks.signer_certificate(output)["signer_certificate_sha256"] == DEBUG


@pytest.mark.parametrize("output", ["", "DOES NOT VERIFY\nERROR: Missing META-INF/MANIFEST.MF\n",
                                    certs(DEBUG) + certs(OTHER, signer=2)])
def test_anything_but_exactly_one_signer_fails(output):
    with pytest.raises(SystemExit, match="exactly one APK signer"):
        verify_qr_apks.signer_certificate(output)


@pytest.mark.parametrize("expected", [OTHER, OTHER.upper(), ":".join(OTHER[i:i + 2] for i in range(0, 64, 2))])
def test_expected_certificate_accepts_apksigner_and_keytool_forms(expected):
    assert verify_qr_apks.signer_certificate(certs(OTHER), expected)["signer_certificate_sha256"] == OTHER


def test_expected_certificate_mismatch_fails():
    with pytest.raises(SystemExit, match="differs from the expected"):
        verify_qr_apks.signer_certificate(certs(DEBUG), OTHER)


def test_expected_certificate_must_be_a_sha256_digest():
    with pytest.raises(ValueError, match="not a SHA-256 digest"):
        verify_qr_apks.normalized_sha256("fde363")


def test_legacy_certificate_pin_still_applies_to_both_apps():
    assert verify_qr_apks.certificate_pins(OTHER) == {"wallet": OTHER, "vault": OTHER}


def test_per_app_certificate_pins_can_differ_and_override_legacy_fallback():
    wallet = "1234567890abcdef" * 4
    vault = "abcdef1234567890" * 4
    assert verify_qr_apks.certificate_pins(OTHER, wallet=wallet, vault=vault) == {
        "wallet": wallet,
        "vault": vault,
    }


@pytest.mark.parametrize(
    "system,tool_names,host_tag",
    [
        ("Darwin", ("aapt", "apksigner"), "darwin-x86_64"),
        ("Windows", ("aapt.exe", "apksigner.bat"), "windows-x86_64"),
    ],
)
def test_apk_tool_discovery_reuses_installed_sdk_on_mac_and_windows(tmp_path, system, tool_names, host_tag):
    sdk = tmp_path / "sdk"
    build_tools = sdk / "build-tools" / "36.0.0"
    ndk = sdk / "ndk" / "27.0.12077973"
    for name in tool_names:
        touch_executable(build_tools / name)
    analyzer_name = "apkanalyzer.bat" if system == "Windows" else "apkanalyzer"
    touch_executable(sdk / "cmdline-tools" / "latest" / "bin" / analyzer_name)
    nm_name = "llvm-nm.exe" if system == "Windows" else "llvm-nm"
    touch_executable(ndk / "toolchains" / "llvm" / "prebuilt" / host_tag / "bin" / nm_name)

    result = verify_qr_apks.discover_apk_tools(
        sdk=sdk,
        build_tools="36.0.0",
        env={},
        system=system,
        home=tmp_path,
    )

    assert result["sdk"] == str(sdk.resolve())
    assert result["build_tools_version"] == "36.0.0"
    assert result["aapt"].endswith(tool_names[0])
    assert result["apksigner"].endswith(tool_names[1])
    assert result["apkanalyzer"].endswith(analyzer_name)
    assert result["llvm_nm"].endswith(nm_name)


def test_qr_apk_help_exposes_shared_and_per_app_certificate_pins():
    result = subprocess.run([sys.executable, str(SCRIPT_PATH), "--help"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "--expect-cert-sha256 " in result.stdout
    assert "--expect-cert-sha256-wallet" in result.stdout
    assert "--expect-cert-sha256-vault" in result.stdout
    assert "--mapping-wallet" in result.stdout
    assert "--mapping-vault" in result.stdout
    assert "--sdk" in result.stdout
    assert "--build-tools" in result.stdout


# `aapt dump xmltree <apk> AndroidManifest.xml` layout (build-tools 36.0.0).
def xmltree(*components):
    lines = ["N: android=http://schemas.android.com/apk/res/android",
             "  E: manifest (line=2)",
             "    E: application (line=10)",
             '      A: android:label(0x01010001)="FCW Watch" (Raw: "FCW Watch")']
    for tag, name in components:
        lines += [f"      E: {tag} (line=20)",
                  f'        A: android:name(0x01010003)="{name}" (Raw: "{name}")',
                  "        E: meta-data (line=21)",
                  '          A: android:name(0x01010003)="backend:com.google.android.datatransport.cct.CctBackendFactory" '
                  '(Raw: "backend:com.google.android.datatransport.cct.CctBackendFactory")']
    return "\n".join(lines) + "\n"


def test_manifest_without_transport_components_passes():
    assert verify_qr_apks.transport_components(xmltree(("activity", "com.coldwallet.watch.MainActivity"))) == []


@pytest.mark.parametrize("component", verify_qr_apks.TRANSPORT_COMPONENTS)
def test_each_ml_kit_transport_component_is_reported(component):
    tag = "receiver" if component.endswith("Receiver") else "service"
    dump = xmltree(("activity", "com.coldwallet.watch.MainActivity"), (tag, component))
    assert verify_qr_apks.transport_components(dump) == [component]


def test_any_other_datatransport_component_is_reported():
    dump = xmltree(("service", "com.google.android.datatransport.runtime.FutureUploadService"))
    assert verify_qr_apks.transport_components(dump) == ["com.google.android.datatransport.runtime.FutureUploadService"]


@pytest.mark.parametrize(("value", "expected"), [
    ("0x0", True),
    ("0xffffffff", False),
])
def test_allow_backup_reads_boolean_value_not_attribute_id_prefix(value, expected):
    manifest = (
        "  E: application (line=10)\n"
        f"    A: android:allowBackup(0x01010280)=(type 0x12){value}\n"
    )
    assert verify_qr_apks.allow_backup_disabled(manifest) is expected


def write_apk(tmp_path, entries):
    apk = tmp_path / "candidate.apk"
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(apk, "w") as archive:
            for name, payload in entries:
                archive.writestr(name, payload)
    return apk


PACKAGES = """\
C d 2 2 269 io.flutter.plugins.GeneratedPluginRegistrant
M d 1 1 174 io.flutter.plugins.GeneratedPluginRegistrant void registerWith(V1.c)
C d 1 1 40 dev.steenbakker.mobile_scanner.MobileScannerPlugin
C d 1 1 40 dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin
C d 1 1 40 dev.fluttercommunity.plus.wakelock.WakelockPlusPlugin
"""
REGISTRANT_CODE = """\
.class public final Lio/flutter/plugins/GeneratedPluginRegistrant;
.method public static registerWith(LV1/c;)V
    :try_start_1
    new-instance v2, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;
    invoke-direct {v2}, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;-><init>()V
    invoke-virtual {v1, v2}, Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add(Lio/flutter/embedding/engine/plugins/FlutterPlugin;)V
    :try_end_1
    .catch Ljava/lang/Exception; {:try_start_1 .. :try_end_1} :catch_1
    :catch_1
    move-exception v1
    const-string v2, "Error registering plugin mobile_scanner, dev.steenbakker.mobile_scanner.MobileScannerPlugin"
    :try_start_2
    new-instance v2, Ldev/fluttercommunity/plus/packageinfo/PackageInfoPlugin;
    invoke-direct {v2}, Ldev/fluttercommunity/plus/packageinfo/PackageInfoPlugin;-><init>()V
    invoke-virtual {v1, v2}, Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add(Lio/flutter/embedding/engine/plugins/FlutterPlugin;)V
    :try_end_2
    .catch Ljava/lang/Exception; {:try_start_2 .. :try_end_2} :catch_2
    :catch_2
    move-exception v1
    const-string v2, "Error registering plugin package_info_plus, dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin"
    :try_start_3
    new-instance v1, Ldev/fluttercommunity/plus/wakelock/WakelockPlusPlugin;
    invoke-direct {v1}, Ldev/fluttercommunity/plus/wakelock/WakelockPlusPlugin;-><init>()V
    invoke-virtual {p0, v1}, Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add(Lio/flutter/embedding/engine/plugins/FlutterPlugin;)V
    :try_end_3
    .catch Ljava/lang/Exception; {:try_start_3 .. :try_end_3} :catch_3
    :catch_3
    move-exception p0
    const-string v1, "Error registering plugin wakelock_plus, dev.fluttercommunity.plus.wakelock.WakelockPlusPlugin"
    return-void
.end method
"""


def analyzer_runner(*args, packages=PACKAGES, code=REGISTRANT_CODE, dex_list="classes.dex\nclasses2.dex\n"):
    operation = tuple(args[1:3])
    if operation == ("dex", "list"):
        return dex_list
    if operation == ("dex", "packages"):
        return packages
    if operation == ("dex", "code"):
        return code
    raise AssertionError(args)


def test_structural_flutter_plugin_registration_can_span_valid_multidex(tmp_path):
    apk = write_apk(tmp_path, [("classes.dex", b"dex one"), ("classes2.dex", b"dex two")])
    mapping = tmp_path / "mapping.txt"
    mapping.write_text("mapping", encoding="utf-8")
    calls = []

    def mapped_runner(*args):
        calls.append(args)
        return analyzer_runner(*args)

    result = verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", mapping=mapping,
                                                        runner=mapped_runner)
    assert result == {
        "registrant_class": "io.flutter.plugins.GeneratedPluginRegistrant",
        "registration_method": "registerWith",
        "required_plugins": ["mobile_scanner", "package_info_plus", "wakelock_plus"],
        "dex_entries": ["classes.dex", "classes2.dex"],
        "analysis": "apkanalyzer structural DEX parse and mapped registrant bytecode",
        "mapping_sha256": hashlib.sha256(b"mapping").hexdigest(),
    }
    mapped_calls = [call for call in calls if call[1:3] in (("dex", "packages"), ("dex", "code"))]
    assert all(("--proguard-mappings", mapping) == call[-3:-1] for call in mapped_calls)


@pytest.mark.parametrize("packages,missing", [
    ("C d 1 1 20 example.Markers\n", "class definition"),
    ("C d 1 1 20 io.flutter.plugins.GeneratedPluginRegistrant\n", "registerWith method"),
])
def test_marker_text_without_registrant_class_or_method_fails(tmp_path, packages, missing):
    apk = write_apk(tmp_path, [("classes.dex", b"all marker strings but no class_defs")])
    runner = lambda *args: analyzer_runner(*args, packages=packages, dex_list="classes.dex\n")
    with pytest.raises(SystemExit, match=missing):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)


@pytest.mark.parametrize("plugin", ["mobile_scanner", "package_info_plus", "wakelock_plus"])
def test_named_plugin_without_registration_in_registerwith_fails(tmp_path, plugin):
    apk = write_apk(tmp_path, [("classes.dex", b"valid dex is represented by analyzer output")])
    code = REGISTRANT_CODE.replace("new-instance", "not-an-instruction", 1) if plugin == "mobile_scanner" else REGISTRANT_CODE
    if plugin != "mobile_scanner":
        marker = f'Error registering plugin {plugin}'
        position = code.index(marker)
        start = code.rfind("new-instance", 0, position)
        code = code[:start] + "not-an-instruction" + code[start + len("new-instance"):]
    runner = lambda *args: analyzer_runner(*args, code=code, dex_list="classes.dex\n")
    with pytest.raises(SystemExit, match=rf"does not directly add {plugin}"):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)


@pytest.mark.parametrize("mutation", ["object_notify", "same_class", "one_construct_three_names"])
def test_arbitrary_or_reused_objects_cannot_stand_in_for_concrete_plugins(tmp_path, mutation):
    apk = write_apk(tmp_path, [("classes.dex", b"DEX parsed by the analyzer fixture")])
    code = REGISTRANT_CODE
    if mutation == "object_notify":
        code = code.replace(
            "Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add"
            "(Lio/flutter/embedding/engine/plugins/FlutterPlugin;)V",
            "Ljava/lang/Object;->notify()V",
        )
    elif mutation == "same_class":
        code = code.replace("Ldev/fluttercommunity/plus/packageinfo/PackageInfoPlugin;",
                            "Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;")
        code = code.replace("Ldev/fluttercommunity/plus/wakelock/WakelockPlusPlugin;",
                            "Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;")
    else:
        first_end = code.index(":try_end_1")
        last_end = code.index(":try_end_3")
        code = code[:first_end] + code[last_end:]
    runner = lambda *args: analyzer_runner(*args, code=code, dex_list="classes.dex\n")
    with pytest.raises(SystemExit, match="does not directly add"):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)


@pytest.mark.parametrize("overwrite", [
    "    move-object v2, v3\n",
    "    invoke-static {}, Lexample/Discard;->nullPlugin()Ljava/lang/Object;\n"
    "    move-result-object v2\n",
])
def test_plugin_register_overwrite_before_registry_add_fails(tmp_path, overwrite):
    apk = write_apk(tmp_path, [("classes.dex", b"DEX parsed by the analyzer fixture")])
    constructor = (
        "    invoke-direct {v2}, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;-><init>()V\n"
    )
    code = REGISTRANT_CODE.replace(constructor, constructor + overwrite, 1)
    runner = lambda *args: analyzer_runner(*args, code=code, dex_list="classes.dex\n")
    with pytest.raises(SystemExit, match="does not directly add mobile_scanner"):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)


def test_invoke_range_and_parameter_registers_are_normalized(tmp_path):
    apk = write_apk(tmp_path, [("classes.dex", b"DEX parsed by the analyzer fixture")])
    code = REGISTRANT_CODE.replace(
        "new-instance v2, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;",
        "new-instance p1, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;",
    ).replace(
        "invoke-direct {v2}, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;-><init>()V",
        "invoke-direct/range {p1 .. p1}, Ldev/steenbakker/mobile_scanner/MobileScannerPlugin;-><init>()V",
    ).replace(
        "invoke-virtual {v1, v2}, Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add",
        "invoke-virtual/range {p0 .. p1}, Lio/flutter/embedding/engine/FlutterEngineConnectionRegistry;->add",
        1,
    )
    runner = lambda *args: analyzer_runner(*args, code=code, dex_list="classes.dex\n")
    assert verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)["required_plugins"] == [
        "mobile_scanner", "package_info_plus", "wakelock_plus"]


def test_plain_text_and_corrupt_secondary_dex_fail_closed(tmp_path):
    apk = write_apk(tmp_path, [("classes.dex", b"plain marker text"), ("classes2.dex", b"not dex")])

    def failed_parser(*args):
        if tuple(args[1:3]) == ("dex", "list"):
            return "classes.dex\nclasses2.dex\n"
        raise subprocess.CalledProcessError(1, args, stderr="invalid DEX")

    with pytest.raises(SystemExit, match="apkanalyzer failed to parse every DEX"):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=failed_parser)


def build_real_multidex_fixture(tmp_path, registrant_transform=None):
    try:
        tools = verify_qr_apks.discover_apk_tools()
    except verify_qr_apks.ToolError as error:
        pytest.skip(f"Android SDK/NDK tools unavailable: {error}")
    javac = shutil.which("javac")
    if not javac:
        pytest.skip("javac unavailable")
    d8 = Path(tools["sdk"]) / "build-tools" / tools["build_tools_version"] / "d8"
    if not d8.is_file():
        pytest.skip(f"D8 unavailable: {d8}")
    sources = {
        "io/flutter/embedding/engine/plugins/FlutterPlugin.java":
            "package io.flutter.embedding.engine.plugins; public interface FlutterPlugin {}",
        "io/flutter/embedding/engine/FlutterEngineConnectionRegistry.java":
            "package io.flutter.embedding.engine; import io.flutter.embedding.engine.plugins.FlutterPlugin; "
            "public class FlutterEngineConnectionRegistry { public void add(FlutterPlugin plugin) {} }",
        "io/flutter/embedding/engine/FlutterEngine.java":
            "package io.flutter.embedding.engine; public class FlutterEngine { "
            "public final FlutterEngineConnectionRegistry pluginRegistry = new FlutterEngineConnectionRegistry(); }",
        "dev/steenbakker/mobile_scanner/MobileScannerPlugin.java":
            "package dev.steenbakker.mobile_scanner; import io.flutter.embedding.engine.plugins.FlutterPlugin; "
            "public class MobileScannerPlugin implements FlutterPlugin {}",
        "dev/fluttercommunity/plus/packageinfo/PackageInfoPlugin.java":
            "package dev.fluttercommunity.plus.packageinfo; import io.flutter.embedding.engine.plugins.FlutterPlugin; "
            "public class PackageInfoPlugin implements FlutterPlugin {}",
        "dev/fluttercommunity/plus/wakelock/WakelockPlusPlugin.java":
            "package dev.fluttercommunity.plus.wakelock; import io.flutter.embedding.engine.plugins.FlutterPlugin; "
            "public class WakelockPlusPlugin implements FlutterPlugin {}",
        "io/flutter/plugins/GeneratedPluginRegistrant.java":
            "package io.flutter.plugins; import io.flutter.embedding.engine.FlutterEngine; "
            "import dev.steenbakker.mobile_scanner.MobileScannerPlugin; "
            "import dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin; "
            "import dev.fluttercommunity.plus.wakelock.WakelockPlusPlugin; "
            "public final class GeneratedPluginRegistrant { public static void registerWith(FlutterEngine engine) { "
            "engine.pluginRegistry.add(new MobileScannerPlugin()); "
            "engine.pluginRegistry.add(new PackageInfoPlugin()); "
            "engine.pluginRegistry.add(new WakelockPlusPlugin()); } }",
    }
    if registrant_transform is not None:
        registrant = "io/flutter/plugins/GeneratedPluginRegistrant.java"
        sources[registrant] = registrant_transform(sources[registrant])
    source_root = tmp_path / "java"
    class_root = tmp_path / "classes"
    for relative, source in sources.items():
        path = source_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
    subprocess.run([javac, "-d", class_root, *map(str, source_root.rglob("*.java"))], check=True,
                   capture_output=True, text=True)
    primary_jar = tmp_path / "primary.jar"
    with zipfile.ZipFile(primary_jar, "w") as archive:
        for path in class_root.rglob("*.class"):
            archive.write(path, path.relative_to(class_root))
    secondary_source = tmp_path / "Secondary.java"
    secondary_source.write_text("package example; public final class Secondary {}", encoding="utf-8")
    secondary_classes = tmp_path / "secondary-classes"
    subprocess.run([javac, "-d", secondary_classes, secondary_source], check=True, capture_output=True, text=True)
    secondary_jar = tmp_path / "secondary.jar"
    with zipfile.ZipFile(secondary_jar, "w") as archive:
        for path in secondary_classes.rglob("*.class"):
            archive.write(path, path.relative_to(secondary_classes))
    primary_out, secondary_out = tmp_path / "primary-dex", tmp_path / "secondary-dex"
    primary_out.mkdir()
    secondary_out.mkdir()
    subprocess.run([d8, "--release", "--output", primary_out, primary_jar], check=True,
                   capture_output=True, text=True)
    subprocess.run([d8, "--release", "--output", secondary_out, secondary_jar], check=True,
                   capture_output=True, text=True)
    primary = (primary_out / "classes.dex").read_bytes()
    secondary = (secondary_out / "classes.dex").read_bytes()
    return tools["apkanalyzer"], primary, secondary


def test_real_d8_null_helper_overwrite_is_rejected(tmp_path):
    def discard_constructed_plugins(source):
        for plugin in ("MobileScannerPlugin", "PackageInfoPlugin", "WakelockPlusPlugin"):
            source = source.replace(
                f"engine.pluginRegistry.add(new {plugin}());",
                f"engine.pluginRegistry.add(discard(new {plugin}()));",
            )
        return source.replace(
            "public final class GeneratedPluginRegistrant {",
            "public final class GeneratedPluginRegistrant { "
            "private static io.flutter.embedding.engine.plugins.FlutterPlugin discard("
            "io.flutter.embedding.engine.plugins.FlutterPlugin plugin) { return null; }",
        )

    apkanalyzer, primary, secondary = build_real_multidex_fixture(
        tmp_path, registrant_transform=discard_constructed_plugins)
    apk = write_apk(tmp_path, [("classes.dex", primary), ("classes2.dex", secondary)])
    with pytest.raises(SystemExit, match="does not directly add mobile_scanner"):
        verify_qr_apks.flutter_plugin_registration(apk, apkanalyzer)


def test_real_apkanalyzer_accepts_valid_multidex_then_rejects_only_corrupt_secondary(tmp_path):
    apkanalyzer, primary, secondary = build_real_multidex_fixture(tmp_path)
    valid = write_apk(tmp_path, [("classes.dex", primary), ("classes2.dex", secondary)])
    assert verify_qr_apks.flutter_plugin_registration(valid, apkanalyzer)["dex_entries"] == [
        "classes.dex", "classes2.dex"]
    corrupt = tmp_path / "corrupt-secondary.apk"
    with zipfile.ZipFile(corrupt, "w") as archive:
        archive.writestr("classes.dex", primary)
        archive.writestr("classes2.dex", b"not dex")
    with pytest.raises(SystemExit, match="apkanalyzer failed to parse every DEX"):
        verify_qr_apks.flutter_plugin_registration(corrupt, apkanalyzer)


def test_real_apkanalyzer_rejects_valid_dex_with_marker_strings_but_no_class_defs(tmp_path):
    apkanalyzer, primary, _ = build_real_multidex_fixture(tmp_path)
    marker_only = bytearray(primary)
    marker_only[96:104] = b"\0" * 8
    marker_only[12:32] = hashlib.sha1(marker_only[32:]).digest()
    marker_only[8:12] = zlib.adler32(marker_only[12:]).to_bytes(4, "little")
    apk = write_apk(tmp_path, [("classes.dex", marker_only)])
    with pytest.raises(SystemExit, match="lacks the GeneratedPluginRegistrant class definition"):
        verify_qr_apks.flutter_plugin_registration(apk, apkanalyzer)


def test_contiguous_dex_numbering_accepts_transition_from_9_to_10(tmp_path):
    entries = [("classes.dex", b"dex")] + [(f"classes{index}.dex", b"dex") for index in range(2, 11)]
    apk = write_apk(tmp_path, entries)
    runner = lambda *args: analyzer_runner(*args, dex_list="\n".join(name for name, _ in entries) + "\n")
    assert len(verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=runner)["dex_entries"]) == 10


@pytest.mark.parametrize("entries,error", [
    ([("AndroidManifest.xml", b"manifest")], "APK has no classes.dex entries"),
    ([("classes2.dex", b"dex")], "must start with classes.dex"),
    ([("classes.dex", b"dex"), ("classes3.dex", b"dex")], "contiguous"),
    ([("classes.dex", b"dex"), ("classes0.dex", b"dex")], "non-canonical"),
    ([("classes.dex", b"dex"), ("classes.dex", b"duplicate")], "duplicate DEX entry"),
])
def test_noncanonical_or_duplicate_dex_entries_fail(tmp_path, entries, error):
    apk = write_apk(tmp_path, entries)
    with pytest.raises(SystemExit, match=error):
        verify_qr_apks.flutter_plugin_registration(apk, "apkanalyzer", runner=analyzer_runner)


@pytest.mark.parametrize("app", ["wallet", "vault"])
def test_release_overlay_removes_ml_kit_transport(app):
    import xml.etree.ElementTree as ET

    android = "{http://schemas.android.com/apk/res/android}"
    tools = "{http://schemas.android.com/tools}"
    overlay = PROJECT_ROOT / "apps" / app / "android" / "app" / "src" / "release" / "AndroidManifest.xml"
    root = ET.parse(overlay).getroot()
    removed = {element.get(f"{android}name") for element in root.iter()
               if element.get(f"{tools}node") == "remove"}
    assert set(verify_qr_apks.TRANSPORT_COMPONENTS) <= removed
    if app == "wallet":
        # The Watch must still reach the user's node and scan QR codes.
        assert not {"android.permission.INTERNET", "android.permission.CAMERA"} & removed


def test_no_check_relies_on_assert():
    # `python -O` / PYTHONOPTIMIZE removes assert statements entirely.
    tree = ast.parse(SCRIPT_PATH.read_text(encoding="utf-8"))
    asserts = [node.lineno for node in ast.walk(tree) if isinstance(node, ast.Assert)]
    assert asserts == [], f"assert checks at lines {asserts} vanish under python -O"


def run_signer_check_under_python_optimize(call):
    code = (
        "import importlib.util, sys\n"
        f"sys.path.insert(0, {str(SCRIPT_PATH.parent)!r})\n"
        f"spec = importlib.util.spec_from_file_location('v', {str(SCRIPT_PATH)!r})\n"
        "v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)\n"
        "print('IMPORT_OK')\n"
        f"result = v.{call}\n"
        "print('CALL_OK:' + result['signer_certificate_sha256'])\n"
    )
    return subprocess.run([sys.executable, "-I", "-O", "-c", code], capture_output=True, text=True)


def test_valid_signer_check_loads_and_passes_under_python_optimize():
    result = run_signer_check_under_python_optimize(f"signer_certificate({certs(DEBUG)!r}, {DEBUG!r})")
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["IMPORT_OK", f"CALL_OK:{DEBUG}"]
    assert result.stderr == ""


@pytest.mark.parametrize(("call", "expected_error"), [
    (f"signer_certificate({certs(DEBUG) + certs(OTHER, signer=2)!r})",
     "expected exactly one APK signer, found 2"),
    (f"signer_certificate({certs(DEBUG)!r}, {OTHER!r})",
     f"APK signer certificate {DEBUG} differs from the expected {OTHER}"),
], ids=["two signers", "unexpected certificate"])
def test_signer_checks_still_fail_under_python_optimize(call, expected_error):
    result = run_signer_check_under_python_optimize(call)
    assert result.returncode != 0
    assert result.stdout == "IMPORT_OK\n"
    assert expected_error in result.stderr
    assert "ModuleNotFoundError" not in result.stderr
