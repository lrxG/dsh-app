import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dsh_client.dart';
import 'mux_client.dart';
import 'notify.dart';

/// One pending `approval/request` delivered over the forwarded-event stream.
class PendingApproval {
  const PendingApproval({
    required this.eventId,
    required this.sessionId,
    required this.toolName,
    this.reason,
  });

  final String eventId;

  /// Agent id — for dsh an agent IS its session, so this matches `session/list`.
  final String sessionId;
  final String toolName;
  final String? reason;
}

/// Subscribes to the Gateway forwarded-event stream and answers approvals.
///
/// The stream is the only path that can claim an approval: dsh delivers
/// `approval/request` as a waterfall and expects the answer back through
/// `$events/result` (see `packages/api/gateway/src/client/remote-events.ts`).
class ApprovalCenter extends ChangeNotifier {
  ApprovalCenter._();

  static final ApprovalCenter instance = ApprovalCenter._();

  DshRpc? _rpc;
  MuxClient? _mux;
  StreamSubscription<MuxEvent>? _sub;
  Timer? _retry;
  String? _clientId;
  String? _origin;
  String? _cookie;
  bool _stopped = true;
  final List<PendingApproval> _pending = [];

  List<PendingApproval> get pending => List.unmodifiable(_pending);

  bool get isRunning => !_stopped && _mux != null;

  /// (Re)connect for one paired PC.
  Future<void> start({
    required String pcOrigin,
    required String cookieHeader,
  }) async {
    _origin = pcOrigin;
    _cookie = cookieHeader;
    _rpc = DshRpc(pcOrigin: pcOrigin, cookieHeader: cookieHeader);
    _stopped = false;
    await _dial();
  }

  Future<void> _dial() async {
    if (_stopped) return;
    _retry?.cancel();
    _clientId = null;
    final mux = MuxClient(pcOrigin: _origin!, cookieHeader: _cookie!);
    try {
      await mux.connect();
    } catch (_) {
      _scheduleRetry();
      return;
    }
    await _sub?.cancel();
    await _mux?.close();
    _mux = mux;
    _sub = mux.open(r'$events', const <String, dynamic>{}).listen(
      _onFrame,
      onError: (_) => _scheduleRetry(),
      onDone: _scheduleRetry,
      cancelOnError: true,
    );
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _clientId = null;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _dial);
  }

  void _onFrame(MuxEvent event) {
    if (event is! MuxItem) return;
    final frame = decodeRemoteEvent(event.value);
    switch (frame) {
      case null:
        return;
      case RemoteEventsReady(:final clientId):
        _clientId = clientId;
      case RemoteEventWaterfall(:final eventId, :final event, :final agentId, :final request):
        if (event != 'approval/request') return;
        if (_pending.any((p) => p.eventId == eventId)) return;
        _pending.add(PendingApproval(
          eventId: eventId,
          sessionId: agentId,
          toolName: '${request['toolName'] ?? '工具调用'}',
          reason: _reasonOf(request),
        ));
        notifyListeners();
        // Surface the request outside the app too.
        final reason = _reasonOf(request);
        Notifier.instance.show(
          title: 'DSH 请求权限',
          body: reason == null
              ? '${request['toolName'] ?? '工具调用'} 等待你的决定'
              : '${request['toolName'] ?? '工具调用'} · $reason',
        );
      case RemoteEventCancelled(:final eventId):
        _pending.removeWhere((p) => p.eventId == eventId);
        notifyListeners();
      case RemoteEventEmit():
        return;
    }
  }

  /// Prefer the localized presentation reason; fall back to the asker's text.
  static String? _reasonOf(Map request) {
    final display = request['displayReason'];
    if (display is Map) {
      for (final key in const ['zh', 'en']) {
        final value = display[key];
        if (value is String && value.isNotEmpty) return value;
      }
    }
    final reason = request['reason'];
    return reason is String && reason.isNotEmpty ? reason : null;
  }

  /// Answer one pending approval; `allow` maps to `allowed-once` / `rejected`.
  Future<void> decide(PendingApproval approval, {required bool allow}) async {
    final clientId = _clientId;
    final rpc = _rpc;
    if (clientId == null || rpc == null) return;
    try {
      await rpc.answerApproval(
        clientId: clientId,
        eventId: approval.eventId,
        allow: allow,
      );
    } finally {
      _pending.removeWhere((p) => p.eventId == approval.eventId);
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    _clientId = null;
    await _sub?.cancel();
    _sub = null;
    await _mux?.close();
    _mux = null;
    _pending.clear();
    notifyListeners();
  }
}
