# Public source and Android r25 publication

The canonical repository and Android downloads are on [GitLab](https://gitlab.com/aa22396584/flutter-cold-wallet). The [GitHub repository](https://github.com/akari-sora/flutter-cold-wallet) is a mirror. The [v1.2.1 release](https://gitlab.com/aa22396584/flutter-cold-wallet/-/releases/v1.2.1) provides the FCW Watch and FCW Vault `1.2.1+10` (r25) testnet APKs.

Both apps are available to selected testers in the Taiwan Google Play closed Alpha. Play-installed acceptance and cross-channel update checks have not been run. Physical camera optics, OEM authentication and physical offline-device isolation remain unverified. The apps are testnet-only; do not use real funds or a real mnemonic. They have not received an independent third-party security audit.

The APK build source was frozen at private development commit `8352361278a60e92d588070788724dc197cd6713`. The independently reviewed [corresponding-source archive](https://pages.stickerstudio.xyz/fcw/source/1.2.1-10/) has SHA-256 `c99e8f25a76a5ff689c033ca02288e5f5f760a09459449758a4ac0462acdb358`. This public repository was prepared from that archive. Its README, START_HERE, CONTRIBUTING, SECURITY and this publication notice were edited after the build to describe public URLs and current status; these edits did not rebuild or re-sign the APKs.

`SOURCE-ARCHIVE-CONTENTS.sha256` and the provenance manifests describe the original archive and must be checked against that archive, not against the later-edited public documentation. Old candidate numbers, links and acceptance statements in the snapshot are historical unless superseded by the current release. A source snapshot and bounded review are not a claim of reproducible builds or legal clearance.

FCW is licensed under [AGPL-3.0-or-later](LICENSE) with the [additional linking permission](LICENSE-EXCEPTION); third-party notices are retained.

## File manifests

`SOURCE-ARCHIVE-CONTENTS.sha256` is the unchanged manifest from the original corresponding-source tar. It describes that archive, including its historical documents; it is not a checksum of the later public Git tree. `CONTENTS.sha256` describes this public snapshot, excluding itself. Documentation and these publication manifests were updated after the APK build; product source was not changed.

The public Git attributes explicitly preserve the original CRLF bytes in two Gradle Windows launchers and one third-party license, so Git archives retain their reviewed checksums. No launcher or license content was edited.
