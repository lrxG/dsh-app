import 'package:shared_preferences/shared_preferences.dart';

/// The OpenCode server this phone connected to last, kept so the entry point
/// opens the web UI without a fresh QR (its session cookie lives 30 days).
class OpenCodeStore {
  static const String _key = 'lanbuddy.opencodeOrigin';

  Future<String?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final origin = prefs.getString(_key);
      return origin != null && origin.isNotEmpty ? origin : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String origin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, origin);
    } catch (_) {
      // Losing the shortcut only means scanning again next time.
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Nothing to clean up.
    }
  }
}
