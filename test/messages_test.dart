import 'package:flutter_test/flutter_test.dart';

import 'package:lan_buddy/session/messages.dart';

void main() {
  test('decodeEvent skips non-surface and injected rows', () {
    expect(
      decodeEvent({
        'type': 'user/message',
        'seq': 1,
        'data': {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
          'source': {'kind': 'skill'},
        },
        'surfaceOp': 'append',
      }),
      isNull,
      reason: 'non-user source = context injection, skip',
    );
    expect(
      decodeEvent({
        'type': 'user/message',
        'seq': 1,
        'data': {
          'content': [],
          'source': {'kind': 'user'},
        },
        // surfaceOp missing = replace/compact row under seq decoding
      }),
      isNull,
    );
  });

  test('decodeEvent decodes user message text', () {
    final m = decodeEvent({
      'type': 'user/message',
      'seq': 7,
      'data': {
        'content': [
          {'type': 'text', 'text': '你好'},
        ],
        'source': {'kind': 'user'},
      },
      'surfaceOp': 'append',
    })!;
    expect(m.role, ChatRole.user);
    expect(m.text, '你好');
    expect(m.seq, 7);
    expect(m.key, 'u7');
  });

  test('decodeEvent decodes assistant text + reasoning', () {
    final m = decodeEvent({
      'type': 'assistant/message',
      'seq': 9,
      'data': {
        'turn': 1,
        'step': 1,
        'message': {
          'id': 'm1',
          'role': 'assistant',
          'content': [
            {'type': 'reasoning', 'text': 'thinking...'},
            {'type': 'text', 'text': '答案'},
          ],
        },
      },
      'surfaceOp': 'append',
    })!;
    expect(m.role, ChatRole.assistant);
    expect(m.text, '答案');
    expect(m.reasoning, 'thinking...');
    expect(m.key, 'a9');
  });

  test('decodeSnapshot keeps order and filters noise', () {
    final bubbles = decodeSnapshot({
      'cursor': 3,
      'records': [
        {
          'type': 'event',
          'event': {
            'type': 'turn/start',
            'seq': 0,
            'time': 0,
            'data': {'turn': 1},
          },
        },
        {
          'type': 'event',
          'event': {
            'type': 'user/message',
            'seq': 1,
            'time': 1,
            'data': {
              'content': [
                {'type': 'text', 'text': 'q'},
              ],
              'source': {'kind': 'user'},
            },
            'surfaceOp': 'append',
          },
        },
        {
          'type': 'event',
          'event': {
            'type': 'assistant/message',
            'seq': 2,
            'time': 2,
            'data': {
              'message': {
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'a'},
                ],
              },
            },
            'surfaceOp': 'append',
          },
        },
      ],
    });
    expect(bubbles.map((b) => b.text).toList(), ['q', 'a']);
    expect(bubbles.map((b) => b.role), [ChatRole.user, ChatRole.assistant]);
  });

  test('LiveAssistant buffers text/reasoning deltas', () {
    final live = LiveAssistant();
    live.applyChunk({'type': 'chunk', 'chunk': {'type': 'text-delta', 'index': 0, 'text': 'he'}});
    live.applyChunk({'type': 'chunk', 'chunk': {'type': 'text-delta', 'index': 0, 'text': 'llo'}});
    live.applyChunk({
      'type': 'chunk',
      'chunk': {'type': 'reasoning-delta', 'index': 1, 'text': 'mind'},
    });
    expect(live.text.toString(), 'hello');
    expect(live.reasoning.toString(), 'mind');
    expect(live.hasContent, isTrue);
  });

  test('newRequestId returns uuid-v4-shaped id', () {
    final id = newRequestId();
    expect(
      RegExp(r'^[0-9a-f]{8}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(id),
      isTrue,
      reason: 'id=$id',
    );
    expect(newRequestId(), isNot(id));
  });

  test('decodeEvent surfaces assistant tool calls as chips', () {
    final m = decodeEvent({
      'type': 'assistant/message',
      'seq': 11,
      'data': {
        'turn': 1,
        'step': 1,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'running it'},
            {
              'type': 'tool-call',
              'id': 'call-1',
              'name': 'shell',
              'arguments': '{"command":"echo hi"}',
            },
            {
              'type': 'tool-call',
              'id': 'call-2',
              'name': 'read_file',
              'arguments': '{}',
            },
          ],
        },
      },
      'surfaceOp': 'append',
    })!;
    expect(m.text, 'running it');
    expect(m.tools, ['shell', 'read_file']);
  });
}
