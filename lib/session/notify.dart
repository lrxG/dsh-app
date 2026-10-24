import 'package:flutter/services.dart';

/// System notifications for the two events worth interrupting the user for:
/// a pending approval and a finished answer.
///
/// The bridge is a tiny native MethodChannel (`lanbuddy/notify`) — no
/// third-party notification plugin, so the Gradle setup stays stock. No push
/// service is involved: the app receives these events over its LAN WebSocket.
class Notifier {
  Notifier._();

  static final Notifier instance = Notifier._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/notify');

  /// Creates the channel and asks for POST_NOTIFICATIONS (Android 13+).
  Future<void> init() async {
    try {
      await _channel.invokeMethod<bool>('init');
    } catch (_) {
      // Best-effort: a denied permission must never break pairing or chat.
    }
  }

  Future<void> show({required String title, required String body}) async {
    try {
      await _channel.invokeMethod<bool>('show', {
        'title': title,
        'body': body,
      });
    } catch (_) {
      // Best-effort.
    }
  }
}
