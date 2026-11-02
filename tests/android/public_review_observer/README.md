# Public review observer (isolated Android test tool)

This test-only APK reads the accessibility tree of an already open **public Vault transaction review**. It targets its own helper package, not the Vault process. It is excluded from both Flutter applications and is never a formal QR-build entry point.

There are no activities, services, receivers, providers, permissions, networking, screenshots, clipboard access, input injection, node actions, signing, shell execution, or disk writes in the APK. It does not alter `FLAG_SECURE`, the Vault lifecycle, or device authentication. Obtaining UiAutomation uses `FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`, preserving existing accessibility services.

The observer refuses any root outside `com.coldwallet.vault`, mixed-package tree, password node, secret/onboarding/unlock/backup marker, incomplete or oversized tree, or surface without the exact visible title `確認交易` plus a visible public-review anchor. An anchor is either an exact static field label from `TransactionReviewCard` (such as `轉帳金額`, `Nonce（交易序號）`, or `Gas 上限`), or **both visible** `核准並簽署` and `等待確認`/`政策拒絕` markers at the bottom. A title alone, unrelated node, or invisible anchor is insufficient. This only authorizes read-only observation; approval visibility and signing remain separately guarded by the coordinating test runner.

The first version passed 13 guard checks but actual runtime observation showed that Android prunes the approval node outside the current viewport. Requiring it simultaneously prevented observing legitimate top/middle public fields. The current viewport regression suite preserves the original 13 checks (with the accepted bottom fixture explicitly visible), adds top/middle/bottom and visibility/secret refusals, and checks every allowed label against the current exact production strings. Rejected results contain fixed reason codes only. Candidate nodes remain only in process memory until all guards pass. A successful result includes the actual `getText()`, `getContentDescription()`, `getHintText()`, bounds, and flags, without deriving or filling any value. Limits: 512 nodes, depth 32, 16,384 characters per field, 128 KiB of text, 192 KiB output. It rechecks the active package, window, and visible title before returning.

Actual Android semantics also merge several card labels into one multiline content description. Public-field, policy, and approval markers therefore match **exact complete lines** within the original bounded visible node text, splitting LF/CRLF/CR only. No substring matching, trimming, aliases, or host-provided values are used. The review title must still equal the entire visible node string `確認交易`; secret detection still scans the entire original string. Combined top/middle/bottom node regressions and partial-label, invisible-anchor, merged-secret, and merged-title refusals extend the 47-check viewport suite to 57 checks. Returned node strings remain unchanged.

An actual first invocation also returned `NO_ACTIVE_ROOT` while Vault remained foreground before and after. Initial root acquisition now polls only while the root is null, using an uptime deadline of five seconds and intervals of at most 50 ms. The first non-null root immediately undergoes the existing package guard before any text read; another package is refused rather than retried. This is a bounded readiness wait, not a reconnect or fixed blind delay. Continued absence still returns `NO_ACTIVE_ROOT`, and a null root during the final window check still refuses immediately. No claim is made about why the runtime returned null, and this does not resolve genuine window absence or platform restrictions.

Actual observation then showed that Flutter's custom accessibility provider did not find the visible exact `確認交易` content description through `findAccessibilityNodeInfosByText`. The final check now explicitly traverses the fresh active root, rather than using that query. It reapplies the same package/password/secret, field/text/tree/depth limits and exact visible-title/public-anchor gate. No second-pass content is returned. A missing title, newly secret surface, changed root/package/window, or invalid tree still refuses; the original title is never assumed to remain present. The 57 host checks validate the shared pure gate, not Android provider behavior; device runtime validation remains separate.

## Build with installed SDK/JDK only

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/android/public_review_observer/build.ps1
```

Optional parameters select already installed tools: `-Sdk`, `-Jdk`, `-BuildToolsVersion`, `-PlatformVersion`, `-DebugKeystore`. No Gradle, Maven, downloads, or third-party dependencies are used. The script runs pure Java guard tests, compiles with `javac` and the SDK `android.jar`, uses official `d8`, `aapt2`, `zipalign`, and `apksigner`, and verifies that the manifest contains no application components or permissions. Outputs are ignored under `target/qr-core/public-review-observer/`.

## Root-coordinated emulator use

Builds do not install, invoke adb, or access a device. Only the coordinating test runner should run the following, on the agreed disposable emulator, with Vault already showing the public review:

```powershell
adb -s emulator-5568 install -t target/qr-core/public-review-observer/public-review-observer-test-only.apk
adb -s emulator-5568 shell am instrument -w -r com.coldwallet.test.publicreviewobserver/com.coldwallet.test.publicreviewobserver.PublicReviewObserver
```

Parse the `public_review_json` result explicitly; absence or `REFUSED` is a failed observation. The helper starts no activity and requests no navigation. Instrumentation starts **only its own** helper process. Whether the Android build changes the active window or the Vault locks while automation connects requires runtime verification; the observer refuses that situation and must not be used to bypass it. It cannot prove visual pixels, optical QR operation, user understanding, or identity verification. Off-screen accessibility nodes are reported with their actual `visible_to_user` flag; their presence is not evidence of having been seen. Missing hints/values remain missing and must not be filled from host transaction data.

Remove only this disposable test package after use:

```powershell
adb -s emulator-5568 uninstall com.coldwallet.test.publicreviewobserver
```

## Official API references checked

- [Instrumentation.getUiAutomation(int)](https://developer.android.com/reference/android/app/Instrumentation#getUiAutomation(int)): cross-application automation; connection may return null.
- [UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES](https://developer.android.com/reference/android/app/UiAutomation#FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES): preserves existing accessibility services.
- [UiAutomation.getRootInActiveWindow()](https://developer.android.com/reference/android/app/UiAutomation#getRootInActiveWindow()): reads the active accessibility root.
- [AccessibilityNodeInfo.getHintText()](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo#getHintText()): API 26; the runtime may return no hint. The observer does not reconstruct one.

Compilation against the installed API 36 `android.jar` also checks the signatures used here.
