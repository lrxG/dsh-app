import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../pairing/pair_client.dart';

/// v0.1 "keep-alive probe": opens the owner-peer Mux WebSocket with the
/// pairing cookie and reports exactly what the Host says back. UI for the
/// real session list / chat lands once the typert endpoints are mapped.
class AlivePage extends StatefulWidget {
  const AlivePage({
    super.key,
    required this.pcOrigin,
    required this.cookieHeader,
  });

  final String pcOrigin;
  final String cookieHeader;

  @override
  State<AlivePage> createState() => _AlivePageState();
}

class _AlivePageState extends State<AlivePage> {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final List<String> _log = [];
  String _state = '未连接';
  Color _stateColor = Colors.grey;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final result = PairResult(
      ok: true,
      pcOrigin: widget.pcOrigin,
      cookieHeader: widget.cookieHeader,
    );
    final url = result.muxUrl;
    _logLine('→ WS $url');
    setState(() => _state = '连接中…');
    try {
      final channel = IOWebSocketChannel.connect(
        url,
        headers: {HttpHeaders.cookieHeader: widget.cookieHeader},
        pingInterval: const Duration(seconds: 15),
      );
      setState(() {
        _channel = channel;
        _state = '已升级：等待 Host 帧';
        _stateColor = Colors.orange;
      });
      _sub = channel.stream.listen(
        (frame) {
          final text = frame is List<int> ? utf8.decode(frame) : '$frame';
          _logLine('← $text');
          setState(() {
            _state = '收到 Host 帧';
            _stateColor = Colors.green;
          });
        },
        onError: (Object e) {
          _logLine('× $e');
          setState(() {
            _state = 'WS 错误';
            _stateColor = Colors.red;
          });
        },
        onDone: () {
          _logLine('· channel closed');
          setState(() {
            _state = '已断开（PC 重启→token 已轮换，请重新扫码）';
            _stateColor = Colors.red;
          });
        },
      );
    } on WebSocketException catch (e) {
      setState(() => _state = 'WS 创建失败：${e.message}');
      _stateColor = Colors.red;
    }
  }

  void _logLine(String line) {
    setState(() {
      _log.insert(0, '${DateTime.now().toIso8601String().substring(11)}  $line');
      if (_log.length > 100) _log.removeLast();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('会话同步（探针）')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.circle, color: _stateColor, size: 12),
              const SizedBox(width: 8),
              Expanded(child: Text(_state)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _log.isEmpty
                ? const Center(child: Text('等待 Mux 帧…'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => SelectionText(_log[i]),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton(
              onPressed: () {
                _sub?.cancel();
                _channel?.sink.close();
                setState(() { _log.clear(); });
                _probe();
              },
              child: const Text('重连'),
            ),
          ),
        ],
      ),
    );
  }
}

class SelectionText extends StatelessWidget {
  const SelectionText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
  }
}
