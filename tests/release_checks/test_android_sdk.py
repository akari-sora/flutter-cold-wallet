"""Discovery is tested with local fake installations; no Android SDK is required."""
import sys

import pytest

from tools.release_checks import android_sdk as sdk


def touch_executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("stub", encoding="utf-8")
    path.chmod(0o755)
    return path


@pytest.mark.parametrize("system,relative", [("Darwin", "Library/Android/sdk"), ("Linux", "Android/Sdk")])
def test_platform_sdk_defaults(tmp_path, system, relative):
    expected = tmp_path / relative
    expected.mkdir(parents=True)
    assert sdk.discover_sdk(env={}, system=system, home=tmp_path) == expected


def test_windows_sdk_default(tmp_path):
    expected = tmp_path / "Android/Sdk"
    expected.mkdir(parents=True)
    assert sdk.discover_sdk(env={"LOCALAPPDATA": str(tmp_path)}, system="Windows") == expected


def test_sdk_precedence_and_missing_override(tmp_path):
    paths = [tmp_path / name for name in ("explicit", "home", "root")]
    for path in paths:
        path.mkdir()
    env = {"ANDROID_HOME": str(paths[1]), "ANDROID_SDK_ROOT": str(paths[2])}
    assert sdk.discover_sdk(paths[0], env=env) == paths[0]
    assert sdk.discover_sdk(env=env) == paths[1]
    del env["ANDROID_HOME"]
    assert sdk.discover_sdk(env=env) == paths[2]
    with pytest.raises(sdk.ToolError, match="--sdk.*not a directory"):
        sdk.discover_sdk(tmp_path / "missing", env=env)


def test_windows_missing_sdk_has_actionable_error():
    with pytest.raises(sdk.ToolError, match="LOCALAPPDATA"):
        sdk.discover_sdk(env={}, system="Windows")


def test_missing_environment_sdk_does_not_silently_fall_back(tmp_path):
    with pytest.raises(sdk.ToolError, match="ANDROID_HOME"):
        sdk.discover_sdk(env={"ANDROID_HOME": str(tmp_path / "absent")})


def test_highest_build_tools_are_numeric_and_stable_wins(tmp_path):
    for name in ("9.0.0", "35.0.0", "36.0.0-rc2", "36.0.0-rc10", "36.0.0", "unrelated"):
        (tmp_path / "build-tools" / name).mkdir(parents=True)
    assert sdk.discover_build_tools(tmp_path).name == "36.0.0"
    assert sdk.discover_build_tools(tmp_path, "9.0.0").name == "9.0.0"
    (tmp_path / "build-tools/36.0.0").rmdir()
    assert sdk.discover_build_tools(tmp_path).name == "36.0.0-rc10"


@pytest.mark.parametrize("version", [None, "36.0.0", "../other"])
def test_missing_or_invalid_build_tools(tmp_path, version):
    with pytest.raises(sdk.ToolError, match="build-tools"):
        sdk.discover_build_tools(tmp_path, version)


@pytest.mark.parametrize("system", ["Darwin", "Linux", "Windows"])
def test_complete_tool_discovery_uses_platform_suffixes(tmp_path, system):
    directory = tmp_path / "sdk/build-tools/36.0.0"
    for filename in (("apksigner.bat", "aapt2.exe", "zipalign.exe") if system == "Windows"
                     else ("apksigner", "aapt2", "zipalign")):
        touch_executable(directory / filename)
    for name in ("java", "keytool", "jarsigner"):
        touch_executable(tmp_path / "jdk/bin" / (name + (".exe" if system == "Windows" else "")))
    bundletool = touch_executable(tmp_path / "bundletool")
    result = sdk.discover_tools(tmp_path / "sdk", bundletool=bundletool,
                                env={"JAVA_HOME": str(tmp_path / "jdk"), "PATH": ""}, system=system)
    assert result["build_tools_version"] == "36.0.0"
    assert result["bundletool"] == [str(bundletool)]
    assert result["apksigner"].endswith("apksigner.bat" if system == "Windows" else "apksigner")
    assert result["aapt2"].endswith("aapt2.exe" if system == "Windows" else "aapt2")
    assert result["zipalign"].endswith("zipalign.exe" if system == "Windows" else "zipalign")


@pytest.mark.parametrize("missing", ["apksigner", "aapt2", "zipalign"])
def test_missing_sdk_tool_names_it(tmp_path, missing):
    for name in ("apksigner", "aapt2", "zipalign"):
        if name != missing:
            touch_executable(tmp_path / "build-tools/36.0.0" / name)
    with pytest.raises(sdk.ToolError, match=missing):
        sdk.discover_tools(tmp_path, env={}, system="Linux")


def test_explicit_bundletool_jar_uses_java(tmp_path):
    jar = tmp_path / "bundletool.jar"
    jar.touch()
    java = touch_executable(tmp_path / "jdk/bin/java")
    command = sdk.discover_bundletool(jar, env={"JAVA_HOME": str(tmp_path / "jdk")}, system="Linux")
    assert command == [str(java), "-jar", str(jar)]


def test_bundletool_and_java_tools_from_path(tmp_path, monkeypatch):
    bundletool = touch_executable(tmp_path / "bundletool")
    java = touch_executable(tmp_path / "java")
    monkeypatch.setattr(sdk.shutil, "which", lambda name, path: str(tmp_path / name))
    assert sdk.discover_bundletool(env={"PATH": str(tmp_path)}) == [str(bundletool)]
    assert sdk.discover_java_tool("java", env={"PATH": str(tmp_path)}, system="Linux") == str(java)


@pytest.mark.parametrize("explicit", [None, "missing.jar"])
def test_missing_bundletool_names_remedy(explicit, monkeypatch):
    monkeypatch.setattr(sdk.shutil, "which", lambda *args, **kwargs: None)
    with pytest.raises(sdk.ToolError, match="bundletool.*--bundletool"):
        sdk.discover_bundletool(explicit, env={"PATH": ""})


def test_missing_java_names_jdk(monkeypatch):
    monkeypatch.setattr(sdk.shutil, "which", lambda *args, **kwargs: None)
    with pytest.raises(sdk.ToolError, match="java.*JDK"):
        sdk.discover_java_tool("java", env={"PATH": ""})


@pytest.mark.skipif(sys.platform == "win32", reason="Windows has no executable permission bit to clear")
def test_nonexecutable_tool_is_rejected(tmp_path):
    tool = tmp_path / "bundletool"
    tool.touch()
    with pytest.raises(sdk.ToolError, match="not executable"):
        sdk.discover_bundletool(tool, system="Linux")


def test_discovery_cli_pass_and_fail(monkeypatch, capsys):
    monkeypatch.setattr(sdk, "discover_tools", lambda *args: {"build_tools_version": "36.0.0"})
    assert sdk.main([]) == 0
    assert '"PASS"' in capsys.readouterr().out

    def missing(*args):
        raise sdk.ToolError("bundletool missing")

    monkeypatch.setattr(sdk, "discover_tools", missing)
    assert sdk.main([]) == 1
    assert "bundletool missing" in capsys.readouterr().out
