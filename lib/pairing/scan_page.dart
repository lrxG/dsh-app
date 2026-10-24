import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen QR scanner. Returns the scanned pairing URL to the caller.
///
/// Any http(s) URL carrying a `token` query parameter is accepted: the
/// dsh CLI prints `/connect?token=…` (v2 grant) while the dsh plugin and
/// the v1 flow print `/?token=…`. PairClient normalizes either shape.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final uri = pairingUriFrom(barcode.rawValue);
      if (uri == null) continue;
      _handled = true;
      Navigator.pop(context, uri);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描 PC 配对二维码')),
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MobileScanner(onDetect: _onDetect),
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '在 PC 上打开 dsh → 设置 →「扫码配对」，用手机扫描二维码',
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
