import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/session/mux_client.dart';

void main() {
  test('decodes the ready frame with clientId', () {
    final frame = decodeRemoteEvent({
      'type': 'ready',
      'clientId': 'client-1',
      'host': {'home': r'C:\Users\example'},
    });
    expect(frame, isA<RemoteEventsReady>());
    expect((frame as RemoteEventsReady).clientId, 'client-1');
  });

  test('decodes an approval waterfall with display reason', () {
    final frame = decodeRemoteEvent({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'ev-1',
      'agentId': 'session-123',
      'request': {
        'toolName': 'shell',
        'reason': 'run tests',
        'displayReason': {'zh': '需要执行命令', 'en': 'needs a shell'},
      },
    });
    expect(frame, isA<RemoteEventWaterfall>());
    final waterfall = frame as RemoteEventWaterfall;
    expect(waterfall.event, 'approval/request');
    expect(waterfall.eventId, 'ev-1');
    expect(waterfall.agentId, 'session-123');
    expect(waterfall.request['toolName'], 'shell');
  });

  test('decodes emit notifications and cancel frames', () {
    final emit = decodeRemoteEvent({
      'type': 'emit',
      'event': 'api-session/status',
      'args': ['session-1', 'idle'],
    });
    expect(emit, isA<RemoteEventEmit>());
    expect((emit as RemoteEventEmit).event, 'api-session/status');
    expect(emit.args.length, 2);

    final cancel = decodeRemoteEvent({'type': 'cancel', 'eventId': 'ev-1'});
    expect(cancel, isA<RemoteEventCancelled>());
    expect((cancel as RemoteEventCancelled).eventId, 'ev-1');
  });

  test('rejects malformed frames', () {
    expect(decodeRemoteEvent(null), isNull);
    expect(decodeRemoteEvent('text'), isNull);
    expect(decodeRemoteEvent({'type': 'ready'}), isNull);
    expect(decodeRemoteEvent({'type': 'waterfall', 'event': 'x'}), isNull);
    expect(decodeRemoteEvent({'type': 'unknown'}), isNull);
  });
}
