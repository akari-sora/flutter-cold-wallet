# Android-first completion plan — 2026-10-23

The owner requested completion of the six remaining-work groups. This plan
tracks implementation, candidate validation and external acceptance separately.
The owner's latest instruction pauses iOS work and prioritizes Android; iOS
acceptance is excluded from the completion criteria for this run.
Preserve the hash-pinned r20 candidates and the original `public-121` and
`phase-0` branches. Never use real funds, private wallet data or production
seeds in tests. Source changes require new candidate identities and evidence.

## Current completion snapshot

- The repaired Wallet r22 source passes the full Wallet suite: **278 passed**
  (`wallet-r22-final-pass.log`). Wallet analysis is clean
  (`wallet-r22-analyze.log`), and the release-check suite reports **198 passed,
  1 skipped** (`release-check-tests-final.log`).
- The complete Vault suite passes **158 tests** with the real host-native
  libraries (`vault-r22-full-final.log`), including restore, storage, backup,
  lifecycle guards and explicit signing. Vault analysis is clean
  (`vault-r22-analyze-final.log`).
- The final Codex focused repair review is **PASS**
  (`r22-final-review-codex.md`). The requested second independent Claude review
  was not obtained because its weekly quota was exhausted; this remains a
  disclosed review-evidence gap, not a failed review.
- Wallet/Vault APK and AAB r22 artifacts were built and content-audited, but all
  four are temporary Android Debug-signed artifacts. They are not uploadable
  release candidates and still require the preserved original app/upload keys.
- Fresh r22 emulator QA found a scanner defect: the Vault scanner reports a
  missing native `mobile_scanner` event-channel implementation and a
  `wakelock_plus` channel error; manual UR entry did not open. Release is
  blocked until the plugin/build cause is repaired and the rebuilt candidate
  passes scanner and signing acceptance. Host test success does not close this
  device-runtime failure.
- The diagnosed build cause is the combination of a tracked-file snapshot
  omitting generated `GeneratedPluginRegistrant.java` and first building with
  `--no-pub`, which skips its regeneration. The repair target is r23
  **1.2.1+8** with fresh Flutter tooling generation, an APK plugin-presence
  regression gate, new artifact audits and repeated emulator acceptance.
- Replacement r23 **1.2.1+8** has now been built from a 547-file frozen source
  snapshot after fresh offline Flutter platform generation. APK/AAB content,
  native correspondence and all 170 split APK 16 KiB alignment checks passed.
  Both APKs installed and cold-started as version code 8 on the isolated AVD.
  Vault authenticated unlock, scanner and manual UR dialog now work. Actual
  public dynamic camera QR decoding, review and explicit slide-to-sign passed;
  Wallet host-native verification returned `verified=true` and
  `SIGNED_TX_READY` with the expected test-vector hash. A fresh manually entered
  request 3b was also reviewed, explicitly signed and independently host-verified;
  it was not a replay of camera request 3a. Permission/settings recovery and
  background relocking passed on r23. Watch scanner/manual-dialog smoke passed;
  its pairing/returned-signature UI remains outside this run. Broadcast was NOT_RUN.
  All four artifacts remain Debug signed. Independent review rejected the first
  raw-marker plugin gate and requested changes to its first structural revision.
  The final mapping-backed replacement re-audited both unchanged APKs and
  passes **222 tests, 1 skipped**; the independent supplement rejects all 13
  negative cases. It now requires adjacent generated plugin construction,
  constructor and registry-add instructions, rejects register overwrite, parses
  allowBackup values correctly, and retains real multidex/numbering/instruction
  regressions. Independent final delta review is **PASS** after fresh real D8 overwrite probes,
  instruction cases, backup parsing and exact-artifact checks. This remains one
  reviewer, with the Fable review unavailable.
- The retained r20 Android emulator flow exercised an actual public request QR
  and Vault signature. Wallet verification returned `SIGNED_TX_READY` with the
  expected request, digest, chain and recovered address; broadcast was
  **NOT_RUN**. Evidence:
  `vault-r20-public-signature-verification.json` in the session scratch folder.
- Per ADR-005 §§11.8 and 12.6, the owner accepted Android emulator coverage plus
  Play closed testing in place of physical-device acceptance. Physical
  camera/biometrics, Galaxy S8/OEM behavior and offline-device isolation remain
  disclosed residual gaps; they are not added completion blockers for this run.
- The owner selected all globally available Play regions. No Console country
  selection was saved. The existing Personal-account answer to `Q-09` does not
  by itself establish a 12-testers/14-days requirement; verify production-access
  requirements separately for each package in Play Console.
- An Android corresponding-source delivery draft passed independent integrity
  and deterministic archive-generation review. Eight archives from four
  output directories match SHA-256
  `e60e88a8deec44e8348c8ddc9a3133d9b8dd30eafee2013e0d3a7a0217d67810`.
  Its 547 source-manifest entries, 314 selected source files, 8 generated
  supplements and sensitive-material exclusions were checked. This does not
  establish distribution-license approval, public source access or APK/AAB
  bit reproducibility. The archive and final review are retained in the ignored
  r23 verification checkpoint.
- The existing CB Studio TRON Vault public Play listing now verifies the public
  support address `aa22396584@gmail.com`. Both canonical languages and embedded
  policies were updated together, effective 2026-10-23, including voluntary email
  handling. All **9 policy/widget tests** and an independent narrow consistency
  review passed. Both app versions advanced to **1.2.1+9**. The new r24 snapshot
  is built from 547 frozen files: both APK audits, AAB content/plugin/native
  checks, FFI correspondence and 170 split 16 KiB checks pass. All 4 artifacts
  are retained as Debug inputs. Four separate r24 outputs are now signed with
  the original app/upload keys through the existing Agent vault; all four
  certificate pins and non-signature-entry byte identity passed. Full signed
  artifact audits now PASS, including both upload pins and all 170 split APK
  16 KiB checks. A fresh isolated runtime retry is in progress. The r24 source archive passed separate independent integrity review, including
  a fresh byte-identical archive pair (SHA-256
  `6c3381f021a51470b28ba5b91407b12a61912b2a8267b77b00d88f6f61cd91b5`). r23 remains the completed functional QA candidate. Original-key
  signing is complete locally; no App publication is claimed. The existing controlled Vercel host now serves
  the bilingual public policies: all 263 prior source files are unchanged, only
  three policy pages were added, and anonymous HTTP plus browser checks passed. A fresh
  r24 emulator booted after one resource-guarded retry, but Android System UI
  became unresponsive during Watch startup; r24 runtime acceptance remains open
  and Vault smoke was NOT_RUN. This does not replace r23 functional evidence.
- iOS remains paused. ADR-005 mainnet phases 1a, 1b, 2a and 2b remain future
  work and are not implemented or enabled by this Android/testnet completion.

## Execution lanes

1. Release-tool repairs: reuse Android SDK discovery, support separate APK
   certificate pins and make environment failures structured. Add regression
   coverage before refactoring and keep existing audit checks intact.
2. Wallet safety: test and repair ambiguous-payment admission, RPC redirect
   policy and sensitive RPC errors. Review nonce/input reservation changes
   against ADR-005 before implementation; cancellation must not imply that an
   already exported or signed transaction can no longer execute.
3. Candidate acceptance: use public test vectors with Android emulator coverage
   and, when Console requires it, Play closed testing for permissions, QR,
   signing/broadcast, locking and traffic. Record physical camera, biometrics,
   S8, stock OKX and offline-isolation gaps as residual evidence gaps under
   ADR-005 §12.6 rather than adding a physical-acceptance blocker.
4. Store/release: prepare screenshots, listings, policy pages and declarations;
   inspect account/app/signing availability; publish only a reviewed, verified
   candidate with the owner's existing authority and record remote readback.
5. Mainnet: keep implementation in the Phase 0 development lane, follow every
   ADR-005 stage and its invariant tests. Complete the phase's review and
   validation before enabling or distributing a mainnet build.
6. iOS: paused by the owner. Preserve already completed source/build work;
   perform no further iOS build, signing or device work in this run.

## Verification and completion

Run focused regression tests first, then relevant package analysis/full suites,
native checks and artifact audits. Keep writer and reviewers independent.
Critical transaction and publication changes require dual review. This run has
one final Codex PASS; the second requested review remains unavailable because
of Claude's weekly quota, so the dual-review evidence gate remains open. Host
tests, emulator results, Play signing, any package-specific closed-test
requirement and publication each require their own evidence. Physical-device
items remain disclosed residual gaps under the owner-approved ADR-005
acceptance boundary. Record unavailable external gates as blocked, never as
completed by a substitute test.

Build outputs and acceptance evidence belong in this session's system temp
directory or a small ignored project directory, not in the source history.
