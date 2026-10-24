import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/session/mux_client.dart';

void main() {
  test('WorkspaceSnapshot reads registry titles, membership, archive set', () {
    final snap = WorkspaceSnapshot.fromWire({
      'items': [
        {
          'workspaceId': 'ws-1',
          'path': r'C:\work\default-workspace',
          'title': 'default-workspace',
          'sessionIds': ['s-1', 's-2'],
          'createdAt': '2026-10-24T00:00:00.000Z',
          'updatedAt': '2026-10-24T00:00:00.000Z',
        },
        {
          'workspaceId': 'ws-2',
          'path': r'C:\work\renamed',
          'title': '我的项目',
          'sessionIds': ['s-3'],
        },
      ],
      'archivedSessionIds': ['s-9'],
      'pinnedSessionIds': [],
    });
    expect(snap.items.map((w) => w.title), ['default-workspace', '我的项目']);
    expect(snap.items.first.sessionIds, ['s-1', 's-2']);
    expect(snap.archivedSessionIds, {'s-9'});
  });

  test('WorkspaceSnapshot tolerates malformed rows', () {
    final snap = WorkspaceSnapshot.fromWire({
      'items': [
        {'workspaceId': 'ws-1'}, // no path
        'nonsense',
        {'workspaceId': 'ws-2', 'path': r'D:\x'},
      ],
    });
    expect(snap.items.map((w) => w.workspaceId), ['ws-2']);
    // Title falls back to the path when the host sends none.
    expect(snap.items.single.title, r'D:\x');
    expect(snap.archivedSessionIds, isEmpty);
  });
}
