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

  /// The chat page that is actually on screen right now. A notification is
  /// suppressed only when the app is foreground *and* this is the session the
  /// task belongs to; every other spot (list page, another chat, background)
  /// deserves a notification.
  String? _viewing;

  bool isViewing(String sessionId) => _foreground && _viewing == sessionId;

  /// The page is the current route, regardless of app foreground. Used to
  /// avoid stacking a second copy when a notification is tapped for the chat
  /// that is already open behind the lock screen.
  bool isShowing(String sessionId) => _viewing == sessionId;

  /// Register/unregister the chat page that became visible or was covered.
  void setViewing(String sessionId) {
    _viewing = sessionId;
  }

  /// Clear only if the caller still owns the slot (a pop can be reported after
  /// the next page has already claimed it).
  void clearViewing(String sessionId) {
    if (_viewing == sessionId) _viewing = null;
  }

  String? titleOf(String sessionId) => _rows[sessionId]?.title;

  String? parentOf(String sessionId) => _rows[sessionId]?.parentId;

  /// Running direct or indirect children (what the PC shows as "N subagent").
  int runningDescendants(String sessionId) {
    var count = 0;
    for (final entry in _rows.entries) {
      if (entry.key == sessionId || !entry.value.running) continue;
      if (_isDescendant(entry.key, sessionId)) count++;
    }
    return count;
  }

  bool _isBusy(String sessionId) {
    if (_rows[sessionId]?.running ?? false) return true;
    return runningDescendants(sessionId) > 0;
  }

  /// A session (or one of its subagents) is working right now. The chat page
  /// uses this when it attached mid-turn and has no live stream of its own yet.
  bool isRunning(String sessionId) => _isBusy(sessionId);

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    // Coming back or going away, the map may have missed the final status
    // frames while the phone dozed; re-read the baseline so a stale "running"
    // row can neither keep a green dot lit nor block the next notification.
    unawaited(_prime(refresh: true));
    notifyListeners();
  }

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

  Future<void> _prime({bool refresh = false}) async {
    final rpc = _rpc;
    if (rpc == null || _stopped) return;
    // `refresh` means the socket was silent for a while: whatever we latched
    // from events before is no longer authoritative, the HTTP baseline is.
    // Clearing first keeps a live frame that lands mid-request newer than it.
    if (refresh) _live.clear();
    try {
      final items = await rpc.listSessions();
      if (_stopped) return;
      // A session that ran and is idle again finished while the socket was
      // silent; that completion still deserves its notification.
      final completed = <String>[];
      for (final s in items) {
        final row = _rows.putIfAbsent(s.sessionId, _Row.new);
        row.title = s.title ?? row.title;
        row.parentId = s.parentSessionId ?? row.parentId;
        row.subagent = s.origin == 'subagent' || row.subagent;
        // A status event already seen is newer than this HTTP baseline.
        if (!_live.contains(s.sessionId)) {
          if (row.running && !s.running) completed.add(s.sessionId);
          row.running = s.running;
        }
      }
      notifyListeners();
      for (final id in completed) {
        _scheduleSettle(id);
      }
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
    // Titles/parent links may have changed while we were disconnected, and
    // status frames were missed: trust the baseline again.
    unawaited(_prime(refresh: true));
  }

  void _scheduleRetry() {
    if (_stopped) return;
    // We cannot see what happened while the socket was down; the next
    // baseline must win over the statuses latched before the drop.
    _live.clear();
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
    // Only a foreground app showing this exact conversation already has the
    // answer on screen. Foreground on the list, on another conversation, or in
    // the background all need the notification the user is waiting for.
    if (isViewing(root)) return;
    if (_isBusy(root)) return;
    final now = DateTime.now();
    final last = _notified[root];
    // Two turns can settle back-to-back; only collapse an immediate echo.
    if (last != null && now.difference(last).inSeconds < 3) return;
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
