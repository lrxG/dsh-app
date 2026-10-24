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
  return joined.length > 600 ? '${joined.substring(0, 600)}…' : joined;
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
    if (msg != null && msg.text.trim().isNotEmpty) out.add(msg);
  }
  return out;
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
