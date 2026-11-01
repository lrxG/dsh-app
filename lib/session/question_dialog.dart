/// The phone's side of `user-questions/request`: one modal with a block per
/// question, selectable options, an optional free-text answer, and an explicit
/// per-question skip. Submitting returns the batch to the PC through
/// [ApprovalCenter], which is the same waterfall path approvals use.
library;

import 'package:flutter/material.dart';

import 'approval_center.dart';
import 'interactions.dart';

/// Show the question card and wait until it is answered, skipped, or settled by
/// another client. Non-dismissible: the PC's turn is blocked until an answer
/// arrives somewhere.
Future<void> showQuestionDialog(BuildContext context, PendingQuestion item) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _QuestionDialog(item: item),
  );
}

class _QuestionDialog extends StatefulWidget {
  const _QuestionDialog({required this.item});

  final PendingQuestion item;

  @override
  State<_QuestionDialog> createState() => _QuestionDialogState();
}

class _QuestionDialogState extends State<_QuestionDialog> {
  late final List<Set<String>> _selected;
  late final List<TextEditingController> _custom;
  late final List<bool> _skipped;

  bool _submitting = false;
  String? _error;

  /// Set once this card is going away, so the center's listener and the submit
  /// path cannot both pop the route.
  bool _closing = false;

  List<AskQuestion> get _questions => widget.item.questions;

  @override
  void initState() {
    super.initState();
    _selected = [for (final _ in _questions) <String>{}];
    _custom = [for (final _ in _questions) TextEditingController()];
    _skipped = [for (final _ in _questions) false];
    ApprovalCenter.instance.addListener(_onCenter);
  }

  @override
  void dispose() {
    ApprovalCenter.instance.removeListener(_onCenter);
    for (final controller in _custom) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The desktop client (or the PC itself) answered first: close this card
  /// instead of letting it submit into a settled request.
  void _onCenter() {
    if (_closing) return;
    final alive =
        ApprovalCenter.instance.pending.any((p) => p.eventId == widget.item.eventId);
    if (alive) return;
    _closing = true;
    if (mounted) Navigator.of(context).maybePop();
  }

  bool get _complete {
    for (var i = 0; i < _questions.length; i++) {
      if (!_skipped[i] &&
          _selected[i].isEmpty &&
          _custom[i].text.trim().isEmpty) {
        return false;
      }
    }
    return true;
  }

  void _toggle(int index, String label) {
    if (_skipped[index]) return;
    final question = _questions[index];
    setState(() {
      final chosen = _selected[index];
      if (question.multiSelect) {
        if (!chosen.remove(label)) chosen.add(label);
        return;
      }
      // Tapping the current single choice clears it, leaving room for a
      // free-text answer.
      final wasOnly = chosen.length == 1 && chosen.contains(label);
      chosen.clear();
      if (!wasOnly) chosen.add(label);
    });
  }

  void _toggleSkip(int index) {
    setState(() {
      final skip = !_skipped[index];
      _skipped[index] = skip;
      if (skip) {
        _selected[index].clear();
        _custom[index].clear();
      }
    });
  }

  Future<void> _submit() async {
    if (_submitting || !_complete) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final answers = buildAskAnswers(
      questions: _questions,
      selected: _selected,
      custom: [for (final controller in _custom) controller.text],
    );
    try {
      await ApprovalCenter.instance.answerQuestion(widget.item, answers);
      if (!mounted || _closing) return;
      _closing = true;
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '回答没能送到 PC：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.58;
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      title: Row(
        children: [
          const Icon(Icons.help_outline, size: 19, color: Color(0xFF007AFF)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _questions.length > 1 ? 'DSH 提问 · ${_questions.length} 个问题' : 'DSH 提问',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1C1C1E),
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: maxHeight,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _questions.length; i++) ...[
                if (i > 0) const Divider(height: 26, color: Color(0xFFE5E5EA)),
                _questionBlock(i),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.45, color: Color(0xFFE5453C)),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        TextButton(
          onPressed: _submitting || !_complete ? null : _submit,
          child: Text(
            _submitting ? '提交中…' : '提交',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: !_submitting && _complete
                  ? const Color(0xFF007AFF)
                  : const Color(0xFFC7C7CC),
            ),
          ),
        ),
      ],
    );
  }

  Widget _questionBlock(int index) {
    final question = _questions[index];
    final skipped = _skipped[index];
    final dim = skipped ? const Color(0xFF8E8E93) : const Color(0xFF1C1C1E);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question.header != null) ...[
          Text(
            question.header!.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.5,
              color: Color(0xFF8E8E93),
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          question.question,
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            fontWeight: FontWeight.w500,
            color: dim,
          ),
        ),
        if (question.detail != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7FA),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: Text(
                question.detail!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: skipped
                      ? const Color(0xFF8E8E93)
                      : const Color(0xFF3A3A3C),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        for (final option in question.options)
          _optionRow(index, option, skipped),
        TextField(
          controller: _custom[index],
          enabled: !skipped,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(fontSize: 14, height: 1.35),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: question.options.isEmpty ? '输入你的回答' : '其他回答（可选）',
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFC7C7CC)),
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF7F7FA),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF007AFF)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _submitting ? null : () => _toggleSkip(index),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              skipped ? '撤销跳过' : '跳过本题',
              style: const TextStyle(fontSize: 13, color: Color(0xFF007AFF)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _optionRow(int index, AskOption option, bool skipped) {
    final selected = _selected[index].contains(option.label);
    final multi = _questions[index].multiSelect;
    final accent = skipped ? const Color(0xFFC7C7CC) : const Color(0xFF007AFF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: skipped ? null : () => _toggle(index, option.label),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEAF2FF) : const Color(0xFFF7F7FA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xFF007AFF) : Colors.transparent,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? (multi
                        ? Icons.check_box
                        : Icons.radio_button_checked)
                    : (multi
                        ? Icons.check_box_outline_blank
                        : Icons.radio_button_unchecked),
                size: 18,
                color: selected ? accent : const Color(0xFF8E8E93),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: skipped
                            ? const Color(0xFF8E8E93)
                            : const Color(0xFF1C1C1E),
                      ),
                    ),
                    if (option.description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        option.description!,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
