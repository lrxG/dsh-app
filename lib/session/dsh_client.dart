import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Generic unary RPC over the Connection HTTP channel.
///
/// Wire format (verified against dsh 0.2.1-rc.3, see docs/PROTOCOL.md):
/// ```
/// POST {pcOrigin}/api/<namespace>/<method>
/// body:  {"type":"client-request","rpcId":<uuid>,"method":<endpoint>,"payload":{"args":…}}
/// resp:  {"type":"server-response","rpcId":…,"result":{"ok":true,"value":…}|{"ok":false,"error":…}}
/// ```
///
/// `args` keys must match the Host method's exact TS parameter names
/// (e.g. `list(_request …)` → `args._request`, `search(request …)` → `args.request`).
class DshRpc {
  DshRpc({required this.pcOrigin, required this.cookieHeader})
      : dio = Dio(BaseOptions(
          contentType: 'application/json',
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
        ));

  final String pcOrigin;
  final String cookieHeader;
  final Dio dio;

  /// One unary call. Returns the `.value` on success, throws [RpcError] on failure.
  Future<dynamic> call(String endpoint, Map<String, dynamic> args) async {
    final rpcId = _rpcId();
    final res = await dio.postUri<Object>(
      Uri.parse('$pcOrigin/api/$endpoint'),
      data: {
        'type': 'client-request',
        'rpcId': rpcId,
        'method': endpoint,
        'payload': {'args': args},
      },
      options: Options(headers: {'cookie': cookieHeader}),
    );
    final body = res.data as Map<String, dynamic>?;
    if (body == null || body['type'] != 'server-response') {
      throw RpcError('rpc/envelope', 'unexpected response envelope', const {});
    }
    final result = body['result'] as Map<String, dynamic>? ?? const {};
    if (result['ok'] != true) {
      final error = result['error'] as Map<String, dynamic>? ?? const {};
      throw RpcError(
        '${error['code'] ?? 'rpc/unknown'}',
        '${error['message'] ?? 'unknown error'}',
        (error['details'] as Map<String, dynamic>?) ?? const {},
      );
    }
    return result['value'];
  }

  /// Session summaries ordered by activity (`session/list`, args `_request`).
  Future<List<SessionSummary>> listSessions() async {
    final value = await call('session/list', {'_request': <String, dynamic>{}});
    final items = (value as Map)['items'] as List? ?? const [];
    return items.map((e) => SessionSummary.fromWire(e as Map)).toList();
  }

  /// Search session message content (`session/search`, args `request`).
  Future<SearchResult> searchSessions(String query) async {
    final value = await call('session/search', {'request': {'query': query}});
    final m = value as Map;
    final items = (m['items'] as List? ?? const [])
        .map((e) => SearchItem.fromWire(e as Map))
        .toList();
    return SearchResult(items: items, hasMore: m['hasMore'] == true);
  }

  /// PC-side model catalog (`session/modelCatalog`, no args).
  ///
  /// value = {default, routableProviders, groups, failures} — the same data
  /// the PC composer model popup renders.
  Future<ModelCatalogData?> modelCatalog() async {
    final value = await call('session/modelCatalog', <String, dynamic>{});
    if (value is! Map) return null;
    return ModelCatalogData.fromWire(value);
  }

  /// One session's projected model selection (`session/projections`).
  ///
  /// values.modelSelection.next is the pending selection, lastUsed the one the
  /// last turn ran with.
  Future<ModelSelection?> sessionModel(String sessionId) async {
    final value = await call('session/projections', {'request': {'sessionId': sessionId}});
    if (value is! Map) return null;
    final values = value['values'];
    if (values is! Map) return null;
    final ms = values['modelSelection'];
    if (ms is! Map) return null;
    final next = ms['next'];
    final used = ms['lastUsed'];
    return ModelSelection.fromWire(next is Map ? next : used is Map ? used : null);
  }

  /// Change one session's model (`session/selectModel`, args `request`).
  /// Host validates the pair against the catalog and returns the accepted value.
  Future<ModelSelection> selectModel(String sessionId, String provider, String model,
      {String? reasoningEffort}) async {
    final value = await call('session/selectModel', {
      'request': {
        'sessionId': sessionId,
        'provider': provider,
        'model': model,
        'reasoningEffort': ?reasoningEffort,
      },
    });
    final selected = value is Map ? value['selected'] : null;
    return ModelSelection.fromWire(selected is Map ? selected : null) ??
        ModelSelection(provider: provider, model: model);
  }

  /// Rename one session (`session/rename`, args `request`).
  Future<String> renameSession(String sessionId, String title) async {
    final value = await call('session/rename', {
      'request': {'sessionId': sessionId, 'title': title},
    });
    final normalized = value is Map ? value['title'] : null;
    return normalized is String && normalized.isNotEmpty ? normalized : title;
  }

  /// Fork one session at its latest completed turn (`session/fork`).
  Future<String?> forkSession(String sessionId) async {
    final value = await call('session/fork', {
      'request': {'sessionId': sessionId},
    });
    final forked = value is Map ? value['sessionId'] : null;
    return forked is String && forked.isNotEmpty ? forked : null;
  }

  /// Upload raw bytes as a staged file (`POST /api/session/uploadFileBinary`).
  ///
  /// Returns the receipt the prompt's `{type:'file', receiptId}` part cites.
  Future<String?> uploadFile({
    required String sessionId,
    required String name,
    required Uint8List bytes,
  }) async {
    final uri = Uri.parse('$pcOrigin/api/session/uploadFileBinary').replace(
      queryParameters: {'sessionId': sessionId, 'name': name},
    );
    final res = await dio.postUri<Object>(
      uri,
      data: bytes,
      options: Options(
        headers: {
          'cookie': cookieHeader,
          'content-type': 'application/octet-stream',
        },
        responseType: ResponseType.json,
      ),
    );
    final body = res.data as Map?;
    final value = body?['value'];
    final receiptId = value is Map ? value['receiptId'] : null;
    return receiptId is String && receiptId.isNotEmpty ? receiptId : null;
  }

  /// Pin or unpin one session ahead of unpinned rows (`workspace/pinSession`).
  Future<void> setPinned(String sessionId, {required bool pinned}) async {
    await call(pinned ? 'workspace/pinSession' : 'workspace/unpinSession', {
      'request': {'sessionId': sessionId},
    });
  }

  /// Stop the session's current turn and its subagent descendants
  /// (`session/cancel`, args `request`).
  Future<void> cancelSession(String sessionId) async {
    await call('session/cancel', {
      'request': {'sessionId': sessionId},
    });
  }

  /// Answer one forwarded `approval/request` (`$events/result`).
  ///
  /// The outcome value is the dsh approval decision: `allowed-once` or
  /// `rejected`. `clientId` comes from the `$events` ready frame.
  Future<void> answerApproval({
    required String clientId,
    required String eventId,
    required bool allow,
  }) async {
    await call(r'$events/result', {
      'clientId': clientId,
      'eventId': eventId,
      'outcome': {
        'kind': 'result',
        'value': allow ? 'allowed-once' : 'rejected',
      },
    });
  }

  /// Fresh-enough correlation id without pulling in crypto packages.
  static String _rpcId() {
    final r = Random();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
        .replaceAllMapped('x', (_) => '0123456789abcdef'[r.nextInt(16)])
        .replaceFirstMapped('y', (_) => '89ab'[r.nextInt(4)]);
  }
}

/// One failed Gateway call.
class RpcError implements Exception {
  RpcError(this.code, this.message, this.details);

  final String code;
  final String message;
  final Map<String, dynamic> details;

  @override
  String toString() => '$code: $message';
}

/// A failed request, said in words the phone UI can show.
///
/// Three cases matter to the user and used to look identical (a raw
/// `DioException [...]` dump in the list): the PC moved/closed its port, the
/// stored pairing is no longer accepted, or the Host itself refused the call.
class RpcFailure {
  const RpcFailure({
    required this.title,
    required this.detail,
    this.unreachable = false,
    this.stalePairing = false,
  });

  final String title;
  final String detail;

  /// Nothing answered: wrong address, dsh closed, or not on the same WiFi.
  final bool unreachable;

  /// The PC answered 401/403: this phone's cookie is no longer accepted, so
  /// only a fresh scan can help.
  final bool stalePairing;

  @override
  String toString() => '$title · $detail';
}

/// Classify anything [DshRpc] (or a mux socket) can throw.
RpcFailure describeFailure(Object error) {
  if (error is RpcError) {
    final stale = error.code.contains('auth') ||
        error.code.contains('unauthor') ||
        error.code.contains('forbidden');
    return RpcFailure(
      title: stale ? '配对已失效' : 'PC 返回错误',
      detail: '${error.code}：${error.message}',
      stalePairing: stale,
    );
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 403) {
      return const RpcFailure(
        title: '配对已失效',
        detail: 'PC 不认这台手机了（PC 重启轮换过密钥，或设备已被移除）。重新扫码配对即可。',
        stalePairing: true,
      );
    }
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const RpcFailure(
          title: '连不上 PC',
          detail: '检查 dsh 是否还在运行、手机和 PC 是否在同一个 WiFi；'
              'PC 换了地址时要重新扫一次码。',
          unreachable: true,
        );
      default:
        return RpcFailure(
          title: '连接出错',
          detail: status != null
              ? 'PC 返回 HTTP $status'
              : '${error.type.name}${error.message == null ? '' : '：${error.message}'}',
        );
    }
  }
  if (error is SocketException) {
    return const RpcFailure(
      title: '连不上 PC',
      detail: '手机和 PC 之间的网络断了（换个 WiFi、关掉 VPN 再试）。',
      unreachable: true,
    );
  }
  return RpcFailure(title: '请求失败', detail: '$error');
}

/// One `session/list` entry (projection hints trimmed to what the UI uses).
class SessionSummary {
  SessionSummary.fromWire(Map e)
      : sessionId = '${e['sessionId'] ?? ''}',
        updatedAt = (e['updatedAt'] as num?)?.toInt() ?? 0,
        running = e['running'] == true,
        blank = e['blank'] == true,
        agentAvailable = e['agentAvailable'] == true,
        cwd = e['cwd'] is String ? e['cwd'] as String : null,
        origin = e['origin'] is String ? e['origin'] as String : null,
        parentSessionId =
            e['parentSessionId'] is String ? e['parentSessionId'] as String : null,
        model = _projectedModel(e['projections']),
        title = _projectedTitle(e['projections']);

  final String sessionId;
  final int updatedAt;
  final bool running;
  final bool blank;
  final bool agentAvailable;
  final String? cwd;
  final String? title;
  /// `origin:'subagent'` rows are hidden by the PC sidebar too (ui-workspace).
  final String? origin;
  final String? parentSessionId;
  /// The session's own model pick (`modelSelection.next|lastUsed`), null when
  /// it still runs on the deployment default.
  final ModelSelection? model;

  /// True for subagent/child sessions the PC doesn't show in its sidebar.
  bool get hiddenOnPc => origin == 'subagent' || parentSessionId != null;

  static ModelSelection? _projectedModel(Object? projections) {
    if (projections is! Map) return null;
    final values = projections['values'];
    if (values is! Map) return null;
    final selection = values['modelSelection'];
    if (selection is! Map) return null;
    final next = selection['next'];
    final lastUsed = selection['lastUsed'];
    return ModelSelection.fromWire(
      next is Map ? next : (lastUsed is Map ? lastUsed : null),
    );
  }

  static String? _projectedTitle(Object? projections) {
    if (projections is! Map) return null;
    final values = projections['values'];
    if (values is! Map) return null;
    final title = values['title'];
    if (title is! String || title.isEmpty) {
      // Untitled (incl. blank) sessions render through the `blank` flag; the
      // UI labels them 新会话 instead of a fake title.
      return null;
    }
    return title;
  }
}

class SearchResult {
  const SearchResult({required this.items, required this.hasMore});

  final List<SearchItem> items;
  final bool hasMore;
}

/// One provider group of the PC model catalog (`session/modelCatalog`).
class ModelGroup {
  ModelGroup.fromWire(Map g)
      : id = '${g['id'] ?? ''}',
        name = '${g['name'] ?? g['id'] ?? ''}',
        models = (g['models'] as List? ?? const [])
            .map((m) => CatalogModel.fromWire(m as Map))
            .toList();

  final String id;
  /// Display name the PC composer renders (e.g. `DeepSeek`, `Token Rhythm`).
  final String name;
  final List<CatalogModel> models;
}

/// Reasoning effort knob the PC composer shows for one model route.
class EffortOption {
  EffortOption.fromWire(Map e)
      : id = '${e['id'] ?? ''}',
        name = '${e['name'] ?? e['id'] ?? ''}',
        description = e['description'] is String ? e['description'] as String : null;

  final String id;
  final String name;
  final String? description;
}

/// Per-model reasoning metadata from the catalog.
class ReasoningInfo {
  ReasoningInfo.fromWire(Map r)
      : efforts = (r['efforts'] as List? ?? const [])
            .map((e) => EffortOption.fromWire(e as Map))
            .toList(),
        defaultEffort = r['defaultEffort'] is String ? r['defaultEffort'] as String : null;

  final List<EffortOption> efforts;
  final String? defaultEffort;

  /// Row subtitle like `思考 · 默认 high`。
  String get summary =>
      '思考${defaultEffort == null ? '' : ' · 默认 $defaultEffort'}';
}

/// One selectable PC model.
class CatalogModel {
  CatalogModel.fromWire(Map m)
      : id = '${m['id'] ?? ''}',
        name = '${m['name'] ?? m['id'] ?? ''}',
        description = m['description'] is String ? m['description'] as String : null,
        reasoning = m['reasoning'] is Map ? ReasoningInfo.fromWire(m['reasoning'] as Map) : null;

  final String id;
  final String name;
  final String? description;
  final ReasoningInfo? reasoning;
}

/// Full `session/modelCatalog` value.
class ModelCatalogData {
  ModelCatalogData.fromWire(Map v)
      : groups = (v['groups'] as List? ?? const [])
            .map((g) => ModelGroup.fromWire(g as Map))
            .toList(growable: false),
        default_ = ModelSelection.fromWire(
          v['default'] is Map ? v['default'] as Map : null,
        ),
        routableProviders = [
          for (final p in v['routableProviders'] as List? ?? const []) '$p',
        ];

  final List<ModelGroup> groups;
  /// Deployment default used before a Session picks one (PC composer seat).
  final ModelSelection? default_;
  final List<String> routableProviders;

  /// Groups the Host can actually route (mirrors the PC popup).
  List<ModelGroup> get routableGroups => [
        for (final g in groups)
          if (routableProviders.contains(g.id) && g.models.isNotEmpty) g,
      ];

  /// Friendly model name for a selection (`id → name`), else the raw id.
  String? displayName(ModelSelection? selection) {
    if (selection == null) return null;
    for (final g in groups) {
      if (g.id != selection.provider) continue;
      for (final m in g.models) {
        if (m.id == selection.model) {
          final effort = m.reasoning == null
              ? null
              : (selection.reasoningEffort ?? m.reasoning!.defaultEffort);
          final effortText = m.reasoning == null || effort == null
              ? ''
              : ' · ${_effortName(m.reasoning!, effort)}';
          return '${m.name}$effortText';
        }
      }
    }
    return selection.model;
  }

  static String _effortName(ReasoningInfo r, String effort) {
    for (final e in r.efforts) {
      if (e.id == effort) return e.name;
    }
    return effort;
  }
}

/// {provider, model, reasoningEffort?} — durable selection shape.
class ModelSelection {
  const ModelSelection({required this.provider, required this.model, this.reasoningEffort});

  /// null-safe wire decode; the composer treats absent as "host default".
  static ModelSelection? fromWire(Map? m) {
    if (m == null) return null;
    if (m['provider'] == null || m['model'] == null) return null;
    return ModelSelection(
      provider: '${m['provider']}',
      model: '${m['model']}',
      reasoningEffort: m['reasoningEffort'] is String ? m['reasoningEffort'] as String : null,
    );
  }

  final String provider;
  final String model;
  final String? reasoningEffort;

  @override
  String toString() => model;
}

class SearchItem {
  SearchItem.fromWire(Map e)
      : sessionId = '${e['sessionId'] ?? ''}',
        snippet = '${e['snippet'] ?? ''}';

  final String sessionId;
  final String snippet;
}
