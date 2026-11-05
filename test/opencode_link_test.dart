import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/opencode/opencode_link.dart';

void main() {
  test('recognises an OpenCode pairing link', () {
    final uri = openCodePairingUriFrom(
      '  http://192.168.31.174:28895/auth/connect/AbC-123_xyz  ',
    );
    expect(uri, isNotNull);
    expect(uri!.host, '192.168.31.174');
    expect(uri.port, 28895);
    expect(openCodeOriginOf(uri), 'http://192.168.31.174:28895');
  });

  test('accepts https and a host without a port', () {
    final uri = openCodePairingUriFrom('https://pc.example.com/auth/connect/abc');
    expect(uri, isNotNull);
    expect(openCodeOriginOf(uri!), 'https://pc.example.com');
  });

  test('leaves dsh links and unrelated payloads alone', () {
    // dsh pairing: the token query is the marker, never this path.
    expect(
      openCodePairingUriFrom('http://192.168.1.10:3456/?token=pw-abc'),
      isNull,
    );
    expect(
      openCodePairingUriFrom('http://192.168.1.10:3456/connect?token=pw-abc'),
      isNull,
    );
    expect(openCodePairingUriFrom('not a url'), isNull);
    expect(openCodePairingUriFrom(null), isNull);
    expect(openCodePairingUriFrom('ftp://host/auth/connect/x'), isNull);
    expect(openCodePairingUriFrom('http://host/auth/connect'), isNull);
    expect(openCodePairingUriFrom('http://host/auth/connect/'), isNull);
    expect(openCodePairingUriFrom('http://host/auth/other/x'), isNull);
    expect(openCodePairingUriFrom('/auth/connect/x'), isNull);
  });

  test('only the exact auth/connect shape is accepted', () {
    expect(
      isOpenCodePairingUri(Uri.parse('http://h:1/auth/connect/code')),
      isTrue,
    );
    expect(
      isOpenCodePairingUri(Uri.parse('http://h:1/auth/connect/code/extra')),
      isFalse,
    );
    expect(isOpenCodePairingUri(Uri.parse('http://h:1/')), isFalse);
  });
}
