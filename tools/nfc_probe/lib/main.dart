import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const FcwNfcProbeApp());
}

class FcwNfcProbeApp extends StatelessWidget {
  const FcwNfcProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FCW NFC Hardware Probe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blueAccent,
        useMaterial3: true,
      ),
      home: const ProbeHomeScreen(),
    );
  }
}

class ProbeHomeScreen extends StatefulWidget {
  const ProbeHomeScreen({super.key});

  @override
  State<ProbeHomeScreen> createState() => _ProbeHomeScreenState();
}

class _ProbeHomeScreenState extends State<ProbeHomeScreen> {
  static const MethodChannel _channel = MethodChannel('com.mobilecoldwallet.nfc_probe/control');

  // Status variables
  bool _adapterPresent = false;
  bool _nfcEnabled = false;
  bool _readerActive = false;
  String _currentRole = 'HCE';
  String _runId = '';
  int _generation = 0;

  // Test Results
  Map<String, dynamic>? _lastSummary;
  Map<String, dynamic>? _lastTx;
  Map<String, dynamic>? _vaultReview;
  String _statusMessage = 'Ready. Please select role or tap Start.';
  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeCall);
    _refreshStatus();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    super.dispose();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'onRoleChanged':
        final data = jsonDecode(call.arguments as String);
        setState(() {
          _currentRole = data['role'] ?? _currentRole;
          _runId = data['run_id'] ?? _runId;
          _generation = data['generation'] ?? _generation;
        });
        break;
      case 'onProbeComplete':
        final summary = jsonDecode(call.arguments as String);
        // Strictly require non-null matching run_id AND positive matching generation (A2)
        final summaryRunId = summary['run_id'];
        final summaryGen = summary['generation'];
        if (summaryRunId is! String ||
            summaryRunId.isEmpty ||
            summaryRunId != _runId ||
            summaryGen is! int ||
            summaryGen <= 0 ||
            summaryGen != _generation) {
          // Discard completion missing run_id/generation or from a stale run/generation
          return;
        }
        setState(() {
          _lastSummary = summary;
          final allPassed = summary['all_passed'] == true;
          final status = summary['status'] ?? (allPassed ? 'PASSED' : 'FAILED');
          _statusMessage = allPassed ? 'PROBE PASSED' : 'PROBE FAILED ($status)';
        });
        break;
      case 'onTxComplete':
        final tx = jsonDecode(call.arguments as String);
        final txRunId = tx['run_id'];
        final txGen = tx['generation'];
        if (txRunId is! String || txRunId != _runId || txGen is! int || txGen <= 0 || txGen != _generation) {
          return;
        }
        setState(() {
          _lastTx = tx;
          _statusMessage = 'NFC TX: ${tx['status']}';
        });
        break;
      case 'onVaultReviewChanged':
        final review = jsonDecode(call.arguments as String) as Map<String, dynamic>;
        final incomingSeq = review['review_seq'];
        final currentSeq = _vaultReview?['review_seq'];
        if (incomingSeq is int && currentSeq is int && incomingSeq < currentSeq) {
          // Ignore stale out-of-order review notification
          return;
        }
        setState(() {
          _vaultReview = review;
          if (review['state'] == 'PENDING_LOCAL_REVIEW') {
            _statusMessage = 'Vault: signing request received - review below';
          } else {
            _statusMessage = 'Vault: ${review['state']} (${review['state_reason'] ?? ''})';
          }
        });
        break;
    }
  }

  Future<void> _startTx() async {
    try {
      await _channel.invokeMethod('startTxSession');
      if (!mounted) return;
      setState(() {
        _lastTx = null;
        _statusMessage = 'NFC TX armed. Touch 1: Tap Vault phone to send request. Touch 2: Tap again after Vault approval.';
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start NFC TX: $e')));
      }
    }
  }

  Future<void> _decideVault(bool approve) async {
    final review = _vaultReview;
    final handleId = review?['handle_id'];
    if (handleId is! String || handleId.isEmpty) return;
    try {
      final res = await _channel.invokeMethod(
        approve ? 'approvePendingVaultTx' : 'rejectPendingVaultTx',
        {
          'handle_id': handleId,
          'request_id': review?['request_id'],
          'payload_sha256': review?['payload_sha256'],
          'signing_digest': review?['signing_digest'],
          'chain_id': review?['chain_id'],
          'expected_signer': review?['expected_signer'],
          'run_id': review?['run_id'],
          'generation': review?['generation'],
          'review_seq': review?['review_seq'],
        },
      );
      final refreshed = await _channel.invokeMethod<String>('getVaultReview');
      if (!mounted) return;
      setState(() {
        if (refreshed != null) _vaultReview = jsonDecode(refreshed) as Map<String, dynamic>;
        _statusMessage = approve ? 'Vault approve result: $res' : 'Vault rejected request';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vault decision failed: $e')));
      }
    }
  }

  Future<void> _refreshStatus() async {
    try {
      final res = await _channel.invokeMethod<String>('getNfcStatus');
      if (res != null && mounted) {
        final map = jsonDecode(res) as Map<String, dynamic>;
        setState(() {
          _adapterPresent = map['adapter_present'] == true;
          _nfcEnabled = map['nfc_enabled'] == true;
          _readerActive = map['reader_active'] == true;
          _currentRole = map['current_role'] ?? 'HCE';
          _runId = map['current_run_id'] ?? '';
          _generation = map['current_generation'] ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _setRole(String role) async {
    try {
      await _channel.invokeMethod('setRole', {'role': role});
      if (!mounted) return;
      setState(() {
        _lastSummary = null;
        _statusMessage = 'Switched to $role. Waiting for RF interaction...';
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to set role: $e')),
        );
      }
    }
  }

  Future<void> _startProbe() async {
    try {
      await _channel.invokeMethod('startProbe');
      if (!mounted) return;
      setState(() {
        _lastSummary = null;
        _statusMessage = 'Reader mode active. Tap target HCE device to probe...';
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start probe: $e')),
        );
      }
    }
  }

  Future<void> _cancelProbe() async {
    try {
      await _channel.invokeMethod('cancelProbe');
      if (!mounted) return;
      setState(() {
        _lastSummary = null;
        _statusMessage = 'Probe cancelled by user.';
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to cancel probe: $e')),
        );
      }
    }
  }

  Future<void> _resetSession() async {
    try {
      await _channel.invokeMethod('resetRunSession');
      if (!mounted) return;
      setState(() {
        _lastSummary = null;
        _statusMessage = 'Session reset. Ready for clean probe run.';
      });
      await _refreshStatus();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reset session: $e')),
        );
      }
    }
  }

  Future<void> _exportEvidence([String? requestedRunId]) async {
    try {
      final bundleRaw = await _channel.invokeMethod<String>(
        'exportPersistentEvidence',
        requestedRunId != null ? {'run_id': requestedRunId} : null,
      );
      final Map<String, dynamic> bundle = bundleRaw != null
          ? jsonDecode(bundleRaw) as Map<String, dynamic>
          : (_lastSummary ?? <String, dynamic>{});
      final evidenceStatus = bundle['evidence_status'] ?? 'OK';
      final evidenceStr = const JsonEncoder.withIndent('  ').convert(bundle);
      await Clipboard.setData(ClipboardData(text: evidenceStr));
      if (!mounted) return;
      if (evidenceStatus != 'OK') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red[800],
            content: Text('Evidence integrity/write error ($evidenceStatus): ${bundle['evidence_error'] ?? "check bundle"}'),
          ),
        );
      } else {
        final reportPath = bundle['report_json_path'] ?? bundle['evidence_file_path'] ?? 'local storage';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Persistent evidence verified ($reportPath) & copied to clipboard.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export persistent evidence: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FCW NFC Hardware Probe'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Status',
            onPressed: _refreshStatus,
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset Session',
            onPressed: _resetSession,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildHardwareStatusCard(),
          const SizedBox(height: 16),
          _buildControlsCard(),
          const SizedBox(height: 16),
          _buildRoleSelectorCard(),
          const SizedBox(height: 16),
          if (_currentRole == 'HCE') _buildVaultReviewCard(),
          if (_currentRole == 'READER') _buildTxResultCard(),
          const SizedBox(height: 16),
          _buildProgressCard(),
          const SizedBox(height: 16),
          _buildReportCard(),
        ],
      ),
    );
  }

  Widget _buildHardwareStatusCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hardware & NFC Subsystem',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            _buildStatusRow('NFC Hardware Present', _adapterPresent),
            _buildStatusRow('NFC Setting Enabled', _nfcEnabled),
            _buildStatusRow('Reader Mode Active', _readerActive),
            const SizedBox(height: 8),
            Text('Current Role: $_currentRole', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Run ID: ${_runId.isEmpty ? "None" : _runId}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('Generation: $_generation', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            Text('Status: $_statusMessage', style: const TextStyle(fontSize: 13, color: Colors.amberAccent)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String title, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title),
          Icon(
            active ? Icons.check_circle : Icons.cancel,
            color: active ? Colors.greenAccent : Colors.redAccent,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildControlsCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Probe Execution Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[700],
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Probe'),
                    onPressed: _startProbe,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[800],
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.stop),
                    label: const Text('Cancel Probe'),
                    onPressed: _cancelProbe,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo[600],
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send_to_mobile),
                label: const Text('Start NFC Tx (public test vector)'),
                onPressed: _startTx,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleSelectorCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'RF Role Selection & Phase Guidance',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _currentRole == 'READER' ? Colors.blueAccent : Colors.grey[800],
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.nfc),
                    label: const Text('Reader Mode'),
                    onPressed: () => _setRole('READER'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _currentRole == 'HCE' ? Colors.teal : Colors.grey[800],
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.credit_card),
                    label: const Text('HCE Vault Mode'),
                    onPressed: () => _setRole('HCE'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _currentRole == 'READER'
                  ? 'Role: Initiator. Bring target HCE device close to initiate AID SELECT, chunk echo, and digest verification.'
                  : 'Role: Target. Emulates Vault APDU service (AID F046435701). Keeps listening for incoming Reader APDUs.',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const Divider(),
            const Text(
              'Dual-Device Physical Validation Guidance:\n'
              '• Phase 1: Device A (Reader) -> Device B (HCE)\n'
              '• Phase 2: Device B (Reader) -> Device A (HCE)\n'
              'Align phone NFC antennas back-to-back until vibration confirms RF link.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard() {
    final summary = _lastSummary;
    final hasRun = summary != null;
    final allPassed = hasRun && summary['all_passed'] == true;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Verification Checklist',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Chip(
                  label: Text(
                    hasRun ? (allPassed ? 'ALL PASSED' : 'FAILED') : 'WAITING RF',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  backgroundColor: hasRun
                      ? (allPassed ? Colors.green[800] : Colors.red[800])
                      : Colors.grey[800],
                ),
              ],
            ),
            const Divider(),
            _buildCheckItem('SELECT AID (Cap 1.0, MaxChunk 128)', summary?['select_passed']),
            _buildCheckItem('32B Chunk Echo & SHA-256', summary?['test_32b_passed']),
            _buildCheckItem('512B (4x128B) Echoes & SHA-256', summary?['test_512b_passed']),
            _buildCheckItem('4KiB (32x128B) Echoes & SHA-256', summary?['test_4kib_passed']),
            _buildCheckItem('Neg: Unknown AID Rejection (6A82)', summary?['neg_routing_passed']),
            _buildCheckItem('Neg: Invalid INS Rejection (6D00)', summary?['neg_ins_passed']),
            _buildCheckItem('Neg: Invalid P1 Rejection (6A86)', summary?['neg_p1_passed']),
            _buildCheckItem('Neg: Oversized Chunk Rejection (6700)', summary?['neg_oversized_passed']),
            if (hasRun && summary?['total_duration_ms'] != null) ...[
              const SizedBox(height: 8),
              Text(
                'Measured RF Duration: ${summary['total_duration_ms']} ms',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.lightBlueAccent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCheckItem(String title, dynamic passed) {
    IconData icon;
    Color color;
    if (passed == true) {
      icon = Icons.check_circle;
      color = Colors.greenAccent;
    } else if (passed == false) {
      icon = Icons.cancel;
      color = Colors.redAccent;
    } else {
      icon = Icons.radio_button_unchecked;
      color = Colors.grey;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildVaultReviewCard() {
    final review = _vaultReview;
    final state = review?['state'] ?? 'NONE';
    final pending = state == 'PENDING_LOCAL_REVIEW';
    final summary = review?['summary'];
    return Card(
      elevation: 2,
      color: pending ? Colors.orange[900] : null,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vault: Local Review of NFC Signing Request',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Divider(),
            Text('State: $state', style: const TextStyle(fontWeight: FontWeight.bold)),
            if (review?['request_id'] != null) Text('Request ID: ${review!['request_id']}', style: const TextStyle(fontSize: 12)),
            if (review?['signing_digest'] != null)
              SelectableText('Signing digest: ${review!['signing_digest']}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            if (summary != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                color: Colors.black45,
                child: SelectableText(const JsonEncoder.withIndent('  ').convert(summary),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            const SizedBox(height: 8),
            const Text('Only this Vault screen can approve. The NFC peer can request, poll or cancel, never approve.',
                style: TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700], foregroundColor: Colors.white),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve & Sign'),
                    onPressed: pending ? () => _decideVault(true) : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[800], foregroundColor: Colors.white),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                    onPressed: pending ? () => _decideVault(false) : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTxResultCard() {
    final tx = _lastTx;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Wallet: NFC Transaction Result', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Divider(),
            SelectableText(
              tx != null
                  ? const JsonEncoder.withIndent('  ').convert(tx)
                  : 'No NFC transaction yet. Tap "Start NFC Tx", then hold the Vault phone to this phone.',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReportCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Probe Evidence Log',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey[700],
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Export JSON'),
                  // Always enabled: HCE/Vault devices have no Reader summary but still persist evidence.
                  onPressed: _exportEvidence,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _lastSummary != null
                    ? const JsonEncoder.withIndent('  ').convert(_lastSummary)
                    : 'No test run completed yet.\nTap two physical devices together to perform RF probe.',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
