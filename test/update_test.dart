import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/update.dart';

void main() {
  test('compares dotted versions, ignoring the tag prefix', () {
    expect(compareVersions('v0.1.17', '0.1.16'), greaterThan(0));
    expect(compareVersions('0.1.16', 'v0.1.16'), 0);
    expect(compareVersions('0.1.9', '0.1.10'), lessThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('0.2.0-rc.1', '0.1.99'), greaterThan(0));
    expect(compareVersions('0.1.17+17', '0.1.17'), 0);
  });

  test('reads the packaged APK out of a release payload', () {
    final release = UpdateRelease.fromJson({
      'tag_name': 'v0.1.17',
      'name': 'v0.1.17 — 更新检查',
      'body': '说明正文',
      'html_url': 'https://github.com/lrxG/dsh-app/releases/tag/v0.1.17',
      'assets': [
        {'name': 'notes.txt', 'size': 1},
        {
          'name': 'dsh-app-release.apk',
          'size': 70437255,
          'browser_download_url':
              'https://github.com/lrxG/dsh-app/releases/download/v0.1.17/dsh-app-release.apk',
          'digest': 'sha256:abc123',
        },
      ],
    });
    expect(release, isNotNull);
    expect(release!.version, '0.1.17');
    expect(release.assetSize, 70437255);
    expect(release.assetDigest, 'sha256:abc123');
    expect(release.assetUrl, endsWith('dsh-app-release.apk'));
  });

  test('a release without the APK asset cannot be installed', () {
    final release = UpdateRelease.fromJson({
      'tag_name': 'v0.1.18',
      'assets': [
        {'name': 'notes.txt', 'size': 1},
      ],
    });
    expect(release, isNull);
    expect(UpdateRelease.fromJson(null), isNull);
  });
}
