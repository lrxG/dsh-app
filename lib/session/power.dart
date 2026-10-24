import 'package:flutter/services.dart';

/// Battery-optimization helper.
///
/// Android freezes (and eventually kills) ordinary background processes, so a
/// paired phone only keeps its LAN socket alive when the system is told to
/// leave this app alone. The app never asks for a foreground service — that
/// would mean a permanent notification — so this exemption is what makes
/// "task finished while the phone sits in my pocket" work.
class PowerSettings {
  PowerSettings._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/power');

  /// Opens the "no restrictions" dialog (falls back to the battery list).
  static Future<bool> requestExempt() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return false;
    }
  }
}
