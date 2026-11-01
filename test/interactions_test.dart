import 'package:flutter_test/flutter_test.dart';
import 'package:lan_buddy/session/interactions.dart';

void main() {
  test('parses the questions of a forwarded request', () {
    final questions = parseAskQuestions([
      {
        'id': 'q1',
        'header': '部署',
        'question': '发布到哪个环境？',
        'detail': '生产环境会立刻影响用户。',
        'options': [
          {'label': '预发', 'description': '先给小部分人看'},
          {'label': '生产'},
        ],
      },
      {
        'id': 'q2',
        'question': '还要做哪些检查？',
        'multiSelect': true,
        'options': [
          {'label': '单测'},
          {'label': '回归'},
        ],
      },
    ]);
    expect(questions, isNotNull);
    expect(questions!.length, 2);

    final first = questions.first;
    expect(first.id, 'q1');
    expect(first.header, '部署');
    expect(first.detail, '生产环境会立刻影响用户。');
    expect(first.multiSelect, isFalse);
    expect(first.options.map((o) => o.label), ['预发', '生产']);
    expect(first.options.first.description, '先给小部分人看');
    expect(first.options.last.description, isNull);

    expect(questions.last.multiSelect, isTrue);
    expect(questions.last.header, isNull);
  });

  test('refuses a request it cannot fully understand', () {
    expect(parseAskQuestions(null), isNull);
    expect(parseAskQuestions('not a list'), isNull);
    expect(parseAskQuestions(const []), isNull);
    expect(parseAskQuestions([
      {'question': '缺少 id'},
    ]), isNull);
    expect(parseAskQuestions([
      {'id': 'q1', 'question': ''},
    ]), isNull);
    expect(parseAskQuestions([
      {
        'id': 'q1',
        'question': '带一个坏选项',
        'options': [
          {'label': 'ok'},
          {'label': 42},
        ],
      },
    ]), isNull);
  });

  test('builds one answer item per question in request order', () {
    final questions = parseAskQuestions([
      {
        'id': 'q1',
        'question': '环境？',
        'options': [
          {'label': '预发'},
          {'label': '生产'},
        ],
      },
      {
        'id': 'q2',
        'question': '补充说明？',
      },
      {
        'id': 'q3',
        'question': '跳过这道题',
        'options': [
          {'label': 'A'},
        ],
      },
    ])!;

    final answers = buildAskAnswers(
      questions: questions,
      selected: [
        {'生产'},
        <String>{},
        <String>{},
      ],
      custom: const ['', '  手动部署  ', ''],
    );

    expect(answers, [
      {
        'id': 'q1',
        'selected': ['生产'],
      },
      {
        'id': 'q2',
        'selected': <String>[],
        'custom': '手动部署',
      },
      {'id': 'q3', 'selected': <String>[]},
    ]);
    // A skip carries no custom key at all, which is how dsh tells it apart
    // from a free-text answer.
    expect(answers.last.containsKey('custom'), isFalse);
  });

  test('serializes labels in option order, not tap order', () {
    final questions = parseAskQuestions([
      {
        'id': 'multi',
        'question': '选哪些？',
        'multiSelect': true,
        'options': [
          {'label': '一'},
          {'label': '二'},
          {'label': '三'},
        ],
      },
    ])!;
    final answers = buildAskAnswers(
      questions: questions,
      selected: [
        {'三', '一'},
      ],
      custom: const [''],
    );
    expect(answers.single['selected'], ['一', '三']);
  });
}
