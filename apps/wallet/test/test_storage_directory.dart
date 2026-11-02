import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Provides each test history with an isolated real directory for import guards.
String testHistoryPath() {
  final directory = Directory.systemTemp.createTempSync('wallet_history_test_');
  addTearDown(() => directory.deleteSync(recursive: true));
  return '${directory.path}/history.json';
}
