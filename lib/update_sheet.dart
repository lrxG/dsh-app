/// Update sheet: check the release page, download the APK, hand it to the
/// system installer. Opened from the version footer on the session list.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'update.dart';
import 'version.dart';

Future<void> showUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _UpdateSheet(),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet();

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet>
    with WidgetsBindingObserver {
  final UpdateService _service = UpdateService.instance;

  bool _checking = true;
  bool _downloading = false;
  bool _installing = false;
  UpdateRelease? _release;
  String? _error;
  String? _note;
  String? _installPath;
  int _received = 0;
  int _total = 0;
  CancelToken? _cancel;

  /// The system sent the user to the "install unknown apps" grant; coming back
  /// to the app retries the installer instead of asking for another tap.
  bool _awaitingInstallPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel('sheet closed');
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_awaitingInstallPermission || _installPath == null) return;
    _awaitingInstallPermission = false;
    _install();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _note = null;
      // A downloaded file belongs to the release it came from; a fresh check
      // must not offer it for a different version.
      _installPath = null;
    });
    final release = await _service.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _release = release;
      _error = release == null ? (_service.error ?? '检查更新失败') : null;
    });
  }

  Future<void> _download() async {
    final release = _release;
    if (release == null || _downloading) return;
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _downloading = true;
      _error = null;
      _note = null;
      _received = 0;
      _total = release.assetSize;
    });
    try {
      final path = await _service.download(
        release,
        cancelToken: cancel,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total > 0 ? total : release.assetSize;
          });
        },
      );
      if (!mounted) return;
      _installPath = path;
      setState(() => _downloading = false);
      await _install();
    } catch (e) {
      if (!mounted) return;
      final cancelled = e is DioException && CancelToken.isCancel(e);
      setState(() {
        _downloading = false;
        if (!cancelled) _error = e is DioException ? _downloadError(e) : '$e';
      });
    } finally {
      _cancel = null;
    }
  }

  Future<void> _install() async {
    final path = _installPath;
    if (path == null || _installing) return;
    setState(() {
      _installing = true;
      _note = null;
      _error = null;
    });
    final outcome = await _service.install(path);
    if (!mounted) return;
    setState(() {
      _installing = false;
      switch (outcome) {
        case InstallOutcome.installer:
          _awaitingInstallPermission = false;
          _note = '已打开系统安装器，按提示完成安装即可（会覆盖当前版本）。';
        case InstallOutcome.permission:
          _awaitingInstallPermission = true;
          _note = '系统需要你允许本应用「安装未知应用」。授权后返回这里，会自动继续安装。';
        case InstallOutcome.failed:
          _awaitingInstallPermission = false;
          _error = _service.error ?? '无法调起安装器';
      }
    });
  }

  String _downloadError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '下载超时，请检查网络后重试';
      case DioExceptionType.connectionError:
        return '下载中断，请检查网络后重试';
      default:
        return '下载失败：${e.message ?? e.type.name}';
    }
  }

  /// Size/progress line under the download button.
  String get _progressText {
    final total = _total;
    final percent = total > 0 ? (_received * 100 / total).round() : null;
    final got = _bytes(_received);
    final all = total > 0 ? _bytes(total) : null;
    if (all == null) return '正在下载 $got…';
    return '正在下载 $got / $all${percent == null ? '' : ' · $percent%'}';
  }

  bool get _hasUpdate {
    final release = _release;
    return release != null && compareVersions(release.version, appVersion) > 0;
  }

  /// The release page carries exactly the build that is running: it can still
  /// be downloaded and installed, which makes the whole download/install chain
  /// testable without waiting for a new version.
  bool get _sameVersion {
    final release = _release;
    return release != null && compareVersions(release.version, appVersion) == 0;
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.82;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 18),
                const Expanded(
                  child: Text(
                    '软件更新',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1C1C1E),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  color: const Color(0xFF8E8E93),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 4),
              ],
            ),
            Flexible(child: SingleChildScrollView(child: _body())),
            _buttons(),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 34),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.2, color: Color(0xFF007AFF)),
              ),
              SizedBox(height: 12),
              Text('正在检查更新…',
                  style: TextStyle(fontSize: 13, color: Color(0xFF8E8E93))),
            ],
          ),
        ),
      );
    }
    final release = _release;
    if (release == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error ?? '检查更新失败',
              style: const TextStyle(fontSize: 14, color: Color(0xFFE5453C)),
            ),
            const SizedBox(height: 8),
            const Text(
              '检查更新需要访问 GitHub。网络受限时可以直接打开发布页，用浏览器下载安装包。',
              style: TextStyle(fontSize: 13, color: Color(0xFF8E8E93), height: 1.5),
            ),
            const SizedBox(height: 6),
            Text(
              '当前版本 $appVersion',
              style: const TextStyle(fontSize: 12, color: Color(0xFFC7C7CC)),
            ),
          ],
        ),
      );
    }
    if (!_hasUpdate) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle,
                    size: 18, color: Color(0xFF30A14E)),
                const SizedBox(width: 6),
                const Text(
                  '已是最新版本',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1C1C1E)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前 $appVersion · 最新 ${release.version}',
              style: const TextStyle(fontSize: 13, color: Color(0xFF8E8E93)),
            ),
            if (_sameVersion) ...[
              const SizedBox(height: 6),
              const Text(
                '发布页上的安装包就是这个版本，可以重装一次（换机、修复安装时有用）。',
                style:
                    TextStyle(fontSize: 12, height: 1.45, color: Color(0xFF8E8E93)),
              ),
            ],
            _status(),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt,
                  size: 18, color: Color(0xFF007AFF)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '发现新版本 ${release.version}',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1C1C1E)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            release.assetSize > 0
                ? '当前 $appVersion · 安装包 ${_bytes(release.assetSize)}'
                : '当前 $appVersion',
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
          if (release.assetDigest == null) ...[
            const SizedBox(height: 6),
            const Text(
              '本次没能取得安装包校验和（GitHub 接口限流时的降级检查），安装时仍由系统校验签名。',
              style: TextStyle(
                  fontSize: 12, height: 1.45, color: Color(0xFFB26B00)),
            ),
          ],
          if (release.body.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 230),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: Text(
                  release.body.trim(),
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.55, color: Color(0xFF3A3A3C)),
                ),
              ),
            ),
          ],
          _status(),
        ],
      ),
    );
  }

  /// Progress and outcome lines shared by both layouts, so a retry inside the
  /// "already current" branch reports the same way as an update.
  Widget _status() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_downloading) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: _total > 0 ? _received / _total : null,
            minHeight: 4,
            backgroundColor: const Color(0xFFE5E5EA),
            color: const Color(0xFF007AFF),
          ),
          const SizedBox(height: 6),
          Text(
            _progressText,
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
        ],
        if (_installing) ...[
          const SizedBox(height: 12),
          const Text('正在调起系统安装器…',
              style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93))),
        ],
        if (_note != null) ...[
          const SizedBox(height: 12),
          Text(
            _note!,
            style: const TextStyle(
                fontSize: 12.5, height: 1.5, color: Color(0xFF30A14E)),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(
                fontSize: 12.5, height: 1.5, color: Color(0xFFE5453C)),
          ),
        ],
      ],
    );
  }

  Widget _buttons() {
    final buttons = <Widget>[];
    if (!_checking && (_hasUpdate || _sameVersion)) {
      if (_installPath != null) {
        buttons.add(_primary(_installing ? '正在打开安装器…' : '继续安装',
            _installing ? null : _install));
      } else {
        final label = _downloading
            ? '下载中…'
            : _sameVersion
                ? '重新安装本版本'
                : (_error != null ? '重新下载并安装' : '下载并安装');
        buttons.add(_primary(label, _downloading ? null : _download));
      }
    } else if (!_checking) {
      buttons.add(_primary('重新检查', _check));
    }
    buttons.add(_secondary(
      '打开发布页',
      () async {
        final ok = await _service.openUrl(releasesPageUrl);
        if (!ok && mounted) {
          setState(() => _error = '没有可用的浏览器，请手动访问 $releasesPageUrl');
        }
      },
    ));
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final button in buttons)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(width: double.infinity, child: button),
            ),
        ],
      ),
    );
  }

  Widget _primary(String label, Future<void> Function()? onPressed) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF007AFF),
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 15)),
    );
  }

  Widget _secondary(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, color: Color(0xFF007AFF)),
      ),
    );
  }

  static String _bytes(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
