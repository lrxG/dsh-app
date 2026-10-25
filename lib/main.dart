import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pairing/scan_page.dart';
import 'pairing/pair_client.dart';
import 'pairing/pair_store.dart';
import 'route_observer.dart';
import 'session/approval_center.dart';
import 'session/chat_page.dart';
import 'session/dsh_client.dart';
import 'session/notify.dart';
import 'session/power.dart';
import 'session/session_activity.dart';
import 'session/sessions_page.dart';
import 'version.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Best-effort: prompt for the notification permission and create the channel.
  Notifier.instance.init();
  runApp(const DshApp());
}

/// App states, driven by the outcome of the /connect exchange.
enum LinkPhase { unpaired, pairing, paired, failed }

class DshApp extends StatelessWidget {
  const DshApp({super.key});

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
        // Full-screen gesture back on Android otherwise previews the predictive
        // "shrink" immediately (feels oversensitive). Slide like iOS instead.
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
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
      navigatorObservers: [routeObserver],
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

class _PairGateState extends State<PairGate> with WidgetsBindingObserver {
  LinkPhase _phase = LinkPhase.unpaired;
  PairResult? _result;

  /// Last scanned/pasted link, so a failed attempt is one tap from a retry.
  Uri? _lastPair;

  /// Remembered PCs (most recent first) and the one currently bound.
  List<SavedPair> _saved = const [];
  String? _activeOrigin;

  /// One approval dialog at a time; the queue drains as each is answered.
  bool _approvalDialogOpen = false;

  /// One-time background-notification hint (shown after the first pairing).
  static const String _hintKey = 'lanbuddy.notificationHintShown';

  /// A notification tap that arrived before the pairing was restored.
  String? _pendingOpen;
  StreamSubscription<String>? _openSub;

  /// Whether the bound PC answers right now. A stored pairing survives dsh
  /// restarts, so "已与 PC 绑定" used to stay on screen even after the PC had
  /// moved to another port or plugged in a different network. `null` means
  /// "checking", which keeps the calm copy until the probe lands.
  bool? _reachable;
  bool _probing = false;
  RpcFailure? _probeFailure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openSub = Notifier.openedSessions.listen(_openSession);
    _restore();
    _claimPendingNotification();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openSub?.cancel();
    ApprovalCenter.instance.removeListener(_maybeShowApproval);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a foreground app suppresses notifications; everything else is
    // "in my pocket", which is exactly when the notification matters.
    SessionActivity.instance.setForeground(state == AppLifecycleState.resumed);
    // A tap that resumed the app carries no extras after a task restore; the
    // native side stores the id, and this is where we claim it.
    if (state == AppLifecycleState.resumed) {
      _claimPendingNotification();
      // The PC may have been restarted or moved while the app was away; the
      // bound-state copy should not keep claiming a link that is gone.
      unawaited(_probe());
    }
  }

  /// Ask the bound PC for the session list, purely to know whether the saved
  /// pairing still works. Failures are classified so the page can say which
  /// one it is: unreachable PC vs. a pairing the Host no longer accepts.
  Future<void> _probe() async {
    final result = _result;
    if (result == null || (result.cookieHeader ?? '').isEmpty) return;
    if (_probing) return;
    setState(() => _probing = true);
    try {
      await DshRpc(pcOrigin: result.pcOrigin, cookieHeader: result.cookieHeader!)
          .listSessions();
      if (!mounted) return;
      setState(() {
        _reachable = true;
        _probeFailure = null;
        _probing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _reachable = false;
        _probeFailure = describeFailure(error);
        _probing = false;
      });
    }
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
    // Same pairing drives the background completion watcher.
    SessionActivity.instance.start(
      pcOrigin: result.pcOrigin,
      cookieHeader: result.cookieHeader!,
    );
    _maybeShowApproval();
  }

  /// Open the conversation a notification tap pointed at.
  Future<void> _openSession(String sessionId) async {
    if (sessionId.isEmpty) return;
    final result = _result;
    if (result == null || (result.cookieHeader ?? '').isEmpty) {
      _pendingOpen = sessionId;
      return;
    }
    final activity = SessionActivity.instance;
    var title = activity.titleOf(sessionId);
    if (title == null || title.isEmpty) {
      // Cold start: the activity map has not been primed yet.
      try {
        final rows = await DshRpc(
          pcOrigin: result.pcOrigin,
          cookieHeader: result.cookieHeader!,
        ).listSessions();
        for (final row in rows) {
          if (row.sessionId == sessionId) {
            title = row.title;
            break;
          }
        }
      } catch (_) {
        // Offline: fall back to the generic label.
      }
    }
    if (!mounted) return;
    // The notification is for the conversation that is already the current
    // page (e.g. the app was backgrounded mid-turn): resuming is enough,
    // pushing another copy would just stack two identical chats.
    if (activity.isShowing(sessionId)) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          sessionId: sessionId,
          title: title ?? '会话',
          pcOrigin: result.pcOrigin,
          cookieHeader: result.cookieHeader!,
          parentSessionId: activity.parentOf(sessionId),
        ),
      ),
    );
  }

  Future<void> _claimPendingNotification() async {
    final id = await Notifier.instance.takePending();
    if (!mounted || id == null || id.isEmpty) return;
    _openSession(id);
  }

  /// Nudge once, right after the first successful pairing. Every later launch
  /// stays clean: the pairing page never carries a permanent settings row.
  Future<void> _maybeShowNotificationHint() async {
    if (!mounted) return;
    // A notification tap may be about to open a conversation; do not stack a
    // dialog on top of it.
    if (_pendingOpen != null) return;
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_hintKey) == true) return;
    if (!mounted) return;
    await preferences.setBool(_hintKey, true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '后台通知',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          '退到后台或锁屏后，任务完成会提醒你，点通知直达对应会话。\n\n'
          'Android 会冻结普通后台应用：把本应用的省电策略设为「无限制」，通知才不会被系统掐断。',
          style: TextStyle(fontSize: 14, height: 1.45, color: Color(0xFF3A3A3C)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              '暂不',
              style: TextStyle(fontSize: 15, color: Color(0xFF8E8E93)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              PowerSettings.requestExempt();
            },
            child: const Text(
              '去设置',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF007AFF),
              ),
            ),
          ),
        ],
      ),
    );
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
      _reachable = null;
      _probeFailure = null;
    });
    _watchApprovals(_result!);
    unawaited(_probe());
    final pending = _pendingOpen;
    if (pending != null) {
      _pendingOpen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openSession(pending));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowNotificationHint());
    }
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
    if (result.ok) {
      _watchApprovals(result);
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowNotificationHint());
    }
  }

  /// Forget the current PC; switch to another saved one when present.
  Future<void> _unpair() async {
    await ApprovalCenter.instance.stop();
    await SessionActivity.instance.stop();
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
      LinkPhase.unpaired => '连接你的 PC',
      LinkPhase.pairing => '配对中…',
      LinkPhase.failed => '配对失败',
      LinkPhase.paired => '已与 PC 绑定',
    };
    final detail = switch (_phase) {
      LinkPhase.unpaired =>
        '在 PC 上打开 dsh → 设置 →「扫码配对」，\n或手动粘贴配对链接。',
      LinkPhase.failed => _result?.error ?? '未知错误',
      LinkPhase.paired => _pairedDetail,
      LinkPhase.pairing => '',
    };
    final detailColor = _reachable == false
        ? const Color(0xFFE5453C)
        : const Color(0xFF8E8E93);
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(title: const Text('DeepSeek Harness')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Center(
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
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: detailColor,
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
                      if (_phase == LinkPhase.paired && _reachable == false) ...[
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: _probing ? null : _probe,
                          child: Text(
                            _probing ? '正在检查…' : '重新检查连接',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF007AFF),
                            ),
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
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                'DeepSeek Harness $appVersion',
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.3,
                  color: Color(0xFFC7C7CC),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The line under "已与 PC 绑定": calm copy only while the PC answers.
  String get _pairedDetail {
    if (_reachable != false) {
      return _probing && _reachable == null ? '正在检查连接…' : '会话和模型与 PC 实时同步';
    }
    if (_probeFailure?.stalePairing == true) {
      return '配对已失效：在 PC 上重新扫码配对一次';
    }
    return '连不上这台 PC · 检查 dsh 是否在运行、手机是否还在同一 WiFi';
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
