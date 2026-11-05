import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../opencode/opencode_link.dart';

/// Full-screen QR scanner. Returns the scanned link to the caller, which routes
/// it by shape: dsh pairing or OpenCode's web UI.
///
/// dsh links carry a `token` query parameter — the CLI prints `/connect?token=…`
/// (v2 grant) while the plugin and the v1 flow print `/?token=…`; PairClient
/// normalizes either shape. OpenCode links are `<origin>/auth/connect/<code>`.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _handled = false;
  bool _hinted = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    var sawText = false;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      sawText = true;
      final uri = pairingUriFrom(raw) ?? openCodePairingUriFrom(raw);
      if (uri == null) continue;
      _handled = true;
      Navigator.pop(context, uri);
      return;
    }
    // Distinguishing "camera never decoded" from "decoded, wrong link" is the
    // whole diagnosis when a QR will not connect.
    if (sawText && !_hinted && mounted) {
      _hinted = true;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('识别到二维码，但不是 dsh / OpenCode 的配对链接'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描配对二维码')),
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MobileScanner(onDetect: _onDetect),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'PC 上用 dsh 扫码配对，或运行 opencode pair 扫 OpenCode 的二维码',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, shadows: [
                Shadow(blurRadius: 8, color: Colors.black),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pairing URL a scanned payload may carry.
///
/// Both shapes are valid: the dsh CLI prints `/connect?token=…` (v2 grant)
/// and the dsh plugin / v1 flow prints `/?token=…`. Only the scheme and a
/// non-empty `token` parameter matter — PairClient normalizes the rest.
Uri? pairingUriFrom(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final token = uri.queryParameters['token'];
  if (token == null || token.isEmpty) return null;
  return uri;
}
