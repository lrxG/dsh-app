import 'dart:async';

import 'package:flutter/services.dart';

/// System notifications for the one event worth interrupting the user for:
/// a main session finishing its work.
///
/// The bridge is a tiny native MethodChannel (`lanbuddy/notify`) — no push
/// service, no foreground service. The app learns about completions over its
/// LAN WebSocket and posts the notification itself; tapping it hands the
/// session id back so the app can open that conversation.
class Notifier {
  Notifier._();

  static final Notifier instance = Notifier._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/notify');

  static final StreamController<String> _opens = StreamController<String>.broadcast();

  /// Session ids delivered by tapping a notification (app already running).
  static Stream<String> get openedSessions => _opens.stream;

  static bool _handling = false;

  /// Creates the channel, asks for POST_NOTIFICATIONS (Android 13+) and starts
  /// relaying notification taps. Safe to call once at startup.
  Future<void> init() async {
    if (!_handling) {
      _handling = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'open-session') {
          final id = call.arguments;
          if (id is String && id.isNotEmpty) _opens.add(id);
        }
        return null;
      });
    }
    try {
      await _channel.invokeMethod<bool>('init');
    } catch (_) {
      // Best-effort: a denied permission must never break pairing or chat.
    }
  }

  /// A tap that cold-started the app, claimed once.
  Future<String?> takePending() async {
    try {
      return await _channel.invokeMethod<String>('takePending');
    } catch (_) {
      return null;
    }
  }

  Future<void> show({
    required String title,
    required String body,
    String? sessionId,
  }) async {
    try {
      await _channel.invokeMethod<bool>('show', {
        'title': title,
        'body': body,
        'sessionId': ?sessionId,
      });
    } catch (_) {
      // Best-effort.
    }
  }
}
