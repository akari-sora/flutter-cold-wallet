# Contributing

Thanks for your interest in FCW Wallet / Vault. The canonical project repository is <https://gitlab.com/aa22396584/flutter-cold-wallet>; its GitHub copy is a mirror. GitLab account access is needed to submit an issue or merge request. Bug reports, tests and focused fixes are welcome.

## Ground rules

- **Never post real secrets.** No real mnemonic, private key, password, backup file or RPC credential in issues, merge requests, commits, logs or screenshots. Use the public BIP-39 test vector (`abandon abandon … about`), the other public vectors already in the tests, or Anvil default accounts. Reports or changes that contain real secrets will be closed.
- Security problems go through the private process in [SECURITY.md](SECURITY.md), not public issues.
- The apps target test networks only. Changes that enable mainnet signing will not be accepted at this stage.
- The app UI is in Traditional Chinese (zh-TW); keep new strings consistent with the surrounding wording.

## Development setup

Install the tools listed under [Prerequisites](README.md#prerequisites) in the README (Flutter 3.41.3, Rust, cargo-ndk, Android NDK 27.0.12077973, Python 3.11 with `tests/requirements.txt`).

## Before you open a merge request

Run the checks for the parts you touched, from the repository root (see [Build and test](README.md#build-and-test) for platform details):

```sh
cargo test --workspace --locked
cargo build --locked -p wallet_ffi -p vault_ffi
export WALLET_FFI_PATH=... VAULT_FFI_PATH=...   # host libraries from target/debug
# in each changed Flutter package or app, and in apps/wallet and apps/vault
# when a shared package changes:
flutter pub get && flutter analyze && flutter test
python3 -m pytest tests -q                       # when Python tests or tools change
```

- `flutter analyze` must report no issues.
- Every fix needs a regression test that fails without the fix.
- Keep changes focused, and match the naming, structure and comment style of the code around them.
- Do not commit generated or machine-specific files (`local.properties`, `.flutter-plugins-dependencies`, built native libraries, `key.properties`, keystores); they are git-ignored.

## Sign your commits (DCO)

Contributions are accepted under the [Developer Certificate of Origin 1.1](https://developercertificate.org/). Add a `Signed-off-by` line to every commit, for example with `git commit -s`:

```
Signed-off-by: Your Name <you@example.com>
```

By signing off you certify that you wrote the change or otherwise have the right to submit it under the project's license.

## License of contributions

FCW is licensed under the GNU Affero General Public License v3.0 or later ([LICENSE](LICENSE)) with the additional permission in [LICENSE-EXCEPTION](LICENSE-EXCEPTION), which allows linking and conveying the apps with Google ML Kit and Google Play services libraries. Your contribution is licensed under the same terms, including that additional permission. Do not submit code you cannot license this way, for example code copied from projects under incompatible licenses.
