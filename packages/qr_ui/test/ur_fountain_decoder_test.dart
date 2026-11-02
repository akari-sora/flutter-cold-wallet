import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_ui/qr_ui.dart';

// The same real UR/Bytewords fixture exercised by ur_adapter fountain_robustness.
const sample =
    "ur:crypto-multi-accounts/onadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddyoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewkbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyehrnwdjk";
const frame1 =
    "ur:crypto-multi-accounts/1-3/lpadaxcfadatcyehrnwdjkhdhdonadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddykewehyax";
const frame2 =
    "ur:crypto-multi-accounts/2-3/lpaoaxcfadatcyehrnwdjkhdhdoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewklphebsfn";
const frame3 =
    "ur:crypto-multi-accounts/3-3/lpaxaxcfadatcyehrnwdjkhdhdbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyaenycpuoya";

void main() {
  test('single-part checksum validated and CBOR bytes returned from native',
      () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    final result = await decoder.receiveFrame(sample.toUpperCase());
    expect(result, hasLength(263));
    expect(result!.first, 0xa5); // CBOR map, not UTF-8 Bytewords text.
    expect(decoder.isComplete, isTrue);
    expect(decoder.completedUrOrFramesJson, sample);
  });

  test('out-of-order multipart decodes actual bytes, ignores duplicates',
      () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    final single = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    addTearDown(single.dispose);
    final progress = <FountainProgress>[];
    final subscription = decoder.progressStream.listen(progress.add);
    addTearDown(subscription.cancel);
    expect(await decoder.receiveFrame(frame3), isNull);
    expect(await decoder.receiveFrame(frame3), isNull);
    expect(await decoder.receiveFrame(frame1), isNull);
    expect(decoder.isComplete, isFalse);
    final result = await decoder.receiveFrame(frame2);
    expect(result, await single.receiveFrame(sample));
    expect(
        jsonDecode(decoder.completedUrOrFramesJson!), [frame1, frame2, frame3]);
    await Future<void>.delayed(Duration.zero);
    expect(progress.map((p) => p.resolvedFragments), [1, 2, 3]);
    expect(progress.last.isComplete, isTrue);
  });

  test('fake payload and corrupted checksum never report complete', () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    await expectLater(
        decoder.receiveFrame('ur:crypto-multi-accounts/partpayload'),
        throwsFormatException);
    await expectLater(
        decoder.receiveFrame('${sample.substring(0, sample.length - 2)}ae'),
        throwsFormatException);
    expect(decoder.isComplete, isFalse);
    expect(decoder.activeType, isNull);
    expect(decoder.orderedFrames, isEmpty);
    expect(await decoder.receiveFrame(sample), hasLength(263));
  });

  test('type locks after first verified frame; reset clears session', () async {
    final decoder = UrFountainDecoder(
        expectedType: 'eth-sign-request,crypto-multi-accounts');
    addTearDown(decoder.dispose);
    await decoder.receiveFrame(frame1);
    await expectLater(
        decoder.receiveFrame(
            frame2.replaceFirst('crypto-multi-accounts', 'eth-sign-request')),
        throwsA(isA<UrTypeMismatchException>()));
    expect(decoder.isComplete, isFalse);
    decoder.reset();
    expect(decoder.activeType, isNull);
    expect(decoder.orderedFrames, isEmpty);
    expect(await decoder.receiveFrame(sample), hasLength(263));
  });

  test('metadata mismatch does not poison accepted frames', () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    await decoder.receiveFrame(frame1);
    await expectLater(
        decoder.receiveFrame(frame2.replaceFirst('/2-3/', '/2-4/')),
        throwsA(isA<UrInconsistentSessionException>()));
    await expectLater(
        decoder.receiveFrame(frame2.replaceFirst('/2-3/', '/3-3/')),
        throwsFormatException);
    expect(decoder.orderedFrames, [frame1]);
    await decoder.receiveFrame(frame2);
    expect(await decoder.receiveFrame(frame3), hasLength(263));
  });

  test('rejected first frame cannot pin another allowed type', () async {
    final decoder = UrFountainDecoder(
        expectedType: 'eth-sign-request,crypto-multi-accounts');
    addTearDown(decoder.dispose);
    await expectLater(decoder.receiveFrame('ur:eth-sign-request/invalid'),
        throwsFormatException);
    expect(decoder.activeType, isNull);
    expect(await decoder.receiveFrame(sample), hasLength(263));
  });

  test('limits and malformed batches rejected before invoking native',
      () async {
    var calls = 0;
    final decoder = UrFountainDecoder(
        expectedType: 'bytes',
        decode: (_, __) {
          calls++;
          throw StateError('native absent');
        });
    addTearDown(decoder.dispose);
    await expectLater(
        decoder.receiveFrame('ur:bytes/${'a' * 8192}'), throwsFormatException);
    await expectLater(
        decoder.receiveFrame('ur:bytes/1-513/ae'), throwsFormatException);
    await expectLater(
        decoder.receiveBatchInput(jsonEncode(List.filled(513, 'ur:bytes/ae'))),
        throwsFormatException);
    await expectLater(decoder.receiveBatchInput('[1]'), throwsFormatException);
    expect(calls, 0);
    await expectLater(decoder.receiveFrame('ur:bytes/ae'), throwsStateError);
    expect(decoder.isComplete, isFalse);
    expect(decoder.activeType, isNull);
    expect(decoder.orderedFrames, isEmpty);
  });
  test('reset during an awaited batch prevents stale completion', () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    final pending =
        decoder.receiveBatchInput(jsonEncode([frame1, frame2, frame3]));
    decoder.reset();
    expect(await pending, isNull);
    expect(decoder.isComplete, isFalse);
    expect(decoder.orderedFrames, isEmpty);
    expect(await decoder.receiveFrame(sample), hasLength(263));
  });

  test('completed payload is cached without decoding again', () async {
    var calls = 0;
    final decoder = UrFountainDecoder(
        expectedType: 'bytes',
        decode: (_, __) {
          calls++;
          return {
            'status': 'complete',
            'payload_hex': 'a0',
            'total_fragments': 1,
            'resolved_fragments': 1
          };
        });
    addTearDown(decoder.dispose);
    expect(await decoder.receiveFrame('ur:bytes/ae'), [0xa0]);
    expect(await decoder.receiveFrame('ur:bytes/ae'), [0xa0]);
    expect(calls, 1);
  });

  test('failed manual batch is all-or-nothing so a different retry works',
      () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    final corrupted = '${frame2.substring(0, frame2.length - 2)}ae';
    await expectLater(decoder.receiveBatchInput('$frame1\n$corrupted'),
        throwsFormatException);
    expect(decoder.orderedFrames, isEmpty);
    expect(decoder.activeType, isNull);
    // A one-part retry would conflict with the 3-part count if frame1 stayed.
    expect(await decoder.receiveBatchInput(sample), hasLength(263));
  });

  test('native session loss clears Dart progress instead of reusing the id',
      () async {
    var calls = 0;
    final decoder = UrFountainDecoder(
        expectedType: 'crypto-multi-accounts',
        decode: (type, frames) {
          calls++;
          return calls == 1
              ? {
                  'status': 'incomplete',
                  'total_fragments': 3,
                  'resolved_fragments': 1
                }
              : {
                  'status': 'error',
                  'error_code': 'ERR_UR_SESSION_RECOVERY',
                  'error': 'synthetic session loss'
                };
        });
    addTearDown(decoder.dispose);
    expect(await decoder.receiveFrame(frame1), isNull);
    await expectLater(decoder.receiveFrame(frame2),
        throwsA(isA<UrInconsistentSessionException>()));
    expect(decoder.orderedFrames, isEmpty);
    expect(decoder.activeType, isNull);
  });

  test('a result rejected after native completion resets the session',
      () async {
    var calls = 0;
    final decoder = UrFountainDecoder(
        expectedType: 'crypto-multi-accounts',
        decode: (type, frames) {
          calls++;
          return calls == 1
              ? {
                  'status': 'complete',
                  'total_fragments': 1,
                  'resolved_fragments': 1,
                  'payload_hex': 'zz'
                }
              : {
                  'status': 'complete',
                  'total_fragments': 1,
                  'resolved_fragments': 1,
                  'payload_hex': 'a5'
                };
        });
    addTearDown(decoder.dispose);
    await expectLater(decoder.receiveFrame(sample), throwsStateError);
    expect(decoder.isComplete, isFalse);
    expect(decoder.orderedFrames, isEmpty);
    expect(await decoder.receiveFrame(sample), [0xa5]);
  });

  test('a failed batch that discards camera progress says so', () async {
    final decoder = UrFountainDecoder(expectedType: 'crypto-multi-accounts');
    addTearDown(decoder.dispose);
    expect(await decoder.receiveFrame(frame1), isNull);
    final corrupted = '${frame2.substring(0, frame2.length - 2)}ae';
    await expectLater(
        decoder.receiveBatchInput(corrupted),
        throwsA(isA<UrInconsistentSessionException>().having(
            (e) => e.toString(), 'message', contains('已一併清除先前的掃描進度'))));
    expect(decoder.orderedFrames, isEmpty);
    expect(await decoder.receiveBatchInput('$frame1\n$frame2\n$frame3'),
        hasLength(263));
  });
}
