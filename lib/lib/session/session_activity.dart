import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dsh_client.dart';
import 'mux_client.dart';
import 'notify.dart';

/// One agent row as far as the activity map is concerned.
class _Row {
  String? title;
  String? parentId;
  bool subagent = false;
  bool running = false;
}

/// App-wide live view of every session's agent status.
///
/// dsh reports `api-session/status` per **agent**, so a parent that dispatched
/// work to subagents is idle while its children run. The PC sidebar derives
/// "N subagent running" from the child rows; this class does the same, and
/// then uses the derived subtree state for two things:
///
///  * the list row dot (busy while any descendant runs),
///  * one completion notification per **main** session once the whole subtree
///    goes quiet (children never notify on their own).
///
/// Data comes from the forwarded-event stream `$events` (already used for
/// approvals) plus a `session/list` baseline for titles and parent links.
class SessionActivity extends ChangeNotifier {
  SessionActivity._();

  static final SessionActivity instance = SessionActivity._();

  final Map<String, _Row> _rows = {};
  final Set<String> _live = {};
  final Map<String, DateTime> _notified = {};
  final Set<Timer> _checks = {};

  DshRpc? _rpc;
  MuxClient? _mux;
  StreamSubscription<MuxEvent>? _sub;
  Timer? _retry;
  String? _origin;
  String? _cookie;
  bool _stopped = true;
  bool _foreground = true;

  /// Session currently open in a chat page, for notification suppression.
  String? activeSessionId;

  String? get pcOrigin => _origin;
  String? get cookieHeader => _cookie;

  /// True while the session itself or any of its descendants runs.
  bool isBusy(String sessionId) {
    if (_rows[sessionId]?.running ?? false) return true;
    return runningDescendants(sessionId) > 0;
  }

  /// Running direct or indirect children (what the PC shows as "N subagent").
  int runningDescendants(String sessionId) {
    var count = 0;
    for (final entry in _rows.entries) {
      if (entry.key == sessionId || !entry.value.running) continue;
      if (_isDescendant(entry.key, sessionId)) count++;
    }
    return count;
  }

  String? titleOf(String sessionId) => _rows[sessionId]?.title;

  String? parentOf(String sessionId) => _rows[sessionId]?.parentId;

  bool isSubagent(String sessionId) => _rows[sessionId]?.subagent ?? false;

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    notifyListeners();
  }

  bool get isForeground => _foreground;

  /// (Re)connect for one paired PC.
  Future<void> start({
    required String pcOrigin,
    required String cookieHeader,
  }) async {
    if (!_stopped && _origin == pcOrigin && _cookie == cookieHeader) return;
    await stop();
    _origin = pcOrigin;
    _cookie = cookieHeader;
    _stopped = false;
    _rpc = DshRpc(pcOrigin: pcOrigin, cookieHeader: cookieHeader);
    await _prime();
    await _dial();
  }

  Future<void> _prime() async {
    final rpc = _rpc;
    if (rpc == null) return;
    try {
      final items = await rpc.listSessions();
      if (_stopped) return;
      for (final s in items) {
        final row = _rows.putIfAbsent(s.sessionId, _Row.new);
        row.title = s.title ?? row.title;
        row.parentId = s.parentSessionId ?? row.parentId;
        row.subagent = s.origin == 'subagent' || row.subagent;
        // A status event already seen is newer than this HTTP baseline.
        if (!_live.contains(s.sessionId)) row.running = s.running;
      }
      notifyListeners();
    } catch (_) {
      // Offline or mid-restart: events still arrive once the socket is up.
    }
  }

  Future<void> _dial() async {
    if (_stopped) return;
    _retry?.cancel();
    final mux = MuxClient(pcOrigin: _origin!, cookieHeader: _cookie!);
    try {
      await mux.connect();
    } catch (_) {
      _scheduleRetry();
      return;
    }
    if (_stopped) {
      await mux.close();
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
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _dial);
  }

  void _onFrame(MuxEvent event) {
    if (event is! MuxItem) return;
    final frame = decodeRemoteEvent(event.value);
    switch (frame) {
      case RemoteEventEmit(:final event, :final args):
        switch (event) {
          case 'api-session/status':
            if (args.length < 2 || args[0] is! String) return;
            _applyStatus(args[0] as String, args[1] == true);
          case 'api-session/added':
            if (args.isEmpty || args[0] is! Map) return;
            _applySummary(SessionSummary.fromWire(args[0] as Map));
          case 'api-session/removed':
            if (args.isEmpty || args[0] is! String) return;
            // A durable child keeps its row on the PC; it is just no longer
            // live. Treat it as stopped so notifications can settle.
            _applyStatus(args[0] as String, false);
        }
      case RemoteEventsReady():
      case RemoteEventWaterfall():
      case RemoteEventCancelled():
      case null:
        return;
    }
  }

  void _applySummary(SessionSummary summary) {
    if (summary.sessionId.isEmpty) return;
    final row = _rows.putIfAbsent(summary.sessionId, _Row.new);
    row.title = summary.title ?? row.title;
    row.parentId = summary.parentSessionId ?? row.parentId;
    row.subagent = summary.origin == 'subagent' || row.subagent;
    if (!_live.contains(summary.sessionId)) row.running = summary.running;
    notifyListeners();
  }

  void _applyStatus(String sessionId, bool running) {
    final row = _rows.putIfAbsent(sessionId, _Row.new);
    final was = row.running;
    row.running = running;
    _live.add(sessionId);
    if (was != running) notifyListeners();
    if (was && !running) _scheduleSettle(sessionId);
  }

  /// Give a settlement turn a moment to wake the parent before deciding the
  /// whole family is done; otherwise "child finished" and "parent handled the
  /// notice" would each fire a notification.
  void _scheduleSettle(String sessionId) {
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 2500), () {
      _checks.remove(timer);
      _settled(sessionId);
    });
    _checks.add(timer);
  }

  void _settled(String sessionId) {
    if (_stopped) return;
    final root = _rootOf(sessionId);
    if (_rows[root]?.subagent ?? false) return; // subagents serve the session
    // Never interrupt someone who is already looking at this conversation.
    if (activeSessionId == root) return;
    if (_foreground) return;
    if (isBusy(root)) return;
    final now = DateTime.now();
    final last = _notified[root];
    if (last != null && now.difference(last).inSeconds < 10) return;
    _notified[root] = now;
    Notifier.instance.show(
      title: _rows[root]?.title ?? 'DSH 会话',
      body: '任务已完成 · 点按查看',
      sessionId: root,
    );
  }

  String _rootOf(String sessionId) {
    var current = sessionId;
    final seen = <String>{current};
    while (true) {
      final parent = _rows[current]?.parentId;
      if (parent == null || parent.isEmpty || !seen.add(parent)) return current;
      current = parent;
      if (seen.length > 32) return current;
    }
  }

  bool _isDescendant(String candidate, String ancestor) {
    var current = _rows[candidate]?.parentId;
    final seen = <String>{candidate};
    while (current != null && current.isNotEmpty && seen.add(current)) {
      if (current == ancestor) return true;
      current = _rows[current]?.parentId;
    }
    return false;
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    for (final timer in _checks) {
      timer.cancel();
    }
    _checks.clear();
    await _sub?.cancel();
    _sub = null;
    await _mux?.close();
    _mux = null;
    _rows.clear();
    _live.clear();
    _notified.clear();
    notifyListeners();
  }
}
