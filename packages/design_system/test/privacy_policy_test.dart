import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Comparable form: no maintainer comments, no indentation or blank lines.
String _normalised(String markdown) => markdown
    .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n');

void main() {
  const policies = {
    'zh-TW': fcwPrivacyPolicyZhTw,
    'en': fcwPrivacyPolicyEn,
  };

  for (final MapEntry(key: locale, value: embedded) in policies.entries) {
    test('the in-app $locale policy is the published one', () {
      final published = File('../../docs/privacy/privacy-policy.$locale.md')
          .readAsStringSync();
      expect(_normalised(embedded), _normalised(published));
    });

    test('the $locale policy names the real apps, source and contact', () {
      expect(embedded, isNot(matches(RegExp(r'<[A-Z_]+>'))));
      expect(embedded, isNot(contains('ColdWallet')));
      expect(embedded, contains('FCW Watch'));
      expect(embedded, contains('FCW Vault'));
      expect(embedded, contains('<$fcwSourceUrl>'));
      expect(embedded, contains('<$fcwSourceUrl/-/issues>'));
      expect(embedded, contains('<mailto:aa22396584@gmail.com>'));
      expect(embedded, contains('AGPL-3.0-or-later'));
    });
  }

  test('the policies state the 1.2.1 behaviour', () {
    const zh = fcwPrivacyPolicyZhTw;
    const en = fcwPrivacyPolicyEn;
    expect(zh, contains(fcwUnauditedNotice));
    expect(
        en,
        contains(
            'not been audited by a third party. Start with small amounts.'));
    // ML Kit's transport is removed from both release builds.
    expect(zh, contains('兩個 App 都沒有任何分析或遙測'));
    expect(en, contains('Neither app contains any analytics or telemetry'));
    expect(zh, isNot(contains('除了第 4 節')));
    expect(en, isNot(contains('Apart from ML Kit')));
    // Plaintext only to this phone and private networks.
    for (final range in [
      '`127.0.0.0/8`',
      '`10.0.0.0/8`',
      '`172.16.0.0/12`',
      '`192.168.0.0/16`',
      '`169.254.0.0/16`',
      '`fc00::/7`',
      '`fe80::/10`',
      '`.local`',
    ]) {
      expect(zh, contains(range));
      expect(en, contains(range));
    }
  });

  test('plaintext to a Bitcoin node exposes its descriptors (section 3.4)', () {
    expect(fcwPrivacyPolicyZhTw, contains('還包括含擴充公鑰的帳戶描述（descriptor）與節點帳號密碼'));
    expect(fcwPrivacyPolicyEn,
        contains('also the descriptors that contain your extended public key'));
  });

  test('the policies name every copy action and who can read it', () {
    // The copy buttons of both apps; each puts public data on the clipboard.
    for (final label in ['複製公開簽章 UR', '複製配對 UR', '複製地址', '複製待簽資料']) {
      expect(fcwPrivacyPolicyZhTw, contains('「$label」'));
    }
    for (final label in [
      'copy public signature UR',
      'copy pairing UR',
      'copy address',
      'copy unsigned request'
    ]) {
      expect(fcwPrivacyPolicyEn, contains('"$label"'));
    }
    expect(fcwPrivacyPolicyZhTw, contains('配對資料含擴充公鑰'));
    expect(fcwPrivacyPolicyEn,
        contains('pairing data contains extended public keys'));
  });

  Future<void> pumpAbout(WidgetTester tester, Brightness brightness) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
      theme: brightness == Brightness.light
          ? ColdWalletTheme.light(role: FcwRole.vault)
          : ColdWalletTheme.dark(role: FcwRole.vault),
      home: const FcwAboutPage(
        appName: 'FCW Vault',
        version: '1.2.1+5',
        notes: [FcwBanner(message: 'app note')],
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets(
        'About page fits 320dp at 2x text with the policy (${brightness.name})',
        (tester) async {
      await pumpAbout(tester, brightness);
      expect(find.text('FCW Vault'), findsOneWidget);
      expect(find.text('版本 1.2.1（建置 5）'), findsOneWidget);
      expect(find.text(fcwUnauditedNotice), findsOneWidget);
      expect(find.text(fcwUnauditedNoticeEn), findsOneWidget);
      expect(find.text('app note'), findsOneWidget);
      expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('about_source_url')))
              .data,
          fcwSourceUrl);
      expect(find.text(fcwLicenseNotice), findsOneWidget);

      // Rendered, not raw, Markdown; English waits behind its own toggle.
      final zh = find.byKey(const Key('about_privacy_policy_zh'));
      expect(find.descendant(of: zh, matching: find.text('FCW 隱私權政策')),
          findsOneWidget);
      expect(find.descendant(of: zh, matching: find.text('11. 聯絡方式')),
          findsOneWidget);
      expect(find.text('FCW Privacy Policy'), findsNothing);
      final rendered = tester
          .widgetList<RichText>(
              find.descendant(of: zh, matching: find.byType(RichText)))
          .map((text) => text.text.toPlainText())
          .join('\n');
      expect(rendered, contains('本專案未經第三方安全稽核，請先小額使用。'));
      expect(rendered, contains('$fcwSourceUrl/-/issues'));
      expect(rendered, isNot(contains('**')));
      expect(rendered, isNot(contains('`')));
      expect(rendered, isNot(contains('## ')));
      expect(rendered, isNot(contains('<http')));

      final toggle = find.byKey(const Key('about_privacy_policy_en_toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final en = find.byKey(const Key('about_privacy_policy_en'));
      expect(find.descendant(of: en, matching: find.text('FCW Privacy Policy')),
          findsOneWidget);
      await tester.ensureVisible(
          find.descendant(of: en, matching: find.text('11. Contact')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
