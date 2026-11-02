# Android testnet candidate corresponding source

Status: Android testnet 1.2.1+10 (r25). Both apps are available to selected testers in Taiwan Google Play closed Alpha. Play-installed acceptance, cross-channel updates, physical camera optics, OEM authentication and physical offline-device isolation remain unverified. No independent security audit has been established. See [PUBLICATION.md](PUBLICATION.md) and the [GitLab release](https://gitlab.com/aa22396584/flutter-cold-wallet/-/releases/v1.2.1).

Source commit: `8352361278a60e92d588070788724dc197cd6713`. Both apps target testnet version `1.2.1+10`. `PROVENANCE/signed-artifacts.json` binds the four candidate files and original certificate fingerprints. It records local signing evidence; it does not by itself establish Play-installed or physical-device acceptance.

Source files are selected from the frozen manifest. Eight generated Android wrapper/registrant inputs are identified separately. Rust and supplemental notice texts come from the previously reviewed r24 archive only after an identical Cargo.lock check; Dart license texts come from the locked local package cache. Private signing material, compiled native libraries and build caches are excluded.

The archive is deterministic from identical complete inputs but a second generation was not run. APK/AAB bit reproducibility is not claimed. Historical test evidence does not by itself establish r25 runtime acceptance; see the current release for the bounded r25 evidence.
