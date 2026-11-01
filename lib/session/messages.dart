/// Decodes durable session snapshot/event records into chat bubbles.
///
/// Wire shapes (dsh 0.2.1-rc.3, packages/api/session-controller/src/types.ts):
///  record = {type:'event', event:{type,seq,time,data,surfaceOp?,ignorable?}}
///  user/message      data:{id, content:[block…], source:{kind:'user'…}}
///  assistant/message  data:{turn,step,stream, message:{id, role, source,
///                     content:[{type:'text'|'reasoning',text}|{type:'tool-call',id,name}…]}}
/// assistant-stream frames carry transient text-delta/reasoning-delta chunks
/// (compact records expanded per packages/llm/llm/src/assistant-stream.ts).
library;

import 'dart:math';

/// One chat bubble.
class ChatMessage {
  ChatMessage({
    required this.key,
    required this.role,
    required this.seq,
    this.text = '',
    this.reasoning,
    this.tools = const [],
  });

  /// Stable identity for ListView keys: `u<seq>` / `a<seq>` / `live`.
  final String key;
  final ChatRole role;

  /// Durable seq the message anchored at (-1 for the transient live bubble).
  int seq;
  String text;
  String? reasoning;

  /// Tool names the assistant called in this message (rendered as chips).
  List<String> tools;
}

enum ChatRole { user, assistant }

/// Whether an event is a real surface message (skips process/ignore rows).
bool isMessageEvent(Map event) {
  if (event['ignorable'] == true) return false;
  final type = event['type'];
  if (type != 'user/message' && type != 'assistant/message') return false;
  // Non-append surface ops are edits/compactions; v0.1 renders only appends.
  return event['surfaceOp'] == 'append';
}

/// Decode one surface event into a bubble, or null for non-message rows.
ChatMessage? decodeEvent(Map event) {
  if (!isMessageEvent(event)) return null;
  final type = event['type'];
  final data = event['data'];
  if (data is! Map) return null;
  final seq = (event['seq'] as num?)?.toInt() ?? -1;
  if (type == 'user/message') {
    final source = data['source'];
    // Non-user sources are context injections (skills, compaction…): skip.
    if (source is! Map || source['kind'] != 'user') return null;
    return ChatMessage(
      key: 'u$seq',
      role: ChatRole.user,
      seq: seq,
      text: _textOf(data['content']),
    );
  }
  if (type == 'assistant/message') {
    final message = data['message'];
    if (message is! Map) return null;
    final content = message['content'];
    final blocks = content is List ? content.whereType<Map>().toList() : const <Map>[];
    return ChatMessage(
      key: 'a$seq',
      role: ChatRole.assistant,
      seq: seq,
      text: _textOf(blocks.where((b) => b['type'] == 'text').toList()),
      reasoning: _reasoningOf(content is List ? content : const []),
      tools: [
        for (final block in blocks)
          if (block['type'] == 'tool-call' && block['name'] is String)
            block['name'] as String,
      ],
    );
  }
  return null;
}

/// Join text parts of a block list; tolerates bare strings and {text} parts.
/// Image blocks render as a placeholder so a caption-less photo still shows.
String _textOf(Object? blocks) {
  if (blocks == null) return '';
  if (blocks is String) return blocks;
  if (blocks is! List) return '';
  return blocks.map((b) {
    if (b is String) return b;
    if (b is Map) {
      if (b['type'] == 'image') return '[图片]';
      if (b['type'] == 'file') {
        final name = b['name'];
        return name is String && name.isNotEmpty ? '[文件] $name' : '[文件]';
      }
      final t = b['text'] ?? b['doc'];
      if (t is String) return t;
    }
    return '';
  }).where((s) => s.isNotEmpty).join('\n');
}

String? _reasoningOf(Object? blocks) {
  if (blocks is! List) return null;
  final parts = blocks
      .whereType<Map>()
      .where((b) => b['type'] == 'reasoning')
      .map((b) => b['text'])
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final joined = parts.join('\n');
  return joined.length > 4000 ? '${joined.substring(0, 4000)}…' : joined;
}

/// Decode an opening `snapshot` frame into bubbles (ordered by seq).
List<ChatMessage> decodeSnapshot(dynamic value) {
  if (value is! Map) return const [];
  final records = value['records'];
  if (records is! List) return const [];
  final out = <ChatMessage>[];
  for (final record in records) {
    if (record is! Map) continue;
    final event = record['event'];
    if (event is! Map) continue;
    if (!isMessageEvent(event)) continue;
    final msg = decodeEvent(event);
    // Tool steps carry reasoning but no user-visible answer; only bubbles with
    // actual text belong in the transcript (the thinking block rides along).
    if (msg != null && msg.text.trim().isNotEmpty) out.add(msg);
  }
  return out;
}

/// One prompt the PC accepted but has not started yet — the rows the PC shows
/// as 「排队」 (a queued turn) or 「插话」 (input for the running turn's next
/// step). They live in dsh's durable Inbox, not in the transcript, so a send
/// during a running task produces no `user/message` event until it is claimed.
class QueuedMessage {
  QueuedMessage({
    required this.itemId,
    required this.text,
    required this.steering,
  });

  /// Agent-owned Inbox identity (the `itemId` of `session/updateQueue`).
  final String itemId;
  String text;

  /// True for `next-step` rows: delivered at the running turn's next step
  /// boundary instead of starting a new turn.
  final bool steering;
}

/// Inbox targets in delivery order: mid-turn input reaches the model before a
/// whole queued turn does.
const List<String> inboxTargets = ['next-step', 'next-turn'];

/// Read the pending Inbox out of a follow `snapshot` frame
/// (`projections.values.inbox`, values keyed by target).
Map<String, List<QueuedMessage>> decodeSnapshotInbox(dynamic snapshot) {
  if (snapshot is! Map) return decodeInbox(null);
  final projections = snapshot['projections'];
  if (projections is! Map) return decodeInbox(null);
  final values = projections['values'];
  if (values is! Map) return decodeInbox(null);
  return decodeInbox(values['inbox']);
}

/// Decode one `inbox` projection value into rows keyed by target.
Map<String, List<QueuedMessage>> decodeInbox(Object? value) {
  final out = <String, List<QueuedMessage>>{for (final target in inboxTargets) target: <QueuedMessage>[]};
  if (value is! Map) return out;
  for (final target in inboxTargets) {
    final rows = value[target];
    if (rows is! List) continue;
    for (final row in rows) {
      final message = queuedOf(row, steering: target == 'next-step');
      if (message != null) out[target]!.add(message);
    }
  }
  return out;
}

/// Decode one durable `user/message`-shaped `UserMessage` into an Inbox row.
QueuedMessage? queuedOf(Object? raw, {required bool steering}) {
  if (raw is! Map) return null;
  final id = raw['id'];
  if (id is! String || id.isEmpty) return null;
  // Inbox rows are prompts; Host-authored injections are never queued.
  final source = raw['source'];
  if (source is! Map || source['kind'] != 'user') return null;
  return QueuedMessage(itemId: id, text: _textOf(raw['content']), steering: steering);
}

/// Apply one `agent/inbox/spliced` event data map to that target's rows.
/// The Host sends the same splice it folded into the projection, so mirroring
/// it keeps the phone's queue identical without extra reads.
void applyInboxSplice(List<QueuedMessage> rows, Map data) {
  final start = (data['start'] as num?)?.toInt();
  if (start == null) return;
  final removed = (data['removedCount'] as num?)?.toInt() ?? 0;
  final steering = data['target'] == 'next-step';
  final insertedRaw = data['inserted'];
  final inserted = <QueuedMessage>[];
  if (insertedRaw is List) {
    for (final row in insertedRaw) {
      final message = queuedOf(row, steering: steering);
      if (message != null) inserted.add(message);
    }
  }
  final at = start.clamp(0, rows.length);
  final end = (at + removed).clamp(at, rows.length);
  rows.replaceRange(at, end, inserted);
}

/// Streaming buffer for the live assistant attempt (`assistant-stream` frames).
class LiveAssistant {
  final text = StringBuffer();
  final reasoning = StringBuffer();

  void applyChunk(Map frame) {
    final chunk = frame['chunk'];
    if (chunk is! Map) return;
    switch ('${chunk['type']}') {
      case 'text-delta':
        text.write(chunk['text'] ?? '');
      case 'reasoning-delta':
        reasoning.write(chunk['text'] ?? '');
      // tool-call-delta / block / usage / finish: ignored in v0.1
    }
  }

  bool get hasContent => text.isNotEmpty || reasoning.isNotEmpty;
}

/// RFC-ish id for `prompt.requestId` without extra deps.
String newRequestId() {
  const variant = '89ab';
  return '${_hex(8)}-4${_hex(3)}-${variant[_rand.nextInt(4)]}${_hex(3)}-${_hex(12)}';
}

String _hex(int length) =>
    List.generate(length, (_) => '0123456789abcdef'[_rand.nextInt(16)]).join();

final _rand = Random();
