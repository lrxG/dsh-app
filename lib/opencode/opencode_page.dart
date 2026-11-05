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

/// Open OpenCode's web UI for [urls] (a pairing link first, the saved origin
/// afterwards). Candidates are tried in order: `opencode pair` publishes every
/// address it knows, and only one of them is reachable from the phone.
Future<void> openOpenCode(BuildContext context, {required List<Uri> urls}) async {
  if (urls.isEmpty) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => OpenCodePage(urls: urls),
  ));
}

class OpenCodePage extends StatefulWidget {
  const OpenCodePage({super.key, required this.urls});

  final List<Uri> urls;

  @override
  State<OpenCodePage> createState() => _OpenCodePageState();
}

class _OpenCodePageState extends State<OpenCodePage> {
  late final WebViewController _controller;

  late List<Uri> _urls = widget.urls;
  int _index = 0;
  int _progress = 0;
  bool _loading = true;
  String? _error;

  Uri get _current => _urls[_index];

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
          if (!mounted) return;
          setState(() {
            _loading = false;
            _progress = 100;
          });
          // The pairing link redirects to the app itself; remember that origin
          // so the next visit needs no QR.
          unawaited(_rememberOrigin());
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
          _failOrNext('打不开 $_current\n${error.description}');
        },
      ))
      ..loadRequest(_current);
  }

  Future<void> _rememberOrigin() async {
    final url = await _controller.currentUrl();
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (uri.pathSegments.length >= 2 &&
        uri.pathSegments[0] == 'auth' &&
        uri.pathSegments[1] == 'connect') {
      return;
    }
    await OpenCodeStore().save(openCodeOriginOf(uri));
  }

  /// A dead candidate is not a failed connection: move on to the next address
  /// before telling the user anything.
  void _failOrNext(String message) {
    if (!mounted) return;
    if (_index + 1 < _urls.length) {
      setState(() {
        _index++;
        _loading = true;
        _error = null;
      });
      _controller.loadRequest(_current);
      return;
    }
    setState(() {
      _loading = false;
      _error = message;
    });
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
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (raw == null || !mounted) return;
    final urls = openCodePairingUrisFrom(raw);
    if (urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这不是 OpenCode 的配对二维码')),
      );
      return;
    }
    setState(() {
      _urls = urls;
      _index = 0;
      _error = null;
      _loading = true;
    });
    await _controller.loadRequest(_current);
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
