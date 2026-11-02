# Android Play bundle checks

Run from the repository root with Python 3. The checker uses only the Python
standard library and installed Android/JDK tools. It does not download tools,
contact devices, upload artifacts, or read app signing configuration.

```sh
python3 tools/release_checks/verify_play_bundle.py --discover-tools
python3 tools/release_checks/verify_play_bundle.py \
  --wallet /path/to/wallet.aab --vault /path/to/vault.aab \
  --expect-upload-cert-sha256-wallet "$WALLET_UPLOAD_CERT_SHA256" \
  --expect-upload-cert-sha256-vault "$VAULT_UPLOAD_CERT_SHA256" \
  --out target/release-checks/play-bundles.json
```

Either AAB can be supplied alone. Certificate fingerprints are public SHA-256
digests, accepted as plain hex or keytool's colon-separated form. Supply each
app's **upload certificate**, which can differ from its APK app-signing
certificate. A Play upload check needs the pin for every app it checks: without
one, that app gets an `upload_certificate_pin` row with status `MISSING`
(`upload_certificate_pinned: false`), and the app and overall status are
`DIAGNOSTIC`, never `PASS`. A debug certificate is refused whatever the pin:
any signer whose subject has `CN=Android Debug` (every Android SDK install
creates its own debug keystore under that name), as well as the known local
debug certificate.

`--repo /path/to/repo` selects the pubspecs (default: this repository).
`--sdk` overrides `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then the platform
default (`~/Library/Android/sdk`, `~/Android/Sdk`, or
`%LOCALAPPDATA%\Android\Sdk`). A configured but missing SDK fails explicitly.
`--build-tools 36.0.0` selects an installed version; otherwise the highest
numeric version is used, with a stable release preferred over its previews.
`--bundletool /path/to/bundletool.jar` uses `java -jar`; an executable path or
`bundletool` on PATH also works. `java`, `keytool`, and `jarsigner` come from
`JAVA_HOME/bin` or PATH. Tool discovery is also importable and available via
`python3 tools/release_checks/android_sdk.py`.

The JSON report contains a status and detail for each check, and records the
signer's subject (`certificate_owner`). The overall status is `FAIL` if any
check failed, `DIAGNOSTIC` if all checks passed but an upload pin is missing,
and `PASS` otherwise. Anything but `PASS` returns exit code 1; invalid CLI
arguments return 2. Checks cover single-base
bundle layout, bundletool validation, manifest identity and pubspec version, Wallet minSdk 24 / Vault
minSdk 28 and targetSdk 36, release flags, exact requested permissions, forbidden
components, both required 64-bit ABIs, every native library's ELF64 PT_LOAD
alignment (at least 16384), and SHA-256 of each library. Signature verification
uses `jarsigner -verify -strict` plus `keytool -printcert -jarfile`, requires one
signer, and rejects unsigned/tampered payloads. Self-signed/untrusted certificate
warnings (jarsigner exit bit 4) are allowed because upload certificates need not
chain to a public CA. Other exit bits fail, and a zero exit without a verified
signature also fails. Verification does not request revocation checks.
These Flutter apps have no dynamic feature modules; extra module manifests are
rejected so they cannot bypass the base manifest audit.

The permission allowlists are deliberately exact:

| App | Requested permissions |
| --- | --- |
| Wallet | `android.permission.CAMERA`, `android.permission.INTERNET`, `android.permission.ACCESS_NETWORK_STATE`, `com.coldwallet.watch.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` |
| Vault | `android.permission.CAMERA`, `android.permission.USE_BIOMETRIC`, `com.coldwallet.vault.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` |

CAMERA/INTERNET/USE_BIOMETRIC come from the app main manifests. Both apps use
`packages/qr_ui` and its `mobile_scanner` dependency. Its camera/ML Kit AndroidX
core dependency adds the per-app signature permission protecting non-exported
dynamic receivers. ML Kit's transport-runtime AAR adds ACCESS_NETWORK_STATE;
Wallet currently retains that uses-permission even when transport components
are removed. Vault's release overlay explicitly removes it, INTERNET, and NFC.
These lists also match the permissions recorded for the `427c87f` APKs in the
private archive's artifact manifest; they are not learned from an
untrusted candidate bundle. No WAKE_LOCK or other extra permission is accepted.
Dependency or manifest changes require explicit review of these lists.

Both apps must omit TransportBackendDiscovery, JobInfoSchedulerService and
AlarmManagerSchedulerBroadcastReceiver; the Vault must also omit
ProfileInstallReceiver (the Wallet keeps it: it only installs baseline profiles). Any remaining
`com.google.android.datatransport.*` component fails too.

Add `--build-apks` to build the default full split set with bundletool and run
`zipalign -c -P 16 4` on **every** generated APK. This checks ZIP offsets for
uncompressed native libraries separately from ELF alignment. The checker creates
a throwaway PKCS12 key and password file inside a temporary directory and removes
both afterward. It accepts no real keystore or password arguments; the generated
APKs are temporary alignment evidence, not distributable release artifacts.

```sh
python3 -m pytest -q tests/release_checks
```

The suite uses scripted tool output and a fake SDK, so it passes on any
machine and does not check the real toolchain. On a release build host, check
the real toolchain with
`python3 tools/release_checks/check_env.py --strict --output <file>`
and keep that report with the release evidence.
`FCW_STRICT_HOST_CHECK=1 python3 -m pytest -q tests/release_checks` also runs
the opt-in host smoke test.

The new tests craft synthetic ELF/AAB ZIP trees and stub Android tool outputs.
Optional tests exercise real JDK signing/tamper detection and real zipalign on
synthetic ZIPs; each skips with a reason when its local tools are unavailable.
No real FCW AAB has been validated by these synthetic tests.

## Local QR APK checks

`verify_qr_apks.py` audits the two already-built local/testnet APKs. It discovers
`aapt` and `apksigner` from the installed Android SDK on macOS, Windows, or
Linux, and `llvm-nm` from NDK 27.0.12077973. Use `--sdk`, `--build-tools`, or
`--ndk` to select an installed toolchain without downloading anything.

The legacy `--expect-cert-sha256` option still requires both APKs to use one
certificate. Release APKs may use separate app-signing keys; pin those with
`--expect-cert-sha256-wallet` and `--expect-cert-sha256-vault`. An app-specific
pin overrides the shared fallback for that app.

The APK audit uses the Android SDK's `apkanalyzer` to parse every canonical,
contiguously numbered `classes*.dex` entry. For minified release builds, pass
each `mapping.txt` produced by that same Gradle/R8 build with `--mapping-wallet`
and `--mapping-vault`; its SHA-256 is recorded in the report. An unminified build
may omit the mapping only when `apkanalyzer` exposes the concrete class names.

The bounded regression gate requires one defined Flutter
`GeneratedPluginRegistrant` class and `registerWith` method, defined concrete
classes for `mobile_scanner`, `package_info_plus`, and `wakelock_plus`, and a
direct, consecutive executable construct → matching constructor →
`FlutterEngineConnectionRegistry.add(FlutterPlugin)` sequence for each concrete
plugin object. Smali labels, comments, and metadata directives may occur between
those instructions; another executable instruction may not. The gate supports
ordinary and `/range` invokes with `v` or `p` registers. Any DEX parse failure,
duplicate entry, non-canonical numbering,
missing definition, or missing direct registration fails closed. This catches
the missing/stale Flutter platform-generation regression; it is not a general
proof of arbitrary DEX behavior, and runtime plugin/device checks remain a
separate acceptance gate.

```sh
python3 tools/release_checks/verify_qr_apks.py \
  --directory /path/to/apks \
  --mapping-wallet /path/to/wallet/mapping.txt \
  --mapping-vault /path/to/vault/mapping.txt \
  --expect-cert-sha256-wallet "$WALLET_APP_CERT_SHA256" \
  --expect-cert-sha256-vault "$VAULT_APP_CERT_SHA256" \
  --output target/release-checks/qr-apks.json
```

The host audit treats missing or malformed default tool paths as failed checks
and records both the expected and detected NDK revision from
`source.properties`; the directory name alone is not sufficient.
