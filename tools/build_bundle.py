#!/usr/bin/env python3
"""Build and validate the Android testnet candidate corresponding source.

All project source is copied only from the candidate's frozen source directory.
Files generated after the freeze are admitted through a small explicit supplement
allowlist and recorded separately from the original source manifest.
"""

from __future__ import annotations

import argparse
import io
import gzip
import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import tarfile
import zipfile
from pathlib import Path

import yaml


ROOT_FILES = {
    ".gitattributes", ".gitignore", "CHANGELOG.md", "CONTRIBUTING.md",
    "Cargo.lock", "Cargo.toml", "LICENSE", "LICENSE-EXCEPTION", "README.md",
    "SECURITY.md",
}
SUPPLEMENT_PATHS = (
    "apps/wallet/android/gradlew",
    "apps/wallet/android/gradlew.bat",
    "apps/wallet/android/gradle/wrapper/gradle-wrapper.jar",
    "apps/wallet/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
    "apps/vault/android/gradlew",
    "apps/vault/android/gradlew.bat",
    "apps/vault/android/gradle/wrapper/gradle-wrapper.jar",
    "apps/vault/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
)
FORBIDDEN_PARTS = {".git", ".dart_tool", ".gradle", "build", "jniLibs"}
FORBIDDEN_SUFFIXES = {".jks", ".keystore", ".p12", ".pfx", ".apk", ".aab", ".so", ".dylib"}


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_manifest(path: Path) -> dict[str, str]:
    rows: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        digest, rel = raw.split(None, 1)
        rel = rel.strip().lstrip("*")
        if rel.startswith("./"):
            rel = rel[2:]
        parts = Path(rel).parts
        if (not re.fullmatch(r"[0-9a-f]{64}", digest) or not parts or
                Path(rel).is_absolute() or ".." in parts or rel in rows):
            raise ValueError(f"invalid source manifest entry: {rel}")
        rows[rel] = digest
    if not rows:
        raise ValueError("empty source manifest")
    return rows


def verify_frozen_source(source: Path, manifest: dict[str, str]) -> None:
    missing = [p for p in manifest if not (source / p).is_file() or (source / p).is_symlink()]
    changed = [p for p, digest in manifest.items() if (source / p).is_file() and sha(source / p) != digest]
    if missing or changed:
        raise RuntimeError(f"frozen source mismatch: missing={missing[:5]} changed={changed[:5]}")


def wanted_source(rel: str) -> bool:
    p = Path(rel)
    if rel in ROOT_FILES:
        return True
    if any(part in FORBIDDEN_PARTS for part in p.parts) or p.suffix.lower() in FORBIDDEN_SUFFIXES:
        return False
    if rel.startswith(("crates/", "packages/")):
        return True
    if rel.startswith("apps/wallet/") or rel.startswith("apps/vault/"):
        tail = p.parts[2:]
        if tail and tail[0] in {"ios", "macos", "linux", "windows", "web"}:
            return False
        return bool(tail and (tail[0] in {"android", "lib", "test", "assets"} or tail[0] in {
            ".gitignore", ".metadata", "README.md", "analysis_options.yaml", "pubspec.yaml", "pubspec.lock"
        }))
    if rel.startswith("docs/"):
        return not rel.startswith("docs/store/") and "/ios" not in rel.lower()
    if rel.startswith("tests/"):
        return True
    if rel.startswith(("tools/release_checks/", "tools/okx_probe/", "tools/reference_oracle/", "tools/nfc_probe/")) or rel == "tools/build_android_qr.ps1":
        return True
    return False


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def parse_lock(path: Path) -> dict[tuple[str, str], set[str]]:
    text = path.read_text(encoding="utf-8")
    blocks = re.split(r"(?=^  [A-Za-z0-9_+.-]+:\s*$)", text, flags=re.MULTILINE)
    out: dict[tuple[str, str], set[str]] = {}
    for block in blocks:
        m_name = re.match(r"^  ([A-Za-z0-9_+.-]+):\s*$", block, re.MULTILINE)
        m_source = re.search(r"^    source: (\S+)\s*$", block, re.MULTILINE)
        m_version = re.search(r'^    version: "?([^"\n]+)"?\s*$', block, re.MULTILINE)
        m_dep = re.search(r"^    dependency: (.+?)\s*$", block, re.MULTILINE)
        if not (m_name and m_source and m_version and m_dep) or m_source.group(1) != "hosted":
            continue
        dep = m_dep.group(1).strip().strip('"')
        scope = "runtime" if dep in {"direct main", "transitive"} else "build-test"
        out.setdefault((m_name.group(1), m_version.group(1)), set()).add(scope)
    return out


def license_files(package_dir: Path) -> list[Path]:
    candidates = []
    for p in package_dir.iterdir() if package_dir.is_dir() else []:
        if p.is_file() and re.match(r"^(LICENSE|COPYING|NOTICE)(\..*)?$", p.name, re.I):
            candidates.append(p)
    return sorted(candidates)


def pubspec_dependencies(path: Path, section: str = "dependencies") -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    value = data.get(section, {}) or {}
    return value if isinstance(value, dict) else {}


def classify_dart_scopes(source: Path, pub_cache: Path, versions: dict[str, str]) -> dict[str, str]:
    def traverse(initial: set[str]) -> set[str]:
        seen: set[str] = set()
        pending = list(initial)
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            version = versions.get(name)
            if not version:
                continue
            spec = pub_cache / "hosted/pub.dev" / f"{name}-{version}" / "pubspec.yaml"
            if spec.is_file():
                pending.extend(pubspec_dependencies(spec).keys())
        return seen.intersection(versions)

    runtime_roots: set[str] = set()
    build_roots: set[str] = set()
    for app in ("wallet", "vault"):
        spec = source / f"apps/{app}/pubspec.yaml"
        for section, roots in (("dependencies", runtime_roots), ("dev_dependencies", build_roots)):
            for name, value in pubspec_dependencies(spec, section).items():
                if isinstance(value, dict) and "path" in value:
                    local = (spec.parent / str(value["path"])).resolve() / "pubspec.yaml"
                    if local.is_file():
                        roots.update(pubspec_dependencies(local).keys())
                elif name in versions:
                    roots.add(name)
    runtime = traverse(runtime_roots)
    build_test = traverse(build_roots) - runtime
    # Flutter SDK test packages are not in the hosted cache graph. Any remaining
    # hosted lock entry is conservatively classified as build/test tooling.
    build_test.update(set(versions) - runtime - build_test)
    return {name: ("runtime" if name in runtime else "build-test") for name in versions}


def copy_dart_licenses(tree: Path, source: Path, pub_cache: Path) -> tuple[int, int, int, int]:
    merged: dict[tuple[str, str], set[str]] = {}
    for app in ("wallet", "vault"):
        for key, scopes in parse_lock(source / f"apps/{app}/pubspec.lock").items():
            merged.setdefault(key, set()).update(scopes)
    versions = {name: version for name, version in merged}
    scopes_by_name = classify_dart_scopes(source, pub_cache, versions)
    lock_occurrences = sum(len(parse_lock(source / f"apps/{app}/pubspec.lock")) for app in ("wallet", "vault"))
    rows = ["ecosystem\tpackage\tversion\tscope\tlicense_paths\tstatus"]
    missing = 0
    runtime = 0
    build_test = 0
    for (name, version), scopes in sorted(merged.items()):
        scope = scopes_by_name[name]
        runtime += scope == "runtime"
        build_test += scope == "build-test"
        package_dir = pub_cache / "hosted/pub.dev" / f"{name}-{version}"
        found = license_files(package_dir)
        rels = []
        for src in found:
            rel = Path("THIRD_PARTY_LICENSES/dart") / f"{name}-{version}" / src.name
            copy_file(src, tree / rel)
            rels.append(rel.as_posix())
        status = "local-cache-text" if rels else "missing-local-text"
        missing += not rels
        rows.append(f"dart\t{name}\t{version}\t{scope}\t{';'.join(rels)}\t{status}")
    (tree / "THIRD_PARTY_LICENSES/LOCKED_DART_DEPENDENCIES.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")
    return runtime, build_test, missing, lock_occurrences


def markdown_link_audit(tree: Path) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    patterns = (
        re.compile(r"!?\[[^\]]*\]\(([^)]+)\)"),
        re.compile(r"<(?:img|a)\b[^>]*(?:src|href)=[\"']([^\"']+)[\"']", re.I),
    )
    for md in sorted(tree.rglob("*.md")):
        text = md.read_text(encoding="utf-8", errors="replace")
        targets = [target for pattern in patterns for target in pattern.findall(text)]
        for target in targets:
            clean = target.split()[0].strip("<>").split("#", 1)[0]
            if not clean or re.match(r"(?:https?|mailto|data):", clean) or clean.startswith("#"):
                continue
            resolved = (md.parent / clean).resolve()
            try:
                resolved.relative_to(tree.resolve())
            except ValueError:
                status = "outside-bundle"
            else:
                status = "missing" if not resolved.exists() else "present"
            if status != "present":
                rows.append((md.relative_to(tree).as_posix(), target, status))
    return rows


def content_manifest(tree: Path) -> list[str]:
    rows = []
    for p in sorted(x for x in tree.rglob("*") if x.is_file() and x.name != "CONTENTS.sha256"):
        rows.append(f"{sha(p)}  {p.relative_to(tree).as_posix()}")
    (tree / "CONTENTS.sha256").write_text("\n".join(rows) + "\n", encoding="utf-8")
    return rows


def deterministic_archive(tree: Path, archive: Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tf:
                for p in [tree] + sorted(tree.rglob("*")):
                    rel = Path(tree.name) if p == tree else Path(tree.name) / p.relative_to(tree)
                    info = tf.gettarinfo(str(p), arcname=rel.as_posix())
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    if info.isfile():
                        with p.open("rb") as f:
                            tf.addfile(info, f)
                    else:
                        tf.addfile(info)


def sensitive_scan(tree: Path) -> list[str]:
    bad = []
    name_re = re.compile(r"(?:key\.properties|\.jks$|\.keystore$|\.p12$|\.pfx$|service.?account|private.?key)", re.I)
    content_re = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|OP_SERVICE_ACCOUNT_TOKEN")
    for p in (x for x in tree.rglob("*") if x.is_file()):
        rel = p.relative_to(tree).as_posix()
        if name_re.search(rel):
            bad.append(rel)
            continue
        # The included generator contains the scanner's marker as source text.
        if rel.lower() != "tools/build_bundle.py" and p.stat().st_size < 5_000_000 and content_re.search(p.read_bytes()):
            bad.append(rel)
    return bad


# r24 archive is used only as previously reviewed third-party notice material,
# and only after its Cargo.lock is compared byte-for-byte to this candidate.
R24_TEMPLATE_SHA256 = '6c3381f021a51470b28ba5b91407b12a61912b2a8267b77b00d88f6f61cd91b5'
R24_TEMPLATE_ROOT = 'fcw-r24-local-corresponding-source-draft/'
PINS = {
    ('wallet', 'apk'): '6a5daf8cfd5059879287e3ad2174257a0d3d0ffd5d5759597006b56a4ab155fc',
    ('vault', 'apk'): '146e90c96c54e21c2b74fd33f6124cdcebaf97b367adc3f634c6f2c36bcfb847',
    ('wallet', 'aab'): 'd3811cdf51e01d2fa03fdf2e447525b85b165e61b995f311832952cde7586868',
    ('vault', 'aab'): 'eb8dd99564bfbd693e90688f1150fc8df0ce7d692d4280e5513bd70501e9cc7e',
}
LABEL = 'fcw-1.2.1-10-corresponding-source'
PROOF = Path(__file__).resolve().parent.parent


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def verify_commit(proof: Path, head: str, manifest: dict[str, str]) -> None:
    """Compare every frozen manifest entry with the actual Git commit."""
    repository = proof.parent.parent.parent
    proc = subprocess.Popen(['git', '-C', str(repository), 'archive', '--format=tar', head], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    found = set()
    try:
        with tarfile.open(fileobj=proc.stdout, mode='r|') as archive:
            for member in archive:
                if member.isdir():
                    continue
                require(member.isfile() and member.name in manifest and member.name not in found, f'unexpected commit member: {member.name}')
                stream = archive.extractfile(member)
                require(stream is not None, f'unreadable commit member: {member.name}')
                h = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(block)
                require(h.hexdigest() == manifest[member.name], f'commit does not match frozen manifest: {member.name}')
                found.add(member.name)
        require(proc.wait(timeout=30) == 0 and found == set(manifest), 'commit archive and frozen manifest differ')
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def checked_inputs(proof: Path) -> tuple[Path, str, dict[str, str], list[dict]]:
    session = json.loads((proof / 'SESSION.json').read_text(encoding='utf-8'))
    source = Path(session['scratch']).resolve() / 'source'
    head = (proof / 'source-head.txt').read_text(encoding='utf-8').strip()
    require(re.fullmatch(r'[0-9a-f]{40}', head) is not None, 'invalid source commit')
    manifest = read_manifest(proof / 'source-files.sha256')
    verify_frozen_source(source, manifest)
    for app in ('wallet', 'vault'):
        require('version: 1.2.1+10' in (source / f'apps/{app}/pubspec.yaml').read_text(), f'{app} source version mismatch')
    build_path = proof / 'build-manifest.json'
    build = json.loads(build_path.read_text(encoding='utf-8'))
    require(build.get('source_commit') == head, 'build source commit mismatch')
    artifacts = build.get('artifacts')
    require(isinstance(artifacts, list) and len(artifacts) == 4, 'build must include all four inputs')
    inputs = {}
    for item in artifacts:
        key = (item.get('app'), item.get('kind'))
        require(key in PINS and key not in inputs, 'invalid or duplicate build input')
        path = Path(item['path']).resolve()
        require(path.parent == (proof / 'inputs').resolve(), 'input outside candidate directory')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == item.get('bytes') and sha(path) == item.get('sha256'), 'build input does not match manifest')
        inputs[key] = item
    require(set(inputs) == set(PINS), 'missing build input')
    public_records = []
    for scope, kind in (('appsign', 'apk'), ('upload', 'aab')):
        report = json.loads((proof / f'signed/signing-report-{scope}.json').read_text(encoding='utf-8'))
        require(report.get('status') == 'PASS' and report.get('scope') == scope and report.get('source_commit') == head and report.get('build_manifest_sha256') == sha(build_path), 'signing report is not bound to source and build')
        signed = report.get('artifacts')
        require(isinstance(signed, list) and len(signed) == 2, 'signing report incomplete')
        seen = set()
        for row in signed:
            app = row.get('app'); key = (app, kind)
            require(key in PINS and key not in seen and row.get('kind') == kind.upper(), 'invalid signed artifact record')
            seen.add(key)
            output = Path(row['output'])
            require(not output.is_absolute() and len(output.parts) == 2 and output.parts[0] == 'signed' and output.name not in ('.', '..'), 'invalid signed artifact path')
            file = proof / output
            require(file.is_file() and not file.is_symlink() and sha(file) == row.get('output_sha256'), 'signed artifact mismatch')
            require(row.get('input_sha256') == inputs[key]['sha256'] and row.get('input') == Path(inputs[key]['path']).name, 'signed input mismatch')
            require(row.get('signer_certificate_sha256') == PINS[key] and row.get('expected_signer_certificate_sha256') == PINS[key], 'signer pin mismatch')
            require(row.get('non_signature_entry_data') == 'BYTE_FOR_BYTE_MATCH', 'signed content mismatch')
            identity = row.get('identity', {})
            require(identity == {'package': 'com.coldwallet.' + ('watch' if app == 'wallet' else 'vault'), 'version_code': 10, 'version_name': '1.2.1'}, 'artifact identity mismatch')
            public_records.append({'app': app, 'kind': kind, 'package': identity['package'], 'version': '1.2.1+10', 'input_sha256': row['input_sha256'], 'signed_filename': output.name, 'signed_bytes': file.stat().st_size, 'signed_sha256': row['output_sha256'], 'certificate_sha256': PINS[key]})
        require(seen == {(app, kind) for app in ('wallet', 'vault')}, 'missing signed app')
    return source, head, manifest, sorted(public_records, key=lambda x: (x['app'], x['kind']))


def copy_reviewed_notices(template: Path, source: Path, tree: Path) -> int:
    require(sha(template) == R24_TEMPLATE_SHA256, 'reviewed r24 notice archive hash mismatch')
    names = ('THIRD_PARTY_LICENSES/FLUTTER_EMBEDDED_NOTICES.txt', 'THIRD_PARTY_LICENSES/JAKARTA_DEPENDENCY_INJECTION_NOTICE.md', 'THIRD_PARTY_LICENSES/MLKIT_TERMS_DELIVERY.md', 'PROVENANCE/verified-supplemental-license-texts.tsv')
    copied = set()
    with tarfile.open(template, 'r:gz') as archive:
        lock = archive.extractfile(R24_TEMPLATE_ROOT + 'Cargo.lock')
        require(lock is not None and lock.read() == (source / 'Cargo.lock').read_bytes(), 'Cargo.lock changed; Rust notice template cannot be reused')
        for member in archive:
            if not member.name.startswith(R24_TEMPLATE_ROOT):
                continue
            rel = member.name.removeprefix(R24_TEMPLATE_ROOT)
            if rel not in names and not rel.startswith('THIRD_PARTY_LICENSES/rust/'):
                continue
            if member.isdir():
                continue
            require(member.isfile() and '..' not in Path(rel).parts and rel not in copied, 'unsafe or duplicate notice archive entry')
            stream = archive.extractfile(member)
            require(stream is not None, 'unreadable notice entry')
            dst = tree / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            with dst.open('xb') as out:
                shutil.copyfileobj(stream, out)
            copied.add(rel)
    require(set(names) <= copied and any(x.startswith('THIRD_PARTY_LICENSES/rust/') for x in copied), 'notice archive incomplete')
    return len(copied)


def strip_digest(path: Path, expected_tool: str) -> str:
    tool = Path.home() / 'Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip'
    require(tool.is_file() and sha(tool) == expected_tool, 'NDK strip tool hash mismatch')
    result = subprocess.run([str(tool), '--strip-unneeded', '-o', '-', str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return hashlib.sha256(result.stdout).hexdigest()


def verify_native_reuse(proof: Path, source: Path, manifest: dict[str, str]) -> None:
    reuse = json.loads((proof / 'native-reuse.json').read_text(encoding='utf-8'))
    require(reuse.get('status') == 'PASS' and reuse.get('mismatches') == [], 'native reuse verification did not pass')
    inputs, libraries = reuse.get('inputs', []), reuse.get('libraries', [])
    require(len(inputs) == reuse.get('rust_input_count') == 48 and len(libraries) == reuse.get('native_library_count') == 4, 'native reuse evidence incomplete')
    seen = set()
    for item in inputs:
        path = item.get('path')
        require(path in manifest and path not in seen and item.get('sha256') == manifest[path] == item.get('r24_sha256'), 'Rust input changed since native reuse verification')
        seen.add(path)
    expected = {(app, abi) for app in ('wallet', 'vault') for abi in ('arm64-v8a', 'x86_64')}
    packaging = json.loads((proof / 'native-packaging.json').read_text(encoding='utf-8'))
    require(packaging.get('status') == 'PASS' and packaging.get('source_commit') == (proof / 'source-head.txt').read_text().strip() and
            packaging.get('tool') == 'Android NDK 28.2.13676358 llvm-strip --strip-unneeded' and
            re.fullmatch(r'[0-9a-f]{64}', packaging.get('tool_sha256', '')) is not None and
            len(packaging.get('libraries', [])) == 4, 'native packaging evidence invalid')
    packaged = {(row.get('app'), row.get('abi')): row for row in packaging['libraries']}
    require(len(packaged) == 4 and set(packaged) == expected, 'native packaging ABI set incomplete')
    seen_libs = set()
    for item in libraries:
        path = item.get('path', '')
        match = re.fullmatch(r'apps/(wallet|vault)/android/app/src/main/jniLibs/(arm64-v8a|x86_64)/lib(wallet|vault)_ffi\.so', path)
        require(match is not None and match[1] == match[3], 'invalid native library path')
        app, abi = match[1], match[2]
        require((app, abi) not in seen_libs and item.get('sha256') == item.get('r24_sha256') and (source / path).is_file() and sha(source / path) == item['sha256'], 'frozen native library differs from verified reuse')
        seen_libs.add((app, abi))
        record = packaged[(app, abi)]
        stripped = strip_digest(source / path, packaging['tool_sha256'])
        require(record.get('source_path') == path and record.get('source_sha256') == item['sha256'] and
                record.get('stripped_sha256') == stripped, 'native strip reproduction mismatch')
        for scope, prefix in (('appsign', ''), ('upload', 'base/')):
            report = json.loads((proof / f'signed/signing-report-{scope}.json').read_text(encoding='utf-8'))
            rows = [row for row in report['artifacts'] if row['app'] == app]
            entry = f'{prefix}lib/{abi}/lib{app}_ffi.so'
            output = record.get('outputs', {}).get(scope, {})
            require(len(rows) == 1 and rows[0].get('native_libraries', {}).get(entry) == stripped and
                    output == {'entry': entry, 'sha256': stripped, 'report_sha256': stripped, 'matches': True}, 'native packaging report mismatch')
            output_path = Path(rows[0]['output'])
            require(not output_path.is_absolute() and len(output_path.parts) == 2 and output_path.parts[0] == 'signed' and
                    not (proof / output_path).is_symlink() and (proof / output_path).is_file(), 'invalid signed artifact path')
            with zipfile.ZipFile(proof / output_path) as archive:
                require(archive.namelist().count(entry) == 1 and hashlib.sha256(archive.read(entry)).hexdigest() == stripped, 'native ZIP entry mismatch')
    require(seen_libs == expected, 'native library ABI set incomplete')


def main() -> None:
    ap = argparse.ArgumentParser(description='Prepare sanitized Android testnet candidate corresponding source from exact final inputs.')
    ap.add_argument('--output', type=Path, required=True, help='new empty output directory; never overwritten')
    ap.add_argument('--r24-template', type=Path, default=PROOF.parent.parent / '1.2.1-r24/verification-2026-10-23/corresponding-source/fcw-r24-local-corresponding-source-draft.tar.gz')
    ap.add_argument('--pub-cache', type=Path, default=Path.home() / '.pub-cache')
    args = ap.parse_args()
    source, head, manifest, artifacts = checked_inputs(PROOF)
    verify_commit(PROOF, head, manifest)
    verify_native_reuse(PROOF, source, manifest)
    template = args.r24_template.resolve()
    require(template.is_file() and sha(template) == R24_TEMPLATE_SHA256, 'reviewed notice template unavailable')
    for rel in SUPPLEMENT_PATHS:
        require(rel not in manifest and (source / rel).is_file() and not (source / rel).is_symlink(), f'generated build supplement missing or tracked: {rel}')
    out = args.output.resolve()
    require(not out.exists(), 'output already exists; refusing to overwrite')
    out.mkdir(parents=True)
    tree = out / LABEL
    tree.mkdir()
    selected = sorted(rel for rel in manifest if wanted_source(rel))
    for rel in selected:
        copy_file(source / rel, tree / rel)
    notices = copy_reviewed_notices(template, source, tree)
    prov = tree / 'PROVENANCE'
    prov.mkdir(exist_ok=True)
    copy_file(PROOF / 'source-files.sha256', prov / 'source-files.sha256')
    copy_file(PROOF / 'native-reuse.json', prov / 'native-reuse.json')
    copy_file(PROOF / 'native-packaging.json', prov / 'native-packaging.json')
    (prov / 'source-head.txt').write_text(head + '\n', encoding='utf-8')
    (prov / 'signed-artifacts.json').write_text(json.dumps({'source_commit': head, 'version': '1.2.1+10', 'artifacts': artifacts}, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    (prov / 'notice-template.json').write_text(json.dumps({'source': 'previously verified r24 corresponding-source draft archive', 'archive_sha256': R24_TEMPLATE_SHA256, 'condition': 'Cargo.lock byte-identical', 'notice_files_copied': notices}, indent=2) + '\n', encoding='utf-8')
    supplements = []
    for rel in SUPPLEMENT_PATHS:
        copy_file(source / rel, tree / rel)
        supplements.append((rel, sha(source / rel)))
    (prov / 'post-snapshot-generated-supplements.tsv').write_text('sha256\tpath\torigin\n' + ''.join(f'{digest}\t{rel}\tpost-snapshot-generated-supplement\n' for rel, digest in supplements), encoding='utf-8')
    counts = copy_dart_licenses(tree, source, args.pub_cache.resolve())
    require(counts[2] == 0, 'Dart license text missing from local cache')
    (tree / 'SOURCE_ALLOWLIST.txt').write_text('\n'.join(selected) + '\n', encoding='utf-8')
    (tree / 'START_HERE.md').write_text(f'''# Android testnet candidate corresponding source\n\nStatus: Android testnet candidate corresponding source. Play publication and independent security audit have not been established.\n\nSource commit: `{head}`. Both apps target testnet version `1.2.1+10`. `PROVENANCE/signed-artifacts.json` binds the four candidate files and original certificate fingerprints. It records local signing evidence, not Play distribution or independent artifact acceptance.\n\nSource files are selected from the frozen manifest. Eight generated Android wrapper/registrant inputs are identified separately. Rust and supplemental notice texts come from the previously reviewed r24 archive only after an identical Cargo.lock check; Dart license texts come from the locked local package cache. Private signing material, compiled native libraries and build caches are excluded.\n\nThe archive is deterministic from identical complete inputs but a second generation was not run. APK/AAB bit reproducibility is not claimed. Historical test evidence does not establish r25 runtime acceptance.\n''', encoding='utf-8')
    (tree / 'BUILDING-ANDROID-r25.md').write_text('''# Android build notes\n\nCandidate version: 1.2.1+10. Build dependencies: Flutter 3.41.3, Dart 3.11.1, Rust 1.96.1, cargo-ndk 4.1.2, JDK 17, Android NDK 27.0.12077973.\n\nGenerate each app’s ARM64 and x86_64 FFI libraries with `cargo ndk`, run `flutter pub get`, then build the Android app bundle with Flutter build name 1.2.1 and build number 10. The candidate APK was derived from its AAB with bundletool. Release keys and credentials are not included. The Gradle wrapper distribution checksum and Rust toolchain are not pinned in source; bit-identical binary reconstruction is not asserted.\n''', encoding='utf-8')
    copy_file(Path(__file__).resolve(), tree / 'tools/build_bundle.py')
    os.chmod(tree / 'tools/build_bundle.py', 0o755)
    links = markdown_link_audit(tree)
    (prov / 'missing-local-markdown-links.tsv').write_text('document\ttarget\tstatus\n' + ''.join(f'{a}\t{b}\t{c}\n' for a,b,c in links), encoding='utf-8')
    generated = sorted(p.relative_to(tree).as_posix() for p in tree.rglob('*') if p.is_file() and p.relative_to(tree).as_posix() not in selected)
    (tree / 'GENERATED_ALLOWLIST.txt').write_text('\n'.join(generated + ['GENERATED_ALLOWLIST.txt', 'CONTENTS.sha256']) + '\n', encoding='utf-8')
    rows = content_manifest(tree)
    bad = sensitive_scan(tree)
    require(not bad, f'sensitive/prohibited payload: {bad}')
    archive = out / f'{LABEL}.tar.gz'
    deterministic_archive(tree, archive)
    require(archive.stat().st_size < 50 * 1024 * 1024, 'archive exceeds 50 MiB')
    summary = {'status': 'ANDROID_TESTNET_CANDIDATE_CORRESPONDING_SOURCE', 'source_commit': head, 'source_files_verified': len(manifest), 'source_files_selected': len(selected), 'supplements': len(supplements), 'dart_runtime_packages': counts[0], 'dart_build_test_packages': counts[1], 'dart_missing_licenses': counts[2], 'unresolved_markdown_links': len(links), 'payload_files': len(rows)+1, 'archive_sha256': sha(archive), 'archive_bytes': archive.stat().st_size, 'archive_reproducibility': 'NOT_RERUN', 'publication': 'NOT_RUN', 'distribution_license_security_review': 'REQUIRED', 'binary_bit_reproducibility': 'NOT_CLAIMED'}
    (out / 'SUMMARY.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    (out / 'ARCHIVE.sha256').write_text(f"{summary['archive_sha256']}  {archive.name}\n", encoding='utf-8')
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
