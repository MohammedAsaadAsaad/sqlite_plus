import 'package:flutter/material.dart';

import 'course_grade.dart';
import 'course_lessons.dart';
import 'course_models.dart';
import 'course_progress.dart';
import 'session.dart';
import 'sql_editor.dart';
import 'sql_view.dart';

const _ink = Color(0xFF14211C);
const _muted = Color(0xFF5C6560);
const _line = Color(0xFFD9E2DC);
const _ok = Color(0xFF0E7C66);
const _error = Color(0xFFC4473A);
const _picked = Color(0xFFE06A00);
const _pickedFill = Color(0xFFFFE4C4);
const _okFill = Color(0xFFD6EBE4);
const _errorFill = Color(0xFFF8D6D2);
const _note = Color(0xFF1C4E8A);
const _paper = Color(0xFFEEF3F0);

enum _Stage { list, lesson, quiz, done }

enum _Phase { part, review, practice }

IconData courseIcon(CourseMark mark) {
  return switch (mark) {
    CourseMark.reading => Icons.table_rows_rounded,
    CourseMark.writing => Icons.edit_note_rounded,
    CourseMark.tables => Icons.grid_on_rounded,
    CourseMark.summaries => Icons.functions_rounded,
    CourseMark.combining => Icons.account_tree_rounded,
    CourseMark.naming => Icons.bookmark_rounded,
  };
}

/// Chapters, then a lesson whose parts, review, and writing stay on one path.
class CoursePage extends StatefulWidget {
  const CoursePage({super.key, required this.progress});

  final CourseProgress progress;

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  _Stage _stage = _Stage.list;
  _Phase _phase = _Phase.part;
  var _level = 0;
  var _chapter = 0;
  var _part = 0;
  var _partReached = 0;
  var _reviewReached = false;
  var _practiceReached = false;
  var _question = 0;
  int? _choice;
  var _checked = false;
  var _task = 0;
  var _ticket = 0;
  var _grading = false;
  var _tablesReady = false;
  var _finishedChapter = false;
  SqlGrade? _grade;
  QueryTable? _preview;
  QueryTable? _expected;
  List<QueryTable?> _examples = const [];
  List<Object?> _exampleErrors = const [];
  List<SchemaObject> _schema = const [];
  final _sql = TextEditingController();

  CourseProgress get progress => widget.progress;

  SqlLesson get _lesson => sqlCourse[_level];

  @override
  void initState() {
    super.initState();
    progress.load();
  }

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  void _back() {
    if (_stage == _Stage.list) {
      Navigator.of(context).pop();
      return;
    }
    _ticket++;
    setState(() => _stage = _Stage.list);
  }

  void _resetAnswer() {
    _choice = null;
    _checked = false;
  }

  void _openLevel(int index) {
    _ticket++;
    _sql.clear();
    setState(() {
      _level = index;
      _stage = _Stage.lesson;
      _phase = _Phase.part;
      _part = 0;
      _partReached = 0;
      _reviewReached = false;
      _practiceReached = false;
      _question = 0;
      _task = 0;
      _grade = null;
      _schema = const [];
      _finishedChapter = false;
      _resetAnswer();
      _examples = List<QueryTable?>.filled(sqlCourse[index].parts.length, null);
      _exampleErrors =
          List<Object?>.filled(sqlCourse[index].parts.length, null);
    });
    _loadExamples(index);
  }

  Future<void> _loadExamples(int index) async {
    final ticket = _ticket;
    final lesson = sqlCourse[index];
    for (var i = 0; i < lesson.parts.length; i++) {
      try {
        final table = await runExample(lesson.parts[i].example);
        if (!mounted || ticket != _ticket) return;
        setState(() => _examples[i] = table);
      } on Object catch (error) {
        if (!mounted || ticket != _ticket) return;
        setState(() => _exampleErrors[i] = error);
      }
    }
  }

  void _openQuiz(int chapter) {
    if (!progress.isChapterOpen(chapter)) return;
    setState(() {
      _chapter = chapter;
      _stage = _Stage.quiz;
      _question = 0;
      _finishedChapter = false;
      _resetAnswer();
    });
  }

  void _checkAnswer() {
    if (_choice == null || _checked) return;
    setState(() => _checked = true);
  }

  void _continuePart() {
    final last = _part == _lesson.parts.length - 1;
    setState(() {
      _resetAnswer();
      if (last) {
        _phase = _Phase.review;
        _question = 0;
        _reviewReached = true;
      } else {
        _part += 1;
        if (_part > _partReached) _partReached = _part;
      }
    });
  }

  void _nextReviewQuestion() {
    final last = _question == _lesson.review.length - 1;
    if (last) {
      _startPractice();
      return;
    }
    setState(() {
      _question += 1;
      _resetAnswer();
    });
  }

  void _nextQuizQuestion() {
    final questions = sqlChapters[_chapter].review;
    final last = _question == questions.length - 1;
    if (last) {
      _finishQuiz();
      return;
    }
    setState(() {
      _question += 1;
      _resetAnswer();
    });
  }

  void _startPractice() {
    _sql.clear();
    setState(() {
      _phase = _Phase.practice;
      _practiceReached = true;
      _task = 0;
      _grade = null;
      _resetAnswer();
    });
    _loadTask();
  }

  Future<void> _loadTask() async {
    final ticket = ++_ticket;
    final task = _lesson.tasks[_task];
    setState(() {
      _tablesReady = false;
      _preview = null;
      _expected = null;
      _grade = null;
      _schema = const [];
    });
    try {
      final expected = await expectedTable(task);
      final preview = task.preview == null ? null : await previewTable(task);
      final objects = await lessonObjects(task.setup);
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _expected = expected;
        _preview = preview;
        _schema = objects;
        _tablesReady = true;
      });
    } on Object catch (error) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _grade = SqlGrade.fail('$error');
        _tablesReady = true;
      });
    }
  }

  Future<void> _check() async {
    if (_grading) return;
    final ticket = _ticket;
    setState(() => _grading = true);
    final task = _lesson.tasks[_task];
    final grade = await gradeSql(task, _sql.text);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _grading = false;
      _grade = grade;
    });
  }

  void _nextTask() {
    _sql.clear();
    setState(() {
      _task += 1;
      _grade = null;
    });
    _loadTask();
  }

  Future<void> _finishLevel() async {
    await progress.markPassed(_level);
    if (!mounted) return;
    setState(() {
      _finishedChapter = false;
      _stage = _Stage.done;
    });
  }

  Future<void> _finishQuiz() async {
    await progress.markChapterPassed(_chapter);
    if (!mounted) return;
    setState(() {
      _finishedChapter = true;
      _stage = _Stage.done;
    });
  }

  void _showPart(int index) {
    if (index > _partReached) return;
    setState(() {
      _phase = _Phase.part;
      _part = index;
      _grade = null;
      _resetAnswer();
    });
  }

  void _showReview() {
    if (!_reviewReached) return;
    setState(() {
      _phase = _Phase.review;
      _question = 0;
      _resetAnswer();
    });
  }

  void _showPractice() {
    if (!_practiceReached) return;
    _startPractice();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_stage) {
      _Stage.list => 'Learn SQL',
      _Stage.lesson => _lesson.title,
      _Stage.quiz => sqlChapters[_chapter].title,
      _Stage.done =>
        _finishedChapter ? sqlChapters[_chapter].title : _lesson.title,
    };
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: _paper,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: IconButton(
              key: const Key('course-back'),
              tooltip: 'Back',
              onPressed: _back,
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text(title),
          ),
          body: Column(
            children: [
              if (_stage == _Stage.lesson) _rail(),
              Expanded(child: _motion(_stageBody())),
            ],
          ),
        );
      },
    );
  }

  Widget _stageBody() {
    return switch (_stage) {
      _Stage.list => _list(),
      _Stage.lesson => switch (_phase) {
          _Phase.part => _partView(),
          _Phase.review => _questionsView(
              _lesson.review,
              onAdvance: _nextReviewQuestion,
              doneLabel: 'Write SQL',
              doneKey: const Key('course-to-sql'),
            ),
          _Phase.practice => _practiceView(),
        },
      _Stage.quiz => _questionsView(
          sqlChapters[_chapter].review,
          onAdvance: _nextQuizQuestion,
          doneLabel: 'Finish chapter',
          doneKey: const Key('course-quiz-finish'),
          heading: 'Chapter questions',
        ),
      _Stage.done => _doneView(),
    };
  }

  Widget _motion(Widget child) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(
          '${_stage.name}-$_level-$_chapter-$_phase-$_part-$_question-$_task'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(18 * (1 - value), 0),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  Widget _rail() {
    final lesson = _lesson;
    return Material(
      color: Colors.white,
      child: SizedBox(
        height: 58,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          children: [
            for (var index = 0; index < lesson.parts.length; index++)
              _chip(
                key: Key('course-step-$index'),
                icon: Icons.menu_book_outlined,
                label: lesson.parts[index].title,
                active: _phase == _Phase.part && _part == index,
                enabled: index <= _partReached,
                onTap: () => _showPart(index),
              ),
            _chip(
              key: const Key('course-step-review'),
              icon: Icons.quiz_outlined,
              label: 'Lesson questions',
              active: _phase == _Phase.review,
              enabled: _reviewReached,
              onTap: _showReview,
            ),
            _chip(
              key: const Key('course-step-write'),
              icon: Icons.edit_outlined,
              label: 'Write',
              active: _phase == _Phase.practice,
              enabled: _practiceReached,
              onTap: _showPractice,
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required Key key,
    required IconData icon,
    required String label,
    required bool active,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = !enabled
        ? const Color(0xFFB7C4BE)
        : active
            ? Colors.white
            : _ok;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: !enabled
            ? const Color(0xFFF4F7F5)
            : active
                ? _ok
                : const Color(0xFFE7F2EC),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: key,
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _list() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        for (var chapter = 0; chapter < sqlChapters.length; chapter++)
          _chapterBlock(chapter),
      ],
    );
  }

  Widget _chapterBlock(int chapter) {
    final item = sqlChapters[chapter];
    final start = firstLessonOf(chapter);
    final passed = [
      for (var index = 0; index < item.lessons.length; index++)
        if (progress.isPassed(start + index)) index,
    ].length;
    final quizOpen = progress.isChapterOpen(chapter);
    final quizPassed = progress.isChapterPassed(chapter);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: quizPassed ? _ok : const Color(0xFFE7F2EC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  courseIcon(item.mark),
                  color: quizPassed ? Colors.white : _ok,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.summary,
                      style: const TextStyle(
                          color: _muted, fontSize: 12, height: 1.3),
                    ),
                  ],
                ),
              ),
              Text(
                '$passed/${item.lessons.length}',
                style: const TextStyle(
                  color: _ok,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < item.lessons.length; index++)
            _levelCard(start + index),
          _quizCard(chapter, open: quizOpen, done: quizPassed),
        ],
      ),
    );
  }

  Widget _levelCard(int index) {
    final lesson = sqlCourse[index];
    final open = progress.isUnlocked(index);
    final done = progress.isPassed(index);
    final number = index - firstLessonOf(chapterOfLesson(index)) + 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: done ? const Color(0xFFB7DDD2) : _line),
        ),
        child: InkWell(
          key: Key('course-level-$index'),
          onTap: open ? () => _openLevel(index) : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              children: [
                _badge('$number', open: open, done: done),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lesson.title,
                        style: TextStyle(
                          color: open ? _ink : const Color(0xFFB7C4BE),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lesson.summary,
                        style: TextStyle(
                          color: open ? _muted : const Color(0xFFB7C4BE),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (done)
                  const Icon(Icons.check_circle, color: _ok, size: 20)
                else if (!open)
                  const Icon(Icons.lock_outline,
                      color: Color(0xFFB7C4BE), size: 20)
                else
                  const Icon(Icons.chevron_right, color: _ok),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quizCard(int chapter, {required bool open, required bool done}) {
    return Material(
      color: open ? const Color(0xFFF7FBFF) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: open ? const Color(0xFFC5D7EE) : _line),
      ),
      child: InkWell(
        key: Key('course-quiz-$chapter'),
        onTap: open ? () => _openQuiz(chapter) : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            children: [
              _badge('',
                  open: open, done: done, icon: Icons.fact_check_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chapter questions',
                      style: TextStyle(
                        color: open ? _ink : const Color(0xFFB7C4BE),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Questions that cover this whole chapter.',
                      style: TextStyle(
                        color: open ? _muted : const Color(0xFFB7C4BE),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (done)
                const Icon(Icons.check_circle, color: _note, size: 20)
              else if (!open)
                const Icon(Icons.lock_outline,
                    color: Color(0xFFB7C4BE), size: 20)
              else
                const Icon(Icons.chevron_right, color: _note),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(
    String text, {
    required bool open,
    required bool done,
    IconData? icon,
  }) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: done
            ? const Color(0xFFD6EBE4)
            : open
                ? const Color(0xFFF4F7F5)
                : const Color(0xFFF7FBF9),
        shape: BoxShape.circle,
      ),
      child: icon != null
          ? Icon(icon, size: 18, color: open ? _note : const Color(0xFFB7C4BE))
          : Text(
              text,
              style: TextStyle(
                color: open ? _ok : const Color(0xFFB7C4BE),
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
    );
  }

  Widget _partView() {
    final part = _lesson.parts[_part];
    final last = _part == _lesson.parts.length - 1;
    final correct = _checked && _choice == part.question.answer;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Part ${_part + 1} of ${_lesson.parts.length}',
                  style: const TextStyle(
                    color: _ok,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  part.title,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  part.teach,
                  style: const TextStyle(color: _ink, height: 1.5),
                ),
                const SizedBox(height: 16),
                _exampleCard(part.example, _part),
                const SizedBox(height: 8),
                _questionCard(part.question, label: 'Question on this part'),
              ],
            ),
          ),
        ),
        _answerBar(
          question: part.question,
          last: last,
          correct: correct,
          advanceLabel: last ? 'Lesson questions' : 'Continue',
          advanceKey:
              last ? const Key('course-to-questions') : const Key('mcq-next'),
          onAdvance: _continuePart,
        ),
      ],
    );
  }

  Widget _exampleCard(SqlExample example, int index) {
    final table = index < _examples.length ? _examples[index] : null;
    final error = index < _exampleErrors.length ? _exampleErrors[index] : null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              example.title,
              style: const TextStyle(
                color: _ink,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              example.note,
              style: const TextStyle(color: _muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            SqlCodeView(source: formatSql(example.statement.trim())),
            const SizedBox(height: 12),
            const Text(
              'Result',
              style: TextStyle(
                color: _ink,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            if (error != null)
              Text('$error', style: const TextStyle(color: _error))
            else if (table == null)
              const Text('Running the example.', style: TextStyle(color: _note))
            else
              _ResultTable(table),
          ],
        ),
      ),
    );
  }

  Widget _questionsView(
    List<SqlQuestion> questions, {
    required VoidCallback onAdvance,
    required String doneLabel,
    required Key doneKey,
    String heading = 'Lesson questions',
  }) {
    final question = questions[_question];
    final correct = _checked && _choice == question.answer;
    final last = _question == questions.length - 1;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              Text(
                '$heading · ${_question + 1} of ${questions.length}',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              _questionCard(question, label: 'Question ${_question + 1}'),
            ],
          ),
        ),
        _answerBar(
          question: question,
          last: last,
          correct: correct,
          advanceLabel: last ? doneLabel : 'Next question',
          advanceKey: last ? doneKey : const Key('mcq-next'),
          onAdvance: onAdvance,
        ),
      ],
    );
  }

  Widget _questionCard(SqlQuestion question, {required String label}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: _note,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              question.prompt,
              style: const TextStyle(
                color: _ink,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            for (var i = 0; i < question.choices.length; i++)
              _choiceTile(question, i),
          ],
        ),
      ),
    );
  }

  Widget _answerBar({
    required SqlQuestion question,
    required bool last,
    required bool correct,
    required String advanceLabel,
    required Key advanceKey,
    required VoidCallback onAdvance,
  }) {
    final Widget button;
    if (_checked && !correct) {
      button = OutlinedButton(
        key: const Key('course-retry'),
        onPressed: () => setState(_resetAnswer),
        child: const Text('Try again'),
      );
    } else if (_checked && correct) {
      button = FilledButton.icon(
        key: advanceKey,
        onPressed: onAdvance,
        icon: const Icon(Icons.arrow_forward),
        label: Text(advanceLabel),
      );
    } else {
      button = FilledButton(
        key: const Key('mcq-next'),
        onPressed: _choice == null ? null : _checkAnswer,
        child: const Text('Check answer'),
      );
    }
    return _bar(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_checked && !correct) ...[
            Text(
              question.why,
              style: const TextStyle(color: _error, height: 1.35),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(height: 48, child: button),
        ],
      ),
    );
  }

  Widget _choiceTile(SqlQuestion question, int index) {
    final selected = _choice == index;
    final correct = index == question.answer;
    final revealed = _checked && (selected || correct);
    final Color fill;
    final Color mark;
    final Color border;
    if (!_checked && selected) {
      fill = _pickedFill;
      mark = _picked;
      border = _picked;
    } else if (_checked && correct) {
      fill = _okFill;
      mark = _ok;
      border = _ok;
    } else if (_checked && selected) {
      fill = _errorFill;
      mark = _error;
      border = _error;
    } else {
      fill = Colors.white;
      mark = const Color(0xFFF4F7F5);
      border = _line;
    }
    final letter = String.fromCharCode(65 + index);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: border, width: revealed || selected ? 2 : 1),
        ),
        child: Material(
          color: const Color(0x00000000),
          child: InkWell(
            key: Key('mcq-choice-$index'),
            onTap: _checked ? null : () => setState(() => _choice = index),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: mark,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      letter,
                      style: TextStyle(
                        color: revealed || selected ? Colors.white : _muted,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      question.choices[index],
                      style: const TextStyle(color: _ink, height: 1.3),
                    ),
                  ),
                  if (!_checked && selected)
                    const Icon(Icons.circle, color: _picked, size: 14)
                  else if (_checked && correct)
                    const Icon(Icons.check_circle, color: _ok, size: 18)
                  else if (_checked && selected)
                    const Icon(Icons.cancel, color: _error, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _practiceView() {
    final task = _lesson.tasks[_task];
    final grade = _grade;
    final passed = grade != null && grade.passed;
    final last = _task == _lesson.tasks.length - 1;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              Text(
                'Statement ${_task + 1} of ${_lesson.tasks.length}',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(task.prompt,
                  style:
                      const TextStyle(color: _ink, height: 1.45, fontSize: 16)),
              const SizedBox(height: 16),
              if (task.preview != null) ...[
                const _Label('Starting rows'),
                const SizedBox(height: 8),
                _waiting(_preview),
                const SizedBox(height: 16),
              ],
              const _Label('Expected result'),
              const SizedBox(height: 8),
              _waiting(_expected),
              if (_schema.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _Label('Tables in this step'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final object in _schema) _tablePill(object)],
                ),
              ],
              if (grade != null && grade.actual.columns.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _Label('Your result'),
                const SizedBox(height: 8),
                _ResultTable(grade.actual),
              ],
            ],
          ),
        ),
        _bar(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SqlEditor(
                controller: _sql,
                objects: _schema,
                visibleLines: 4,
                hint: 'Write one SQL statement',
                inputKey: const Key('task-sql'),
                highlightKey: const Key('task-highlight'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Suggestions follow the word you are typing and the tables in this step.',
                style: TextStyle(color: _muted, fontSize: 12, height: 1.3),
              ),
              if (grade != null) ...[
                const SizedBox(height: 8),
                Text(
                  grade.message,
                  style: TextStyle(
                    color: passed ? _ok : _error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: passed && last
                    ? FilledButton(
                        key: const Key('task-finish'),
                        onPressed: _finishLevel,
                        child: const Text('Finish lesson'),
                      )
                    : passed
                        ? FilledButton(
                            key: const Key('task-next'),
                            onPressed: _nextTask,
                            child: const Text('Next statement'),
                          )
                        : FilledButton(
                            key: const Key('task-check'),
                            onPressed: _grading ? null : _check,
                            child: Text(_grading ? 'Checking' : 'Check'),
                          ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _waiting(QueryTable? table) {
    if (!_tablesReady || table == null) {
      return const Text('Running the example.', style: TextStyle(color: _note));
    }
    return _ResultTable(table);
  }

  Widget _doneView() {
    final nextLesson = _level + 1;
    final hasNextLesson =
        nextLesson < sqlCourse.length && progress.isUnlocked(nextLesson);
    final chapter = _finishedChapter ? _chapter : chapterOfLesson(_level);
    final showQuiz = !_finishedChapter &&
        progress.isChapterOpen(chapter) &&
        !progress.isChapterPassed(chapter) &&
        !hasNextLesson;
    final finishedCourse =
        _finishedChapter && chapter == sqlChapters.length - 1;
    final title = finishedCourse
        ? 'You finished the course.'
        : _finishedChapter
            ? 'You finished this chapter.'
            : 'You finished this lesson.';
    final detail = finishedCourse
        ? 'Every chapter is open from the list.'
        : showQuiz
            ? 'The chapter questions are open.'
            : hasNextLesson
                ? 'The next lesson is open.'
                : 'You can return to the list.';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFD6EBE4),
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Icon(Icons.check, color: _ok, size: 28),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(detail, style: const TextStyle(color: _muted, height: 1.4)),
            ],
          ),
        ),
        _bar(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasNextLesson)
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const Key('course-next'),
                    onPressed: () => _openLevel(nextLesson),
                    child: const Text('Next lesson'),
                  ),
                ),
              if (showQuiz)
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const Key('course-next'),
                    onPressed: () => _openQuiz(chapter),
                    child: const Text('Chapter questions'),
                  ),
                ),
              if (hasNextLesson || showQuiz) const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const Key('course-home'),
                  onPressed: () => setState(() => _stage = _Stage.list),
                  child: const Text('All lessons'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tablePill(SchemaObject object) {
    final columns = object.columns.map((column) => column.name).join(', ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE7F2EC),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        columns.isEmpty ? object.name : '${object.name}: $columns',
        style: const TextStyle(
            color: _ok, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }

  Widget _bar(Widget child) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: child,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: _ink, fontWeight: FontWeight.w700, fontSize: 13),
    );
  }
}

class _ResultTable extends StatelessWidget {
  const _ResultTable(this.table);

  final QueryTable table;

  @override
  Widget build(BuildContext context) {
    if (table.columns.isEmpty) {
      return const Text('No rows.', style: TextStyle(color: _muted));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: _line),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFE7F2EC)),
                children: [
                  for (final column in table.columns)
                    _box(column, header: true, missing: false),
                ],
              ),
              for (final row in table.rows)
                TableRow(
                  children: [
                    for (final value in row)
                      _box(value, header: false, missing: value == 'NULL'),
                  ],
                ),
            ],
          ),
        ),
        if (table.rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No rows.', style: TextStyle(color: _muted)),
          ),
      ],
    );
  }

  Widget _box(String text, {required bool header, required bool missing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          color: header ? _ok : (missing ? _muted : _ink),
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          fontWeight: header ? FontWeight.w700 : FontWeight.w400,
          fontStyle: missing ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }
}
