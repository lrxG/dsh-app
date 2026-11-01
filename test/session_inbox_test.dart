import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/session/messages.dart';

Map<String, dynamic> userMessage(String id, String text, {bool user = true}) => {
      'id': id,
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': user ? {'kind': 'user', 'rpcId': 'r-$id'} : {'kind': 'skill'},
    };

void main() {
  test('snapshot inbox renders mid-turn input before queued turns', () {
    final inbox = decodeSnapshotInbox({
      'projections': {
        'values': {
          'inbox': {
            'next-turn': [userMessage('t1', '排队第二条')],
            'next-step': [
              userMessage('s1', '插话'),
              userMessage('x1', '', user: false),
            ],
          },
        },
      },
    });
    expect(inbox['next-step']!.map((m) => m.itemId), ['s1']);
    expect(inbox['next-step']!.first.steering, isTrue);
    expect(inbox['next-turn']!.single.text, '排队第二条');
    expect(inbox['next-turn']!.single.steering, isFalse);
  });

  test('missing projections decode to empty rows', () {
    final inbox = decodeSnapshotInbox({'records': const []});
    expect(inbox['next-step'], isEmpty);
    expect(inbox['next-turn'], isEmpty);
    expect(decodeSnapshotInbox(null)['next-turn'], isEmpty);
  });

  test('splice inserts, replaces and removes rows in place', () {
    final rows = <QueuedMessage>[];
    applyInboxSplice(rows, {
      'target': 'next-turn',
      'start': 0,
      'inserted': [userMessage('a', 'A'), userMessage('b', 'B')],
    });
    expect(rows.map((m) => m.text), ['A', 'B']);

    applyInboxSplice(rows, {
      'target': 'next-turn',
      'start': 1,
      'removedCount': 1,
      'inserted': [userMessage('b2', 'B 改过')],
    });
    expect(rows.map((m) => m.itemId), ['a', 'b2']);

    applyInboxSplice(rows, {
      'target': 'next-turn',
      'start': 0,
      'removedCount': 1,
      'inserted': const [],
      'outcome': 'canceled',
    });
    expect(rows.single.text, 'B 改过');
  });
}
