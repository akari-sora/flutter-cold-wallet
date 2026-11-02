/// Exact Decimal-String-to-BigInt Parser and Formatter.
/// Strictly uses pure string and [BigInt] arithmetic with ZERO floating-point (`double`) operations.
class AmountParseException implements Exception {
  final String message;
  const AmountParseException(this.message);

  @override
  String toString() => 'AmountParseException: $message';
}

class DecimalAmountParser {
  static final RegExp _validDecimalPattern = RegExp(r'^\d+(\.\d+)?$');

  /// Parses a human-readable decimal string (e.g. "0.05", "12.345678") into
  /// exact base units ([BigInt]) for a token with [decimals] decimal places.
  ///
  /// Throws [AmountParseException] on invalid syntax, negative values,
  /// scientific notation, excess fractional precision, or zero (when [allowZero] is false).
  static BigInt parseToBaseUnits(
    String input, {
    required int decimals,
    bool allowZero = false,
  }) {
    if (decimals < 0 || decimals > 77) {
      throw AmountParseException('Invalid token decimals: $decimals');
    }

    final trimmed = input.trim();
    if (trimmed.length > 256) {
      throw const AmountParseException('金額超過可處理的長度');
    }
    if (trimmed.isEmpty) {
      throw const AmountParseException('金額不可為空 (Amount cannot be empty)');
    }
    if (trimmed.startsWith('-')) {
      throw const AmountParseException(
          '金額不可為負數 (Negative amount is forbidden)');
    }
    if (trimmed.contains('e') || trimmed.contains('E')) {
      throw const AmountParseException(
        '不支援科學記號表示法，請輸入十進位數字 (Scientific notation is forbidden)',
      );
    }
    if (!_validDecimalPattern.hasMatch(trimmed)) {
      throw AmountParseException(
          '無效的十進位金額格式 (Invalid decimal amount): "$trimmed"');
    }

    final parts = trimmed.split('.');
    final wholeStr = parts[0];
    final fracStr = parts.length > 1 ? parts[1] : '';

    if (fracStr.length > decimals) {
      throw AmountParseException(
        '小數點位數超過上限：最多支援 $decimals 位小數，實際輸入 ${fracStr.length} 位',
      );
    }

    final paddedFrac = fracStr.padRight(decimals, '0');
    final combinedDigits = '$wholeStr$paddedFrac';
    final normalizedDigits = combinedDigits.replaceFirst(RegExp(r'^0+'), '');
    final result =
        normalizedDigits.isEmpty ? BigInt.zero : BigInt.parse(normalizedDigits);
    if (result >= (BigInt.one << 256)) {
      throw const AmountParseException('金額超過 256 位元整數上限');
    }

    if (!allowZero && result <= BigInt.zero) {
      throw const AmountParseException(
          '轉帳金額必須大於 0 (Amount must be greater than zero)');
    }

    return result;
  }

  /// Formats exact base units ([BigInt]) into a human-readable decimal string
  /// using pure [BigInt] integer division and remainder.
  static String formatBaseUnits(
    BigInt baseUnits, {
    required int decimals,
    int? maxFractionDigits,
  }) {
    if (decimals <= 0) {
      return baseUnits.toString();
    }
    final isNegative = baseUnits.isNegative;
    final absVal = baseUnits.abs();
    final divisor = BigInt.from(10).pow(decimals);
    final whole = absVal ~/ divisor;
    final rem = absVal % divisor;

    if (rem == BigInt.zero) {
      return '${isNegative ? "-" : ""}$whole';
    }

    String frac = rem.toString().padLeft(decimals, '0');
    if (maxFractionDigits != null &&
        maxFractionDigits >= 0 &&
        frac.length > maxFractionDigits) {
      frac = frac.substring(0, maxFractionDigits);
    }
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    if (frac.isEmpty) {
      return '${isNegative ? "-" : ""}$whole';
    }
    return '${isNegative ? "-" : ""}$whole.$frac';
  }
}
