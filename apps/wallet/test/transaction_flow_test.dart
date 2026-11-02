import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'package:wallet/screens/transaction_history_screen.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_builder.dart';
import 'package:wallet/services/transaction_history.dart';

import 'app_lifecycle.dart';
import 'test_storage_directory.dart';
import 'denied_camera.dart';

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
}

const address = '0x9858effd232b4033e47d90003d41ec34ecaeda94';
final hash = '0x${'a' * 64}';
const account = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/44'/60'/0'/0/0",
    address: address,
    chainId: 11155111,
    label: '測試帳戶',
);

Map<String, dynamic> _derivationBinding(AccountDescriptor source) => {
      'derivationPath': source.derivationPath,
      'masterFingerprint': source.masterFingerprint.toLowerCase(),
      'compressedPublicKeyHex': source.compressedPublicKeyHex?.toLowerCase(),
    };

class FakeFfi implements WalletFfiService {
  int cancels = 0;
  int builds = 0;
  int verifications = 0;
  Map<String, dynamic>? lastRegistration;
  bool reject = false;
  bool rejectDecode = false;
  @override
  void cancelPendingSession(String sessionId) {
    cancels++;
  }

  @override
  Map<String, dynamic>? decodeIntentJson(
          {required String rawRlpHex, required int declaredChainId,
  }) =>
      rejectDecode
          ? null
          : {
              'chain_id': declaredChainId,
              'recipient': address,
              'raw_amount': '123',
              'fee_cap_wei': '456',
          };
  @override
  Map<String, dynamic> buildEthSignRequestUr(
      {required String sessionId,
      required String requestIdHex,
      required String rawTxHex,
      required int chainId,
      required String derivationPath,
      required String masterFingerprintHex,
      required String expectedAddress,
      int maxFragmentLen = 120,
  }) {
    builds++;
    lastRegistration = {
      'sessionId': sessionId,
      'requestId': requestIdHex,
      'unsignedPayload': rawTxHex,
      'account': expectedAddress,
      'derivationPath': derivationPath,
      'masterFingerprint': masterFingerprintHex,
      'chainId': chainId,
    };
    return {
      'status': 'PENDING_REGISTERED',
      'request_id': requestIdHex,
      'expected_digest': 'a' * 64,
      'ur_single': 'ur:eth-sign-request/test',
      'fountain_frames': ['ur:eth-sign-request/test'],
    };
  }

  @override
  Map<String, dynamic> verifyAndAssembleEthSignatureUr(
      {required String sessionId,
      required String expectedRequestIdHex,
      required String urOrFrames,
  }) {
    verifications++;
    return reject
        ? {'verified': false, 'error': 'wrong signature'}
        : {
            'verified': true,
            'status': 'SIGNED_TX_READY',
            'chain_id': 11155111,
            'request_id': expectedRequestIdHex,
            'recovered_address': address,
            'signed_raw_tx_hex': '0x1234',
            'local_tx_hash': hash,
        };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A request too large for one QR: shown only as animated fountain frames.
class _FountainFfi extends FakeFfi {
  @override
  Map<String, dynamic> buildEthSignRequestUr(
          {required String sessionId,
          required String requestIdHex,
          required String rawTxHex,
          required int chainId,
          required String derivationPath,
          required String masterFingerprintHex,
          required String expectedAddress,
          int maxFragmentLen = 120,
  }) =>
      {
        ...super.buildEthSignRequestUr(
            sessionId: sessionId,
            requestIdHex: requestIdHex,
            rawTxHex: rawTxHex,
            chainId: chainId,
            derivationPath: derivationPath,
            masterFingerprintHex: masterFingerprintHex,
            expectedAddress: expectedAddress,
            maxFragmentLen: maxFragmentLen,
    ),
        'ur_single': null,
        'fountain_frames': [
          'ur:eth-sign-request/1-2/test',
          'ur:eth-sign-request/2-2/test',
    ],
      };
}

// Holds every save until the test opens the gate.
class _GatedHistory extends MemoryHistory {
  final gate = Completer<void>();

  @override
  Future<void> save(Map<String, dynamic> record) async {
    await gate.future;
    await super.save(record);
  }
}

class MemoryHistory extends TransactionHistory {
  MemoryHistory() : super(pathOverride: testHistoryPath());
  @override
  Future<Map<String, dynamic>?> findPotentiallyExecutable({
    required String account,
    required int chainId,
  }) async {
    for (final record in records) {
      if ((record['account'] as String?)?.toLowerCase() ==
              account.toLowerCase() &&
          record['chainId'] == chainId &&
          record['state'] != 'confirmed' &&
          record['state'] != 'executionFailed') {
        return Map<String, dynamic>.from(record);
      }
    }
    return null;
  }

  @override
  Future<void> cancelPending(String requestId) async {
    for (final record in records) {
      if (record['requestId'] == requestId &&
          record['state'] == 'awaitingSignature') {
        record['state'] = 'cancelled';
      }
    }
  }

  final List<Map<String, dynamic>> records = [];
  @override
  Future<List<Map<String, dynamic>>> read() async =>
      records.map((r) => Map<String, dynamic>.from(r)).toList();
  @override
  Future<void> save(Map<String, dynamic> record) async {
    records.removeWhere((r) => r['requestId'] == record['requestId']);
    records.insert(0, Map<String, dynamic>.from(record));
  }
}

class _DelayedAdmissionHistory extends TransactionHistory {
  final ready = Completer<void>();
  final proceed = Completer<void>();
  _DelayedAdmissionHistory(String path) : super(pathOverride: path);

  @override
  Future<List<Map<String, dynamic>>> read() async {
    ready.complete();
    await proceed.future;
    return [];
  }
}

class FakeRpc extends NodeRpcClient {
  int gasEstimate = 22001;
  int sends = 0;
  int queries = 0;
  int chainChecks = 0;
  bool wrongChain = false;
  bool failSend = false;
  bool mismatchedHash = false;
  bool failPriority = false;
  Future<int>? chainResult;
  Map<String, dynamic>? receipt;
  @override
  Future<int> verifyChainId(int expectedChainId) async {
    chainChecks++;
    if (wrongChain) throw StateError('chain mismatch');
    if (chainResult != null) return chainResult!;
    return expectedChainId;
  }

  @override
  Future<String> sendRawTransaction(String signedTxHex,
      {int? expectedChainId, bool Function()? canDispatch,
  }) async {
    sends++;
    if (failSend) throw Exception('connection lost');
    return mismatchedHash ? '0x${'b' * 64}' : hash;
  }

  @override
  Future<Map<String, dynamic>?> getTransactionReceipt(String txHash) async {
    queries++;
    return receipt;
  }

  @override
  Future<Map<String, dynamic>?> getTransactionByHash(String txHash) async =>
      null;
  @override
  Future<int> getTransactionCount(String address) async => 7;
  @override
  Future<BigInt> getGasPrice() async => BigInt.from(1234567891);
  @override
  Future<BigInt> getMaxPriorityFeePerGas() async {
    if (failPriority) throw Exception('unsupported');
    return BigInt.one;
  }

  @override
  Future<int> estimateGas(
          {required String from,
          required String to,
          BigInt? valueWei,
          String? dataHex,
  }) async =>
      gasEstimate;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/event'),
        (_) async => null,
    );
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'),
        (call) async {
      if (call.method == 'state') return 1;
      if (call.method == 'start') {
        return {
          'textureId': 1,
          'numberOfCameras': 1,
          'size': {'width': 640.0, 'height': 480.0},
          };
      }
      return null;
    },
    );
  });
  testWidgets('recovery panel shows the vault fingerprint in uppercase',
      (tester,
  ) async {
    final rpc = FakeRpc();
    final requestId = '12' * 16;
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: account.copyWith(masterFingerprint: 'deadbeef'),
            ffiOverride: FakeFfi(),
            rpcOverride: rpc,
            historyOverride: MemoryHistory(),
            requestId: requestId,
            sessionId: 'original-session',
            unsignedRlpHex: '12',
            restoredRecord: {
          'requestId': requestId,
          'sessionId': 'original-session',
          'account': address,
        ..._derivationBinding(account.copyWith(masterFingerprint: 'deadbeef'),
            ),
          'chainId': 11155111,
          'rpcUrl': rpc.rpcUrl,
          'unsignedPayload': '12',
          'state': 'awaitingSignature',
        },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('金庫指紋：DEADBEEF'), findsOneWidget);
    expect(find.textContaining('deadbeef'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('denied camera on the signature scan opens the app settings',
      (tester,
  ) async {
    mockDeniedCamera(tester);
    final platformCalls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call,
    ) async {
      platformCalls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null,
      ),
    );
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: account,
            ffiOverride: FakeFfi(),
            rpcOverride: FakeRpc(),
            historyOverride: MemoryHistory(),
            requestId: '12' * 16,
            sessionId: 'original-session',
            unsignedRlpHex: '12',
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Leaving for the settings revokes this scan; the scanner is gone on return.
    expect(find.textContaining('返回後即可掃描'), findsNothing);
    expect(find.textContaining('由本機交易紀錄核對並接收原請求的既有簽章'), findsOneWidget);
    expect(find.textContaining('不需重新簽署'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scanner_open_app_settings_btn')));
    await tester.pump();
    expect(platformCalls, ['openAppSettings']);
    await tester.pumpWidget(const SizedBox());
  });
  for (final entry in ['send screen', 'history']) {
    testWidgets(
        'a camera permission dialog does not revoke the EVM scan from the $entry',
        (tester) async {
      final dialog = mockCameraPermissionDialog(tester);
      final ffi = FakeFfi();
      final rpc = FakeRpc();
      final requestId = '12' * 16;
      await tester.pumpWidget(MaterialApp(
          home: ScanSignatureScreen(
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: MemoryHistory(),
              requestId: requestId,
              sessionId: 'original-session',
              unsignedRlpHex: '12',
              restoredRecord: entry == 'history'
                  ? {
                      'requestId': requestId,
                      'sessionId': 'original-session',
                      'account': address,
        ..._derivationBinding(account),
                      'chainId': 11155111,
                      'rpcUrl': rpc.rpcUrl,
                      'unsignedPayload': '12',
                      'state': 'cancelled',
                    }
                  : null,
            ),
          ),
        );
      await tester.pumpAndSettle();
      if (entry == 'history') {
        await _tapVisible(
            tester, find.byKey(const Key('confirm_existing_signature_btn')),
          );
        await tester.pumpAndSettle();
      }
      expect(find.byType(AirGapScanner), findsOneWidget);
      final cancels = ffi.cancels;

      // The scanner's permission request, even one Android denies by itself,
      // puts a system activity over the app while it is pending: inactive,
      // then resumed once answered.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive,
        );
      await tester.pump();
      dialog.complete(false);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed,
        );
      await tester.pumpAndSettle();
      expect(ffi.cancels, cancels, reason: 'The receive authorization stays');
      expect(find.byType(AirGapScanner), findsOneWidget);
      expect(find.textContaining('接收授權已撤銷'), findsNothing);
      expect(find.textContaining('由本機交易紀錄核對並接收原請求的既有簽章'), findsOneWidget);

      // Losing focus with no permission request pending still revokes it.
      loseAndRegainFocus(tester);
      await tester.pumpAndSettle();
      expect(ffi.cancels, greaterThan(cancels));
      expect(find.byType(AirGapScanner), findsNothing);
      expect(find.textContaining('接收授權已撤銷'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    );
  }
  Widget freshScan(FakeFfi ffi) => MaterialApp(
      home: ScanSignatureScreen(
          account: account,
          ffiOverride: ffi,
          rpcOverride: FakeRpc(),
          historyOverride: MemoryHistory(),
          requestId: '12' * 16,
          sessionId: 'original-session',
          unsignedRlpHex: '12',
    ),
  );
  testWidgets('a slow camera start without a permission request still revokes',
      (tester) async {
    final started = mockSlowGrantedCamera(tester);
    final ffi = FakeFfi();
    await tester.pumpWidget(freshScan(ffi));
    await tester.pump();
    expect(find.byType(AirGapScanner), findsOneWidget);
    final cancels = ffi.cancels;
    // The camera was granted earlier, so no system dialog is open: this is
    // e.g. the notification shade.
    loseAndRegainFocus(tester);
    await tester.pump();
    expect(ffi.cancels, greaterThan(cancels));
    expect(find.byType(AirGapScanner), findsNothing);
    expect(find.textContaining('接收授權已撤銷'), findsOneWidget);
    started.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  },
  );
  testWidgets('a focus loss after the permission is answered still revokes',
      (tester,
  ) async {
    final (dialog, started) = mockCameraPermissionThenSlowStart(tester);
    final ffi = FakeFfi();
    await tester.pumpWidget(freshScan(ffi));
    await tester.pump();
    expect(find.byType(AirGapScanner), findsOneWidget);
    final cancels = ffi.cancels;
    // The dialog is allowed and closes; the camera is still starting.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    dialog.complete(true);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(ffi.cancels, cancels, reason: 'The dialog itself does not revoke');
    expect(find.byType(AirGapScanner), findsOneWidget);
    // e.g. the notification shade while the camera starts.
    loseAndRegainFocus(tester);
    await tester.pump();
    expect(ffi.cancels, greaterThan(cancels));
    expect(find.byType(AirGapScanner), findsNothing);
    expect(find.textContaining('接收授權已撤銷'), findsOneWidget);
    started.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('a scan waiting behind another scanner still revokes on focus loss',
      (tester) async {
    final dialog = mockCameraPermissionDialog(tester);
    // Another scanner's start is still waiting for its permission dialog.
    await tester.pumpWidget(MaterialApp(
        home: AirGapScanner(
            expectedType: 'crypto-psbt', onPayloadComplete: (_) {},
          ),
        ),
      );
    await tester.pump();
    final ffi = FakeFfi();
    await tester.pumpWidget(freshScan(ffi));
    await tester.pump();
    expect(find.byType(AirGapScanner), findsOneWidget);
    final cancels = ffi.cancels;
    loseAndRegainFocus(tester);
    await tester.pump();
    expect(ffi.cancels, greaterThan(cancels));
    expect(find.textContaining('接收授權已撤銷'), findsOneWidget);
    dialog.complete(false);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  },
  );
  testWidgets(
      'the EVM denied-camera hint is wholly readable above the panel at 200% text',
      (tester) async {
    mockDeniedCamera(tester);
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: account,
            ffiOverride: FakeFfi(),
            rpcOverride: FakeRpc(),
            historyOverride: MemoryHistory(),
            requestId: '12' * 16,
            sessionId: 'original-session',
            unsignedRlpHex: '12',
          ),
        ),
      );
    await tester.pumpAndSettle();
    final hint = find.textContaining('由本機交易紀錄核對並接收原請求的既有簽章');
    expect(hint, findsOneWidget);
    // Either on screen or scrollable into view, never under the panel.
    final scroll = find.ancestor(of: hint, matching: find.byType(Scrollable));
    expect(scroll, findsOneWidget);
    final viewport = tester.getRect(scroll);
    expect(viewport.top,
        greaterThanOrEqualTo(tester.getRect(find.text('掃描簽署結果')).bottom),
      );
    expect(
        viewport.bottom,
        lessThanOrEqualTo(tester
            .getRect(find.byKey(const Key('scanner_status_panel')))
            .top,
        ),
      );
    final position = tester.state<ScrollableState>(scroll).position;
    expect(tester.getRect(hint).top, greaterThanOrEqualTo(viewport.top));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(tester.getRect(hint).bottom, lessThanOrEqualTo(viewport.bottom));
    expect(find.byKey(const Key('scanner_open_app_settings_btn')).hitTestable(),
        findsOneWidget,
      );
    await tester.pumpWidget(const SizedBox());
  },
  );
  for (final savedState in ['awaitingSignature', 'cancelled']) {
    testWidgets(
        '$savedState original request needs explicit recovery confirmation before native registration',
        (tester) async {
      final ffi = FakeFfi();
      final rpc = FakeRpc();
      final history = MemoryHistory();
      final requestId = '12' * 16;
      final record = <String, dynamic>{
        'requestId': requestId,
        'sessionId': 'original-session',
        'account': address,
        ..._derivationBinding(account),
        'chainId': 11155111,
        'rpcUrl': rpc.rpcUrl,
        'unsignedPayload': '12',
        'state': savedState,
      };
      final key = GlobalKey<ScanSignatureScreenState>();
      await tester.pumpWidget(MaterialApp(
          home: ScanSignatureScreen(
              key: key,
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history,
              requestId: requestId,
              sessionId: 'original-session',
              unsignedRlpHex: '12',
              restoredRecord: record,
            ),
          ),
        );
      await tester.pumpAndSettle();
      expect(ffi.builds, 0,
          reason: 'Opening a cancelled/unsigned record is not confirmation',
        );
      expect(find.byKey(const Key('confirm_existing_signature_btn')),
          findsOneWidget,
        );
      await key.currentState!.ingestSignatureUr('existing-signature');
      expect(ffi.verifications, 0);
      await _tapVisible(
          tester, find.byKey(const Key('confirm_existing_signature_btn')),
        );
      await tester.pumpAndSettle();
      expect(ffi.builds, 1);
      expect(ffi.lastRegistration, {
        'sessionId': 'original-session',
        'requestId': requestId,
        'unsignedPayload': '12',
        'account': address,
        'derivationPath': account.derivationPath,
        'masterFingerprint': account.masterFingerprint,
        'chainId': 11155111,
      });
      expect(rpc.chainChecks, 1);
      expect(rpc.sends, 0);
      await tester.runAsync(
          () => key.currentState!.ingestSignatureUr('existing-signature'),
        );
      await tester.pump();
      expect(history.records.single['requestId'], requestId);
      expect(history.records.single['unsignedPayload'], '12');
      expect(history.records.single['state'], 'verified');
      expect(rpc.sends, 0,
          reason: 'Receiving an existing signature never broadcasts',
        );
      await tester.pumpWidget(const SizedBox());
    },
    );
  }
  Map<String, dynamic> pendingRecord(FakeRpc rpc) => {
        'requestId': '12' * 16,
        'sessionId': 'original-session',
        'account': address,
        ..._derivationBinding(account),
        'chainId': 11155111,
        'rpcUrl': rpc.rpcUrl,
        'unsignedPayload': '12',
        'state': 'cancelled',
      };

  Widget recoveryScreen({
    required WalletFfiService ffi,
    required FakeRpc rpc,
    required Map<String, dynamic> record,
    GlobalKey<ScanSignatureScreenState>? key,
    MemoryHistory? history,
    AccountDescriptor selectedAccount = account,
  }) =>
      MaterialApp(
          home: ScanSignatureScreen(
              key: key,
              account: selectedAccount,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history ?? MemoryHistory(),
              requestId: record['requestId'] as String,
              sessionId: record['sessionId'] as String,
              unsignedRlpHex: record['unsignedPayload'] as String,
              restoredRecord: record,
    ),
  );

  for (final shape in ['missing path', 'missing fingerprint', 'path',
    'fingerprint', 'public key', 'selected path', 'selected fingerprint',
  ]) {
    testWidgets('restored original request refuses unproven derivation $shape',
        (tester) async {
      final ffi = FakeFfi();
      final rpc = FakeRpc();
      final history = MemoryHistory();
      final record = pendingRecord(rpc);
      var selected = account;
      switch (shape) {
        case 'missing path':
          record.remove('derivationPath');
        case 'missing fingerprint':
          record.remove('masterFingerprint');
        case 'path':
          record['derivationPath'] = "m/44'/60'/0'/0/1";
        case 'fingerprint':
          record['masterFingerprint'] = 'deadbeef';
        case 'public key':
          record['compressedPublicKeyHex'] = '02${'a' * 64}';
        case 'selected path':
          selected = account.copyWith(derivationPath: "m/44'/60'/0'/0/1");
        case 'selected fingerprint':
          selected = account.copyWith(masterFingerprint: 'deadbeef');
      }
      history.records.add(Map<String, dynamic>.from(record));
      final before = jsonEncode(history.records);
      await tester.pumpWidget(recoveryScreen(
          ffi: ffi, rpc: rpc, record: record, history: history,
          selectedAccount: selected,
          ),
        );
      await tester.pumpAndSettle();
      expect(find.textContaining('派生身分'), findsOneWidget);
      expect(find.byKey(const Key('confirm_original_request_qr_btn')), findsNothing,
        );
      expect(find.byKey(const Key('confirm_existing_signature_btn')), findsNothing,
        );
      expect(ffi.builds, 0);
      expect(ffi.verifications, 0);
      expect(rpc.chainChecks, 0);
      expect(rpc.sends, 0);
      expect(jsonEncode(history.records), before,
          reason: 'An unresolved legacy or conflicting record stays intact',
        );
      await tester.pumpWidget(const SizedBox());
    },
    );
  }

  testWidgets(
      'recovery confirmation becomes tappable again after returning to the foreground',
      (tester) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final key = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(recoveryScreen(
        ffi: ffi, rpc: rpc, record: pendingRecord(rpc), key: key,
        ),
      );
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('confirm_existing_signature_btn')),
            )
            .onPressed,
        isNotNull,
      );

    key.currentState!.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(find.textContaining('已離開前景，接收授權已撤銷'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('confirm_existing_signature_btn')),
            )
            .onPressed,
        isNull,
      );
    expect(ffi.builds, 0);

    key.currentState!.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('confirm_existing_signature_btn')),
            )
            .onPressed,
        isNotNull,
      );
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
      );
    await tester.pumpAndSettle();
    expect(ffi.builds, 1);
    await tester.pumpWidget(const SizedBox());
  },
  );

  testWidgets(
      'history opens unsigned and cancelled records without registering',
      (tester) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final history = MemoryHistory();
    for (final state in ['awaitingSignature', 'cancelled']) {
      history.records.clear();
      history.records.add({...pendingRecord(rpc), 'state': state});
      await tester.pumpWidget(MaterialApp(
          key: ValueKey(state),
          home: TransactionHistoryScreen(
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history,
            ),
          ),
        );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm_existing_signature_btn')),
          findsOneWidget,
        );
      expect(ffi.builds, 0);
      expect(rpc.sends, 0);
    }
    await tester.pumpWidget(const SizedBox());
  },
  );

  testWidgets(
      'unsigned public backup needs confirmation and binds verified current RPC',
      (tester) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final history = MemoryHistory();
    final key = GlobalKey<ScanSignatureScreenState>();
    final record = {...pendingRecord(rpc), 'state': 'unknown', 'rpcUrl': ''};
    await tester.pumpWidget(recoveryScreen(
        ffi: ffi, rpc: rpc, record: record, key: key, history: history,
        ),
      );
    await tester.pumpAndSettle();
    expect(ffi.builds, 0);
    expect(find.byKey(const Key('confirm_existing_signature_btn')),
        findsOneWidget,
      );
    expect(find.textContaining('原始 RPC 未備份'), findsOneWidget);
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
      );
    await tester.pumpAndSettle();
    expect(rpc.chainChecks, 1);
    expect(ffi.lastRegistration!['requestId'], record['requestId']);
    await key.currentState!.ingestSignatureUr('existing-response');
    await tester.pump();
    expect(history.records.single['rpcUrl'], rpc.rpcUrl);
    expect(
        history.records.single['unsignedPayload'], record['unsignedPayload'],
      );
    expect(history.records.single['state'], 'verified');
    expect(rpc.sends, 0);
    await tester.pumpWidget(const SizedBox());
  },
  );

  testWidgets(
      'changed account chain RPC or corrupt original record fails closed',
      (tester) async {
    final rpc = FakeRpc();
    for (final mutation in <Map<String, dynamic>>[
      {'account': '0x${'f' * 40}'},
      {'chainId': 31337},
      {'rpcUrl': 'https://different.invalid'},
      {'rpcUrl': ''},
      {'state': 'unknown'},
      {'signedRaw': '0x1234'},
      {'hash': hash},
      {'requestId': 'not-an-original-uuid'},
    ]) {
      final ffi = FakeFfi();
      await tester.pumpWidget(recoveryScreen(
          ffi: ffi, rpc: rpc, record: {...pendingRecord(rpc), ...mutation},
          ),
        );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm_existing_signature_btn')),
          findsNothing,
        );
      expect(find.byKey(const Key('signature_verification_error_text')),
          findsOneWidget,
        );
      expect(ffi.builds, 0);
      expect(rpc.sends, 0);
      await tester.pumpWidget(const SizedBox());
    }
    final ffi = FakeFfi()..rejectDecode = true;
    await tester.pumpWidget(
        recoveryScreen(ffi: ffi, rpc: rpc, record: pendingRecord(rpc)),
      );
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('confirm_existing_signature_btn')), findsNothing,
      );
    expect(ffi.builds, 0);
    await tester.pumpWidget(const SizedBox());
  },
  );

  testWidgets('wrong existing response never becomes verified or broadcasts',
      (tester,
  ) async {
    final ffi = FakeFfi()..reject = true;
    final rpc = FakeRpc();
    final history = MemoryHistory();
    final key = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(recoveryScreen(
        ffi: ffi,
        rpc: rpc,
        record: pendingRecord(rpc),
        key: key,
        history: history,
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
    );
    await tester.pumpAndSettle();
    await key.currentState!.ingestSignatureUr('wrong-existing-response');
    await tester.pump();
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    expect(history.records, isEmpty);
    expect(rpc.sends, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background revokes receive and requires explicit reconfirmation',
      (tester) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final key = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(recoveryScreen(
        ffi: ffi, rpc: rpc, record: pendingRecord(rpc), key: key,
        ),
      );
    await tester.pumpAndSettle();
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
      );
    await tester.pumpAndSettle();
    expect(ffi.builds, 1);
    leaveApp(tester);
    returnToApp(tester);
    await tester.pumpAndSettle();
    await key.currentState!.ingestSignatureUr('response-after-background');
    expect(ffi.verifications, 0);
    expect(find.byKey(const Key('rescan_signature_btn')), findsNothing);
    expect(find.byKey(const Key('confirm_existing_signature_btn')),
        findsOneWidget,
      );
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
      );
    await tester.pumpAndSettle();
    expect(ffi.builds, 2);
    expect(ffi.lastRegistration!['requestId'], '12' * 16);
    expect(rpc.sends, 0);
    await tester.pumpWidget(const SizedBox());
  },
  );

  for (final abandon in ['background', 'dispose', 'changeAccount']) {
    testWidgets('RPC continuation cannot register after $abandon',
        (tester,
    ) async {
      final ffi = FakeFfi();
      final rpc = FakeRpc();
      final gate = Completer<int>();
      rpc.chainResult = gate.future;
      final record = pendingRecord(rpc);
      final key = GlobalKey<ScanSignatureScreenState>();
      await tester.pumpWidget(
          recoveryScreen(ffi: ffi, rpc: rpc, record: record, key: key),
      );
      await tester.pumpAndSettle();
      await _tapVisible(
          tester, find.byKey(const Key('confirm_existing_signature_btn')),
      );
      await tester.pump();
      expect(ffi.builds, 0);
      if (abandon == 'background') {
        leaveApp(tester);
        returnToApp(tester);
      } else if (abandon == 'changeAccount') {
        await tester.pumpWidget(recoveryScreen(
            ffi: ffi,
            rpc: rpc,
            record: record,
            key: key,
            selectedAccount: account.copyWith(address: '0x${'f' * 40}'),
          ),
        );
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      gate.complete(11155111);
      await tester.pumpAndSettle();
      expect(ffi.builds, 0);
      expect(rpc.sends, 0);
      if (abandon == 'background') {
        rpc.chainResult = null;
        await _tapVisible(
            tester, find.byKey(const Key('confirm_existing_signature_btn')),
        );
        await tester.pumpAndSettle();
        expect(ffi.builds, 1);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('wrong RPC chain cannot authorize original request recovery',
      (tester,
  ) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc()..wrongChain = true;
    await tester.pumpWidget(
        recoveryScreen(ffi: ffi, rpc: rpc, record: pendingRecord(rpc)),
    );
    await tester.pumpAndSettle();
    await _tapVisible(
        tester, find.byKey(const Key('confirm_existing_signature_btn')),
    );
    await tester.pumpAndSettle();
    expect(ffi.builds, 0);
    expect(find.byKey(const Key('signature_verification_error_text')),
        findsOneWidget,
    );
    expect(rpc.sends, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final interruption in ['background', 'saved-before-display']) {
    testWidgets(
      'an unsigned request survives $interruption with the same QR binding',
      (tester) async {
        final ffi = FakeFfi();
        final rpc = FakeRpc();
        final history = interruption == 'saved-before-display'
            ? _GatedHistory()
            : MemoryHistory();
        await tester.pumpWidget(
          MaterialApp(
            home: SendTxScreen(
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history,
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const Key('tx_recipient_field')),
          address,
        );
        await tester.enterText(
          find.byKey(const Key('tx_amount_field')),
          '0.000001',
        );
        final state = tester.state<SendTxScreenState>(
          find.byType(SendTxScreen),
        );
        await state.syncFromRpc();
        final build = state.generateUnsignedTx();
        await tester.pump();
        if (interruption == 'saved-before-display') {
          expect(find.byType(AnimatedFountainQr), findsNothing);
          await tester.pumpWidget(const SizedBox());
          (history as _GatedHistory).gate.complete();
        } else {
          await build;
          leaveApp(tester);
          returnToApp(tester);
          await tester.pump();
          expect(find.byType(AnimatedFountainQr), findsNothing);
          await tester.pumpWidget(const SizedBox());
        }
        await build;
        final original = Map<String, dynamic>.from(history.records.single);
        expect(original['state'], 'awaitingSignature');
        final originalBinding = Map<String, dynamic>.from(
          ffi.lastRegistration!,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: TransactionHistoryScreen(
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tapVisible(tester, find.byType(ListTile));
        await tester.pumpAndSettle();
        expect(find.byType(AnimatedFountainQr), findsNothing);
        expect(
          ffi.builds,
          1,
          reason: 'Opening history must not authorize a QR',
        );
        await _tapVisible(
          tester,
          find.byKey(const Key('confirm_original_request_qr_btn')),
        );
        await tester.pump();
        expect(find.byKey(const Key('original_request_qr')), findsOneWidget);
        expect(ffi.builds, 2);
        expect(
          ffi.lastRegistration,
          originalBinding,
          reason: 'Recovery must preserve nonce, bytes, account, chain and IDs',
        );
        expect(
          history.records.single,
          original,
          reason: 'Showing the same request must not create another payment',
        );
        expect(rpc.sends, 0);
        await _tapVisible(
          tester,
          find.byKey(const Key('scan_original_request_signature_btn')),
        );
        await tester.pumpAndSettle();
        final recovery = tester.state<ScanSignatureScreenState>(
          find.byType(ScanSignatureScreen),
        );
        await tester.runAsync(
          () => recovery.ingestSignatureUr('original-response'),
        );
        await tester.pump();
        expect(history.records.single['requestId'], original['requestId']);
        expect(
          history.records.single['unsignedPayload'],
          original['unsignedPayload'],
        );
        expect(history.records.single['state'], 'verified');
        expect(rpc.sends, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final change in ['none', 'original QR', 'amount', 'requestId', 'account',
  ]) {
    testWidgets(
        'production native recovery checks existing response against $change',
        (tester) async {
      final fixture = jsonDecode(
          File('test/fixtures/existing_signature_public.json',
                  )
              .readAsStringSync(),
                ) as Map<String, dynamic>;
      var selected = AccountDescriptor.fromJson(
          Map<String, dynamic>.from(fixture['account'] as Map),
        );
      final ffi = WalletFfiService();
      expect(ffi.init(), 0);
      final rpc = FakeRpc();
      var raw = fixture['unsignedPayload'] as String;
      if (change == 'amount') {
        raw = TransactionBuilder.buildLegacyUnsignedRlp(
            nonce: 1,
            gasPriceWei: BigInt.from(2000000000),
            gasLimit: 21000,
            toAddress: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
            valueWei: BigInt.from(123456789012346),
            calldata: Uint8List(0),
            chainId: 11155111,
          );
      }
      if (change == 'account') selected = selected.copyWith(address: address);
      final record = <String, dynamic>{
        'requestId': change == 'requestId' ? '7b' * 16 : fixture['requestId'],
        'sessionId': fixture['sessionId'],
        'account': selected.address.toLowerCase(),
        ..._derivationBinding(selected),
        'chainId': 11155111,
        'rpcUrl': rpc.rpcUrl,
        'unsignedPayload': raw,
        'state': 'cancelled',
      };
      ffi.cancelPendingSession(record['sessionId'] as String);
      final history = MemoryHistory();
      final key = GlobalKey<ScanSignatureScreenState>();
      await tester.pumpWidget(recoveryScreen(
          ffi: ffi,
          rpc: rpc,
          record: record,
          key: key,
          selectedAccount: selected,
          history: history,
          ),
        );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm_existing_signature_btn')),
          findsOneWidget,
        );
      expect(find.byKey(const Key('verified_intent_text')), findsOneWidget);
      await _tapVisible(
          tester,
          find.byKey(Key(change == 'original QR'
              ? 'confirm_original_request_qr_btn'
              : 'confirm_existing_signature_btn',
            ),
          ),
        );
      await tester.pumpAndSettle();
      if (change == 'original QR') {
        expect(find.byKey(const Key('original_request_qr')), findsOneWidget);
        expect(history.records, isEmpty);
        await _tapVisible(tester,
            find.byKey(const Key('scan_original_request_signature_btn')),
          );
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() => key.currentState!
          .ingestSignatureUr(fixture['signatureUr'] as String,
          ),
        );
      await tester.pump();
      expect(rpc.sends, 0);
      if (change == 'none' || change == 'original QR') {
        expect(history.records.single['requestId'], fixture['requestId']);
        expect(history.records.single['signedRaw'], fixture['signedRaw']);
        expect(history.records.single['hash'], fixture['hash']);
        expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget,
          );
      } else {
        expect(history.records, isEmpty);
        expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
        expect(find.byKey(const Key('signature_verification_error_text')),
            findsOneWidget,
          );
      }
      await tester.pumpWidget(const SizedBox());
    },
    );
  }
  test(
      'signed public transaction survives a new storage instance and corruption errors',
      () async {
    final dir = Directory.systemTemp.createTempSync('wallet_tx_disk_');
    try {
      final path = '${dir.path}/history.json';
      await TransactionHistory(pathOverride: path)
          .save({'requestId': '11' * 16,
          'sessionId': 'session',
          'account': address,
          'chainId': 11155111,
          'unsignedPayload': '12',
          'signatureUr': 'signature', 'signedRaw': '0x1234',
          'hash': hash,
          'state': 'unknown',
        });
      expect(
          (await TransactionHistory(pathOverride: path).read())
              .single['signedRaw'],
          '0x1234',
        );
      File(path).writeAsStringSync('{broken');
      await expectLater(
          TransactionHistory(pathOverride: path).read(), throwsFormatException,
        );
    } finally {
      dir.deleteSync(recursive: true);
    }
  },
  );
  test(
      'concurrent history mutations preserve records and cancellation never erases verified bytes',
      () async {
    final dir = Directory.systemTemp.createTempSync('wallet_tx_concurrent_');
    try {
      final path = '${dir.path}/history.json';
      final first = TransactionHistory(pathOverride: path);
      final second = TransactionHistory(pathOverride: path);
      await Future.wait([
        first.save({'requestId': '11' * 16,
            'sessionId': 'awaiting',
            'account': address,
            'chainId': 11155111,
            'unsignedPayload': '12', 'state': 'awaitingSignature',
          }),
        second.save({
          'requestId': '22' * 16,
            'sessionId': 'signed',
            'account': address,
            'chainId': 11155111,
            'unsignedPayload': '12',
          'state': 'verified',
            'signatureUr': 'signature',
            'signedRaw': '0x1234',
            'hash': hash,
          }),
      ]);
      await Future.wait(
          [first.cancelPending('11' * 16), second.cancelPending('22' * 16),
        ]);
      final records = await first.read();
      expect(records.length, 2);
      expect(records.singleWhere((r) => r['requestId'] == '11' * 16)['state'],
          'cancelled',
        );
      expect(
          records.singleWhere((r) => r['requestId'] == '22' * 16)['signedRaw'],
          '0x1234',
        );
      expect(records.singleWhere((r) => r['requestId'] == '22' * 16)['state'],
          'verified',
        );
      Directory('$path.tmp').createSync();
      await expectLater(first.save({'requestId': '33' * 16,
            'sessionId': 'lost',
            'account': address,
            'chainId': 11155111,
            'unsignedPayload': '12', 'state': 'unknown',
          }),
          throwsA(isA<FileSystemException>()),
        );
      expect((await second.read()).length, 2);
    } finally {
      dir.deleteSync(recursive: true);
    }
  },
  );
  test(
    'unfinished public import blocks EVM admission even if corrupt',
    () async {
      final dir = Directory.systemTemp.createTempSync('wallet_tx_import_');
      try {
        final history = TransactionHistory(
          pathOverride: '${dir.path}/history.json',
        );
        final progress = File('${dir.path}/public_import_progress.json')
          ..writeAsStringSync('{');
        await expectLater(
          history.findPotentiallyExecutable(
            account: address,
            chainId: 11155111,
          ),
          throwsStateError,
        );
        await expectLater(
          history.requireRecoveryAllowed(account: address, chainId: 11155111),
          throwsStateError,
        );
        expect(progress.readAsStringSync(), '{');
        progress.deleteSync();
        expect(
          await history.findPotentiallyExecutable(
            account: address,
            chainId: 11155111,
          ),
          isNull,
        );
        await history.requireRecoveryAllowed(
          account: address,
          chainId: 11155111,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'public import starting during history read blocks EVM admission',
    () async {
      final dir = Directory.systemTemp.createTempSync('wallet_tx_import_race_');
      try {
        final history = _DelayedAdmissionHistory('${dir.path}/history.json');
        final admission = history.findPotentiallyExecutable(
          account: address,
          chainId: 11155111,
        );
        await history.ready.future;
        File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
        history.proceed.complete();
        await expectLater(admission, throwsStateError);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'unknown history identities cannot be skipped during admission',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'wallet_tx_bad_identity_',
      );
      try {
        final path = '${dir.path}/history.json';
        final history = TransactionHistory(pathOverride: path);
        for (final row in [
          '{"chainId":31337}',
          '{"account":"not-an-address","chainId":31337}',
          '{"account":"$address"}',
          '{"account":"$address","chainId":0}',
          '{"account":"$address","chainId":"31337"}',
        ]) {
          final source = '{"version":1,"transactions":[$row]}';
          File(path).writeAsStringSync(source);
          await expectLater(history.read(), throwsFormatException);
          await expectLater(
            history.findPotentiallyExecutable(
              account: address,
              chainId: 11155111,
            ),
            throwsFormatException,
          );
          expect(File(path).readAsStringSync(), source);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'merge preserves an existing codec-invalid history byte for byte',
    () async {
      final dir = Directory.systemTemp.createTempSync('wallet_tx_bad_merge_');
      try {
        final file = File('${dir.path}/history.json');
        const source =
            '{"version":1,"transactions":['
            '{"account":"$address","chainId":11155111,"requestId":"invalid"}]}';
        file.writeAsStringSync(source);
        final history = TransactionHistory(pathOverride: file.path);
        await expectLater(
          history.mergeRestoredRecords([
            {
              'requestId': '11' * 16,
              'account': address,
              'chainId': 11155111,
              'unsignedPayload': '12',
            },
          ]),
          throwsFormatException,
        );
        expect(file.readAsStringSync(), source);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test('new codec-invalid row is never written to history', () async {
    final dir = Directory.systemTemp.createTempSync('wallet_tx_bad_new_');
    try {
      final file = File('${dir.path}/history.json');
      final history = TransactionHistory(pathOverride: file.path);
      final valid = <String, dynamic>{
        'requestId': '55' * 16,
        'sessionId': 'session',
        'account': address,
        'chainId': 11155111,
        'unsignedPayload': '12',
        'state': 'awaitingSignature',
        'rpcUrl': 'http://localhost:8545',
      };
      await expectLater(
        history.save({...valid, 'requestId': 'bad'}),
        throwsFormatException,
      );
      expect(file.existsSync(), false);
      await history.save(valid);
      final before = file.readAsBytesSync();
      await expectLater(
        history.save({...valid, 'requestId': 'bad'}),
        throwsFormatException,
      );
      expect(file.readAsBytesSync(), before);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
  test(
    'terminal rows without a complete signature block admission without writes',
    () async {
      final dir = Directory.systemTemp.createTempSync('terminal_admission_');
      try {
        final file = File('${dir.path}/public_transactions.json');
        final history = TransactionHistory(pathOverride: file.path);
        for (final state in ['confirmed', 'executionFailed']) {
          for (final extra in <Map<String, dynamic>>[
            {},
            {'signatureUr': 'sig', 'signedRaw': '0x12'},
          ]) {
            final row = {
              'requestId': '11' * 16,
              'sessionId': 'test',
              'account': address,
              'chainId': 11155111,
              'unsignedPayload': '12',
              'state': state,
              ...extra,
            };
            file.writeAsStringSync(
              jsonEncode({
                'version': 1,
                'transactions': [row],
              }),
            );
            final before = file.readAsBytesSync();
            await expectLater(
              history.findPotentiallyExecutable(
                account: address,
                chainId: 11155111,
              ),
              throwsFormatException,
            );
            expect(file.readAsBytesSync(), before);
          }
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test('same-account unsettled EVM history blocks a new independent payment',
      () async {
    final dir = Directory.systemTemp.createTempSync('wallet_tx_admission_');
    try {
      final history = TransactionHistory(
          pathOverride: '${dir.path}/public_transactions.json',
        );
        var index = 0;
      for (final state in [
        'awaitingSignature',
        'cancelled',
        'verified',
        'broadcasting',
        'unknown',
      ]) {
        await history.save({
          'requestId': (++index).toRadixString(16).padLeft(32, '0'),
            'sessionId': 'request-$state',
          'account': address.toUpperCase(),
          'chainId': 11155111,
          'nonce': 7,
          'unsignedPayload': '12',
          'state': state,
        });
        final blocked = await history.findPotentiallyExecutable(
            account: address, chainId: 11155111,
          );
        expect(blocked?['state'], state);
        await history.save({...blocked!, 'state': 'confirmed',
            'signatureUr': 'signature',
            'signedRaw': '0x12',
            'hash': hash,
          });
      }
      expect(
          await history.findPotentiallyExecutable(
              account: address, chainId: 11155111,
          ),
          isNull,
        );
    } finally {
      dir.deleteSync(recursive: true);
    }
  },
  );
  test(
      'restored history merge is atomic, immutable, bounded and preserves local status',
      () async {
    final dir = Directory.systemTemp.createTempSync('wallet_tx_merge_');
    try {
      final path = '${dir.path}/history.json';
      final history = TransactionHistory(pathOverride: path);
      final signed = <String, dynamic>{
        'requestId': '11' * 16,
          'sessionId': 'local-session',
        'account': address,
        ..._derivationBinding(account),
        'chainId': 11155111,
        'unsignedPayload': 'abcd',
        'signatureUr': 'signature',
        'signedRaw': '0x1234',
        'hash': hash,
        'state': 'confirmed',
        'rpcUrl': 'http://localhost:8545',
        };
      await history.save(signed);
      final before = File(path).readAsBytesSync();
      await expectLater(
          history.mergeRestoredRecords([
            {...signed, 'requestId': '22' * 16, 'state': 'verified'},
            {...signed, 'unsignedPayload': 'ffff'},
          ]),
          throwsFormatException,
        );
      expect(File(path).readAsBytesSync(), before,
          reason:
              'Conflicting batch must not partially write its earlier valid row',
        );
      await history.mergeRestoredRecords([
        {...signed, 'state': 'unknown', 'rpcUrl': ''},
        {...signed, 'requestId': '22' * 16, 'state': 'confirmed', 'rpcUrl': '',
          },
        {...signed, 'requestId': '22' * 16, 'state': 'verified', 'rpcUrl': '',
          },
      ]);
      final records = await history.read();
      expect(records.length, 2);
      expect(records.singleWhere((r) => r['requestId'] == '11' * 16)['state'],
          'confirmed',
        );
      expect(records.singleWhere((r) => r['requestId'] == '11' * 16)['rpcUrl'],
          'http://localhost:8545',
        );
      expect(records.singleWhere((r) => r['requestId'] == '22' * 16)['state'],
          'unknown',
        );
      expect(records.singleWhere((r) => r['requestId'] == '22' * 16)['rpcUrl'], '',
        );
      final merged = File(path).readAsBytesSync();
      for (final change in [
        {'account': '0x${'1' * 40}'},
        {'chainId': 31337},
        {'derivationPath': "m/44'/60'/0'/0/1"},
        {'masterFingerprint': 'deadbeef'},
        {'compressedPublicKeyHex': '02${'a' * 64}'},
        {'signatureUr': 'changed'},
        {'signedRaw': '0xffff'},
        {'hash': '0x${'b' * 64}'},
      ]) {
        await expectLater(
            history.mergeRestoredRecords([
              {...signed, ...change},
            ]),
            throwsFormatException,
          );
        expect(File(path).readAsBytesSync(), merged);
      }
      expect(
          () =>
              history.mergeRestoredRecords(List.generate(1001, (_) => signed)),
          throwsFormatException,
        );
      expect(
          () => history.mergeRestoredRecords([
                {...signed, 'signatureUr': 'x' * (2 * 1024 * 1024)},
          ]),
          throwsFormatException,
        );
    } finally {
      dir.deleteSync(recursive: true);
    }
  },
  );
  test(
    'restored history signatures only move toward complete records',
    () async {
      final dir = Directory.systemTemp.createTempSync('wallet_tx_monotonic_');
      try {
        final path = '${dir.path}/history.json';
        final history = TransactionHistory(pathOverride: path);
        final unsigned = <String, dynamic>{
          'requestId': '33' * 16,
          'sessionId': 'session',
          'account': address,
          ..._derivationBinding(account),
          'chainId': 11155111,
          'unsignedPayload': 'abcd',
          'state': 'awaitingSignature',
          'rpcUrl': 'http://localhost:8545',
        };
        final signed = <String, dynamic>{
          ...unsigned,
          'signatureUr': 'signature',
          'signedRaw': '0x1234',
          'hash': hash,
          'state': 'confirmed',
        };
        await history.save(signed);
        final original = File(path).readAsBytesSync();
        await history.mergeRestoredRecords([unsigned]);
        final kept = (await history.read()).single;
        expect(kept['signatureUr'], signed['signatureUr']);
        expect(kept['state'], 'confirmed');
        await expectLater(
          history.mergeRestoredRecords([
            {...signed, 'signatureUr': 'other-signature'},
          ]),
          throwsFormatException,
        );
        final beforeReset = File(path).readAsBytesSync();
        expect(beforeReset, original);

        File(path).deleteSync();
        await history.save(unsigned);
        await history.mergeRestoredRecords([signed]);
        final enriched = (await history.read()).single;
        expect(enriched['signatureUr'], signed['signatureUr']);
        expect(enriched['signedRaw'], signed['signedRaw']);
        expect(enriched['hash'], signed['hash']);
        expect(enriched['state'], 'unknown');
        expect(enriched['rpcUrl'], unsigned['rpcUrl']);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test(
    'restore preview and callback reject without changing history',
    () async {
      final dir = Directory.systemTemp.createTempSync('wallet_tx_preview_');
      try {
        final file = File('${dir.path}/history.json');
        final history = TransactionHistory(pathOverride: file.path);
        final row = <String, dynamic>{
          'requestId': '44' * 16,
          'sessionId': 'session',
          'account': address,
          ..._derivationBinding(account),
          'chainId': 11155111,
          'unsignedPayload': 'abcd',
          'state': 'awaitingSignature',
          'rpcUrl': 'http://localhost:8545',
        };
        await history.validateRestoredRecords([row]);
        expect(file.existsSync(), false);
        await history.save(row);
        final original = file.readAsBytesSync();
        var validations = 0;
        await history.validateRestoredRecords(
          [row],
          validateExisting: (records) {
            validations++;
            expect(records.single['requestId'], row['requestId']);
          },
        );
        expect(validations, 1);
        expect(file.readAsBytesSync(), original);
        void reject(List<Map<String, dynamic>> records) {
          throw const FormatException('binding rejected');
        }

        await expectLater(
          history.validateRestoredRecords([row], validateExisting: reject),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), original);
        await expectLater(
          history.mergeRestoredRecords([row], validateExisting: reject),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), original);
        await expectLater(
          history.validateRestoredRecords([
            {...row, 'unsignedPayload': 'ffff'},
          ]),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), original);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
      'imported empty RPC binding verifies chain then rebinds unknown; wrong chain rejects',
      (tester) async {
    final history = MemoryHistory();
    final restored = <String, dynamic>{
      'requestId': 'restored',
      'account': address,
        ..._derivationBinding(account),
      'chainId': 11155111,
      'unsignedPayload': '12',
      'signatureUr': 'signature',
      'signedRaw': '0x1234',
      'hash': hash,
      'state': 'verified',
      'rpcUrl': '',
      };
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
            sessionId: 'restored-session',
            requestId: 'restored',
            unsignedRlpHex: '12',
            restoredRecord: restored,
          ),
        ),
      );
    await tester.pumpAndSettle();
    expect(rpc.chainChecks, 1);
    expect(ffi.builds, 1);
    expect(rpc.sends, 0);
    expect(history.records.single['rpcUrl'], rpc.rpcUrl);
    expect(history.records.single['state'], 'unknown');
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    expect(find.byKey(const Key('query_transaction_btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final rejectedFfi = FakeFfi();
    final wrongRpc = FakeRpc()..wrongChain = true;
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: account,
            ffiOverride: rejectedFfi,
            rpcOverride: wrongRpc,
            historyOverride: MemoryHistory(),
            sessionId: 'restored-session',
            requestId: 'restored',
            unsignedRlpHex: '12',
            restoredRecord: restored,
          ),
        ),
      );
    await tester.pumpAndSettle();
    expect(rejectedFfi.builds, 0);
    expect(wrongRpc.sends, 0);
    expect(find.byKey(const Key('signature_verification_error_text')),
        findsOneWidget,
      );
    await tester.pumpWidget(const SizedBox());
  },
  );
  test('uint256 ERC20 overflow and negative transaction quantity rejected', () {
    expect(
        () => TransactionBuilder.encodeErc20TransferCalldata(
            recipientAddress: address, amountRaw: BigInt.one << 256,
      ),
        throwsArgumentError,
    );
    expect(
        () => TransactionBuilder.buildLegacyUnsignedRlp(
            nonce: -1,
            gasPriceWei: BigInt.one,
            gasLimit: 21000,
            toAddress: address,
            valueWei: BigInt.one,
            calldata: Uint8List(0),
            chainId: 11155111,
      ),
        throwsArgumentError,
    );
  });
  test('empty or malformed token ABI is error; priority RPC has no fallback',
      () async {
    for (final result in ['0x', '0x12', '0x${'z' * 64}']) {
      final rpc = NodeRpcClient(
          client: MockClient((req) async => http.Response(
              jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}), 200,
            ),
          ),
        );
      await expectLater(
          rpc.getErc20Balance(tokenContract: address, holderAddress: address),
          throwsA(isA<RpcException>()),
        );
    }
    final rpc = NodeRpcClient(
        client: MockClient((req) async => http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'error': {'code': -32601},
            }),
            200,
          ),
        ),
      );
    await expectLater(
        rpc.getMaxPriorityFeePerGas(), throwsA(isA<RpcException>()),
      );
  },
  );
  test(
      'receipt requires matching hash and status; status 0 is execution failure',
      () {
    expect(
        TransactionOutcome.receiptState(
            {'transactionHash': hash, 'blockNumber': '0x1', 'status': '0x0',
        },
            hash),
        'executionFailed',
      );
    expect(
        () => TransactionOutcome.receiptState(
            {'transactionHash': hash, 'blockNumber': '0x1',
        }, hash),
        throwsFormatException,
      );
    expect(
        () => TransactionOutcome.receiptState({
              'transactionHash': '0x${'b' * 64}',
              'blockNumber': '0x1',
              'status': '0x1',
        }, hash),
        throwsFormatException,
      );
  },
  );
  testWidgets('RPC fee source follows the selected transaction format',
      (tester,
  ) async {
    final calls = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      final call = jsonDecode(request.body) as Map<String, dynamic>;
      calls.add(call);
      const results = {
        'eth_chainId': '0xaa36a7',
        'eth_getTransactionCount': '0x1',
        'eth_gasPrice': '0x499602d3',
        'eth_maxPriorityFeePerGas': '0x1',
        'eth_estimateGas': '0x55f1',
      };
      return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'result': results[call['method']],
          }),
          200,
      );
    });
    addTearDown(client.close);
    final rpc =
        NodeRpcClient(rpcUrl: 'https://fee-source.invalid', client: client,
    );
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: FakeFfi(),
            rpcOverride: rpc,
            historyOverride: MemoryHistory(),
        ),
      ),
    );
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
    );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
    );
    await _tapVisible(tester, find.byKey(const Key('tx_fee_settings_toggle')));
    await tester.pumpAndSettle();

    for (final format in ['Legacy', 'EIP-1559']) {
      calls.clear();
      await _tapVisible(tester, find.text(format));
      await tester.pumpAndSettle();
      await _tapVisible(
          tester, find.byKey(const Key('sync_rpc_nonce_gas_btn')),
      );
      await tester.pumpAndSettle();

      expect(calls.map((call) => call['method']).toList(), [
        'eth_chainId',
        'eth_getTransactionCount',
        'eth_gasPrice',
        if (format == 'EIP-1559') 'eth_maxPriorityFeePerGas',
        'eth_estimateGas',
      ]);
      expect(calls[1]['params'], [address, 'pending']);
      expect(calls.last['params'], [
        {'from': address, 'to': address, 'value': '0x1'},
      ]);
      final source = tester.widget<Text>(find.textContaining('來源：')).data!;
      expect(source, contains(rpc.rpcUrl));
      expect(source, contains('Chain ID 11155111；Nonce 1；Gas 估算 22001'));
      if (format == 'Legacy') {
        expect(source, isNot(contains('Type-2')));
        expect(source, contains('Legacy'));
        expect(source, contains('gasPrice'));
        expect(source, contains('1.234567891 Gwei'));
        expect(
            tester
                .widget<TextField>(
                    find.byKey(const Key('tx_gas_price_gwei_field')),
              )
                .controller!
                .text,
            '1.234567891',
        );
      } else {
        expect(source, contains('Type-2 Max Fee'));
        expect(source, contains('gasPrice × 2 + priority'));
        expect(source, isNot(contains('Legacy')));
        expect(
            tester
                .widget<TextField>(
                    find.byKey(const Key('tx_max_fee_gwei_field')))
                .controller!
                .text,
            '2.469135783',
        );
      }
      expect(find.byKey(const Key('send_tx_error_text')), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'empty form, exact RPC parameters, and exported request blocks replacement',
      (tester) async {
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final history = MemoryHistory();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
          ),
        ),
      );
    expect(
        (tester.widget(find.byKey(const Key('tx_recipient_field')))
                as TextField)
            .controller!
            .text,
        '',
      );
    expect(
        (tester.widget(find.byKey(const Key('tx_amount_field'))) as TextField)
            .controller!
            .text,
        '',
      );
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.generateUnsignedTx();
    await tester.pump();
    expect(ffi.builds, 0);
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
      );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
      );
    await state.syncFromRpc();
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('tx_fee_settings_toggle')),
      );
    await _tapVisible(tester, find.byKey(const Key('tx_fee_settings_toggle')),
      );
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byKey(const Key('tx_nonce_field'))) as TextField)
            .controller!
            .text,
        '7',
      );
    expect(
        (tester.widget(find.byKey(const Key('tx_gas_limit_field')))
                as TextField)
            .controller!
            .text,
        '22001',
      );
    expect(
        (tester.widget(find.byKey(const Key('tx_max_fee_gwei_field')))
                as TextField)
            .controller!
            .text,
        '2.469135783',
      );
    await state.generateUnsignedTx();
    await tester.pump();
    expect(ffi.builds, 1);
    // Losing focus alone (notification shade, split screen) revokes it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byKey(const Key('proceed_scan_signature_btn')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await state.generateUnsignedTx();
    await tester.pump();
    expect(history.records.single['state'], 'awaitingSignature');
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '2');
    await tester.pump();
    expect(ffi.cancels, greaterThan(0));
    expect(find.byKey(const Key('proceed_scan_signature_btn')), findsNothing);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '1' * 100,
      );
    await state.generateUnsignedTx();
    await tester.pump();
    expect(ffi.builds, 1);
    expect(history.records.single['state'], 'awaitingSignature');
    expect(find.textContaining('仍有可能執行的先前交易'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  },
  );
  testWidgets('a request build ignores repeat taps until it finishes',
      (tester,
  ) async {
    final ffi = FakeFfi();
    final history = _GatedHistory();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: FakeRpc(),
            historyOverride: history,
        ),
      ),
    );
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
    );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
    );
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.syncFromRpc();
    await tester.pump();
    final button = find.byKey(const Key('generate_sign_request_qr_btn'));

    final first = state.generateUnsignedTx();
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull,
        reason: 'The build button is disabled while a request is built',
    );
    final second = state.generateUnsignedTx();
    history.gate.complete();
    await Future.wait([first, second]);
    await tester.pumpAndSettle();

    expect(ffi.builds, 1, reason: 'A repeat tap must not build again');
    // Nor may it cancel the build in flight: that would orphan its record
    // and leave no QR.
    expect(ffi.cancels, 0);
    expect(history.records, hasLength(1));
    expect(find.text('交給 Vault 簽署'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a built request scrolls the QR section into view',
      (tester,
  ) async {
    tester.view.physicalSize = const Size(400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ffi = FakeFfi();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: FakeRpc(),
            historyOverride: MemoryHistory(),
        ),
      ),
    );
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
    );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
    );
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.syncFromRpc();
    await tester.pump();
    await state.generateUnsignedTx();
    await tester.pumpAndSettle();
    expect(ffi.builds, 1);
    final heading = tester.getRect(find.text('交給 Vault 簽署'));
    expect(heading.top, greaterThanOrEqualTo(0));
    expect(heading.bottom, lessThanOrEqualTo(720),
        reason: 'The built request must be scrolled into view',
    );

    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('only a built request QR is announced to screen readers',
      (tester,
  ) async {
    final ffi = FakeFfi();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: FakeRpc(),
            historyOverride: MemoryHistory(),
        ),
      ),
    );
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.generateUnsignedTx();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('send_tx_error_text')), findsOneWidget);
    expect(tester.takeAnnouncements(), isEmpty,
        reason: 'A rejected build already shows its error; nothing is built',
    );

    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
    );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
    );
    await state.syncFromRpc();
    await tester.pump();
    await state.generateUnsignedTx();
    await tester.pumpAndSettle();
    expect(ffi.builds, 1);
    expect(tester.takeAnnouncements(), [
      isAccessibilityAnnouncement('待簽交易 QR 已建立，請用 Vault 掃描並核對後簽署。',
          textDirection: TextDirection.ltr,
      ),
    ]);

    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a built multi-frame request shows its whole QR on a short phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    final ffi = _FountainFfi();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: account,
            ffiOverride: ffi,
            rpcOverride: FakeRpc(),
            historyOverride: MemoryHistory(),
          ),
        ),
      );
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), address,
      );
    await tester.enterText(
        find.byKey(const Key('tx_amount_field')), '0.000000000000000001',
      );
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.syncFromRpc();
    await tester.pump();
    await state.generateUnsignedTx();
    // The fountain animates continuously, so the scroll is pumped explicitly.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(ffi.builds, 1);
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    final qr = tester.getRect(find.byType(AnimatedFountainQr));
    expect(qr.height, lessThanOrEqualTo(viewport.height));
    expect(qr.top, greaterThanOrEqualTo(viewport.top),
        reason: 'The whole QR card must be on screen after building',
      );
    expect(qr.bottom, lessThanOrEqualTo(viewport.bottom),
        reason: 'The whole QR card must be on screen after building',
      );

    await tester.pumpWidget(const SizedBox());
  },
  );
  for (final feeSource in ['estimate', 'manual']) {
    testWidgets(
        'production native Sepolia self transfer accepts 12000 gas from $feeSource',
        (tester) async {
      final ffi = WalletFfiService();
      expect(ffi.init(), 0);
      final rpc = FakeRpc()..gasEstimate = 12000;
      final history = MemoryHistory();
      await tester.pumpWidget(MaterialApp(
          home: SendTxScreen(
              account: account,
              ffiOverride: ffi,
              rpcOverride: rpc,
              historyOverride: history,
            ),
          ),
        );
      await tester.enterText(find.byKey(const Key('tx_recipient_field')),
          address.toUpperCase().replaceFirst('0X', '0x'),
        );
      await tester.enterText(
          find.byKey(const Key('tx_amount_field')), '0.000001',
        );
      final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen),
        );
      if (feeSource == 'estimate') {
        await state.syncFromRpc();
      } else {
        await _tapVisible(
            tester, find.byKey(const Key('tx_fee_settings_toggle')),
          );
        await tester.pumpAndSettle();
        for (final entry in {
          'tx_nonce_field': '7',
          'tx_gas_limit_field': '12000',
          'tx_max_fee_gwei_field': '2.469135783',
          'tx_priority_fee_gwei_field': '0.000000001',
        }.entries) {
          final field = tester.widget<TextField>(find.byKey(Key(entry.key)));
          field.controller!.text = entry.value;
        }
      }
      await state.generateUnsignedTx();
      await tester.pump();
      expect(find.byKey(const Key('send_tx_error_text')), findsNothing);
      expect(
          find.byKey(const Key('proceed_scan_signature_btn')), findsOneWidget,
        );
      expect(history.records, hasLength(1));
      final raw = history.records.single['unsignedPayload'] as String;
      expect(
          raw,
          TransactionBuilder.buildEip1559UnsignedPayload(
              chainId: 11155111,
              nonce: 7,
              maxPriorityFeePerGasWei: BigInt.one,
              maxFeePerGasWei: BigInt.from(2469135783),
              gasLimit: 12000,
              toAddress: address,
              valueWei: BigInt.from(1000000000000),
              calldata: Uint8List(0),
          ),
        );
      expect(ffi.decodeIntentJson(rawRlpHex: raw, declaredChainId: 11155111),
          isNotNull,
        );
      expect(rpc.sends, 0);
      await tester.pumpWidget(const SizedBox());
    },
    );
  }
  for (final shape in [
    'other recipient',
    'other chain',
    'Legacy',
    'ERC20',
    'below floor',
    'above maximum',
  ]) {
    testWidgets('low gas exception rejects $shape before creating a request',
        (tester,
    ) async {
      final ffi = WalletFfiService();
      expect(ffi.init(), 0);
      final history = MemoryHistory();
      await tester.pumpWidget(MaterialApp(
          home: SendTxScreen(
              account: shape == 'other chain'
                  ? account.copyWith(chainId: 31337)
                  : account,
              ffiOverride: ffi,
              rpcOverride: FakeRpc(),
              historyOverride: history,
          ),
        ),
      );
      await tester.enterText(find.byKey(const Key('tx_recipient_field')),
          shape == 'other recipient' ? '0x${'f' * 40}' : address,
      );
      await tester.enterText(
          find.byKey(const Key('tx_amount_field')), '0.000001',
      );
      if (shape == 'ERC20') {
        await _tapVisible(
            tester, find.byKey(const Key('asset_selector_dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('USDC · Sepolia').last);
        await tester.pumpAndSettle();
      }
      await _tapVisible(
          tester, find.byKey(const Key('tx_fee_settings_toggle')),
      );
      await tester.pumpAndSettle();
      if (shape == 'Legacy') {
        await tester.tap(find.text('Legacy'));
        await tester.pumpAndSettle();
      }
      for (final entry in {
        'tx_nonce_field': '7',
        'tx_gas_limit_field': shape == 'below floor'
            ? '11999'
            : shape == 'above maximum'
                ? '500001'
                : '12000',
        if (shape == 'Legacy')
          'tx_gas_price_gwei_field': '1'
        else ...{
          'tx_max_fee_gwei_field': '2',
          'tx_priority_fee_gwei_field': '1',
        },
      }.entries) {
        tester.widget<TextField>(find.byKey(Key(entry.key))).controller!.text =
            entry.value;
      }
      await tester
          .state<SendTxScreenState>(find.byType(SendTxScreen))
          .generateUnsignedTx();
      await tester.pump();
      expect(find.byKey(const Key('send_tx_error_text')), findsOneWidget);
      expect(find.textContaining('Gas Limit 超出安全範圍'), findsOneWidget);
      expect(find.byKey(const Key('proceed_scan_signature_btn')), findsNothing);
      expect(history.records, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'verified scan requires explicit broadcast; uncertain retry queries same hash; restart re-verifies',
      (tester) async {
    final history = MemoryHistory();
    final ffi = FakeFfi();
    final rpc = FakeRpc();
    final key = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            key: key,
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
            sessionId: 'session',
            requestId: 'request',
            unsignedRlpHex: '12',
          ),
        ),
      );
    await tester
        .runAsync(() => key.currentState!.ingestSignatureUr('signature'),
      );
    await tester.pump();
    expect(rpc.sends, 0);
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget);
    rpc.failSend = true;
    await tester.runAsync(() => key.currentState!.broadcast());
    await tester.pump();
    expect(rpc.sends, 1);
    expect(find.text('結果待查，請查詢同一筆交易'), findsWidgets);
    await tester.runAsync(() => key.currentState!.broadcast());
    expect(rpc.sends, 1);
    await tester.runAsync(() => key.currentState!.queryTransaction());
    expect(rpc.queries, 1);
    rpc.failSend = false;
    await tester.runAsync(() => key.currentState!.broadcast());
    await tester.pump();
    expect(rpc.sends, 2);
    rpc.receipt = {
      'transactionHash': hash,
      'blockNumber': '0x1',
      'status': '0x0',
      };
    await tester.runAsync(() => key.currentState!.queryTransaction());
    await tester.pump();
    expect(find.text('已確認（執行失敗）'), findsWidgets);
    final records = (await tester.runAsync(history.read))!;
    expect(records.single['signedRaw'], '0x1234');
    expect(records.single['state'], 'executionFailed');
    await tester.pumpWidget(const SizedBox());
    final restoreKey = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            key: restoreKey,
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
            sessionId: 'session',
            requestId: 'request',
            unsignedRlpHex: '12',
            restoredRecord: records.single,
          ),
        ),
      );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(ffi.builds, 1);
    expect(rpc.sends, 2);
    expect(find.byKey(const Key('query_transaction_btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  },
  );
  testWidgets('wrong signature rejects; wrong node hash never claims accepted',
      (tester) async {
    final history = MemoryHistory();
    final ffi = FakeFfi()..reject = true;
    final rpc = FakeRpc()..mismatchedHash = true;
    final key = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            key: key,
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
            requestId: 'request',
            unsignedRlpHex: '12',
          ),
        ),
      );
    await tester.runAsync(() => key.currentState!.ingestSignatureUr('bad'));
    await tester.pump();
    expect(rpc.sends, 0);
    expect(find.byKey(const Key('signature_verification_error_text')),
        findsOneWidget,
      );
    await tester.pumpWidget(const SizedBox());
    ffi.reject = false;
    final next = GlobalKey<ScanSignatureScreenState>();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            key: next,
            account: account,
            ffiOverride: ffi,
            rpcOverride: rpc,
            historyOverride: history,
            requestId: 'request2',
            unsignedRlpHex: '12',
          ),
        ),
      );
    await tester.runAsync(() => next.currentState!.ingestSignatureUr('good'));
    await tester.runAsync(() => next.currentState!.broadcast());
    await tester.pump();
    expect(find.text('節點已接受，待查確認'), findsNothing);
    expect(find.byKey(const Key('broadcast_rpc_error_text')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  },
  );
}
