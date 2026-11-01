/// Self-update: GitHub Release lookup, APK download, and the native installer
/// hand-off.
///
/// The app is distributed only through `lrxG/dsh-app` releases, so the release
/// page is the single source of truth: the tag names the version, the
/// `dsh-app-release.apk` asset is the build, and its GitHub digest is what we
/// verify before offering it to the installer.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'version.dart';

/// Human-facing release page (fallback when a download is not practical).
const String releasesPageUrl = 'https://github.com/lrxG/dsh-app/releases';

/// Fixed asset name: every release uploads the same file.
const String _apkAssetName = 'dsh-app-release.apk';

const String _latestApi =
    'https://api.github.com/repos/lrxG/dsh-app/releases/latest';

const String _lastCheckKey = 'lanbuddy.updateCheckedAt';

/// Numeric dotted-version comparison; a leading `v` and any `-rc` / `+build`
/// suffix are ignored. Returns <0, 0, >0 like `compareTo`.
int compareVersions(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

List<int> _versionParts(String value) {
  final trimmed = value.startsWith('v') ? value.substring(1) : value;
  final core = trimmed.split(RegExp(r'[-+]')).first;
  if (core.isEmpty) return const [0];
  return [for (final part in core.split('.')) int.tryParse(part) ?? 0];
}

/// One published release, trimmed to what the update sheet shows and needs.
class UpdateRelease {
  const UpdateRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.pageUrl,
    required this.assetUrl,
    required this.assetSize,
    required this.assetDigest,
  });

  final String tagName;
  final String name;
  final String body;
  final String pageUrl;
  final String assetUrl;
  final int assetSize;

  /// GitHub's `sha256:<hex>` digest, null when the API omits it.
  final String? assetDigest;

  /// Dotted version without the tag's `v` (`v0.1.17` → `0.1.17`).
  String get version => tagName.startsWith('v') ? tagName.substring(1) : tagName;

  static UpdateRelease? fromJson(Object? value) {
    if (value is! Map) return null;
    final tag = value['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final assets = value['assets'];
    Map? apk;
    if (assets is List) {
      for (final asset in assets) {
        if (asset is Map && asset['name'] == _apkAssetName) {
          apk = asset;
          break;
        }
      }
    }
    final assetUrl = apk?['browser_download_url'];
    if (apk == null || assetUrl is! String || assetUrl.isEmpty) return null;
    final size = apk['size'];
    return UpdateRelease(
      tagName: tag,
      name: value['name'] is String ? value['name'] as String : tag,
      body: value['body'] is String ? value['body'] as String : '',
      pageUrl: value['html_url'] is String
          ? value['html_url'] as String
          : releasesPageUrl,
      assetUrl: assetUrl,
      assetSize: size is num ? size.toInt() : 0,
      assetDigest: apk['digest'] is String ? apk['digest'] as String : null,
    );
  }
}

/// Result of asking the native side to run the installer.
enum InstallOutcome {
  /// The system installer is now showing.
  installer,

  /// The app lacks the "install unknown apps" grant; the settings page opened.
  permission,

  /// No installer could be started (missing file, blocked intent…).
  failed,
}

/// App-wide update state: one daily silent check plus the manual check the
/// version footer triggers.
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const MethodChannel _channel = MethodChannel('lanbuddy/update');

  /// How often a launch may hit GitHub on its own.
  static const Duration _checkInterval = Duration(hours: 24);

  UpdateRelease? _latest;
  UpdateRelease? get latest => _latest;

  bool _checking = false;
  bool get checking => _checking;

  String? _error;
  String? get error => _error;

  /// A release newer than the running build.
  bool get hasUpdate {
    final release = _latest;
    return release != null && compareVersions(release.version, appVersion) > 0;
  }

  /// One check per [_checkInterval], silently: being offline or blocked must
  /// never nag, the footer simply stays plain.
  Future<void> checkIfDue() async {
    if (_checking || hasUpdate) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastCheckKey);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (last != null && now - last < _checkInterval.inMilliseconds) return;
      await prefs.setInt(_lastCheckKey, now);
    } catch (_) {
      // No preferences: a check is still harmless.
    }
    await check();
  }

  /// Ask GitHub for the latest release. Returns null when the lookup fails
  /// (offline, blocked, rate-limited) and records the reason in [error].
  Future<UpdateRelease?> check() async {
    if (_checking) return _latest;
    _checking = true;
    _error = null;
    notifyListeners();
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'dsh-app',
        'Cache-Control': 'no-cache',
      },
    ));
    try {
      final res = await dio.get<Object>(_latestApi);
      final release = UpdateRelease.fromJson(res.data);
      if (release == null) {
        _error = '发布页里没有找到安装包';
      } else {
        _latest = release;
      }
      return release;
    } on DioException catch (e) {
      // `api.github.com` is rate-limited per egress IP and is sometimes blocked
      // where the release page itself still loads; the tag redirect is enough
      // to detect a version, so try that before reporting a failure.
      final fallback = await _checkViaRedirect();
      if (fallback != null) {
        _latest = fallback;
        return fallback;
      }
      _error = _describe(e);
      return null;
    } catch (e) {
      _error = '$e';
      return null;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Version-only fallback: `releases/latest` answers with a redirect to the
  /// newest tag, and the asset URL is deterministic, so the update survives a
  /// GitHub rate limit (no size or digest, which only the API publishes).
  Future<UpdateRelease?> _checkViaRedirect() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: const {'User-Agent': 'dsh-app'},
    ));
    try {
      final res = await dio.get<Object>(
        'https://github.com/lrxG/dsh-app/releases/latest',
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final location = res.headers.value('location') ?? '';
      final tag = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location)?.group(1);
      if (tag == null || tag.isEmpty) return null;
      return UpdateRelease(
        tagName: tag,
        name: tag,
        body: '',
        pageUrl: location.startsWith('http')
            ? location
            : 'https://github.com$location',
        assetUrl: 'https://github.com/lrxG/dsh-app/releases/download/$tag/$_apkAssetName',
        assetSize: 0,
        assetDigest: null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Download the release APK into the cache and verify its digest when
  /// GitHub published one. Returns the file path.
  Future<String> download(
    UpdateRelease release, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final cache = await getTemporaryDirectory();
    final dir = Directory('${cache.path}/updates');
    await dir.create(recursive: true);
    // One build at a time: stale installers are useless and can be huge.
    for (final entry in await dir.list().toList()) {
      if (entry is File) {
        try {
          await entry.delete();
        } catch (_) {
          // Locked by a previous installer session: leave it.
        }
      }
    }
    final file = File('${dir.path}/dsh-app-${release.version}.apk');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      headers: const {'Accept': 'application/octet-stream'},
    ));
    await dio.download(
      release.assetUrl,
      file.path,
      cancelToken: cancelToken,
      deleteOnError: true,
      onReceiveProgress: onProgress,
    );
    final digest = release.assetDigest;
    if (digest != null && digest.startsWith('sha256:')) {
      final actual = await _sha256(file);
      final expected = digest.substring('sha256:'.length).toLowerCase();
      if (actual != expected) {
        await file.delete();
        throw StateError('安装包校验失败（下载可能被中断），请重试');
      }
    }
    return file.path;
  }

  /// Hand the downloaded APK to the system installer.
  Future<InstallOutcome> install(String path) async {
    try {
      final result =
          await _channel.invokeMethod<Object>('install', {'path': path});
      final status = result is Map ? '${result['status']}' : '';
      switch (status) {
        case 'installer':
          return InstallOutcome.installer;
        case 'permission':
          return InstallOutcome.permission;
      }
      final message = result is Map && result['message'] is String
          ? result['message'] as String
          : null;
      if (message != null && message.isNotEmpty) _error = message;
      return InstallOutcome.failed;
    } on PlatformException catch (e) {
      _error = e.message ?? e.code;
      return InstallOutcome.failed;
    }
  }

  /// Open a release page in the browser.
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String _describe(DioException e) {
    final status = e.response?.statusCode;
    if (status == 404) return '发布页还没有正式版本';
    if (status == 403 || status == 429) return 'GitHub 限流了，稍后再试';
    if (status != null) return 'GitHub 返回 HTTP $status';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连 GitHub 超时，检查手机网络或代理';
      case DioExceptionType.connectionError:
        return '连不上 GitHub（可能是网络限制），可直接打开发布页';
      default:
        return '检查更新失败：${e.message ?? e.type.name}';
    }
  }
}
