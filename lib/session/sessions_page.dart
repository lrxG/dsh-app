import 'dart:async';

import 'package:flutter/material.dart';

import 'dsh_client.dart';
import 'chat_page.dart';
import 'mux_client.dart';
import 'session_activity.dart';
import '../version.dart';

/// Session list mirroring the PC sidebar: subagent/child durable summaries
/// hidden (`origin:'subagent'`, same rule as dsh ui-workspace), archived
/// sessions hidden (PC's archive action), groups taken from the PC's
/// Workspace registry (user titles + 「未分组」 bucket), iOS "inset grouped"
/// visuals.
class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.pcOrigin,
    required this.cookieHeader,
  });

  final String pcOrigin;
  final String cookieHeader;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  late final DshRpc _rpc;
  List<SessionSummary>? _items;

  /// Every visible summary (incl. blanks), used by the ＋ reuse path.
  List<SessionSummary> _allItems = const [];

  /// Archived sessions (hidden from the grouping, restorable from PC or here).
  List<SessionSummary> _archived = const [];

  /// Pinned session ids (registry-global), rendered ahead of unpinned rows.
  Set<String> _pinned = const {};

  /// PC model catalog, used to show each row's model name.
  ModelCatalogData? _catalog;

  /// PC Workspace registry (titles, membership, archived set). Null when the
  /// snapshot failed — grouping then falls back to cwd tails.
  WorkspaceSnapshot? _workspaces;
  RpcFailure? _error;
  bool _loading = false;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _rpc = DshRpc(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    // Live agent status (including subagent descendants) drives the row dots.
    SessionActivity.instance.addListener(_onActivity);
    _refresh();
  }

  @override
  void dispose() {
    SessionActivity.instance.removeListener(_onActivity);
    super.dispose();
  }

  void _onActivity() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final snapshotFuture = _loadWorkspaces();
      final catalogFuture = _rpc.modelCatalog().catchError((Object _) => null);
      final items = await _rpc.listSessions();
      final snapshot = await snapshotFuture;
      final catalog = await catalogFuture;
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _workspaces = snapshot;
        _pinned = (snapshot?.pinnedSessionIds ?? const <String>[]).toSet();
        // PC sidebar rule: subagent durable summaries and archived sessions
        // never render in the main grouping.
        final archived = snapshot?.archivedSessionIds ?? const <String>{};
        final visible = items.where((s) => !s.hiddenOnPc).toList();
        // Reuse targets must be live blanks: archived blanks are refused by the
        // Host's reuse gate, which used to fail every new-session tap.
        _allItems = visible
            .where((s) => !archived.contains(s.sessionId))
            .toList();
        // PC hides blank sessions (created but never used); mirror it and keep
        // them only as the ＋ reuse target.
        _items = _allItems.where((s) => !s.blank).toList();
        _archived = visible
            .where((s) => archived.contains(s.sessionId))
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeFailure(error);
        _loading = false;
      });
    }
  }

  /// One-shot `workspace/follow` over a short-lived mux socket.
  Future<WorkspaceSnapshot?> _loadWorkspaces() async {
    final mux = MuxClient(
      pcOrigin: widget.pcOrigin,
      cookieHeader: widget.cookieHeader,
    );
    try {
      await mux.connect();
      return await mux.fetchWorkspaceSnapshot();
    } catch (_) {
      return null;
    } finally {
      await mux.close();
    }
  }

  /// `session/create` in a Workspace (like the PC's New Session), reusing that
  /// Workspace's newest blank, then open chat. A session created without a
  /// Workspace lands in「未分组」, so pick one whenever the PC lists any.
  Future<void> _create() async {
    if (_creating) return;
    // A tap during the first refresh would otherwise see an empty registry and
    // create an ungrouped session; wait for the Workspace snapshot first.
    var workspaces = _workspaces?.items ?? const <WorkspaceInfo>[];
    if (_workspaces == null) {
      setState(() => _creating = true);
      final snapshot = await _loadWorkspaces();
      if (!mounted) return;
      if (snapshot != null) _workspaces = snapshot;
      setState(() => _creating = false);
      if (!mounted) return;
      workspaces = snapshot?.items ?? const <WorkspaceInfo>[];
    }
    String? workspaceId;
    if (workspaces.length == 1) {
      workspaceId = workspaces.first.workspaceId;
    } else if (workspaces.length > 1) {
      workspaceId = await _pickWorkspace(workspaces);
      if (!mounted) return;
      if (workspaceId == null) return; // cancelled
    }
    setState(() => _creating = true);
    try {
      // Reuse only a blank that belongs to the target Workspace (the Host's
      // reuse gate requires membership); otherwise create a fresh one there.
      final memberIds = workspaceId == null
          ? null
          : workspaces
              .firstWhere((w) => w.workspaceId == workspaceId)
              .sessionIds
              .toSet();
      SessionSummary? blankRow;
      for (final s in _allItems) {
        if (!s.blank) continue;
        if (memberIds != null && !memberIds.contains(s.sessionId)) continue;
        if (blankRow == null || s.updatedAt > blankRow.updatedAt) blankRow = s;
      }
      final request = <String, dynamic>{
        'workspaceId': ?workspaceId,
        if (blankRow != null) 'sessionId': blankRow.sessionId,
      };
      Map? value;
      try {
        value = await _rpc.call('session/create', {'request': request}) as Map?;
      } on RpcError {
        // The blank may have become unusable (archived elsewhere, membership
        // changed). Never fail the tap: create fresh in the same Workspace.
        if (request.isEmpty) rethrow;
        value = await _rpc.call('session/create', {
          'request': <String, dynamic>{
            'workspaceId': ?workspaceId,
          },
        }) as Map?;
      }
      final sessionId = value is Map ? '${value['sessionId']}' : '';
      if (!mounted) return;
      if (sessionId.isEmpty) throw 'session/create 未返回 sessionId';
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            sessionId: sessionId,
            title: '新会话',
            pcOrigin: widget.pcOrigin,
            cookieHeader: widget.cookieHeader,
          ),
        ),
      );
      if (mounted) _refresh();
    } on RpcError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('新建失败：${e.code} ${e.message}'),
          backgroundColor: const Color(0xFFE5453C),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('网络错误：$e'),
          backgroundColor: const Color(0xFFE5453C),
        ));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Workspace caption from a cwd path (last segment, like PC's `~` tail).
  static String _workspaceOf(String? cwd) {
    if (cwd == null || cwd.isEmpty) return '未指定目录';
    final parts = cwd.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? cwd : parts.last;
  }

  /// `今天 HH:mm` / `昨天` / `MM-dd` / `yyyy-MM-dd`, driven by local time.
  static String _timeOf(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.year, t.month, t.day);
    final diff = today.difference(d).inDays;
    final hh = '${t.hour}'.padLeft(2, '0');
    final mm = '${t.minute}'.padLeft(2, '0');
    if (diff <= 0) return '今天 $hh:$mm';
    if (diff == 1) return '昨天 $hh:$mm';
    if (t.year == now.year) return '${t.month}-${'${t.day}'.padLeft(2, '0')} $hh:mm';
    return '${t.year}-${t.month}-${'${t.day}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F2F7),
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF007AFF),
        elevation: 0,
        centerTitle: true,
        title: Text(
          'DSH 会话',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, size: 23),
            tooltip: '搜索会话',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: _creating
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Color(0xFF007AFF)),
                  )
                : const Icon(Icons.add, size: 26),
            tooltip: '新建会话',
            onPressed: _creating ? null : _create,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: switch ((_items, _error)) {
              (_, final RpcFailure e) => _ErrorView(
                  e,
                  onRetry: _refresh,
                  onRepair: () => Navigator.of(context).popUntil((r) => r.isFirst),
                ),
              (final List<SessionSummary> list, null) when list.isEmpty =>
                const _EmptyView(),
              (final List<SessionSummary> list, null) => _buildList(list),
              _ => const Center(
                  child: CircularProgressIndicator(color: Color(0xFF007AFF)),
                ),
            },
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Text(
                'DeepSeek Harness $appVersion',
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.3,
                  color: Color(0xFFC7C7CC),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<SessionSummary> list) {
    final sections = _group(list);
    final total = sections.values.fold<int>(0, (n, rows) => n + rows.length);

    return RefreshIndicator(
      color: const Color(0xFF007AFF),
      onRefresh: _refresh,
      child: ListView.custom(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        childrenDelegate: SliverChildBuilderDelegate(
          (context, index) => _section(sections, index, total),
          childCount: _childCount(sections),
        ),
      ),
    );
  }

  /// PC sidebar composition: Workspaces in registry order with their user
  /// titles, then the「未分组」bucket for sessions no Workspace accounts for
  /// (membership comes from the registry's `sessionIds`, never a cwd guess).
  /// Without a snapshot, fall back to cwd-tail groups.
  Map<String, List<SessionSummary>> _group(List<SessionSummary> list) {
    final sections = <String, List<SessionSummary>>{};
    final snapshot = _workspaces;
    // Pinned rows first (registry-global), then newest activity.
    int newestFirst(SessionSummary a, SessionSummary b) {
      final aPinned = _pinned.contains(a.sessionId);
      final bPinned = _pinned.contains(b.sessionId);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    }

    if (snapshot == null) {
      final sorted = [...list]..sort(newestFirst);
      for (final s in sorted) {
        sections.putIfAbsent(_workspaceOf(s.cwd), () => []).add(s);
      }
    } else {
      final owner = <String, String>{};
      for (final w in snapshot.items) {
        for (final id in w.sessionIds) {
          owner[id] = w.workspaceId;
        }
      }
      final grouped = <String, List<SessionSummary>>{};
      final loose = <SessionSummary>[];
      for (final s in list) {
        final workspaceId = owner[s.sessionId];
        if (workspaceId == null) {
          loose.add(s);
        } else {
          grouped.putIfAbsent(workspaceId, () => []).add(s);
        }
      }
      for (final w in snapshot.items) {
        final rows = grouped[w.workspaceId];
        if (rows == null || rows.isEmpty) continue;
        rows.sort(newestFirst);
        // Keep titles unique as section keys (two workspaces may share one).
        var label = w.title;
        var n = 2;
        while (sections.containsKey(label)) {
          label = '${w.title} ($n)';
          n++;
        }
        sections[label] = rows;
      }
      if (loose.isNotEmpty) {
        loose.sort(newestFirst);
        sections['未分组'] = loose;
      }
    }

    sections.removeWhere((_, rows) => rows.isEmpty);
    return sections;
  }

  int _childCount(Map<String, List<SessionSummary>> sections) {
    var n = 1; // top spacer
    for (final rows in sections.values) {
      n += 1 + rows.length; // header + rows
    }
    if (_archived.isNotEmpty) n += 1; // trailing "已归档" entry
    return n;
  }

  Widget _section(
    Map<String, List<SessionSummary>> sections,
    int index,
    int total,
  ) {
    var i = index;
    if (i == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
        child: Text(
          _loading ? '正在刷新…' : '$total 个会话 · 下拉刷新',
          style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
        ),
      );
    }
    i -= 1;
    if (_archived.isNotEmpty && index == _childCount(sections) - 1) {
      return _ArchivedEntry(count: _archived.length, onTap: _openArchived);
    }
    for (final entry in sections.entries) {
      final rows = entry.value;
      if (i == 0) {
        return _SectionHeader(entry.key);
      }
      if (i <= rows.length) {
        final row = rows[i - 1];
        return _SessionRow(
          summary: row,
          timeText: _timeOf(row.updatedAt),
          modelText: _modelText(row),
          showDivider: i != rows.length,
          first: i == 1,
          last: i == rows.length,
          pinned: _pinned.contains(row.sessionId),
          onTap: () => _open(row),
          onLongPress: () => _showActions(row),
        );
      }
      i -= 1 + rows.length;
    }
    return const SizedBox.shrink();
  }

  Future<void> _openArchived() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ArchivedSessionsPage(
          pcOrigin: widget.pcOrigin,
          cookieHeader: widget.cookieHeader,
          initial: _archived,
        ),
      ),
    );
    if (changed == true && mounted) _refresh();
  }

  /// iOS action sheet for one row: rename, pin, archive.
  Future<void> _showActions(SessionSummary s) async {
    final pinned = _pinned.contains(s.sessionId);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                s.blank ? '新会话' : (s.title ?? '未命名'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6D6D72)),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _SheetAction(
                    label: '重命名',
                    onTap: () => Navigator.pop(ctx, 'rename'),
                  ),
                  _SheetAction(
                    label: pinned ? '取消置顶' : '置顶',
                    onTap: () => Navigator.pop(ctx, 'pin'),
                  ),
                  _SheetAction(
                    label: '从列表移除（归档）',
                    destructive: true,
                    onTap: () => Navigator.pop(ctx, 'archive'),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: _SheetAction(
                label: '取消',
                bold: true,
                onTap: () => Navigator.pop(ctx, 'cancel'),
              ),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'rename':
        await _rename(s);
      case 'pin':
        await _togglePin(s);
      case 'archive':
        await _confirmRemove(s);
    }
  }

  Future<void> _rename(SessionSummary s) async {
    final controller =
        TextEditingController(text: s.blank ? '' : (s.title ?? ''));
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '重命名会话',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(
            hintText: '会话标题',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (text) => Navigator.pop(ctx, text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(fontSize: 15, color: Color(0xFF007AFF))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text(
              '保存',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF007AFF)),
            ),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    try {
      await _rpc.renameSession(s.sessionId, value);
      if (mounted) _refresh();
    } on RpcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('重命名失败：${e.code} ${e.message}'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    }
  }

  Future<void> _togglePin(SessionSummary s) async {
    final pinned = _pinned.contains(s.sessionId);
    try {
      await _rpc.setPinned(s.sessionId, pinned: !pinned);
      if (mounted) _refresh();
    } on RpcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${pinned ? '取消置顶' : '置顶'}失败：${e.code} ${e.message}'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    }
  }

  /// Model caption for one row: the session's own pick, else the deployment
  /// default (marked as such), resolved through the catalog display names.
  String _modelText(SessionSummary s) {
    final selection = s.model ?? _catalog?.default_;
    if (selection == null) return '模型未配置';
    final label = _catalog?.displayName(selection) ?? selection.model;
    return s.model == null ? '$label · 默认' : label;
  }

  /// Sheet to choose the Workspace for a new session. Only real workspaces are
  /// offered: a session's cwd must equal the workspace path, and creating
  /// without one lands in dsh's install directory (useless for project work).
  /// Returns a workspace id, or null when cancelled.
  Future<String?> _pickWorkspace(List<WorkspaceInfo> workspaces) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '新建到哪个工作区？',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6D6D72),
                  ),
                ),
              ),
              for (final workspace in workspaces)
                _SheetAction(
                  label: workspace.title,
                  onTap: () => Navigator.pop(ctx, workspace.workspaceId),
                ),
              const Divider(height: 0.5, thickness: 0.5, color: Color(0xFFE5E5EA)),
              _SheetAction(
                label: '取消',
                bold: true,
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionSearchPage(
          pcOrigin: widget.pcOrigin,
          cookieHeader: widget.cookieHeader,
        ),
      ),
    );
    if (mounted) _refresh();
  }

  /// Long-press → archive one session (`workspace/archiveSession`), the same
  /// action the PC sidebar's row menu performs. Archived sessions leave the
  /// grouping on both sides and stay restorable from the PC.
  Future<void> _confirmRemove(SessionSummary s) async {
    final label = s.blank ? '新会话' : (s.title ?? '未命名');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '从列表移除？',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        content: Text(
          s.running
              ? '「$label」正在运行，将从 PC 与手机的会话列表移除（归档），并先停止它的运行。PC 端可随时恢复。'
              : '「$label」将从 PC 与手机的会话列表移除（归档），PC 端可随时恢复。',
          style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF3A3A3C)),
        ),
        actionsAlignment: MainAxisAlignment.end,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '取消',
              style: TextStyle(fontSize: 15, color: Color(0xFF007AFF)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '移除',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE5453C),
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _rpc.call('workspace/archiveSession', {
        'request': {
          'sessionId': s.sessionId,
          if (s.running) 'stopActivity': true,
        },
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已从列表移除（PC 端可恢复）'),
        duration: Duration(seconds: 2),
      ));
      _refresh();
    } on RpcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('移除失败：${e.code} ${e.message}'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('网络错误：$e'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    }
  }

  Future<void> _open(SessionSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          sessionId: s.sessionId,
          title: s.blank ? '新会话' : (s.title ?? '未命名'),
          pcOrigin: widget.pcOrigin,
          cookieHeader: widget.cookieHeader,
        ),
      ),
    );
    // The chat page can rename/fork/archive; pick those up on return.
    if (mounted) _refresh();
  }
}

/// Grey caps caption above one card group (iOS section header).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF6D6D72),
        ),
      ),
    );
  }
}

/// One inset-grouped row card: title + status + cwd caption + relative time.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.summary,
    required this.timeText,
    required this.modelText,
    required this.showDivider,
    required this.first,
    required this.last,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final SessionSummary summary;
  final String timeText;
  final String modelText;
  final bool showDivider;

  /// Rows of one section form a single iOS grouped card: only the first and
  /// last rows keep the outer corners, so abutting rows do not show the
  /// pinched notch of two rounded cards meeting.
  final bool first;
  final bool last;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    // A parent that delegated to subagents is idle itself, exactly like the PC
    // sidebar: the row stays "active" while any descendant runs.
    final children = SessionActivity.instance.runningDescendants(summary.sessionId);
    final running = summary.running || children > 0;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(first ? 12 : 0),
        bottom: Radius.circular(last ? 12 : 0),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (pinned) ...[
                    const Icon(Icons.push_pin,
                        size: 14, color: Color(0xFF007AFF)),
                    const SizedBox(width: 5),
                  ],
                  Expanded(
                    child: Text(
                      summary.blank ? '新会话' : (summary.title ?? '未命名'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (running) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF30D158), // iOS green
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    timeText,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8E8E93),
                      // Ordered column: with proportional digits "17:11" is
                      // narrower than "05:25", so same-length timestamps
                      // started at different x and the column looked ragged.
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                children > 0 ? '$modelText · 子智能体 ×$children' : modelText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: children > 0
                      ? const Color(0xFF30A14E)
                      : const Color(0xFF8A8A8E),
                ),
              ),
              if (showDivider)
                Container(height: 0.5, color: const Color(0xFFE5E5EA)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One iOS action-sheet row.
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.bold = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              color: destructive ? const Color(0xFFE5453C) : const Color(0xFF007AFF),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the combined search result (name match or content match).
class _SearchRow {
  const _SearchRow({
    required this.sessionId,
    required this.byName,
    this.summary,
    this.snippet,
  });

  final String sessionId;
  final bool byName;
  final SessionSummary? summary;
  final String? snippet;
}

/// Session search over **names and message content**.
///
/// The Host's `session/search` is FTS5 phrase matching over message content
/// only, so names are matched here (case-insensitive) and merged with content
/// hits. Content hits keep the Host's semantics; for ASCII queries typed with
/// upper-case letters only hits whose snippet keeps that case are shown.
class SessionSearchPage extends StatefulWidget {
  const SessionSearchPage({
    super.key,
    required this.pcOrigin,
    required this.cookieHeader,
  });

  final String pcOrigin;
  final String cookieHeader;

  @override
  State<SessionSearchPage> createState() => _SessionSearchPageState();
}

class _SessionSearchPageState extends State<SessionSearchPage> {
  late final DshRpc _rpc;
  final TextEditingController _input = TextEditingController();
  Timer? _debounce;
  List<_SearchRow> _rows = const [];
  Map<String, SessionSummary> _summaries = const {};
  bool _loading = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _rpc = DshRpc(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    _loadSummaries();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadSummaries() async {
    try {
      final items = await _rpc.listSessions();
      if (!mounted) return;
      setState(() {
        _summaries = {
          for (final s in items)
            if (!s.hiddenOnPc && !s.blank) s.sessionId: s,
        };
      });
      if (_query.isNotEmpty) _debounceNow();
    } catch (_) {
      // Titles are cosmetic; content search still works without them.
    }
  }

  void _onChanged(String value) {
    _query = value.trim();
    _debounce?.cancel();
    if (_query.isEmpty) {
      setState(() {
        _rows = const [];
        _loading = false;
      });
      return;
    }
    _debounceNow();
  }

  void _debounceNow() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      final query = _query;
      if (query.isNotEmpty) _search(query);
    });
  }

  Future<void> _search(String query) async {
    final lower = query.toLowerCase();
    // 1) Name matches: client-side, case-insensitive, every length.
    final nameHits = _summaries.values
        .where((s) => (s.title ?? '').toLowerCase().contains(lower))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final seen = nameHits.map((s) => s.sessionId).toSet();
    final rows = <_SearchRow>[
      for (final s in nameHits)
        _SearchRow(sessionId: s.sessionId, byName: true, summary: s),
    ];

    setState(() {
      _loading = true;
    });

    // 2) Content matches from the Host's FTS index. A query that hits nothing
    // (or a Host whose index is unavailable) simply leaves the name matches
    // standing: an empty result is an empty result, not an error to explain.
    try {
      final result = await _rpc.searchSessions(query);
      if (!mounted) return;
      // Content is case-sensitive: the snippet must carry the typed spelling.
      // (Names above stay case-insensitive.)
      final asciiQuery = RegExp(r'^[\x20-\x7E]+$').hasMatch(query);
      for (final item in result.items) {
        if (seen.contains(item.sessionId)) continue;
        final summary = _summaries[item.sessionId];
        if (summary != null && summary.blank) continue;
        if (asciiQuery && !item.snippet.contains(query)) continue;
        rows.add(_SearchRow(
          sessionId: item.sessionId,
          byName: false,
          summary: summary,
          snippet: item.snippet,
        ));
      }
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    }
  }

  void _open(_SearchRow row) {
    final summary = row.summary ?? _summaries[row.sessionId];
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          sessionId: row.sessionId,
          title: summary == null
              ? '会话'
              : (summary.blank ? '新会话' : (summary.title ?? '未命名')),
          pcOrigin: widget.pcOrigin,
          cookieHeader: widget.cookieHeader,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F2F7),
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF007AFF),
        elevation: 0,
        title: TextField(
          controller: _input,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 16.5, color: Color(0xFF1C1C1E)),
          decoration: const InputDecoration(
            hintText: '搜索会话名或内容…',
            hintStyle: TextStyle(color: Color(0xFF8E8E93)),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: Color(0xFF007AFF)),
                ),
              ),
            ),
        ],
      ),
      body: _query.isEmpty
          ? const Center(
              child: Text(
                '输入关键字，匹配会话名和聊天内容',
                style: TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
              ),
            )
          : _rows.isEmpty
              ? Center(
                  child: Text(
                    _loading ? '搜索中…' : '没有匹配的会话',
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF8E8E93)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final row = _rows[index];
                    final summary = row.summary ?? _summaries[row.sessionId];
                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _open(row),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      summary == null
                                          ? '会话'
                                          : (summary.blank
                                              ? '新会话'
                                              : (summary.title ?? '未命名')),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1C1C1E),
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: row.byName
                                          ? const Color(0x1A007AFF)
                                          : const Color(0x1464D2C6),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      row.byName ? '名称' : '内容',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: row.byName
                                            ? const Color(0xFF007AFF)
                                            : const Color(0xFF2E9E93),
                                      ),
                                    ),
                                  ),
                                  if (summary != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _SessionsPageState._timeOf(summary.updatedAt),
                                      style: const TextStyle(
                                          fontSize: 12, color: Color(0xFF8E8E93)),
                                    ),
                                  ],
                                ],
                              ),
                              if (row.snippet != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  row.snippet!.replaceAll(RegExp(r'\s+'), ' '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                    color: Color(0xFF3A3A3C),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.forum_outlined, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            'PC 上还没有可同步的会话',
            style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 6),
          Text(
            '点右上角 ＋ 新建一个试试',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView(this.failure, {required this.onRetry, required this.onRepair});

  final RpcFailure failure;
  final VoidCallback onRetry;

  /// Back to the pairing page: the stored cookie is dead, only a scan helps.
  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              failure.unreachable ? Icons.wifi_off_rounded : Icons.link_off_rounded,
              size: 52,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 14),
            Text(
              failure.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1C1C1E),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              failure.detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.45),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF007AFF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('重试', style: TextStyle(fontSize: 15)),
                ),
                if (failure.stalePairing) ...[
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: onRepair,
                    child: const Text(
                      '重新配对',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF007AFF),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Trailing entry opening the archived-session list.
class _ArchivedEntry extends StatelessWidget {
  const _ArchivedEntry({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Row(
              children: [
                const Icon(Icons.archive_outlined, size: 19, color: Color(0xFF8E8E93)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '已归档',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF3A3A3C),
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 19, color: Color(0xFFC7C7CC)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Archived sessions with one-tap restore (`workspace/unarchiveSession`).
/// Pops `true` when anything was restored so the caller refreshes.
class ArchivedSessionsPage extends StatefulWidget {
  const ArchivedSessionsPage({
    super.key,
    required this.pcOrigin,
    required this.cookieHeader,
    required this.initial,
  });

  final String pcOrigin;
  final String cookieHeader;
  final List<SessionSummary> initial;

  @override
  State<ArchivedSessionsPage> createState() => _ArchivedSessionsPageState();
}

class _ArchivedSessionsPageState extends State<ArchivedSessionsPage> {
  late final DshRpc _rpc;
  late List<SessionSummary> _rows;
  final Set<String> _busy = {};
  bool _loading = false;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _rpc = DshRpc(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    _rows = [...widget.initial];
    _reload();
  }

  /// Refresh from the host: `session/list` + the registry archive set.
  Future<void> _reload() async {
    setState(() => _loading = true);
    final mux = MuxClient(
      pcOrigin: widget.pcOrigin,
      cookieHeader: widget.cookieHeader,
    );
    try {
      final items = await _rpc.listSessions();
      WorkspaceSnapshot? snapshot;
      try {
        await mux.connect();
        snapshot = await mux.fetchWorkspaceSnapshot();
      } catch (_) {
        snapshot = null;
      }
      final archived = snapshot?.archivedSessionIds ?? const <String>{};
      if (!mounted) return;
      setState(() {
        _rows = items
            .where((s) => !s.hiddenOnPc && archived.contains(s.sessionId))
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('读取归档失败：$e'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    } finally {
      await mux.close();
    }
  }

  Future<void> _restore(SessionSummary s) async {
    if (_busy.contains(s.sessionId)) return;
    setState(() => _busy.add(s.sessionId));
    try {
      await _rpc.call('workspace/unarchiveSession', {
        'request': {'sessionId': s.sessionId},
      });
      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => r.sessionId == s.sessionId);
        _busy.remove(s.sessionId);
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已恢复到会话列表'),
        duration: Duration(seconds: 2),
      ));
    } on RpcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('恢复失败：${e.code} ${e.message}'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('网络错误：$e'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    } finally {
      if (mounted) setState(() => _busy.remove(s.sessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF2F2F7),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF2F2F7),
          surfaceTintColor: Colors.transparent,
          foregroundColor: const Color(0xFF007AFF),
          elevation: 0,
          centerTitle: true,
          leading: BackButton(
            onPressed: () => Navigator.pop(context, _changed),
          ),
          title: const Text(
            '已归档',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1C1C1E),
            ),
          ),
        ),
        body: _loading && _rows.isEmpty
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF007AFF)),
              )
            : _rows.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.archive_outlined,
                            size: 54, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Text(
                          '没有已归档的会话',
                          style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '长按会话即可从列表移除（归档）',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    color: const Color(0xFF007AFF),
                    onRefresh: _reload,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final s = _rows[index];
                        final busy = _busy.contains(s.sessionId);
                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.blank ? '新会话' : (s.title ?? '未命名'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1C1C1E),
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${_SessionsPageState._timeOf(s.updatedAt)} · ${s.cwd ?? '未指定目录'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF8A8A8E),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Color(0xFF007AFF),
                                        ),
                                      )
                                    : TextButton(
                                        onPressed: () => _restore(s),
                                        style: TextButton.styleFrom(
                                          foregroundColor: const Color(0xFF007AFF),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 6),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text(
                                          '恢复',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}
