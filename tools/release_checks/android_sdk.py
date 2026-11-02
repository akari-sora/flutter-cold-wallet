"""Find the local Android release tools without downloading or installing anything."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil


class ToolError(RuntimeError):
    pass


def discover_sdk(sdk=None, *, env=None, system=None, home=None):
    env = os.environ if env is None else env
    system = system or platform.system()
    home = Path.home() if home is None else Path(home)
    if sdk is not None:
        source, candidate = "--sdk", sdk
    elif env.get("ANDROID_HOME"):
        source, candidate = "ANDROID_HOME", env["ANDROID_HOME"]
    elif env.get("ANDROID_SDK_ROOT"):
        source, candidate = "ANDROID_SDK_ROOT", env["ANDROID_SDK_ROOT"]
    elif system == "Darwin":
        source, candidate = "macOS default", home / "Library/Android/sdk"
    elif system == "Windows":
        if not env.get("LOCALAPPDATA"):
            raise ToolError("Android SDK missing: set --sdk, ANDROID_HOME, ANDROID_SDK_ROOT or LOCALAPPDATA")
        source, candidate = "Windows default", Path(env["LOCALAPPDATA"]) / "Android/Sdk"
    else:
        source, candidate = "Linux default", home / "Android/Sdk"
    path = Path(candidate).expanduser().resolve()
    if not path.is_dir():
        raise ToolError(f"Android SDK from {source} is not a directory: {path}")
    return path


def build_tools_version_key(version):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[- ]?(alpha|beta|rc)[.-]?(\d+))?", version)
    if not match:
        raise ValueError(f"not an Android build-tools version: {version}")
    major, minor, patch, stage, number = match.groups()
    return (int(major), int(minor), int(patch),
            {"alpha": 0, "beta": 1, "rc": 2, None: 3}[stage], int(number or 0))


def discover_build_tools(sdk, version=None):
    directory = Path(sdk) / "build-tools"
    if version is not None:
        if Path(version).name != version or version in (".", ".."):
            raise ToolError("--build-tools must name an installed build-tools version")
        selected = directory / version
    else:
        versions = []
        if directory.is_dir():
            for path in directory.iterdir():
                if path.is_dir():
                    try:
                        versions.append((build_tools_version_key(path.name), path))
                    except ValueError:
                        continue
        if not versions:
            raise ToolError(f"Android build-tools missing under {directory}; install build-tools or set --build-tools")
        selected = max(versions)[1]
    if not selected.is_dir():
        raise ToolError(f"Android build-tools {version} missing: {selected}")
    return selected


def executable(path, name, system):
    path = Path(path)
    if not path.is_file() or (system != "Windows" and not os.access(path, os.X_OK)):
        raise ToolError(f"{name} executable missing or not executable: {path}")
    return str(path.resolve())


def discover_java_tool(name, *, env=None, system=None):
    env = os.environ if env is None else env
    system = system or platform.system()
    filename = name + (".exe" if system == "Windows" else "")
    if env.get("JAVA_HOME"):
        candidate = Path(env["JAVA_HOME"]) / "bin" / filename
        if candidate.is_file():
            return executable(candidate, name, system)
    found = shutil.which(filename, path=env.get("PATH", ""))
    if not found:
        raise ToolError(f"{name} missing: install a JDK and set JAVA_HOME or add its bin directory to PATH")
    return executable(found, name, system)


def discover_bundletool(bundletool=None, *, env=None, system=None):
    env = os.environ if env is None else env
    system = system or platform.system()
    if bundletool is not None:
        candidate = Path(bundletool).expanduser()
        if not candidate.is_file():
            found = shutil.which(str(bundletool), path=env.get("PATH", ""))
            if not found:
                raise ToolError(f"bundletool missing: {bundletool}; pass --bundletool /path/to/bundletool.jar or executable")
            candidate = Path(found)
    else:
        found = shutil.which("bundletool", path=env.get("PATH", ""))
        if not found:
            raise ToolError("bundletool missing from PATH; pass --bundletool /path/to/bundletool.jar or executable")
        candidate = Path(found)
    if candidate.suffix.lower() == ".jar":
        return [discover_java_tool("java", env=env, system=system), "-jar", str(candidate.resolve())]
    return [executable(candidate, "bundletool", system)]


def discover_tools(sdk=None, build_tools=None, bundletool=None, *, env=None, system=None, home=None):
    system = system or platform.system()
    sdk_path = discover_sdk(sdk, env=env, system=system, home=home)
    directory = discover_build_tools(sdk_path, build_tools)
    filenames = {
        "apksigner": "apksigner.bat" if system == "Windows" else "apksigner",
        "aapt2": "aapt2.exe" if system == "Windows" else "aapt2",
        "zipalign": "zipalign.exe" if system == "Windows" else "zipalign",
    }
    result = {"sdk": str(sdk_path), "build_tools_version": directory.name}
    for name, filename in filenames.items():
        result[name] = executable(directory / filename, name, system)
    result["bundletool"] = discover_bundletool(bundletool, env=env, system=system)
    for name in ("java", "keytool", "jarsigner"):
        result[name] = discover_java_tool(name, env=env, system=system)
    return result


def add_tool_arguments(parser):
    parser.add_argument("--sdk", type=Path, help="Android SDK (otherwise ANDROID_HOME, ANDROID_SDK_ROOT, platform default)")
    parser.add_argument("--build-tools", help="Installed build-tools version (otherwise highest installed)")
    parser.add_argument("--bundletool", help="bundletool executable or JAR (otherwise PATH)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    add_tool_arguments(parser)
    args = parser.parse_args(argv)
    try:
        report = {"status": "PASS", "tools": discover_tools(args.sdk, args.build_tools, args.bundletool)}
    except (ToolError, OSError) as error:
        report = {"status": "FAIL", "detail": str(error)}
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
