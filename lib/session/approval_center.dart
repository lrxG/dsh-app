import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dsh_client.dart';
import 'interactions.dart';
import 'mux_client.dart';
import 'notify.dart';

/// One decision the PC is blocked on: an approval prompt or a question.
sealed class PendingInteraction {
  const PendingInteraction({required this.eventId, required this.sessionId});

  /// Correlates the answer with the Host's pending waterfall.
  final String eventId;

  /// Agent id — for dsh an agent IS its session, so this matches `session/list`.
  final String sessionId;
}

/// One pending `approval/request` delivered over the forwarded-event stream.
class PendingApproval extends PendingInteraction {
  const PendingApproval({
    required super.eventId,
    required super.sessionId,
    required this.toolName,
    this.reason,
  });

  final String toolName;
  final String? reason;
}

/// One pending `user-questions/request`: the turn waits until somebody answers.
///
/// The desktop client shows the same request, and whichever client answers
/// first claims it; the Host then cancels it for the rest.
class PendingQuestion extends PendingInteraction {
  const PendingQuestion({
    required super.eventId,
    required super.sessionId,
    required this.questions,
  });

  final List<AskQuestion> questions;
}

/// Subscribes to the Gateway forwarded-event stream and answers approvals and
/// questions.
///
/// The stream is the only path that can claim either: dsh delivers them as
/// waterfalls and expects the answer back through `$events/result` (see
/// `packages/api/gateway/src/client/remote-events.ts`).
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
  final List<PendingInteraction> _pending = [];

  /// Whether the `$events` stream is live. A failed subscription used to be a
  /// silent 5-second retry loop, which looks exactly like "approvals never
  /// arrive"; the UI surfaces this state instead.
  bool _ready = false;
  String? _channelError;

  List<PendingInteraction> get pending => List.unmodifiable(_pending);

  /// True once the Host sent the stream's `ready` frame.
  bool get channelReady => _ready;

  /// Last reason the channel is down: mux error code, socket error, or null
  /// while connected.
  String? get channelError => _channelError;

  bool get isRunning => !_stopped && _mux != null;

  /// Reconnect immediately when a screen is resumed instead of waiting for the
  /// five-second retry timer (Android freezes timers while backgrounded).
  void ensureConnected() {
    if (_stopped || _ready || _origin == null) return;
    _retry?.cancel();
    unawaited(_dial());
  }

  /// (Re)connect for one paired PC.
  Future<void> start({
    required String pcOrigin,
    required String cookieHeader,
  }) async {
    _origin = pcOrigin;
    _cookie = cookieHeader;
    _rpc = DshRpc(pcOrigin: pcOrigin, cookieHeader: cookieHeader);
    _stopped = false;
    _ready = false;
    _channelError = null;
    await _dial();
  }

  Future<void> _dial() async {
    if (_stopped) return;
    _retry?.cancel();
    _clientId = null;
    _ready = false;
    final mux = MuxClient(pcOrigin: _origin!, cookieHeader: _cookie!);
    try {
      await mux.connect();
    } catch (e) {
      _channelError = 'dial: $e';
      _scheduleRetry();
      return;
    }
    await _sub?.cancel();
    await _mux?.close();
    _mux = mux;
    _sub = mux.open(r'$events', const <String, dynamic>{}).listen(
      _onFrame,
      onError: (Object e) {
        _channelError = 'socket: $e';
        _scheduleRetry();
      },
      onDone: () {
        _channelError ??= 'closed';
        _scheduleRetry();
      },
      cancelOnError: true,
    );
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _clientId = null;
    _ready = false;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _dial);
    notifyListeners();
  }

  void _onFrame(MuxEvent event) {
    if (event is MuxError) {
      _channelError = '${event.code}: ${event.message}';
      debugPrint('[lanbuddy] \$events stream error ${event.code}: ${event.message}');
      notifyListeners();
      return;
    }
    if (event is MuxEnd) {
      _channelError ??= 'ended';
      debugPrint('[lanbuddy] \$events stream ended');
      return;
    }
    if (event is! MuxItem) return;
    final frame = decodeRemoteEvent(event.value);
    switch (frame) {
      case null:
        return;
      case RemoteEventsReady(:final clientId):
        _clientId = clientId;
        _ready = true;
        _channelError = null;
        debugPrint('[lanbuddy] \$events ready ($clientId)');
        notifyListeners();
      case RemoteEventWaterfall(
          :final eventId,
          :final event,
          :final agentId,
          :final request,
        ):
        if (_pending.any((p) => p.eventId == eventId)) return;
        debugPrint('[lanbuddy] waterfall $event ($eventId)');
        switch (event) {
          case 'approval/request':
            final reason = _reasonOf(request);
            _pending.add(PendingApproval(
              eventId: eventId,
              sessionId: agentId,
              toolName: '${request['toolName'] ?? '工具调用'}',
              reason: reason,
            ));
            notifyListeners();
            // Surface the request outside the app too.
            Notifier.instance.show(
              title: 'DSH 请求权限',
              body: reason == null
                  ? '${request['toolName'] ?? '工具调用'} 等待你的决定'
                  : '${request['toolName'] ?? '工具调用'} · $reason',
            );
          case 'user-questions/request':
            final questions = parseAskQuestions(request['questions']);
            if (questions == null) return;
            _pending.add(PendingQuestion(
              eventId: eventId,
              sessionId: agentId,
              questions: questions,
            ));
            notifyListeners();
            Notifier.instance.show(
              title: 'DSH 提问',
              body: questions.length == 1
                  ? questions.first.question
                  : '${questions.first.question}（共 ${questions.length} 个问题）',
            );
        }
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

  /// Answer one pending question with its full batch.
  ///
  /// The pending entry is only dropped once the Host accepted the answer: a
  /// failed send has to stay on screen so it can be retried.
  Future<void> answerQuestion(
    PendingQuestion question,
    List<Map<String, dynamic>> answers,
  ) async {
    final clientId = _clientId;
    final rpc = _rpc;
    if (clientId == null || rpc == null) {
      throw StateError('与 PC 的连接还没准备好，请稍后重试');
    }
    await rpc.answerQuestion(
      clientId: clientId,
      eventId: question.eventId,
      answers: answers,
    );
    _pending.removeWhere((p) => p.eventId == question.eventId);
    notifyListeners();
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    _clientId = null;
    _ready = false;
    _channelError = null;
    await _sub?.cancel();
    _sub = null;
    await _mux?.close();
    _mux = null;
    _pending.clear();
    notifyListeners();
  }
}
