import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  for (final address in [
    '0x9858effd232b4033e47d90003d41ec34ecaeda94',
    'bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu',
  ]) {
    testWidgets('public receive address QR remains available: $address',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AnimatedFountainQr(frames: [address], startPaused: true))));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
          tester
              .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
              .frames
              .single,
          address);
      expect(
          tester
              .widget<QrImageView>(find.byType(QrImageView))
              .errorCorrectionLevel,
          QrErrorCorrectLevel.M);
      expect(find.text('無可用 QR 資料'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('QR fits a narrow panel with large readable labels',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
                body: SingleChildScrollView(
                    child: SizedBox(
                        width: 220,
                        child: AnimatedFountainQr(
                          frames: ['public-frame-one', 'public-frame-two'],
                          startPaused: true,
                        )))))));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(AnimatedFountainQr)).width, 220);
  });

  testWidgets('replacing a frame sequence resets the visible frame safely',
      (tester) async {
    Widget view(List<String> frames) => MaterialApp(
        home: Scaffold(
            body: AnimatedFountainQr(
                key: const ValueKey('same-display'),
                frames: frames,
                startPaused: true)));
    await tester.pumpWidget(view(['one', 'two', 'three']));
    await tester.tap(find.byTooltip('下一幀 (步進)'));
    await tester.pump();
    await tester.tap(find.byTooltip('下一幀 (步進)'));
    await tester.pump();
    await tester.pumpWidget(view(['replacement']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused result QR stays still until user plays or steps',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AnimatedFountainQr(
      frames: ['public-frame-one', 'public-frame-two'],
      startPaused: true,
    ))));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('幀 1 / 2'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);
    await tester.tap(find.byTooltip('下一幀 (步進)'));
    await tester.pump();
    expect(find.text('幀 2 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('播放'));
    await tester.pump(const Duration(milliseconds: 170));
    expect(find.text('幀 1 / 2'), findsOneWidget);
  });

  testWidgets('other QR displays retain automatic playback by default',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AnimatedFountainQr(
      frames: ['public-frame-one', 'public-frame-two'],
    ))));
    expect(find.byTooltip('暫停'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 170));
    expect(find.text('幀 2 / 2'), findsOneWidget);
  });
}
