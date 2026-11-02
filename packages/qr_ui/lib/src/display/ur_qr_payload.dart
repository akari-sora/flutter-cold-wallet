import 'dart:convert';

/// Public UR display/copy contract shared by request and response screens.
class UrQrPayload {
  // Lowercase ASCII UR uses byte mode. Version 40 at ECC M holds 2,331 bytes.
  static const maxDisplayChars = 2331;
  static const maxWireChars = 8192;
  static const maxFrames = 512;
  static const maxSessionChars = 2097152;

  final String? singleUr;
  final List<String> frames;
  final String? _copySingleUr;
  final List<String> _copyFrames;

  UrQrPayload({String? singleUr, Iterable<String> frames = const []})
      : singleUr = isDisplayableFrame(singleUr) ? singleUr : null,
        frames = _boundedFrames(frames, maxDisplayChars),
        _copySingleUr =
            _isBoundedFrame(singleUr, maxWireChars) ? singleUr : null,
        _copyFrames = _boundedFrames(frames, maxWireChars);

  static bool isDisplayableFrame(String? frame) =>
      _isBoundedFrame(frame, maxDisplayChars);

  /// The shared QR widget also displays public EVM and Bitcoin addresses.
  static bool isDisplayableQrData(String? data) =>
      data != null &&
      data.isNotEmpty &&
      utf8.encode(data).length <= maxDisplayChars;

  static bool _isBoundedFrame(String? frame, int limit) =>
      frame != null &&
      frame.isNotEmpty &&
      frame.length <= limit &&
      frame.toLowerCase().startsWith('ur:') &&
      frame.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

  static List<String> _boundedFrames(Iterable<String> frames, int limit) {
    final result = <String>[];
    var totalChars = 0;
    for (final frame in frames) {
      totalChars += frame.length;
      if (result.length == maxFrames ||
          totalChars > maxSessionChars ||
          !_isBoundedFrame(frame, limit)) {
        return const [];
      }
      result.add(frame);
    }
    return List.unmodifiable(result);
  }

  bool get hasSingle => singleUr != null;
  bool get hasCopy => copyText.isNotEmpty;

  List<String> displayFrames({bool preferSingle = false}) {
    if (preferSingle && hasSingle) return [singleUr!];
    if (frames.isNotEmpty) return frames;
    return hasSingle ? [singleUr!] : const [];
  }

  /// A complete request/response, including every multipart frame when needed.
  String get copyText {
    if (singleUr != null) return singleUr!;
    if (frames.isNotEmpty) return jsonEncode(frames);
    if (_copySingleUr != null) return _copySingleUr;
    return _copyFrames.isEmpty ? '' : jsonEncode(_copyFrames);
  }
}
