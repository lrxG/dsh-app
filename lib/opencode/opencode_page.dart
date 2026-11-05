/// OpenCode's own web UI, embedded so the phone keeps a real session.
///
/// The server's login cookie lives 30 days and the WebView keeps it in the
/// app's cookie store, so — unlike a phone browser that clears cookies on
/// exit — reopening this page stays signed in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../pairing/scan_page.dart';
import 'opencode_link.dart';
import 'opencode_store.dart';

/// Open [url] (a pairing link the first time, the saved origin afterwards).
Future<void> openOpenCode(BuildContext context, {required String url}) async {
  final uri = Uri.tryParse(url);
  if (uri != null) unawaited(OpenCodeStore().save(openCodeOriginOf(uri)));
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => OpenCodePage(initialUrl: url),
  ));
}

class OpenCodePage extends StatefulWidget {
  const OpenCodePage({super.key, required this.initialUrl});

  final String initialUrl;

  @override
  State<OpenCodePage> createState() => _OpenCodePageState();
}

class _OpenCodePageState extends State<OpenCodePage> {
  late final WebViewController _controller;

  int _progress = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF2F2F7))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _loading = true;
              _error = null;
            });
          }
        },
        onPageFinished: (_) {
          if (mounted) {
            setState(() {
              _loading = false;
              _progress = 100;
            });
          }
        },
        onHttpError: (error) {
          final status = error.response?.statusCode;
          if (status == null || status < 400) return;
          if (mounted) {
            setState(() {
              _loading = false;
              _error = status == 404 || status == 410
                  ? '这个配对链接已经用过或过期了（5 分钟内有效），重新扫一次二维码。'
                  : 'OpenCode 返回 HTTP $status';
            });
          }
        },
        onWebResourceError: (error) {
          // Subresource failures (favicon, analytics) must not blank the page.
          if (error.isForMainFrame == false) return;
          if (mounted) {
            setState(() {
              _loading = false;
              _error = '打不开 ${widget.initialUrl}\n${error.description}';
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    await _controller.reload();
  }

  /// Pair with another OpenCode server without leaving the app.
  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<Uri>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (scanned == null || !mounted) return;
    if (!isOpenCodePairingUri(scanned)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这不是 OpenCode 的配对二维码')),
      );
      return;
    }
    unawaited(OpenCodeStore().save(openCodeOriginOf(scanned)));
    setState(() {
      _error = null;
      _loading = true;
    });
    await _controller.loadRequest(scanned);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else if (mounted) {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF2F2F7),
        appBar: AppBar(
          title: const Text('OpenCode'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              tooltip: '重新加载',
              onPressed: _reload,
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, size: 22),
              tooltip: '扫码换服务器',
              onPressed: _scan,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading)
              LinearProgressIndicator(
                value: _progress > 0 && _progress < 100 ? _progress / 100 : null,
                minHeight: 2,
                backgroundColor: const Color(0xFFE5E5EA),
                color: const Color(0xFF007AFF),
              ),
            Expanded(
              child: _error == null
                  ? WebViewWidget(controller: _controller)
                  : _errorView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded,
                size: 38, color: Color(0xFFC7C7CC)),
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, height: 1.5, color: Color(0xFF3A3A3C)),
            ),
            const SizedBox(height: 8),
            const Text(
              '确认手机和 PC 在同一个局域网；配对链接 5 分钟内有效。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.5, color: Color(0xFF8E8E93)),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _reload,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                minimumSize: const Size(140, 42),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('重试'),
            ),
            TextButton(
              onPressed: _scan,
              child: const Text(
                '重新扫码',
                style: TextStyle(fontSize: 14, color: Color(0xFF007AFF)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
