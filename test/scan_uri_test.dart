import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/pairing/scan_page.dart';

void main() {
  test('accepts the v1 index grant the dsh plugin prints', () {
    final uri = pairingUriFrom('http://192.168.1.10:3080/?token=pw-abc');
    expect(uri, isNotNull);
    expect(uri!.queryParameters['token'], 'pw-abc');
  });

  test('accepts the dsh CLI /connect grant', () {
    final uri = pairingUriFrom(
      'http://192.168.1.10:3080/connect?token=pw-abc&interactions=answer',
    );
    expect(uri, isNotNull);
    expect(uri!.path, '/connect');
  });

  test('tolerates surrounding whitespace and uppercase scheme', () {
    expect(pairingUriFrom('  HTTP://10.0.0.2:3080/?token=x  '), isNotNull);
  });

  test('rejects non-http payloads and token-less URLs', () {
    expect(pairingUriFrom('ftp://host/?token=x'), isNull);
    expect(pairingUriFrom('http://host/'), isNull);
    expect(pairingUriFrom('http://host/?token='), isNull);
    expect(pairingUriFrom('just some text'), isNull);
    expect(pairingUriFrom(null), isNull);
  });
}
