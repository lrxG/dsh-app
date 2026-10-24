import 'dart:async';

import 'package:flutter/material.dart';

import 'dsh_client.dart';
import 'mux_client.dart';

/// One row of the session's visible background-job roster.
class JobRow {
  const JobRow({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
  });

  final String id;
  final String kind;
  final String label;
  final String status;

  bool get running => status == 'running' || status == 'stopping';

  static JobRow? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String) return null;
    return JobRow(
      id: id,
      kind: '${raw['kind'] ?? ''}',
      label: '${raw['label'] ?? ''}',
      status: '${raw['status'] ?? ''}',
    );
  }
}

/// Background jobs the session can see (`job/list` stream + `job/kill`).
class JobsPage extends StatefulWidget {
  const JobsPage({
    super.key,
    required this.sessionId,
    required this.pcOrigin,
    required this.cookieHeader,
  });

  final String sessionId;
  final String pcOrigin;
  final String cookieHeader;

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  late final DshRpc _rpc;
  MuxClient? _mux;
  StreamSubscription<MuxEvent>? _sub;
  List<JobRow> _rows = const [];
  String? _error;
  bool _loading = true;
  final Set<String> _killing = {};

  @override
  void initState() {
    super.initState();
    _rpc = DshRpc(pcOrigin: widget.pcOrigin, cookieHeader: widget.cookieHeader);
    _connect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _mux?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    final mux = MuxClient(
      pcOrigin: widget.pcOrigin,
      cookieHeader: widget.cookieHeader,
    );
    try {
      await mux.connect();
      if (!mounted) {
        await mux.close();
        return;
      }
      _mux = mux;
      _sub = mux.open('job/list', {
        'request': {'sessionId': widget.sessionId},
      }).listen(_onFrame, onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = '任务流断开：$e';
          _loading = false;
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '连接失败：$e';
        _loading = false;
      });
    }
  }

  void _onFrame(MuxEvent event) {
    if (event is! MuxItem) return;
    final value = event.value;
    if (value is! Map || value['type'] != 'rows') return;
    final raw = value['jobs'];
    final rows = raw is List
        ? raw.map(JobRow.fromWire).whereType<JobRow>().toList()
        : <JobRow>[];
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _kill(JobRow job) async {
    if (_killing.contains(job.id)) return;
    setState(() => _killing.add(job.id));
    try {
      await _rpc.call('job/kill', {
        'request': {'sessionId': widget.sessionId, 'jobId': job.id},
      });
    } on RpcError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('终止失败：${e.code} ${e.message}'),
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
      if (mounted) setState(() => _killing.remove(job.id));
    }
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
        title: const Text(
          '后台任务',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF007AFF)))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF8E8E93)),
                    ),
                  ),
                )
              : _rows.isEmpty
                  ? const Center(
                      child: Text(
                        '这个会话没有后台任务',
                        style: TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
                      ),
                    )
                  : RefreshIndicator(
                      color: const Color(0xFF007AFF),
                      onRefresh: () async {
                        await _sub?.cancel();
                        await _mux?.close();
                        setState(() => _loading = true);
                        await _connect();
                      },
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          final job = _rows[index];
                          final busy = _killing.contains(job.id);
                          return Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            clipBehavior: Clip.antiAlias,
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 11, 10, 11),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: job.running
                                          ? const Color(0xFF30D158)
                                          : const Color(0xFFC7C7CC),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          job.label.isEmpty
                                              ? job.id
                                              : job.label,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF1C1C1E),
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${job.kind} · ${job.status}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF8E8E93),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (job.running)
                                    busy
                                        ? const Padding(
                                            padding:
                                                EdgeInsets.only(right: 12),
                                            child: SizedBox(
                                              width: 18,
                                              height: 18,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color:
                                                          Color(0xFFE5453C)),
                                            ),
                                          )
                                        : TextButton(
                                            onPressed: () => _kill(job),
                                            style: TextButton.styleFrom(
                                              foregroundColor:
                                                  const Color(0xFFE5453C),
                                              minimumSize: Size.zero,
                                              padding: const EdgeInsets
                                                  .symmetric(
                                                  horizontal: 10, vertical: 6),
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                            child: const Text(
                                              '终止',
                                              style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight:
                                                      FontWeight.w500),
                                            ),
                                          ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
