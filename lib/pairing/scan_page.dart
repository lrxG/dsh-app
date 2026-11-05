import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../opencode/opencode_link.dart';

/// Full-screen QR scanner. Returns the raw payload to the caller, which routes
/// it by shape: dsh pairing link or OpenCode pairing payload.
///
/// dsh links carry a `token` query parameter — the CLI prints `/connect?token=…`
/// (v2 grant) while the plugin and the v1 flow print `/?token=…`; PairClient
/// normalizes either shape. OpenCode's QR is a JSON payload, see
/// `opencode_link.dart`.
///
/// The camera is not the only source: a QR saved in the photo album (or a
/// screenshot of the PC terminal) can be decoded too.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  final ImagePicker _picker = ImagePicker();

  bool _handled = false;
  bool _hinted = false;
  bool _picking = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// True when [raw] is a pairing payload either product understands.
  bool _accept(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    return pairingUriFrom(raw) != null ||
        openCodePairingUrisFrom(raw).isNotEmpty;
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    var sawText = false;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      sawText = true;
      if (!_accept(raw)) continue;
      _handled = true;
      Navigator.pop(context, raw);
      return;
    }
    // Distinguishing "camera never decoded" from "decoded, wrong link" is the
    // whole diagnosis when a QR will not connect.
    if (sawText) _hint();
  }

  void _hint() {
    if (_hinted || !mounted) return;
    _hinted = true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('识别到二维码，但不是 dsh / OpenCode 的配对码'),
    ));
  }

  /// Decode a QR from a saved image — the fallback when the camera will not
  /// lock onto the PC screen.
  Future<void> _pickImage() async {
    if (_picking || _handled) return;
    setState(() => _picking = true);
    try {
      final file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null || !mounted) return;
      final capture = await _controller.analyzeImage(file.path);
      for (final barcode in capture?.barcodes ?? const <Barcode>[]) {
        final raw = barcode.rawValue;
        if (!_accept(raw)) continue;
        _handled = true;
        if (mounted) Navigator.pop(context, raw);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这张图片里没有 dsh / OpenCode 的配对码'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('读取图片失败，换一张再试')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描配对二维码')),
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'PC 上用 dsh 扫码配对，或运行 opencode pair 扫 OpenCode 的二维码',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.5,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: _picking ? null : _pickImage,
                    icon: const Icon(Icons.photo_library_outlined, size: 20),
                    label: Text(_picking ? '正在识别…' : '从相册选择二维码'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1C1C1E),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pairing URL a scanned dsh payload may carry.
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
