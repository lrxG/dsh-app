import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/opencode/opencode_link.dart';

void main() {
  test('reads the JSON payload opencode pair actually encodes', () {
    const payload =
        '{"code":"AbC-123_xyz","urls":["http://192.168.1.10:28895"]}';
    final urls = openCodePairingUrisFrom(payload);
    expect(urls, hasLength(1));
    expect(
      urls.single.toString(),
      'http://192.168.1.10:28895/auth/connect/AbC-123_xyz',
    );
    expect(openCodeOriginOf(urls.single), 'http://192.168.1.10:28895');
  });

  test('puts a reachable address before the PC loopback', () {
    const payload =
        '{"code":"abc","urls":["http://127.0.0.1:28894","http://192.168.1.10:28895"]}';
    final urls = openCodePairingUrisFrom(payload);
    expect(urls.map((u) => u.host).toList(), ['192.168.1.10', '127.0.0.1']);
  });

  test('accepts a plain pairing link and the single url field', () {
    final link = openCodePairingUrisFrom(
      'http://192.168.1.10:28895/auth/connect/abc',
    );
    expect(link.single.path, '/auth/connect/abc');

    final single = openCodePairingUrisFrom(
      '{"code":"abc","url":"http://h:1"}',
    );
    expect(single.single.toString(), 'http://h:1/auth/connect/abc');
  });

  test('deduplicates repeated addresses', () {
    const payload = '{"code":"abc","urls":["http://h:1","http://h:1"]}';
    expect(openCodePairingUrisFrom(payload), hasLength(1));
  });

  test('leaves dsh links and junk alone', () {
    expect(
      openCodePairingUrisFrom('http://192.168.1.10:3456/?token=pw-abc'),
      isEmpty,
    );
    expect(
      openCodePairingUrisFrom('http://192.168.1.10:3456/connect?token=pw-abc'),
      isEmpty,
    );
    expect(openCodePairingUrisFrom('not a url'), isEmpty);
    expect(openCodePairingUrisFrom(null), isEmpty);
    expect(openCodePairingUrisFrom('   '), isEmpty);
    expect(openCodePairingUrisFrom('ftp://host/auth/connect/x'), isEmpty);
    expect(openCodePairingUrisFrom('http://host/auth/connect'), isEmpty);
    expect(openCodePairingUrisFrom('http://host/auth/connect/'), isEmpty);
    expect(openCodePairingUrisFrom('/auth/connect/x'), isEmpty);
  });

  test('rejects malformed pairing payloads', () {
    expect(openCodePairingUrisFrom('{"code":"abc","urls":[]}'), isEmpty);
    expect(openCodePairingUrisFrom('{"urls":["http://h:1"]}'), isEmpty);
    expect(openCodePairingUrisFrom('{"code":"","urls":["http://h:1"]}'), isEmpty);
    expect(openCodePairingUrisFrom('{"code":"abc"}'), isEmpty);
    expect(openCodePairingUrisFrom('{oops'), isEmpty);
    expect(openCodePairingUrisFrom('["http://h:1"]'), isEmpty);
    expect(
      openCodePairingUrisFrom('{"code":"abc","urls":["nonsense"]}'),
      isEmpty,
    );
  });

  test('only the exact auth/connect shape counts as a pairing link', () {
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
