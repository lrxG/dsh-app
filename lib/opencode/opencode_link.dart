/// OpenCode serves its web UI from the same server as its API and protects it
/// with a 30-day cookie that only a pairing link can mint:
/// `<origin>/auth/connect/<code>`.
///
/// The app already scans QR codes for dsh pairing, so a scanned payload is
/// classified here first — dsh links carry a `?token=` query, OpenCode links
/// carry the `auth/connect` path, and the two never overlap.
library;

/// The OpenCode pairing URL a scanned payload carries, or null.
Uri? openCodePairingUriFrom(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !isOpenCodePairingUri(uri)) return null;
  return uri;
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
