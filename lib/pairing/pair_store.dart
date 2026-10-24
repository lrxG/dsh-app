import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A pairing that survives app launches.
///
/// The v1 browser-session cookie outlives both WebSocket drops and dsh
/// restarts (its signing secret is durable on the PC), so storing it means the
/// user pairs once and never rescans — even when the PC's dsh is restarted
/// often. Several PCs can be remembered and switched between.
class SavedPair {
  const SavedPair({
    required this.pcOrigin,
    required this.cookieHeader,
    this.cookieName,
    this.savedAt,
  });

  final String pcOrigin;
  final String cookieHeader;
  final String? cookieName;
  final int? savedAt;

  /// Short label for the device list (host:port).
  String get label {
    final uri = Uri.tryParse(pcOrigin);
    return uri == null ? pcOrigin : '${uri.host}:${uri.port}';
  }

  Map<String, Object?> toJson() => {
        'origin': pcOrigin,
        'cookie': cookieHeader,
        if (cookieName != null) 'name': cookieName,
        if (savedAt != null) 'savedAt': savedAt,
      };

  static SavedPair? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final origin = raw['origin'];
    final cookie = raw['cookie'];
    if (origin is! String || origin.isEmpty || cookie is! String || cookie.isEmpty) {
      return null;
    }
    final name = raw['name'];
    final savedAt = raw['savedAt'];
    return SavedPair(
      pcOrigin: origin,
      cookieHeader: cookie,
      cookieName: name is String ? name : null,
      savedAt: savedAt is int ? savedAt : null,
    );
  }
}

class PairStore {
  static const _kPairs = 'lanbuddy.pairs';

  /// Cap remembered PCs: each entry is one cookie (~200 bytes), but unbounded
  /// growth is still pointless — the oldest entries fall off first.
  static const _maxDevices = 8;

  // Legacy single-pair keys (read once, then folded into the list).
  static const _kOrigin = 'lanbuddy.pcOrigin';
  static const _kCookie = 'lanbuddy.cookieHeader';
  static const _kCookieName = 'lanbuddy.cookieName';
  static const _kSavedAt = 'lanbuddy.savedAt';

  /// Every remembered PC, most recently saved first.
  Future<List<SavedPair>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPairs);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map(SavedPair.fromJson)
              .whereType<SavedPair>()
              .toList();
        }
      }
      // Migrate the v1 single pair (if any) into the list. Write directly:
      // save() reads the list, so calling it here would recurse.
      final origin = prefs.getString(_kOrigin);
      final cookie = prefs.getString(_kCookie);
      if (origin != null && origin.isNotEmpty && cookie != null && cookie.isNotEmpty) {
        final migrated = SavedPair(
          pcOrigin: origin,
          cookieHeader: cookie,
          cookieName: prefs.getString(_kCookieName),
          savedAt: prefs.getInt(_kSavedAt),
        );
        await _write([migrated]);
        // The list is now the source of truth; drop the legacy single-pair keys.
        await prefs.remove(_kOrigin);
        await prefs.remove(_kCookie);
        await prefs.remove(_kCookieName);
        await prefs.remove(_kSavedAt);
        return [migrated];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// Most recent pairing, or null when nothing is stored.
  Future<SavedPair?> loadMostRecent() async {
    final all = await loadAll();
    return all.isEmpty ? null : all.first;
  }

  /// Insert or update one PC; it becomes the most recent entry.
  Future<void> save(SavedPair pair) async {
    try {
      final all = await loadAll();
      final next = [
        SavedPair(
          pcOrigin: pair.pcOrigin,
          cookieHeader: pair.cookieHeader,
          cookieName: pair.cookieName,
          savedAt: pair.savedAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
        ...all.where((p) => p.pcOrigin != pair.pcOrigin),
      ];
      // Insert-or-update plus a hard cap keeps the store bounded.
      await _write(next.take(_maxDevices).toList());
    } catch (_) {
      // Non-fatal: the current session still works, next launch re-pairs.
    }
  }

  Future<void> remove(String pcOrigin) async {
    try {
      final all = await loadAll();
      await _write(all.where((p) => p.pcOrigin != pcOrigin).toList());
    } catch (_) {
      // Nothing to remove.
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPairs);
      await prefs.remove(_kOrigin);
      await prefs.remove(_kCookie);
      await prefs.remove(_kCookieName);
      await prefs.remove(_kSavedAt);
    } catch (_) {
      // Nothing to clear.
    }
  }

  Future<void> _write(List<SavedPair> pairs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPairs,
      jsonEncode([for (final pair in pairs) pair.toJson()]),
    );
  }
}
