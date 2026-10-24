import 'package:flutter/services.dart';

/// Battery-optimization helpers.
///
/// Android freezes (and eventually kills) ordinary background processes, so a
/// paired phone only keeps its LAN socket alive when the system is told to
/// leave this app alone. The app never asks for a foreground service — that
/// would mean a permanent notification — so this exemption is what makes
/// "task finished while the phone sits in my pocket" work.
class PowerSettings {
  PowerSettings._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/power');

  /// True when the OS already lets this app work in the background.
  static Future<bool> isExempt() async {
    try {
      final value = await _channel.invokeMethod<Map>('status');
      return value?['ignoring'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the "no restrictions" dialog (falls back to the battery list).
  static Future<bool> requestExempt() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's system settings page (autostart lives there on HyperOS).
  static Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod<bool>('appSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
