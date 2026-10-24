import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';

import '../pairing/pair_client.dart';

/// Frame received on one opened logical stream (host → client half of
/// `RemoteStreamServerMessage`, packages/api/gateway/src/stream-protocol.ts).
sealed class MuxEvent {
  const MuxEvent(this.streamId);

  final String streamId;
}

class MuxItem extends MuxEvent {
  const MuxItem(super.streamId, this.value);

  final dynamic value;
}

class MuxError extends MuxEvent {
  const MuxError(super.streamId, this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class MuxEnd extends MuxEvent {
  const MuxEnd(super.streamId);
}

/// Client half of the Gateway-owned `/api/remote.mux` WebSocket.
///
/// Client sends: {open(streamId,endpoint,payload) | item | end | cancel}
/// Host replies: {item | error | end} — all logical streams multiplex one socket.
class MuxClient {
  MuxClient({required this.pcOrigin, required this.cookieHeader});

  final String pcOrigin;
  final String cookieHeader;

  IOWebSocketChannel? _channel;
  final Map<String, StreamController<MuxEvent>> _streams = {};
  int _seq = 0;
  bool _closedByUs = false;

  /// Idempotent; resolves the channel from the pairing result (ws + cookie).
  Future<void> connect() async {
    if (_channel != null) return;
    _closedByUs = false;
    final pair = PairResult(
      ok: true,
      pcOrigin: pcOrigin,
      cookieHeader: cookieHeader,
    );
    _channel = IOWebSocketChannel.connect(
      pair.muxUrl,
      headers: {'cookie': cookieHeader},
      pingInterval: const Duration(seconds: 15),
    );
    _channel!.stream.listen(_onFrame, onError: _propagateAll, onDone: _propagateAll);
  }

  /// Open one logical stream; returns its item stream (auto-error/end closes).
  Stream<MuxEvent> open(String endpoint, Map<String, dynamic> args) {
    final streamId = 'lb-${_seq++}-${_randomTag()}';
    final controller = StreamController<MuxEvent>();
    _streams[streamId] = controller;
    _send({
      'type': 'open',
      'streamId': streamId,
      'endpoint': endpoint,
      'payload': {'args': args},
    });
    return controller.stream;
  }

  /// Open the durable follow stream of one session.
  Stream<MuxEvent> followSession(String sessionId, {int maxMessages = 50}) =>
      open('session/follow', {
        'request': {
          'address': {'kind': 'session', 'sessionId': sessionId},
          'maxMessages': maxMessages,
          'assistantStream': true,
        },
      });

  /// One-shot `workspace/follow` baseline: PC's workspace titles and the
  /// registry-global archived set, which `session/list` does not carry.
  ///
  /// The stream is cancelled right after the baseline frame, so the socket
  /// carries no long-lived subscription.
  Future<WorkspaceSnapshot?> fetchWorkspaceSnapshot({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final events = open('workspace/follow', const <String, dynamic>{})
          .timeout(timeout);
      await for (final event in events) {
        if (event is MuxItem) {
          final value = event.value;
          if (value is Map &&
              value['type'] == 'baseline' &&
              value['value'] is Map) {
            return WorkspaceSnapshot.fromWire(value['value'] as Map);
          }
        } else if (event is MuxError || event is MuxEnd) {
          return null;
        }
      }
    } catch (_) {
      // Timeout, dead socket, or a host without the workspace plugin.
    }
    return null;
  }

  void _onFrame(dynamic raw) {
    Object? decoded;
    try {
      decoded = raw is List<int> ? jsonDecode(utf8.decode(raw)) : jsonDecode('$raw');
    } catch (_) {
      return; // non-JSON control noise: ignore
    }
    if (decoded is! Map) return _propagateAll();
    final streamId = decoded['streamId'];
    final controller = streamId is String ? _streams[streamId] : null;
    if (controller == null) return;
    switch (decoded['type']) {
      case 'item':
        controller.add(MuxItem(streamId, decoded['value']));
      case 'error':
        final err = decoded['error'] as Map? ?? const {};
        controller.add(MuxError(
          streamId,
          '${err['code'] ?? 'mux/error'}',
          '${err['message'] ?? 'unknown'}',
        ));
        _close(streamId);
      case 'end':
        controller.add(MuxEnd(streamId));
        _close(streamId);
      default:
        _propagateAll();
    }
  }

  void _close(String streamId) {
    _streams.remove(streamId)?.close();
  }

  void _propagateAll([Object? _]) {
    // The socket is gone (error or done). Drop the channel so the next
    // connect() re-dials a fresh WebSocket instead of writing into the dead
    // one — otherwise reconnect hangs forever at "等待同步…".
    if (!_closedByUs) _channel = null;
    for (final id in List.of(_streams.keys)) {
      _streams[id]?.addError(SocketClosed(_closedByUs));
    }
    for (final kv in _streams.entries.toList()) {
      kv.value.close();
      _streams.remove(kv.key);
    }
  }

  void _send(Map<String, dynamic> message) {
    final sink = _channel?.sink;
    if (sink == null) throw StateError('MuxClient not connected');
    sink.add(jsonEncode(message));
  }

  Future<void> close() async {
    _closedByUs = true;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  /// Unique enough without a dependency.
  static String _randomTag() {
    final r = Random();
    return List.generate(8, (_) => '0123456789abcdef'[r.nextInt(16)]).join();
  }
}

/// One decoded frame from the Gateway forwarded-event stream (`$events`).
///
/// Wire contract: `packages/api/gateway/src/stream-protocol.ts`
/// (`RemoteEventDownlinkFrame`).
sealed class RemoteEventFrame {
  const RemoteEventFrame();
}

/// Opening frame: the event generation is live; `clientId` correlates replies.
class RemoteEventsReady extends RemoteEventFrame {
  const RemoteEventsReady(this.clientId);

  final String clientId;
}

/// A pending Agent-scoped waterfall (e.g. `approval/request`) to answer.
class RemoteEventWaterfall extends RemoteEventFrame {
  const RemoteEventWaterfall({
    required this.eventId,
    required this.event,
    required this.agentId,
    required this.request,
  });

  final String eventId;
  final String event;
  final String agentId;
  final Map request;
}

/// A Host notification (`emit`) — no answer expected.
class RemoteEventEmit extends RemoteEventFrame {
  const RemoteEventEmit(this.event, this.args);

  final String event;
  final List args;
}

/// The Host withdrew a pending waterfall by id.
class RemoteEventCancelled extends RemoteEventFrame {
  const RemoteEventCancelled(this.eventId);

  final String eventId;
}

/// Decode one `$events` item; null for malformed or unknown frames.
RemoteEventFrame? decodeRemoteEvent(Object? value) {
  if (value is! Map) return null;
  switch (value['type']) {
    case 'ready':
      final clientId = value['clientId'];
      return clientId is String && clientId.isNotEmpty
          ? RemoteEventsReady(clientId)
          : null;
    case 'waterfall':
      final eventId = value['eventId'];
      final event = value['event'];
      final agentId = value['agentId'];
      final request = value['request'];
      if (eventId is! String || event is! String || request is! Map) {
        return null;
      }
      return RemoteEventWaterfall(
        eventId: eventId,
        event: event,
        agentId: agentId is String ? agentId : '',
        request: request,
      );
    case 'emit':
      final event = value['event'];
      final args = value['args'];
      return event is String
          ? RemoteEventEmit(event, args is List ? args : const [])
          : null;
    case 'cancel':
      final eventId = value['eventId'];
      return eventId is String ? RemoteEventCancelled(eventId) : null;
    default:
      return null;
  }
}

/// Socket dropped before a stream finished (phone asleep, PC restart…).
class SocketClosed implements Exception {
  SocketClosed(this.byUs);

  final bool byUs;

  @override
  String toString() => byUs ? 'socket closed by us' : 'socket closed (PC 重启或网络断开)';
}

/// One Workspace registry entry (`WorkspaceView` in dsh workspace-controller).
///
/// The sidebar groups by this registry: `title` is user-renameable, and
/// `sessionIds` is the authoritative membership list — not a cwd guess.
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
  });

  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;

  static WorkspaceInfo? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['workspaceId'];
    final path = raw['path'];
    final title = raw['title'];
    if (id is! String || path is! String) return null;
    final ids = raw['sessionIds'];
    return WorkspaceInfo(
      workspaceId: id,
      path: path,
      title: title is String && title.isNotEmpty ? title : path,
      sessionIds: ids is List ? ids.map((e) => '$e').toList() : const [],
    );
  }
}

/// Baseline of the PC's Workspace registry.
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.items,
    required this.archivedSessionIds,
    required this.pinnedSessionIds,
  });

  /// Registry order — the PC sidebar renders Workspaces in this sequence.
  final List<WorkspaceInfo> items;

  /// Sessions hidden from grouping surfaces (PC's "archive" action).
  final Set<String> archivedSessionIds;

  /// Sessions pinned ahead of unpinned rows, most recently pinned first.
  final List<String> pinnedSessionIds;

  static WorkspaceSnapshot fromWire(Map value) {
    final rawItems = value['items'];
    final rawArchived = value['archivedSessionIds'];
    final rawPinned = value['pinnedSessionIds'];
    return WorkspaceSnapshot(
      items: rawItems is List
          ? rawItems.map(WorkspaceInfo.fromWire).whereType<WorkspaceInfo>().toList()
          : const [],
      archivedSessionIds: rawArchived is List
          ? rawArchived.map((e) => '$e').toSet()
          : const {},
      pinnedSessionIds: rawPinned is List
          ? rawPinned.map((e) => '$e').toList()
          : const [],
    );
  }
}
