/// What `opencode pair` puts in its QR code.
///
/// The QR is **not** a URL: it is a JSON payload naming a one-time code and the
/// server URLs to reach it on:
///
/// ```json
/// {"code":"AbC-123_xyz","urls":["http://192.168.1.10:28895"]}
/// ```
///
/// A plain `<origin>/auth/connect/<code>` link is accepted too, because that is
/// what the terminal prints as text and what users paste.
library;

import 'dart:convert';

/// Every OpenCode pairing URL a scanned payload carries, best candidate first.
///
/// Returns an empty list when the payload is neither an OpenCode pairing
/// payload nor an `auth/connect` link.
List<Uri> openCodePairingUrisFrom(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return const [];
  if (text.startsWith('{')) return _fromPairPayload(text);
  final uri = Uri.tryParse(text);
  if (uri != null && isOpenCodePairingUri(uri)) return [uri];
  return const [];
}

/// `<origin>/auth/connect/<code>`, and nothing else.
bool isOpenCodePairingUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (uri.authority.isEmpty) return false;
  final segments = uri.pathSegments;
  return segments.length == 3 &&
      segments[0] == 'auth' &&
      segments[1] == 'connect' &&
      segments[2].isNotEmpty;
}

/// `http://host:port` of any OpenCode URL — the web UI's stable address once a
/// pairing session exists.
String openCodeOriginOf(Uri uri) => '${uri.scheme}://${uri.authority}';

List<Uri> _fromPairPayload(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map) return const [];
  final code = decoded['code'];
  if (code is! String || code.isEmpty) return const [];

  final servers = <String>[];
  final many = decoded['urls'];
  if (many is List) {
    for (final value in many) {
      if (value is String && value.isNotEmpty) servers.add(value);
    }
  }
  final one = decoded['url'];
  if (one is String && one.isNotEmpty) servers.add(one);

  final reachable = <Uri>[];
  final loopback = <Uri>[];
  final seen = <String>{};
  for (final server in servers) {
    final base = Uri.tryParse(server);
    if (base == null) continue;
    final scheme = base.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') continue;
    if (base.authority.isEmpty) continue;
    final uri = Uri(
      scheme: scheme,
      userInfo: base.userInfo.isEmpty ? null : base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/auth/connect/${Uri.encodeComponent(code)}',
    );
    if (!seen.add(uri.toString())) continue;
    // The phone is never on the PC's loopback, so a LAN or tunnel address is
    // the one worth trying first.
    if (_isLoopback(base.host)) {
      loopback.add(uri);
    } else {
      reachable.add(uri);
    }
  }
  return [...reachable, ...loopback];
}

bool _isLoopback(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' ||
      lower == '::1' ||
      lower == '[::1]' ||
      lower.startsWith('127.');
}
