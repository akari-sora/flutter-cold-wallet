# Security policy

FCW Wallet / Vault is experimental software for **test networks only** (Sepolia, local development chains and Bitcoin regtest). It has **not** been audited by a third party, and there is **no bug bounty**. Do not use it with a real mnemonic or real funds.

## Reporting a vulnerability

Please report security problems privately, not in public issues or merge requests:

1. Open a **confidential issue** at <https://gitlab.com/aa22396584/flutter-cold-wallet/-/issues/new> and confirm the confidential setting is available and selected before submitting. A GitLab account is required.
2. Describe the affected component and commit, how to reproduce the problem with test data, and what an attacker could achieve.

This route is not anonymous. If confidential issue submission is unavailable, do not submit sensitive details publicly; no alternate public security contact has yet been verified.

**Never include a real mnemonic, private key, password or backup file** — not in the report, logs, screenshots or attachments. Reproduce with the public BIP-39 test vector (`abandon abandon … about`) or Anvil default accounts. If a report contains real secrets, consider them compromised and move any funds.

This is a small project maintained on a best-effort basis, with no guaranteed response time. Once a fix is ready we will agree a disclosure date with you; please do not disclose the issue publicly before then.

## Scope

In scope:

- `apps/vault` and `apps/wallet`, including the Android and iOS platform code;
- the Rust crates in `crates/` and the Dart packages in `packages/`;
- the QR / BC-UR request and signature formats, the transaction policy engine, the request-binding and signature checks, and the encrypted backup format;
- the build scripts that produce the release-configuration APKs.

Out of scope:

- test tools that use public keys by design: `tools/nfc_probe` (its "vault" uses the public `abandon … about` mnemonic), `tools/okx_probe`, `tools/reference_oracle` and `tests/android/public_review_observer`;
- Unverified third-party APKs: builds made without `key.properties` use a local debug keystore. Check the official app-signing certificate fingerprints in the [GitLab release](https://gitlab.com/aa22396584/flutter-cold-wallet/-/releases/v1.2.1) before installing the official APKs;
- third-party apps and libraries (for example OKX Wallet, Google ML Kit, Flutter plugins) — report those upstream; we are glad to hear about how they affect FCW;
- attacks that require a rooted or otherwise compromised Vault device, beyond what `docs/threat-model.md` covers;
- anything involving mainnet or real assets, which the apps do not support.

See [docs/threat-model.md](docs/threat-model.md) for the trust boundaries the design assumes.
