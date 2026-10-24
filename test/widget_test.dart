import 'package:flutter_test/flutter_test.dart';

import 'package:lan_buddy/main.dart';
import 'package:lan_buddy/pairing/pair_client.dart';

void main() {
  testWidgets('pair gate renders launch state', (tester) async {
    await tester.pumpWidget(const DshApp());
    expect(find.text('DeepSeek Harness'), findsOneWidget);
    expect(find.text('连接你的 PC'), findsOneWidget);
    expect(find.text('扫码配对'), findsOneWidget);
  });

  test('error-only PairResult keeps ok=false', () {
    const r = PairResult(error: 'invalid');
    expect(r.ok, isFalse);
    expect(r.muxUrl.toString(), endsWith('/api/remote.mux'));
  });
}
