import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_builder.dart';
import 'package:wallet/services/transaction_history.dart';
import 'test_storage_directory.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/scan_signature_screen.dart';

class _OfflineFailingRpcClient extends NodeRpcClient {
  _OfflineFailingRpcClient() : super(rpcUrl: 'http://127.0.0.1:1');

  @override
  Future<int> verifyChainId(int expectedChainId) async {
    throw const RpcException(
      method: 'eth_chainId',
      message: 'ERR_RPC_OFFLINE: Local test node unreachable',
    );
  }

  @override
  Future<String> sendRawTransaction(String signedRawTxHex,
      {int? expectedChainId, bool Function()? canDispatch}) async {
    throw const RpcException(
      method: 'eth_sendRawTransaction',
      message: 'ERR_RPC_BROADCAST_FAILED: Simulated node rejection',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/event'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'),
        (call) async {
      if (call.method == 'state') return 1;
      if (call.method == 'start') {
        return {
          'textureId': 1,
          'numberOfCameras': 1,
          'size': {'width': 640.0, 'height': 480.0}
        };
      }
      return null;
    });
  });
  group('TransactionBuilder & DecimalAmountParser unit tests', () {
    test('TransactionBuilder encodes 68-byte ERC-20 transfer calldata', () {
      final calldata = TransactionBuilder.encodeErc20TransferCalldata(
        recipientAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        amountRaw: BigInt.from(100500000), // 100.5 USDC
      );

      expect(calldata.length, 68);
      expect(calldata[0], 0xa9);
      expect(calldata[1], 0x05);
      expect(calldata[2], 0x9c);
      expect(calldata[3], 0xbb);

      for (var i = 4; i < 16; i++) {
        expect(calldata[i], 0, reason: 'Dirty padding detected at byte $i');
      }
    });

    test(
        'TransactionBuilder builds Legacy EIP-155 and EIP-1559 Type-2 unsigned payloads',
        () {
      final legacyRlp = TransactionBuilder.buildLegacyUnsignedRlp(
        nonce: 0,
        gasPriceWei: BigInt.from(20000000000),
        gasLimit: 21000,
        toAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        valueWei: BigInt.from(1000000000000000000),
        calldata: Uint8List(0),
        chainId: 11155111,
      );
      expect(legacyRlp.isNotEmpty, isTrue);

      final eip1559Hex = TransactionBuilder.buildEip1559UnsignedPayload(
        chainId: 11155111,
        nonce: 3,
        maxPriorityFeePerGasWei: BigInt.from(1500000000),
        maxFeePerGasWei: BigInt.from(30000000000),
        gasLimit: 65000,
        toAddress: NodeRpcClient.sepoliaUsdcContract,
        valueWei: BigInt.zero,
        calldata: TransactionBuilder.encodeErc20TransferCalldata(
          recipientAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
          amountRaw: BigInt.from(25000000),
        ),
      );
      expect(eip1559Hex.startsWith('02'), isTrue);
    });

    test(
        'TransactionBuilder reconstructs signed Legacy and EIP-1559 transactions',
        () {
      final rHex = '11' * 32;
      final sHex = '22' * 32;
      final signedLegacy = TransactionBuilder.reconstructSignedLegacyTx(
        nonce: 0,
        gasPriceWei: BigInt.from(20000000000),
        gasLimit: 21000,
        toAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        valueWei: BigInt.from(1000000000000000000),
        calldata: Uint8List(0),
        chainId: 11155111,
        rHex: rHex,
        sHex: sHex,
        vByte: 27,
      );
      expect(signedLegacy.startsWith('0x'), isTrue);

      final signed1559 = TransactionBuilder.reconstructSignedEip1559Tx(
        chainId: 11155111,
        nonce: 1,
        maxPriorityFeePerGasWei: BigInt.from(1500000000),
        maxFeePerGasWei: BigInt.from(30000000000),
        gasLimit: 21000,
        toAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        valueWei: BigInt.from(500000000000000000),
        calldata: Uint8List(0),
        rHex: rHex,
        sHex: sHex,
        vByte: 1,
      );
      expect(signed1559.startsWith('0x02'), isTrue);
    });
  });

  group('Real WalletFfiService & Watch-Only UI integration tests', () {
    late WalletFfiService ffi;
    late Directory tempDir;
    late String storagePath;

    // Known test vector for abandon x11 + about (account 0)
    const account0Address = '0x9858effd232b4033e47d90003d41ec34ecaeda94';
    const account0Pubkey =
        '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299';
    const masterFp = '73c5da0a';

    setUp(() {
      ffi = WalletFfiService();
      ffi.init();
      tempDir = Directory.systemTemp.createTempSync('fcw_wallet_test_');
      storagePath = '${tempDir.path}/paired_accounts.json';
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'WalletFfiService verifies secp256k1 pubkey-to-address and builds Legacy & EIP-1559 eth-sign-request URs',
        () {
      expect(
        ffi.verifyPubkeyAddress(
          compressedPubkeyHex: account0Pubkey,
          expectedAddress: account0Address,
        ),
        isTrue,
      );
      expect(
        ffi.verifyPubkeyAddress(
          compressedPubkeyHex: account0Pubkey,
          expectedAddress: '0x000000000000000000000000000000000000dead',
        ),
        isFalse,
      );

      // Build Legacy EIP-155 eth-sign-request UR
      final legacyRlp = TransactionBuilder.buildLegacyUnsignedRlp(
        nonce: 0,
        gasPriceWei: BigInt.from(20000000000),
        gasLimit: 21000,
        toAddress: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        valueWei: DecimalAmountParser.parseToBaseUnits('0.1', decimals: 18),
        calldata: Uint8List(0),
        chainId: 11155111,
      );

      final reqLegacy = ffi.buildEthSignRequestUr(
        sessionId: 'sess-w-1',
        requestIdHex: '00112233445566778899aabbccddeeff',
        rawTxHex: legacyRlp,
        chainId: 11155111,
        derivationPath: "m/44'/60'/0'/0/0",
        masterFingerprintHex: masterFp,
        expectedAddress: account0Address,
      );
      expect(reqLegacy['status'], 'PENDING_REGISTERED');
      expect(
          (reqLegacy['ur_single'] as String).startsWith('ur:eth-sign-request/'),
          isTrue);

      // Build EIP-1559 Type-2 ERC-20 USDC eth-sign-request UR
      final eip1559Hex = TransactionBuilder.buildEip1559UnsignedPayload(
        chainId: 11155111,
        nonce: 1,
        maxPriorityFeePerGasWei: BigInt.from(1500000000),
        maxFeePerGasWei: BigInt.from(25000000000),
        gasLimit: 65000,
        toAddress: NodeRpcClient.sepoliaUsdcContract,
        valueWei: BigInt.zero,
        calldata: TransactionBuilder.encodeErc20TransferCalldata(
          recipientAddress: account0Address,
          amountRaw:
              DecimalAmountParser.parseToBaseUnits('12.345678', decimals: 6),
        ),
      );
      final req1559 = ffi.buildEthSignRequestUr(
        sessionId: 'sess-w-2',
        requestIdHex: '11223344556677889900aabbccddeeff',
        rawTxHex: eip1559Hex,
        chainId: 11155111,
        derivationPath: "m/44'/60'/0'/0/0",
        masterFingerprintHex: masterFp,
        expectedAddress: account0Address,
      );
      expect(req1559['status'], 'PENDING_REGISTERED');
      expect(req1559['tx_type'], 'EIP1559');
      expect(
          (req1559['ur_single'] as String).startsWith('ur:eth-sign-request/'),
          isTrue);
    });

    testWidgets(
        'AccountScreen starts empty (no mock account) and rejects invalid pairing UR',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AccountScreen(
            ffiOverride: ffi,
            rpcOverride: _OfflineFailingRpcClient(),
            storagePathOverride: storagePath,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state =
          tester.state<AccountScreenState>(find.byType(AccountScreen));
      expect(state.currentAccount, isNull);
      expect(find.byKey(const Key('no_paired_accounts_title')), findsOneWidget);

      // Rejects invalid UR
      final ok = state.ingestPairingUr('ur:eth-signature/invalid');
      await tester.pumpAndSettle();
      expect(ok, isFalse);
      expect(state.currentAccount, isNull);
    });

    testWidgets(
        'ScanSignatureScreen fails closed on invalid signature UR and never fakes broadcast success',
        (WidgetTester tester) async {
      const account = AccountDescriptor(
        chainId: 11155111,
        address: account0Address,
        derivationPath: "m/44'/60'/0'/0/0",
        masterFingerprint: masterFp,
        compressedPublicKeyHex: account0Pubkey,
      );

      final unsignedPayload = TransactionBuilder.buildLegacyUnsignedRlp(
        nonce: 9,
        gasPriceWei: BigInt.from(2000000000),
        gasLimit: 21000,
        toAddress: account0Address,
        valueWei: BigInt.one,
        calldata: Uint8List(0),
        chainId: 11155111,
      );
      final pending = ffi.buildEthSignRequestUr(
          sessionId: 'sess-fail-closed',
          requestIdHex: '00112233445566778899aabbccddeeff',
          rawTxHex: unsignedPayload,
          chainId: 11155111,
          derivationPath: account.derivationPath,
          masterFingerprintHex: masterFp,
          expectedAddress: account0Address);
      expect(pending['status'], 'PENDING_REGISTERED');
      await tester.pumpWidget(
        MaterialApp(
          home: ScanSignatureScreen(
            account: account,
            sessionId: 'sess-fail-closed',
            requestId: '00112233445566778899aabbccddeeff',
            unsignedRlpHex: unsignedPayload,
            ffiOverride: ffi,
            historyOverride: TransactionHistory(pathOverride: testHistoryPath()),
            rpcOverride: _OfflineFailingRpcClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final state = tester
          .state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
      await state.ingestSignatureUr('ur:eth-signature/not-a-valid-cbor');
      await tester.pumpAndSettle();

      expect(find.textContaining('廣播成功'), findsNothing);
      expect(find.textContaining('ERR_'), findsWidgets);
      expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
