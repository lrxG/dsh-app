import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/session/dsh_client.dart';

void main() {
  test('SessionSummary reads the projected model selection', () {
    final summary = SessionSummary.fromWire({
      'sessionId': 's-1',
      'updatedAt': 1,
      'blank': false,
      'running': false,
      'cwd': r'C:\work',
      'projections': {
        'values': {
          'title': 'demo',
          'modelSelection': {
            'next': {
              'provider': 'tokenrhythm',
              'model': 'deepseek-v4.1-flash-1017',
              'reasoningEffort': 'high',
            },
            'lastUsed': {'provider': 'x', 'model': 'y'},
          },
        },
      },
    });
    expect(summary.model?.provider, 'tokenrhythm');
    expect(summary.model?.model, 'deepseek-v4.1-flash-1017');
    expect(summary.model?.reasoningEffort, 'high');
  });

  test('SessionSummary falls back to lastUsed and tolerates absence', () {
    final fallback = SessionSummary.fromWire({
      'sessionId': 's-2',
      'projections': {
        'values': {
          'modelSelection': {
            'lastUsed': {'provider': 'p', 'model': 'm'},
          },
        },
      },
    });
    expect(fallback.model?.model, 'm');

    final none = SessionSummary.fromWire({'sessionId': 's-3'});
    expect(none.model, isNull);
  });
}
