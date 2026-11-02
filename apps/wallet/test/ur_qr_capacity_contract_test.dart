import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/src/ffi/ur_decoder.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'transaction_flow_test.dart' as fixtures;

List<int> _le(int value, int bytes) =>
    List.generate(bytes, (index) => (value >> (8 * index)) & 255);
List<int> _compact(int value) => value < 253
    ? [value]
    : value <= 65535
        ? [253, ..._le(value, 2)]
        : [254, ..._le(value, 4)];

// Public serialization fixture only: no spendability, ownership or signing claim.
String _maximumPublicPsbt() {
  final tx = <int>[
    ..._le(2, 4),
    1,
    ...List.filled(32, 0x11),
    ..._le(0, 4),
    0,
    ..._le(0xfffffffd, 4),
    1,
    ..._le(1000, 8),
    22,
    0,
    20,
    ...List.filled(20, 0x22),
    ..._le(0, 4),
  ];
  List<int> encode(int metadataLength) => [
        0x70,
        0x73,
        0x62,
        0x74,
        0xff,
        1,
        0,
        ..._compact(tx.length),
        ...tx,
        1,
        0x50,
        ..._compact(metadataLength),
        ...List.filled(metadataLength, 0x55),
        0,
        0,
        0,
      ];
  const target = 131072 - 8; // Tag 310 plus the CBOR byte-string header.
  final overhead = encode(target).length - target;
  final bytes = encode(target - overhead);
  expect(bytes.length, target);
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class _FrameOnlyFfi extends fixtures.FakeFfi {
  int? fragmentLength;
  final frames = [
    'ur:eth-sign-request/1-2/publicone',
    'ur:eth-sign-request/2-2/publictwo'
  ];

  @override
  Map<String, dynamic> buildEthSignRequestUr({
    required String sessionId,
    required String requestIdHex,
    required String rawTxHex,
    required int chainId,
    required String derivationPath,
    required String masterFingerprintHex,
    required String expectedAddress,
    int maxFragmentLen = 0,
  }) {
    fragmentLength = maxFragmentLen;
    return {
      'status': 'PENDING_REGISTERED',
      'request_id': requestIdHex,
      'expected_digest': 'a' * 64,
      'ur_single': '',
      'fountain_frames': frames
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraryPath = Platform.environment['WALLET_FFI_PATH'];

  test(
      'maximum public PSBT crosses default Dart native display and copy contract',
      () {
    final ffi = WalletFfiService(DynamicLibrary.open(libraryPath!));
    final encoded = ffi.encodePsbtUr(_maximumPublicPsbt());
    expect(encoded['status'], 'SUCCESS');
    expect(encoded['ur_single'], '');
    expect((encoded['cbor_hex'] as String).length, 131072 * 2);
    final frames = List<String>.from(encoded['fountain_frames'] as List);
    expect(frames.length, 512);
    final payload =
        UrQrPayload(singleUr: encoded['ur_single'] as String, frames: frames);
    expect(payload.hasSingle, isFalse);
    expect(payload.displayFrames(), frames);
    final copied = List<String>.from(jsonDecode(payload.copyText) as List);
    expect(copied, frames);
    final decoded = NativeUrDecoder.decode('crypto-psbt', copied);
    expect(decoded['status'], 'complete');
    expect(decoded['payload_hex'], encoded['cbor_hex']);
  },
      skip: libraryPath == null
          ? 'Requires a fresh public wallet FFI build'
          : false);

  testWidgets('frame-only request selects adaptive QR and copies every frame',
      (tester) async {
    final ffi = _FrameOnlyFfi();
    String? clipboard;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
      account: fixtures.account,
      ffiOverride: ffi,
      rpcOverride: fixtures.FakeRpc(),
      historyOverride: fixtures.MemoryHistory(),
    )));
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), fixtures.address);
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001');
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.syncFromRpc();
    await state.generateUnsignedTx();
    await tester.pump();
    expect(ffi.fragmentLength, 0);
    final toggle = tester.widget<FilterChip>(
        find.byKey(const Key('sign_request_fountain_toggle')));
    expect(toggle.selected, isTrue);
    expect(toggle.onSelected, isNull);
    final copy = find.byKey(const Key('copy_sign_request_ur_btn'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();
    expect(jsonDecode(clipboard!), ffi.frames);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
