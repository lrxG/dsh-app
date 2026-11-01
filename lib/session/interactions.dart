/// The questions a PC can put to the phone mid-turn.
///
/// dsh forwards `user-questions/request` to every connected client with the
/// same payload its desktop UI receives, and the answer travels back through
/// `$events/result` exactly like an approval outcome — the value just is an
/// `{answers: [...]}` batch instead of a decision string.
library;

/// One selectable answer offered by a question.
class AskOption {
  const AskOption({required this.label, this.description});

  /// The label that travels back as the answer value.
  final String label;

  /// Optional supporting line rendered under the label.
  final String? description;

  static AskOption? fromJson(Object? value) {
    if (value is! Map) return null;
    final label = value['label'];
    if (label is! String || label.isEmpty) return null;
    final description = value['description'];
    return AskOption(
      label: label,
      description: _text(description),
    );
  }
}

/// One question of a forwarded `user-questions/request`.
class AskQuestion {
  const AskQuestion({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const <AskOption>[],
    this.multiSelect = false,
  });

  /// Caller-provided id, echoed in the answer so the tool can match it up.
  final String id;
  final String question;
  final String? header;
  final String? detail;
  final List<AskOption> options;
  final bool multiSelect;

  static AskQuestion? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final question = value['question'];
    if (id is! String || id.isEmpty) return null;
    if (question is! String || question.isEmpty) return null;
    final rawOptions = value['options'];
    final options = <AskOption>[];
    if (rawOptions is List) {
      for (final raw in rawOptions) {
        final option = AskOption.fromJson(raw);
        // A malformed option would leave a label the PC cannot match; treat
        // the whole prompt as unreadable instead of guessing.
        if (option == null) return null;
        options.add(option);
      }
    }
    return AskQuestion(
      id: id,
      question: question,
      header: _text(value['header']),
      detail: _text(value['detail']),
      options: options,
      multiSelect: value['multiSelect'] == true,
    );
  }
}

/// Parse the forwarded `questions` array.
///
/// Returns null when the request is empty or any entry is malformed, so a
/// half-understood prompt is never claimed — the PC or another client keeps it.
List<AskQuestion>? parseAskQuestions(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final questions = <AskQuestion>[];
  for (final raw in value) {
    final question = AskQuestion.fromJson(raw);
    if (question == null) return null;
    questions.add(question);
  }
  return questions;
}

/// Build the answer batch: one item per question, in request order.
///
/// An empty selection with no custom text is dsh's explicit "skipped" answer —
/// the tool then continues without an answer instead of blocking.
List<Map<String, dynamic>> buildAskAnswers({
  required List<AskQuestion> questions,
  required List<Set<String>> selected,
  required List<String> custom,
}) {
  final answers = <Map<String, dynamic>>[];
  for (var i = 0; i < questions.length; i++) {
    final question = questions[i];
    final chosen = i < selected.length ? selected[i] : const <String>{};
    final text = i < custom.length ? custom[i].trim() : '';
    answers.add({
      'id': question.id,
      // Option order, not tap order: the PC compares labels, and a stable order
      // reads better in the transcript.
      'selected': [
        for (final option in question.options)
          if (chosen.contains(option.label)) option.label,
      ],
      if (text.isNotEmpty) 'custom': text,
    });
  }
  return answers;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
