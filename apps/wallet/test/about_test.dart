import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/app_info.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/services/account_store.dart';

const _account = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  chainId: 11155111,
  label: '日常帳戶',
  compressedPublicKeyHex: '02public-test-key',
);

class _PublicFfi implements WalletFfiService {
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('wallet_about_'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('the About version is the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
            .firstMatch(pubspec)
            ?.group(1),
        appVersion);
  });

  Future<void> mount(
      WidgetTester tester, String path, Brightness brightness) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
        theme: brightness == Brightness.light
            ? ColdWalletTheme.light(role: FcwRole.wallet)
            : ColdWalletTheme.dark(role: FcwRole.wallet),
        home: AccountScreen(
            ffiOverride: _PublicFfi(), storagePathOverride: path)));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    for (final paired in [false, true]) {
      testWidgets(
          'the home footer says unaudited and About opens '
          '(${paired ? 'paired' : 'empty'}, ${brightness.name})',
          (tester) async {
        final path = '${directory.path}/accounts.json';
        if (paired) {
          AccountStore(path).save(const AccountSnapshot(accounts: [_account]));
        }
        await mount(tester, path, brightness);
        final notice = find.byKey(const Key('wallet_unaudited_notice'));
        await tester.ensureVisible(notice);
        await tester.pumpAndSettle();
        expect(
            find.descendant(
                of: notice, matching: find.text(fcwUnauditedNotice)),
            findsOneWidget);
        expect(tester.takeException(), isNull);

        final about = find.byKey(const Key('about_btn'));
        await tester.ensureVisible(about);
        await tester.pumpAndSettle();
        expect(tester.getSize(about).height, greaterThanOrEqualTo(48));
        await tester.tap(about);
        await tester.pumpAndSettle();
        expect(find.byType(FcwAboutPage), findsOneWidget);
        expect(find.text('FCW Watch'), findsOneWidget);
        expect(find.text('版本 ${appVersion.replaceFirst('+', '（建置 ')}）'),
            findsOneWidget);
        expect(find.text(fcwUnauditedNotice), findsOneWidget);
        expect(
            tester
                .widget<SelectableText>(
                    find.byKey(const Key('about_source_url')))
                .data,
            fcwSourceUrl);
        expect(
            find.byKey(const Key('about_privacy_policy_zh')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
