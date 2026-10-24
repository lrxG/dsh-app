import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import 'dsh_client.dart';
import 'files.dart';
import 'jobs_page.dart';
import 'messages.dart';
import 'mux_client.dart';
import 'notify.dart';
import 'session_activity.dart';

/// Chat view of one session: durable snapshot → bubbles, live `event` frames
/// appended, transient `assistant-stream` chunks rendered as a live bubble.
/// The bottom bar sends `session/prompt` (mode picks steer when the agent is
/// visibly working, queue otherwise).
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.sessionId,
    required this.title,
    required this.pcOrigin,
    required this.cookieHeader,
    this.parentSessionId,
    this.subagentMode = 'unknown',
  });

  final String sessionId;
  final String title;
  final String pcOrigin;
  final String cookieHeader;

  /// Set for a subagent conversation: dsh requires the durable parent address
  /// to open it, and one-shot children are read-only.
  final String? parentSessionId;
  final String subagentMode;

  bool get isSubagent => parentSessionId != null;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  MuxClient _mux = MuxClient(pcOrigin: '', cookieHeader: '');
  late final DshRpc _rpc;
  StreamSubscription<MuxEvent>? _sub;

  final List<ChatMessage> _messages = [];
  LiveAssistant? _live;

  String _state = '连接中…';
  Color _stateColor = Colors.orange;
  bool _reconnectable = false;

  /// Terminal state: the PC no longer knows this cookie (dsh restarted, the
  /// owner-peer registry is in-process). Only re-pairing recovers.
  bool _needRescan = false;

  /// Auto-reconnect loop after an unclean close.
  Timer? _retryTimer;
  int _autoFailures = 0;
  static const int _autoMax = 6;

  /// Agent visibly between assistant-stream start…end.
  bool _busy = false;

  /// Local title (rename updates it without rebuilding the parent list).
  late String _title = widget.title;

  /// PC-synced model state: catalog + this session's durable selection.
  ModelCatalogData? _catalog;
  ModelSelection? _selection;
  bool _pickingModel = false;

  /// Screen 1 pick: tapped model awaiting its effort choice (null = model list).
  _PickContext? _pickScreen;

  /// effort id tapped on screen 1 (reset when leaving this flow).
  String? _pickEffort;

  bool _sending = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// One staged photo (compressed JPEG), sent as an inline image part.
  Uint8List? _pendingImage;
  String? _pendingImageName;
  bool _pickingImage = false;

  /// One staged document; uploaded before the prompt and cited by receipt.
  AttachmentFile? _pendingFile;

  /// Last "answer finished" notification, to avoid duplicates from the
  /// stream-end frame plus the durable message echo.
  DateTime? _lastTurnNotify;

  /// Current conversation: starts as [ChatPage.sessionId] and switches to the
  /// fork's id once the first prompt creates it (see [_forkArmed]).
  late String _sessionId;

  /// dsh's `session/fork` persists a session immediately, so arming the action
  /// and forking together with the first prompt is the only way to avoid
  /// leaving an unused fork on the PC (there is no delete RPC).
  bool _forkArmed = false;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _mux = MuxClient(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    _rpc = DshRpc(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    // Send-button tint follows the field content.
    _input.addListener(() {
      if (mounted) setState(() {});
    });
    SessionActivity.instance.activeSessionId = _sessionId;
    SessionActivity.instance.addListener(_onActivity);
    _follow(auto: false);
  }

  void _onActivity() {
    if (mounted) setState(() {});
  }

  /// Full re-dial of the follow stream. Manual taps reset the auto-retry
  /// loop; auto runs stop once [needRescan] turns the action into re-pairing.
  Future<void> _follow({required bool auto}) async {
    _retryTimer?.cancel();
    if (auto && _needRescan) return;
    setState(() {
      if (!auto) {
        _needRescan = false;
        _autoFailures = 0;
        _messages.clear();
        _live = null;
        _busy = false;
      }
      _reconnectable = false;
      _state = '连接中…';
      _stateColor = Colors.orange;
    });
    if (!await _reachable()) {
      _scheduleRetry();
      return;
    }
    _sub?.cancel();
    _sub = null;
    await _mux.close(); // ends any half-dead socket from the previous run
    final fresh = MuxClient(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    try {
      await fresh.connect();
      _sub = fresh.followSession(
        _sessionId,
        parentSessionId: widget.parentSessionId,
        mode: widget.subagentMode,
      ).listen(
        _onFrame,
        onError: _onStreamError,
        onDone: _onClosed,
      );
      _mux = fresh;
    } catch (e) {
      _setState('连不上 Mux：$e', Colors.red);
      setState(() => _reconnectable = true);
      _scheduleRetry();
      return;
    }
    _loadModelState();
  }

  /// Pull the PC catalog + this session's projected selection (parallel).
  Future<void> _loadModelState() async {
    try {
      final results = await Future.wait([
        _rpc.modelCatalog().catchError((Object _) => null as ModelCatalogData?),
        _rpc.sessionModel(_sessionId).catchError((Object _) => null as ModelSelection?),
      ]);
      if (!mounted) return;
      setState(() {
        _catalog = results[0] as ModelCatalogData?;
        _selection = results[1] as ModelSelection?;
      });
    } catch (_) {
      // Model chip quietly stays hidden; chat still works without it.
    }
  }

  /// What the AppBar chip shows. An unconfigured session mirrors the PC
  /// composer seat: the catalog deployment default is what a prompt would use.
  String _chipLabel() {
    final catalog = _catalog;
    final selection = _selection ?? catalog?.default_;
    final name = catalog?.displayName(selection);
    return name ?? '选择模型';
  }

  bool get _chipEnabled {
    final catalog = _catalog;
    return catalog != null && catalog.routableGroups.isNotEmpty;
  }

  /// iOS-style bottom-sheet picker over the PC catalog, mirroring the PC
  /// composer: provider sections (display names), model rows with description,
  /// then a reasoning-effort step when the chosen route owns one. The final
  /// choice lands via `session/selectModel` (Host validates and returns the
  /// accepted value).
  Future<void> _pickModel() async {
    final catalog = _catalog;
    if (catalog == null || _pickingModel || !mounted) return;
    _pickingModel = true;
    final current = _selection ?? catalog.default_;
    setState(() {
      _pickScreen = null;
      _pickEffort = null;
    });
    try {
      final picked = await showModalBottomSheet<({String provider, String model, String? effort})>(
        context: context,
        backgroundColor: const Color(0xFFF2F2F7),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        isScrollControlled: true,
        builder: (sheetContext) {
          // Two-stage flow inside one sheet: null screen = providers+models,
          // non-null = effort list for the tapped model.
          return StatefulBuilder(
            builder: (sheetContext, setSheet) {
              final screen = _pickScreen;
              final title = screen == null ? '选择模型' : '思考深度';
              return SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.72,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 10, 16, 8),
                        child: Row(children: [
                          if (screen != null)
                            IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                              color: const Color(0xFF007AFF),
                              onPressed: () => setSheet(() {
                                _pickScreen = null;
                                _pickEffort = null;
                              }),                            ),
                          Expanded(
                            child: Text(
                              title,
                              textAlign: screen == null ? TextAlign.left : TextAlign.center,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1C1C1E),
                              ),
                            ),
                          ),
                        ]),
                      ),
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: screen == null
                              ? _modelRows(catalog, current, sheetContext, setSheet)
                              : _effortRows(screen, sheetContext, setSheet),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
      if (picked == null) return;
      final selected = await _rpc.selectModel(
        _sessionId,
        picked.provider,
        picked.model,
        reasoningEffort: picked.effort,
      );
      if (!mounted) return;
      setState(() => _selection = selected);
    } on RpcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('切换模型失败：${e.code} ${e.message}'),
        backgroundColor: const Color(0xFFE5453C),
      ));
    } finally {
      if (mounted) {
        setState(() {
          _pickScreen = null;
          _pickEffort = null;
        });
      }
      _pickingModel = false;
    }
  }

  /// One iOS grouped card: optional caps header + white rounded body with
  /// hairline separators. Returns header + card widgets.
  List<Widget> _groupCard({required String? header, required List<Widget> rows}) => [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
            child: Text(
              header,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6D6D72),
              ),
            ),
          ),
        Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              rows[i],
              if (i != rows.length - 1)
                Container(height: 0.5, color: const Color(0xFFE5E5EA), margin: const EdgeInsets.only(left: 16)),
            ]
          ]),
        ),
      ];

  List<Widget> _modelRows(
    ModelCatalogData catalog,
    ModelSelection? current,
    BuildContext sheetContext,
    StateSetter setSheet,
  ) {
    final widgets = <Widget>[];
    for (final group in catalog.routableGroups) {
      widgets.addAll(_groupCard(
        header: group.name,
        rows: [
          for (final m in group.models)
            _SheetRow(
              title: m.name,
              subtitle: m.description,
              footnote: m.reasoning?.summary,
              selected: current?.provider == group.id && current?.model == m.id,
              onTap: () {
                final r = m.reasoning;
                if (r != null && r.efforts.length > 1) {
                  setSheet(() {
                    _pickScreen = _PickContext(
                      providerId: group.id,
                      providerName: group.name,
                      model: m,
                    );
                    _pickEffort = null;
                  });
                  return;
                }
                Navigator.pop(sheetContext, (
                  provider: group.id,
                  model: m.id,
                  effort: r?.defaultEffort,
                ));
              },
            ),
        ],
      ));
    }
    return widgets;
  }

  List<Widget> _effortRows(
    _PickContext pick,
    BuildContext sheetContext,
    StateSetter setSheet,
  ) {
    final r = pick.model.reasoning!;
    final usedEffort = _pickEffort ?? r.defaultEffort;
    return [
      ..._groupCard(header: pick.model.name, rows: [
        for (final e in r.efforts)
          _SheetRow(
            title: e.name,
            subtitle: e.description,
            selected: usedEffort == null ? e.id == r.defaultEffort : usedEffort == e.id,
            onTap: () {
              Navigator.pop(sheetContext, (
                provider: pick.providerId,
                model: pick.model.id,
                effort: e.id,
              ));
            },
          ),
        ]),
      if (r.defaultEffort != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'PC 当前默认「${r.defaultEffort}」',
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
        ),
    ];
  }

  void _onFrame(MuxEvent event) {
    switch (event) {
      case MuxItem(:final value):
        if (value is! Map) return;
        switch ('${value['type']}') {
          case 'snapshot':
            _onSnapshot(value);
          case 'event':
            final e = value['event'];
            if (e is Map) _onDurableEvent(e);
          case 'assistant-stream':
            _onAssistantStream(value);
        }
      case MuxError(:final code, :final message):
        // Fatal for this follow stream; feed the auto-reconnect loop.
        _setState('流错误 $code：$message', Colors.red);
        setState(() => _reconnectable = true);
        _scheduleRetry();
      case MuxEnd():
        setState(() => _reconnectable = true);
        _scheduleRetry();
    }
  }

  void _onSnapshot(Map value) {
    final bubbles = decodeSnapshot(value);
    _autoFailures = 0;
    setState(() {
      _messages
        ..clear()
        ..addAll(bubbles);
      _state = '已同步 ${_messages.length} 条消息';
      _stateColor = Colors.green;
    });
    _scrollDown();
  }

  void _onDurableEvent(Map event) {
    final msg = decodeEvent(event);
    if (msg == null) return;
    final wasBusy = _busy;
    setState(() {
      // A settled assistant message means the live attempt folded into it.
      if (msg.role == ChatRole.assistant) {
        _live = null;
        _busy = false;
      }
      _messages.add(msg);
      _state = '已同步 ${_messages.length} 条消息';
      _stateColor = Colors.green;
    });
    if (wasBusy && msg.role == ChatRole.assistant) _notifyTurnDone(msg.text);
    _scrollDown();
  }

  /// System notification when a turn that was running has settled.
  void _notifyTurnDone(String text) {
    // Looking at the app means the answer is already on screen.
    if (SessionActivity.instance.isForeground) return;
    final now = DateTime.now();
    if (_lastTurnNotify != null &&
        now.difference(_lastTurnNotify!).inSeconds < 5) {
      return;
    }
    _lastTurnNotify = now;
    final preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    Notifier.instance.show(
      title: '回答完成 · $_title',
      body: preview.isEmpty
          ? '会话已空闲'
          : (preview.length > 80 ? '${preview.substring(0, 80)}…' : preview),
      sessionId: _sessionId,
    );
  }

  void _onAssistantStream(Map value) {
    final frame = value['frame'];
    if (frame is! Map) return;
    switch ('${frame['type']}') {
      case 'start':
        setState(() {
          _busy = true;
          _live = LiveAssistant();
          _state = '生成中…';
          _stateColor = const Color(0xFF5E5CE6); // iOS indigo
        });
      case 'chunk':
        final live = _live;
        if (live == null) return;
        live.applyChunk(frame);
        _refreshLive();
      case 'end':
        final outcome = frame['outcome'];
        setState(() {
          _busy = false;
          if (outcome is! Map || outcome['kind'] != 'committed') {
            _live = null; // abandoned: transient text is gone
          }
          if (_live != null) {
            _state = '已同步 ${_messages.length} 条消息';
            _stateColor = Colors.green;
          }
        });
    }
  }

  /// Throttle rebuilds of the streaming bubble.
  DateTime _lastLivePaint = DateTime.fromMillisecondsSinceEpoch(0);

  void _refreshLive() {
    final now = DateTime.now();
    if (now.difference(_lastLivePaint).inMilliseconds < 80) return;
    _lastLivePaint = now;
    setState(() {});
    _scrollDown();
  }

  /// iOS action sheet: rename / fork / subagent list.
  Future<void> _showMore() async {
    final action = await showModalBottomSheet<String>(
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
              if (!widget.isSubagent) ...[
                _SheetAction(label: '重命名', onTap: () => Navigator.pop(ctx, 'rename')),
                _SheetAction(label: '分叉会话', onTap: () => Navigator.pop(ctx, 'fork')),
              ],
              _SheetAction(label: '子任务', onTap: () => Navigator.pop(ctx, 'subagents')),
              if (!widget.isSubagent)
                _SheetAction(label: '后台任务', onTap: () => Navigator.pop(ctx, 'jobs')),
              const Divider(height: 0.5, thickness: 0.5, color: Color(0xFFE5E5EA)),
              _SheetAction(label: '取消', bold: true, onTap: () => Navigator.pop(ctx, 'cancel')),
            ],
          ),
        ),
      ),
    );
    switch (action) {
      case 'rename':
        await _rename();
      case 'fork':
        _fork();
      case 'subagents':
        await _openSubagents();
      case 'jobs':
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => JobsPage(
                sessionId: _sessionId,
                pcOrigin: widget.pcOrigin,
                cookieHeader: widget.cookieHeader,
              ),
            ),
          );
        }
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _title);
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
          decoration: const InputDecoration(counterText: '', border: OutlineInputBorder()),
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
            child: const Text('保存',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF007AFF))),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    try {
      final normalized = await _rpc.renameSession(_sessionId, value);
      if (mounted) setState(() => _title = normalized);
    } on RpcError catch (e) {
      if (!mounted) return;
      _snack('重命名失败：${e.code} ${e.message}');
    }
  }

  /// Arm the fork instead of creating it: dsh persists a fork immediately and
  /// has no delete RPC, so an abandoned fork would linger on the PC forever.
  /// The session is created together with the first prompt ([_send]).
  void _fork() {
    if (widget.isSubagent) return;
    // dsh forks from a completed turn; a brand-new session has none.
    if (!_messages.any((m) => m.role == ChatRole.assistant)) {
      _snack('还没有完成的回合，无法分叉');
      return;
    }
    setState(() => _forkArmed = true);
  }

  /// List this session's subagent children (hidden from the main list). Forks
  /// also carry lineage but are not subagents, so filter on `origin` here.
  Future<void> _openSubagents() async {
    List<SessionSummary> children;
    try {
      final all = await _rpc.listSessions();
      children = all
          .where((s) => s.origin == 'subagent' && s.parentSessionId == _sessionId)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (e) {
      if (!mounted) return;
      _snack('读取子任务失败：$e');
      return;
    }
    if (!mounted) return;
    if (children.isEmpty) {
      _snack('这个会话还没有子任务');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Text(
                '子任务',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: children.length,
                itemBuilder: (_, index) {
                  final child = children[index];
                  return ListTile(
                    dense: true,
                    title: Text(
                      child.title ?? '子任务 ${index + 1}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5),
                    ),
                    subtitle: Text(
                      _timeLabel(child.updatedAt),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: child.running
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF30D158)),
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatPage(
                            sessionId: child.sessionId,
                            title: child.title ?? '子任务',
                            pcOrigin: widget.pcOrigin,
                            cookieHeader: widget.cookieHeader,
                            parentSessionId: _sessionId,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: const Color(0xFFE5453C)),
    );
  }

  /// Stop the running turn (and its subagent descendants).
  Future<void> _cancelTurn() async {
    try {
      await _rpc.cancelSession(_sessionId);
    } on RpcError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('停止失败：${e.code} ${e.message}'),
            backgroundColor: const Color(0xFFE5453C),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('网络错误：$e'),
            backgroundColor: const Color(0xFFE5453C),
          ),
        );
      }
    }
  }

  /// Pick a photo (camera or gallery), downscale it, and stage it for sending.
  Future<void> _pickImage(bool camera) async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
      if (picked == null) return;
      Uint8List? bytes;
      try {
        bytes = await FlutterImageCompress.compressWithFile(
          picked.path,
          minWidth: 1600,
          minHeight: 1600,
          quality: 82,
          format: CompressFormat.jpeg,
        );
      } catch (_) {
        bytes = null; // fall back to the picker's own output
      }
      bytes ??= await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pendingImage = bytes;
        _pendingImageName =
            picked.name.isEmpty ? 'photo.jpg' : picked.name;
      });
    } catch (e) {
      if (mounted) _snack('选择图片失败：$e');
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  /// Attachment sheet: camera / gallery.
  Future<void> _attachMenu() async {
    final choice = await showModalBottomSheet<Object>(
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
              _SheetAction(
                label: '拍照',
                onTap: () => Navigator.pop(ctx, true),
              ),
              _SheetAction(
                label: '从相册选择',
                onTap: () => Navigator.pop(ctx, false),
              ),
              _SheetAction(
                label: '选择文件',
                onTap: () => Navigator.pop(ctx, 'file'),
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
    if (choice == null) return;
    if (choice == 'file') {
      await _pickFile();
      return;
    }
    await _pickImage(choice == true);
  }

  /// Pick a document through SAF; uploaded before the prompt is sent.
  Future<void> _pickFile() async {
    final picked = await FilePickerBridge.pick();
    if (picked == null || !mounted) return;
    if (picked.size > 25 * 1024 * 1024) {
      _snack('文件过大（上限 25 MB）');
      return;
    }
    setState(() => _pendingFile = picked);
  }


  Future<void> _send() async {
    final text = _input.text.trim();
    final image = _pendingImage;
    final file = _pendingFile;
    if ((text.isEmpty && image == null && file == null) || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      // The first prompt is what actually creates an armed fork, so leaving
      // the page without sending leaves no session behind.
      if (_forkArmed) {
        String? forked;
        try {
          forked = await _rpc.forkSession(_sessionId);
        } on RpcError catch (e) {
          _input.text = text;
          _snack('分叉失败：${e.code} ${e.message}');
          return;
        }
        final id = forked;
        if (id == null || id.isEmpty) {
          _input.text = text;
          _snack('分叉失败：PC 未返回新会话');
          return;
        }
        setState(() {
          _forkArmed = false;
          _sessionId = id;
          _title = '$_title（分叉）';
          // The fork starts idle; the old turn's busy flag belongs to the
          // source session.
          _busy = false;
          _live = null;
        });
        SessionActivity.instance.activeSessionId = id;
        await _follow(auto: true);
      }
      final content = <Map<String, dynamic>>[
        if (text.isNotEmpty) {'type': 'text', 'text': text},
        if (image != null)
          {
            'type': 'image',
            'mediaType': 'image/jpeg',
            'data': base64Encode(image),
            'name': _pendingImageName ?? 'photo.jpg',
          },
      ];
      if (file != null) {
        final receipt = await _rpc.uploadFile(
          sessionId: _sessionId,
          name: file.name,
          bytes: await file.readBytes(),
        );
        if (receipt == null) {
          throw const FormatException('文件上传未返回 receiptId');
        }
        content.add({'type': 'file', 'receiptId': receipt});
      }
      await _rpc.call('session/prompt', {
        'request': {
          'requestId': newRequestId(),
          'sessionId': _sessionId,
          'mode': _busy ? 'steer' : 'queue',
          'content': content,
        },
      });
      // Durable user/message echo arrives on the follow stream; nothing here.
      if (mounted && (image != null || file != null)) {
        setState(() {
          _pendingImage = null;
          _pendingImageName = null;
          _pendingFile = null;
        });
        if (file != null) await file.deleteTemp();
      }
    } on RpcError catch (e) {
      if (mounted) {
        final reason = e.details['reason'];
        final message = reason == 'MODEL_DOES_NOT_SUPPORT_IMAGES'
            ? '当前模型不支持图片输入，请先在模型选择器里切换一个支持视觉的模型'
            : '发送失败：${e.code} ${e.message}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: const Color(0xFFE5453C),
          ),
        );
      }
      _input.text = text; // restore for retry
    } on FormatException catch (e) {
      if (mounted) _snack('文件上传失败：${e.message}');
      _input.text = text;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('网络错误：$e'),
            backgroundColor: const Color(0xFFE5453C),
          ),
        );
      }
      _input.text = text;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onStreamError(Object e) {
    if (e is SocketClosed && e.byUs) return;
    // done follows immediately on the same stream: _onClosed diagnoses.
    setState(() => _reconnectable = true);
  }

  /// Unclean close: let the loop bring it back (frozen network stacks warm up
  /// within seconds; a restarted PC is detected via its 401 below).
  void _onClosed() {
    setState(() => _reconnectable = true);
    _scheduleRetry();
  }

  /// One HTTP RPC round-trip decides what killed the stream.
  ///
  /// 401 = the PC answered but no longer knows this cookie's owner peer (dsh
  /// restarted; the signing secret is durable, the in-process peer registry
  /// is not) → only re-pairing recovers. Connection errors stay recoverable.
  Future<bool> _reachable() async {
    try {
      await _rpc.listSessions();
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        setState(() => _needRescan = true);
        _setState('PC 已重启（配对已失效），请重新配对', Colors.red);
      }
      return false;
    } on RpcError catch (_) {
      return true; // the Host answered; a business-layer error is still reachable
    } catch (_) {
      return false;
    }
  }

  /// Advance the auto-reconnect loop; exhausted retries flip to re-pairing.
  void _scheduleRetry() {
    if (_needRescan) return;
    if (_autoFailures >= _autoMax) {
      setState(() => _needRescan = true);
      _setState('重试 $_autoMax 次仍未恢复，请重新配对', Colors.red);
      return;
    }
    setState(() => _reconnectable = true);
    final n = ++_autoFailures;
    _setState('已断开，自动重连中（第 $n 次）…', Colors.red);
    _retryTimer = Timer(
      const Duration(seconds: 5),
      () => _follow(auto: true),
    );
  }

  void _setState(String s, Color c) => setState(() {
        _state = s;
        _stateColor = c;
      });

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    SessionActivity.instance.removeListener(_onActivity);
    if (SessionActivity.instance.activeSessionId == _sessionId) {
      SessionActivity.instance.activeSessionId = null;
    }
    _retryTimer?.cancel();
    _sub?.cancel();
    _mux.close();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bubbles = [
      for (final m in _messages) _bubble(m),
      // Live streaming attempt renders as a provisional assistant bubble.
      if (_live case final live? when live.hasContent)
        _bubble(ChatMessage(
          key: 'live',
          role: ChatRole.assistant,
          seq: -1,
          text: live.text.toString(),
          reasoning: live.reasoning.isEmpty
              ? null
              : live.reasoning.toString().substring(0, live.reasoning.length.clamp(0, 600)),
        )),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF9F9F9),
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF007AFF),
        elevation: 0,
        centerTitle: true,
        title: Text(
          _title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
        ),
        actions: [
          // Model chip mirrors the PC composer seat. An unconfigured session
          // shows the catalog default (what a prompt would use). Subagents
          // inherit their parent's model and cannot be re-selected.
          if (_chipEnabled && !widget.isSubagent) ...[
            const SizedBox(width: 4),
            _modelChip(),
            const SizedBox(width: 2),
          ],
          IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_horiz, size: 24, color: Color(0xFF007AFF)),
            tooltip: '更多',
            onPressed: _showMore,
          ),
          IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _busy ? Icons.sync : Icons.arrow_circle_down,
              size: 24,
              color: _busy ? const Color(0xFF5E5CE6) : Colors.grey.shade400,
            ),
            tooltip: _busy ? '正在生成（将发送则打断）' : '空闲',
            onPressed: null,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          // Sync/status strip
          Container(
            width: double.infinity,
            color: const Color(0xFFF2F2F7),
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Row(children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: _stateColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _state,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
                ),
              ),
              if (_reconnectable)
                GestureDetector(
                  onTap: _needRescan
                      ? () => Navigator.of(context).popUntil((r) => r.isFirst)
                      : () => _follow(auto: false),
                  child: Text(
                    _needRescan ? '重新配对' : '重连',
                    style: TextStyle(
                      color: const Color(0xFF007AFF),
                      fontSize: 14,
                      fontWeight: _needRescan ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              if (SessionActivity.instance.runningDescendants(_sessionId)
                  case final running when running > 0) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _openSubagents,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Color(0xFF30D158),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '子智能体 ×$running',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF30A14E),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
          if (_forkArmed)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF4E0),
              padding: const EdgeInsets.fromLTRB(16, 7, 12, 7),
              child: Row(
                children: [
                  const Icon(Icons.call_split,
                      size: 14, color: Color(0xFFB26B00)),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '分叉待发 · 发送第一条消息后才会创建新会话',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8A5A00)),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _forkArmed = false),
                    child: const Text(
                      '取消',
                      style: TextStyle(fontSize: 12, color: Color(0xFF007AFF)),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFE5E5EA)),
          Expanded(
            child: bubbles.isEmpty
                ? Center(
                    child: Text(
                      _stateColor == Colors.green ? '空会话 · 发条消息试试' : '等待同步…',
                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    itemCount: bubbles.length,
                    itemBuilder: (_, i) => bubbles[i],
                  ),
          ),
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFE5E5EA)),
          if (widget.isSubagent)
            const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Text(
                  '子智能体会话 · 只读（由主会话调度）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
                ),
              ),
            )
          else
            SafeArea(
            top: false,
            child: Container(
              color: const Color(0xFFF9F9F9),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pendingImage != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(
                              _pendingImage!,
                              width: 54,
                              height: 54,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '将随消息一起发送',
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF8E8E93)),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close,
                                size: 18, color: Color(0xFF8E8E93)),
                            onPressed: () => setState(() {
                              _pendingImage = null;
                              _pendingImageName = null;
                            }),
                          ),
                        ],
                      ),
                    ),
                  if (_pendingFile != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.insert_drive_file_outlined,
                              size: 20, color: Color(0xFF007AFF)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${_pendingFile!.name} · ${_formatBytes(_pendingFile!.size)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF8E8E93)),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close,
                                size: 18, color: Color(0xFF8E8E93)),
                            onPressed: () =>
                                setState(() => _pendingFile = null),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 34, minHeight: 34),
                        icon: _pickingImage
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Color(0xFF007AFF)),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined,
                                size: 24, color: Color(0xFF007AFF)),
                        tooltip: '添加图片',
                        onPressed: _pickingImage ? null : _attachMenu,
                      ),
                      const SizedBox(width: 2),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFE5E5EA)),
                      ),
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: const TextStyle(fontSize: 15.5, color: Color(0xFF1C1C1E)),
                        decoration: InputDecoration(
                          hintText: '向这个会话发送消息…',
                          hintStyle: const TextStyle(color: Color(0xFFAEAEB2)),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_busy) ...[
                    GestureDetector(
                      onTap: _cancelTurn,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0x1AE5453C),
                        ),
                        child: const Icon(Icons.stop_rounded,
                            size: 21, color: Color(0xFFE5453C)),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  GestureDetector(
                    onTap: _sending ? null : _send,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _sending || _input.text.trim().isEmpty
                            ? const Color(0xFFB7CDF3)
                            : const Color(0xFF007AFF),
                      ),
                      child: _sending
                          ? const Center(
                              child: SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              ),
                            )
                          : const Icon(Icons.arrow_upward_rounded,
                              size: 22, color: Colors.white),
                    ),
                  ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The AppBar model chip (pill) opens the PC catalog picker.
  Widget _modelChip() {
    return GestureDetector(
      onTap: _pickingModel ? null : _pickModel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF007AFF).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(15),
        ),
        constraints: const BoxConstraints(maxWidth: 170),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.memory, size: 15, color: Color(0xFF007AFF)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              _chipLabel(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF007AFF),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Icon(Icons.expand_more_rounded, size: 15, color: Color(0xFF007AFF)),
        ]),
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == ChatRole.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser ? const Color(0xFF007AFF) : const Color(0xFFE9E9EB);
    final fg = isUser ? Colors.white : const Color(0xFF1C1C1E);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 5),
            bottomRight: Radius.circular(isUser ? 5 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: align,
          children: [
            if (m.reasoning != null && !isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    iconColor: const Color(0xFF8E8E93),
                    collapsedIconColor: const Color(0xFF8E8E93),
                    title: Text(
                      '思考过程',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          m.reasoning!,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6D6D72), height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (m.tools.isNotEmpty && !isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tool in m.tools)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F2F7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.build_outlined,
                                size: 12, color: Color(0xFF6D6D72)),
                            const SizedBox(width: 4),
                            Text(
                              tool,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF3A3A3C),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            SelectableText(
              m.text,
              style: TextStyle(color: fg, fontSize: 15.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picked model awaiting its effort choice (sheet screen-1 payload).
class _PickContext {
  const _PickContext({
    required this.providerId,
    required this.providerName,
    required this.model,
  });

  final String providerId;
  final String providerName;
  final CatalogModel model;
}

/// iOS-style sheet row: title + optional grey captions + trailing check.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.title,
    this.subtitle,
    this.footnote,
    this.selected = false,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? footnote;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 16, color: Color(0xFF1C1C1E)),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF8A8A8E)),
                      ),
                    ),
                  if (footnote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        footnote!,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6D6D72)),
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, size: 22, color: Color(0xFF007AFF)),
          ],
        ),
      ),
    );
  }
}

/// `今天 HH:mm` / `MM-dd HH:mm` label for subagent rows.
String _timeLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final hh = '${t.hour}'.padLeft(2, '0');
  final mm = '${t.minute}'.padLeft(2, '0');
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return '今天 $hh:$mm';
  return '${t.month}-${'${t.day}'.padLeft(2, '0')} $hh:mm';
}

/// One iOS action-sheet row (chat page menu).
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.label,
    required this.onTap,
    this.bold = false,
  });

  final String label;
  final VoidCallback onTap;
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
              color: const Color(0xFF007AFF),
            ),
          ),
        ),
      ),
    );
  }
}

/// Human byte size for attachment chips.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
