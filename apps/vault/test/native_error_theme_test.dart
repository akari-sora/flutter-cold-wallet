import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';

class _UnavailableCore implements VaultFfiService {
  @override
  int init() => -1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('native failure remains readable in the selected dark theme',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester
        .pumpWidget(ColdWalletVaultApp(ffiOverride: _UnavailableCore()));
    final title = find.text('無法啟動金庫');
    final failure = find.textContaining('原生核心初始化失敗');
    expect(title, findsOneWidget);
    expect(failure, findsOneWidget);
    final theme = Theme.of(tester.element(failure));
    expect(theme.brightness, Brightness.dark);
    expect(tester.widget<Text>(failure).style?.color,
        theme.textTheme.bodyMedium?.color);
    expect(tester.widget<Text>(title).style?.color, theme.colorScheme.error);
    expect(find.text('核准並簽署'), findsNothing);
  });
}
