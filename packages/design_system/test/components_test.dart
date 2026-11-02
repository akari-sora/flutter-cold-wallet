import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _address = '0x2222222222222222222222222222222222222222';

Future<void> _pumpNarrow(WidgetTester tester, Widget child,
    {FcwRole role = FcwRole.wallet,
    Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light
        ? ColdWalletTheme.light(role: role)
        : ColdWalletTheme.dark(role: role),
    home: MediaQuery(
      data: const MediaQueryData(
          size: Size(320, 640), textScaler: TextScaler.linear(2)),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(FcwSpace.page),
          child: child,
        ),
      ),
    ),
  ));
}

void main() {
  for (final role in FcwRole.values) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'components fit 320dp at 2x text (${role.name} ${brightness.name})',
          (tester) async {
        await _pumpNarrow(
          tester,
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FcwRoleBadge(FcwRole.vault),
              FcwStatusPill('結果待查，請查詢同一筆交易', tone: FcwTone.warning),
              FcwBanner(
                  tone: FcwTone.danger,
                  title: '政策拒絕',
                  message: '未知政策衝突，無法簽署；請回到連網錢包重新建立請求。'),
              FcwPanel(child: Text('面板內容')),
              FcwAmountHero(caption: '轉帳金額', amount: '100.5 USDC'),
              FcwField(label: '收款地址', value: _address, mono: true),
              FcwField(
                  label: '網路', value: 'Ethereum Sepolia Testnet (11155111)'),
            ],
          ),
          role: role,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('FcwField exposes the full value as selectable semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpNarrow(
          tester,
          const FcwField(
              label: '收款地址',
              value: _address,
              valueKey: Key('value'),
              mono: true));
      final text =
          tester.widget<SelectableText>(find.byKey(const Key('value')));
      expect(text.data, _address);
      expect(text.semanticsLabel, _address);
      expect(text.maxLines, isNull);
      expect(find.bySemanticsLabel(_address), findsWidgets);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('status pill and banner always pair an icon with text',
      (tester) async {
    await _pumpNarrow(
        tester,
        const Column(children: [
          FcwStatusPill('已確認', tone: FcwTone.success),
          FcwBanner(tone: FcwTone.warning, message: '請勿截圖'),
        ]));
    for (final finder in [find.byType(FcwStatusPill), find.byType(FcwBanner)]) {
      expect(find.descendant(of: finder, matching: find.byType(Icon)),
          findsOneWidget);
    }
    expect(find.text('已確認'), findsOneWidget);
    expect(find.text('請勿截圖'), findsOneWidget);
  });

  testWidgets('slide fill hides behind the thumb at rest and trails a drag',
      (tester) async {
    // 2x text makes the track taller than the thumb.
    await _pumpNarrow(tester, SlideToConfirm(onConfirmed: () {}));
    final fill = find.byKey(const Key('slide_to_confirm_fill'));
    final thumb = find
        .ancestor(
            of: find.byIcon(Icons.arrow_forward_ios),
            matching: find.byType(Container))
        .first;
    expect(tester.getSize(find.byType(SlideToConfirm)).height,
        greaterThan(tester.getSize(thumb).height));
    expect(tester.getRect(fill), tester.getRect(thumb));

    final gesture = await tester.startGesture(tester.getCenter(thumb));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    final dragged = tester.getRect(thumb);
    expect(tester.getRect(fill).right, dragged.right);
    expect(tester.getRect(fill).height, dragged.height);
    expect(tester.getRect(fill).left, dragged.left - 100);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(fill), tester.getRect(thumb));
  });

  testWidgets('tiles inside a panel draw their ink on the panel',
      (tester) async {
    await _pumpNarrow(tester,
        FcwPanel(child: ListTile(title: const Text('交易紀錄'), onTap: () {})));
    // Ink and the focus highlight paint on the nearest Material; a colored
    // box between it and the tile would hide them.
    final ink = tester.widget<Material>(find
        .ancestor(of: find.byType(ListTile), matching: find.byType(Material))
        .first);
    expect(
        find.descendant(
            of: find.byType(FcwPanel), matching: find.byWidget(ink)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(FcwPanel),
            matching: find.byWidgetPredicate((widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color != null)),
        findsNothing);
  });

  testWidgets('an expanded section does not clip its first floating label',
      (tester) async {
    await _pumpNarrow(
        tester,
        FcwPanel(
          child: ExpansionTile(
            initiallyExpanded: true,
            title: const Text('節點設定'),
            children: [
              TextField(
                  controller: TextEditingController(text: 'http://127.0.0.1'),
                  decoration: const InputDecoration(labelText: 'RPC 網址')),
            ],
          ),
        ));
    final clip = find
        .descendant(
            of: find.byType(ExpansionTile), matching: find.byType(ClipRect))
        .first;
    expect(tester.getRect(find.text('RPC 網址')).top,
        greaterThanOrEqualTo(tester.getRect(clip).top));
  });

  testWidgets('a role badge in an app bar keeps the title name intact',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final (role, title) in [
        (FcwRole.vault, '離線金庫'),
        (FcwRole.wallet, 'Wallet'),
      ]) {
        await tester.pumpWidget(MaterialApp(
          theme: ColdWalletTheme.light(role: role),
          home: Scaffold(
            appBar: AppBar(
              title: Row(mainAxisSize: MainAxisSize.min, children: [
                FcwRoleBadge(role),
                const SizedBox(width: FcwSpace.md),
                Flexible(child: Text(title)),
              ]),
            ),
          ),
        ));
        expect(find.bySemanticsLabel(title), findsOneWidget);
        expect(
            find.bySemanticsLabel(role == FcwRole.vault ? '離線簽章裝置' : '連網觀察裝置'),
            findsOneWidget);
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('role badge is announced to screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpNarrow(
          tester,
          const Row(children: [
            FcwRoleBadge(FcwRole.vault),
            FcwRoleBadge(FcwRole.wallet),
          ]));
      expect(find.bySemanticsLabel('離線簽章裝置'), findsOneWidget);
      expect(find.bySemanticsLabel('連網觀察裝置'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}
