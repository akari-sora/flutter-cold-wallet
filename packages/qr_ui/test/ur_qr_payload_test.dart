import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qr_ui/qr_ui.dart';

void main() {
  test('maximum displayable byte-mode UR fits the configured QR renderer', () {
    final frame = 'ur:bytes/${'a' * (UrQrPayload.maxDisplayChars - 9)}';
    expect(frame.length, UrQrPayload.maxDisplayChars);
    final payload = UrQrPayload(singleUr: frame, frames: [frame]);
    expect(payload.hasSingle, isTrue);
    expect(payload.displayFrames(preferSingle: true), [frame]);
    expect(payload.copyText, frame);
    expect(
        QrValidator.validate(
                data: frame,
                version: QrVersions.auto,
                errorCorrectionLevel: QrErrorCorrectLevel.M)
            .status,
        QrValidationStatus.valid);
  });

  test('full capacity frame-only payload preserves order and complete copy',
      () {
    final frames = List.generate(UrQrPayload.maxFrames,
        (index) => 'ur:crypto-psbt/${index + 1}-512/${'a' * 512}');
    final payload = UrQrPayload(singleUr: '', frames: frames);
    expect(payload.hasSingle, isFalse);
    expect(payload.displayFrames(), frames);
    expect(payload.displayFrames(preferSingle: true), frames);
    expect(jsonDecode(payload.copyText), frames);
  });

  test('historical wire-bounded single remains copyable without rendering', () {
    final single = 'ur:crypto-psbt/${'a' * 3000}';
    final payload = UrQrPayload(singleUr: single);
    expect(payload.hasSingle, isFalse);
    expect(payload.displayFrames(), isEmpty);
    expect(payload.hasCopy, isTrue);
    expect(payload.copyText, single);
  });
}
