import 'package:flutter/material.dart';

import 'pairing/scan_page.dart';
import 'pairing/pair_client.dart';
import 'pairing/pair_store.dart';
import 'session/approval_center.dart';
import 'session/notify.dart';
import 'session/sessions_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Best-effort: prompt for the notification permission and create the channel.
  Notifier.instance.init();
  runApp(const DshCompanionApp());
}

/// App states, driven by the outcome of the /connect exchange.
enum LinkPhase { unpaired, pairing, paired, failed }

class DshCompanionApp extends StatelessWidget {
  const DshCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepSeek Harness',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF), // iOS blue
        ).copyWith(surface: const Color(0xFFF2F2F7)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF2F2F7),
          surfaceTintColor: Colors.transparent,
          foregroundColor: Color(0xFF007AFF),
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
        ),
      ),
      home: const PairGate(),
    );
  }
}

/// Root screen: shows pairing state, offers QR scan (+ manual URL fallback),
/// and on success links to the session screen.
class PairGate extends StatefulWidget {
  const PairGate({super.key});

  @override
  State<PairGate> createState() => _PairGateState();
}

class _PairGateState extends State<PairGate> {
  LinkPhase _phase = LinkPhase.unpaired;
  PairResult? _result;

  /// Last scanned/pasted link, so a failed attempt is one tap from a retry.
  Uri? _lastPair;

  /// Remembered PCs (most recent first) and the one currently bound.
  List<SavedPair> _saved = const [];
  String? _activeOrigin;

  /// One approval dialog at a time; the queue drains as each is answered.
  bool _approvalDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    ApprovalCenter.instance.removeListener(_maybeShowApproval);
    super.dispose();
  }

  /// Watch the PC's approval waterfall once a pairing exists.
  void _watchApprovals(PairResult result) {
    if ((result.cookieHeader ?? '').isEmpty) return;
    ApprovalCenter.instance.removeListener(_maybeShowApproval);
    ApprovalCenter.instance.addListener(_maybeShowApproval);
    ApprovalCenter.instance.start(
      pcOrigin: result.pcOrigin,
      cookieHeader: result.cookieHeader!,
    );
    _maybeShowApproval();
  }

  /// iOS-style prompt for the oldest pending approval.
  void _maybeShowApproval() {
    if (_approvalDialogOpen || !mounted) return;
    final pending = ApprovalCenter.instance.pending;
    if (pending.isEmpty) return;
    final item = pending.first;
    _approvalDialogOpen = true;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'DSH 请求权限',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.toolName,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1C1C1E),
              ),
            ),
            if (item.reason != null) ...[
              const SizedBox(height: 8),
              Text(
                item.reason!,
                style: const TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: Color(0xFF3A3A3C),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              '会话 ${item.sessionId.length > 8 ? item.sessionId.substring(item.sessionId.length - 8) : item.sessionId}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '拒绝',
              style: TextStyle(fontSize: 15, color: Color(0xFFE5453C)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '允许一次',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF007AFF),
              ),
            ),
          ),
        ],
      ),
    ).then((allow) async {
      _approvalDialogOpen = false;
      if (allow != null) {
        try {
          await ApprovalCenter.instance.decide(item, allow: allow);
        } catch (_) {
          // The request may already be cancelled; just move on.
        }
      }
      _maybeShowApproval();
    });
  }

  /// A stored v1 cookie stays valid across sockets and dsh restarts, so a
  /// previous pairing reopens the bound state without a rescan.
  Future<void> _restore() async {
    final saved = await PairStore().loadAll();
    if (!mounted || saved.isEmpty) {
      if (mounted) setState(() => _saved = const []);
      return;
    }
    setState(() => _saved = saved);
    _activate(saved.first);
  }

  /// Bind the UI (and the approval watcher) to one saved PC.
  void _activate(SavedPair saved) {
    setState(() {
      _result = PairResult(
        ok: true,
        pcOrigin: saved.pcOrigin,
        cookieHeader: saved.cookieHeader,
        cookieName: saved.cookieName,
      );
      _phase = LinkPhase.paired;
      _activeOrigin = saved.pcOrigin;
    });
    _watchApprovals(_result!);
  }

  Future<void> _scan() async {
    final scanned = await Navigator.push<Uri>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (scanned != null) await _pair(scanned);
  }

  Future<void> _pair(Uri pairUrl) async {
    _lastPair = pairUrl;
    setState(() => _phase = LinkPhase.pairing);
    final result = await PairClient().exchange(pairUrl);
    if (result.ok) {
      await PairStore().save(SavedPair(
        pcOrigin: result.pcOrigin,
        cookieHeader: result.cookieHeader ?? '',
        cookieName: result.cookieName,
      ));
      final saved = await PairStore().loadAll();
      if (mounted) setState(() => _saved = saved);
      if (mounted) _activeOrigin = result.pcOrigin;
    }
    if (!mounted) return;
    setState(() {
      _result = result;
      _phase = result.ok ? LinkPhase.paired : LinkPhase.failed;
    });
    if (result.ok) _watchApprovals(result);
  }

  /// Forget the current PC; switch to another saved one when present.
  Future<void> _unpair() async {
    await ApprovalCenter.instance.stop();
    ApprovalCenter.instance.removeListener(_maybeShowApproval);
    final origin = _activeOrigin ?? _result?.pcOrigin;
    if (origin != null && origin.isNotEmpty) {
      await PairStore().remove(origin);
    } else {
      await PairStore().clear();
    }
    final remaining = await PairStore().loadAll();
    if (!mounted) return;
    setState(() => _saved = remaining);
    if (remaining.isNotEmpty) {
      _activate(remaining.first);
      return;
    }
    setState(() {
      _result = null;
      _phase = LinkPhase.unpaired;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = switch (_phase) {
      LinkPhase.unpaired => '连接你的 PC 伴侣',
      LinkPhase.pairing => '配对中…',
      LinkPhase.failed => '配对失败',
      LinkPhase.paired => '已与 PC 绑定',
    };
    final detail = switch (_phase) {
      LinkPhase.unpaired =>
        '在 PC 上打开 dsh → 设置 →「扫码配对」，\n或手动粘贴配对链接。',
      LinkPhase.failed => _result?.error ?? '未知错误',
      LinkPhase.paired => '会话与模型与 PC 实时同步',
      LinkPhase.pairing => '',
    };
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(title: const Text('DeepSeek Harness')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Hero badge: soft blue disc replaces the raw icon.
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: const Color(0xFF007AFF).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    child: _phase == LinkPhase.pairing
                        ? const SizedBox(
                            width: 34,
                            height: 34,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Color(0xFF007AFF),
                            ),
                          )
                        : Icon(
                            switch (_phase) {
                              LinkPhase.paired => Icons.check_rounded,
                              LinkPhase.failed => Icons.link_off,
                              _ => Icons.qr_code_scanner,
                            },
                            size: 44,
                            color: const Color(0xFF007AFF),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                status,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1C1C1E),
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: Color(0xFF8E8E93),
                  ),
                ),
              ],
              if (_phase == LinkPhase.failed && _lastPair != null) ...[
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () => _pair(_lastPair!),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF007AFF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('重试配对', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
              if (_phase == LinkPhase.paired && _saved.length > 1) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      for (final device in _saved)
                        InkWell(
                          onTap: device.pcOrigin == _activeOrigin
                              ? null
                              : () => _activate(device),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
                            child: Row(
                              children: [
                                Icon(
                                  device.pcOrigin == _activeOrigin
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 17,
                                  color: device.pcOrigin == _activeOrigin
                                      ? const Color(0xFF30D158)
                                      : const Color(0xFFC7C7CC),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    device.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: device.pcOrigin == _activeOrigin
                                          ? const Color(0xFF1C1C1E)
                                          : const Color(0xFF3A3A3C),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close,
                                      size: 16, color: Color(0xFFAEAEB2)),
                                  tooltip: '移除这台设备',
                                  onPressed: () async {
                                    await PairStore().remove(device.pcOrigin);
                                    final remaining = await PairStore().loadAll();
                                    if (!mounted) return;
                                    setState(() => _saved = remaining);
                                    if (device.pcOrigin == _activeOrigin) {
                                      if (remaining.isNotEmpty) {
                                        _activate(remaining.first);
                                      } else {
                                        setState(() {
                                          _result = null;
                                          _phase = LinkPhase.unpaired;
                                        });
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_phase == LinkPhase.paired && _result != null) ...[
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SessionsPage(
                          pcOrigin: _result!.pcOrigin,
                          cookieHeader: _result!.cookieHeader ?? '',
                        ),
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF007AFF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('进入会话', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_phase == LinkPhase.paired)
                TextButton(
                  onPressed: _unpair,
                  child: const Text(
                    '解除绑定',
                    style: TextStyle(fontSize: 13, color: Color(0xFF8E8E93)),
                  ),
                ),
              _PairAction(
                icon: Icons.qr_code_scanner_rounded,
                label: '扫码配对',
                onTap: _phase == LinkPhase.pairing ? null : _scan,
              ),
              const SizedBox(height: 10),
              _PairAction(
                icon: Icons.paste_rounded,
                label: '手动粘贴配对链接',
                onTap: _phase == LinkPhase.pairing ? null : () => _manual(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _manual(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '粘贴配对链接',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '把 PC 端的配对链接整条粘进来',
                filled: true,
                fillColor: const Color(0xFFF2F2F7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextAction(
            label: '取消',
            onPressed: () => Navigator.pop(ctx),
          ),
          TextAction(
            label: '配对',
            bold: true,
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.queryParameters.containsKey('token')) {
      setState(() {
        _result = PairResult(error: '链接无效（缺少 token）');
        _phase = LinkPhase.failed;
      });
      return;
    }
    await _pair(uri);
  }
}

/// iOS-style full-width list action (white rounded row, blue leading icon).
class _PairAction extends StatelessWidget {
  const _PairAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 21, color: const Color(0xFF007AFF)),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: enabled ? const Color(0xFF007AFF) : const Color(0xFFAEAEB2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// iOS "Cancel / OK" dialog action pair.
class TextAction extends StatelessWidget {
  const TextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.bold = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF007AFF),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 15, fontWeight: bold ? FontWeight.w600 : FontWeight.w400),
      ),
    );
  }
}
