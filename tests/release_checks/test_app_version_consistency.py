"""Keep each app's About version synchronized with its release version."""

import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent


def test_app_versions_match_pubspecs():
    for app in ("wallet", "vault"):
        app_root = PROJECT_ROOT / "apps" / app
        pubspec = (app_root / "pubspec.yaml").read_text(encoding="utf-8")
        app_info = (app_root / "lib" / "app_info.dart").read_text(
            encoding="utf-8"
        )

        pubspec_version = re.search(
            r"^version:\s*(\S+)\s*$", pubspec, flags=re.MULTILINE
        )
        about_version = re.search(
            r"^const appVersion = '([^']+)';\s*$",
            app_info,
            flags=re.MULTILINE,
        )

        assert pubspec_version is not None, f"{app}: pubspec version is missing"
        assert about_version is not None, f"{app}: appVersion is missing"
        assert about_version.group(1) == pubspec_version.group(1), (
            f"{app}: About version {about_version.group(1)} does not match "
            f"pubspec version {pubspec_version.group(1)}"
        )
