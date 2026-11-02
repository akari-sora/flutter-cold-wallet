import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/vault_home_screen.dart';

class _LockedPublicBoundary extends Fake implements VaultFfiService {
  @override
  int init() => 0;
  @override
  bool cancel([String? handleId]) => true;
  @override
  bool lock() => true;
  @override
  Map<String, dynamic> checkStorageStatus(String path) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': false,
        'master_fingerprint': '1234abcd',
      };
}

void main() {
  testWidgets('empty unlock stays usable above IME at 320dp and 2x text',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('fcw_public_ime_');
    addTearDown(() => directory.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final platformCalls = <String>[];
    const platform = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform,
        (call) async {
      platformCalls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: VaultHomeScreen(
        ffi: _LockedPublicBoundary(),
        storagePath: '${directory.path}/not-a-vault.json',
      ),
    ));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('vault_unlock_pin_field'));
    await tester.ensureVisible(field);
    await tester.showKeyboard(field);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final unlock = find.byKey(const Key('vault_unlock_submit_btn'));
    await tester.ensureVisible(unlock);
    await tester.pumpAndSettle();
    expect(unlock.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(unlock).dy, lessThanOrEqualTo(340));
    await tester.tap(unlock);
    await tester.pumpAndSettle();
    final error = find.textContaining('請輸入 PIN 碼 / 密碼');
    await tester.ensureVisible(error);
    await tester.pumpAndSettle();
    expect(error.hitTestable(), findsOneWidget);
    // Same channel method the unlock path invokes (vault_home_screen).
    expect(platformCalls, isNot(contains('authenticateWithDevice')));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.byKey(const Key('scan_sign_request_btn')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
