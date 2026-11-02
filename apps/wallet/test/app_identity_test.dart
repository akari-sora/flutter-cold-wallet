import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/main.dart';

// The store listing, the privacy policy and the launcher must name the same app.
const _name = 'FCW Watch';

class _UnavailableCore implements WalletFfiService {
  @override
  int init() => -1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('the Android launcher and iOS home screen show the store name', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(RegExp(r'android:label="([^"]*)"').firstMatch(manifest)?.group(1),
        _name);
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(
        RegExp(r'<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>')
            .firstMatch(plist)
            ?.group(1),
        _name);
  });

  testWidgets('the task switcher shows the store name', (tester) async {
    await tester
        .pumpWidget(ColdWalletWatchApp(ffiOverride: _UnavailableCore()));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, _name);
  });
}
