import 'package:flutter/material.dart';

import 'course_grade.dart';
import 'course_lessons.dart';
import 'course_models.dart';
import 'course_progress.dart';
import 'sql_view.dart';

const _ink = Color(0xFF14211C);
const _muted = Color(0xFF5C6560);
const _line = Color(0xFFD9E2DC);
const _ok = Color(0xFF0E7C66);
const _error = Color(0xFFC4473A);
const _note = Color(0xFF1C4E8A);

enum _Stage { list, examples, questions, practice, done }

/// Examples, questions, then one checked statement per level.
class CoursePage extends StatefulWidget {
  const CoursePage({super.key, required this.progress});

  final CourseProgress progress;

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  _Stage _stage = _Stage.list;
  var _level = 0;
  var _question = 0;
  int? _choice;
  var _checked = false;
  var _task = 0;
  var _ticket = 0;
  var _grading = false;
  var _tablesReady = false;
  SqlGrade? _grade;
  QueryTable? _preview;
  QueryTable? _expected;
  List<QueryTable?> _examples = const [];
  List<Object?> _exampleErrors = const [];
  final _sql = TextEditingController();

  CourseProgress get progress => widget.progress;

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

  void _openLevel(int index) {
    _ticket++;
    _sql.clear();
    setState(() {
      _level = index;
      _stage = _Stage.examples;
      _question = 0;
      _choice = null;
      _checked = false;
      _task = 0;
      _grade = null;
      _examples = List<QueryTable?>.filled(
        sqlCourse[index].examples.length,
        null,
      );
      _exampleErrors = List<Object?>.filled(
        sqlCourse[index].examples.length,
        null,
      );
    });
    _loadExamples(index);
  }

  Future<void> _loadExamples(int index) async {
    final ticket = _ticket;
    final level = sqlCourse[index];
    for (var i = 0; i < level.examples.length; i++) {
      try {
        final table = await runExample(level.examples[i]);
        if (!mounted || ticket != _ticket) return;
        setState(() => _examples[i] = table);
      } on Object catch (error) {
        if (!mounted || ticket != _ticket) return;
        setState(() => _exampleErrors[i] = error);
      }
    }
  }

  void _startPractice() {
    _sql.clear();
    setState(() {
      _stage = _Stage.practice;
      _task = 0;
      _grade = null;
    });
    _loadTask();
  }

  Future<void> _loadTask() async {
    final ticket = ++_ticket;
    final task = sqlCourse[_level].tasks[_task];
    setState(() {
      _tablesReady = false;
      _preview = null;
      _expected = null;
      _grade = null;
    });
    try {
      final expected = await expectedTable(task);
      final preview = task.preview == null ? null : await previewTable(task);
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _expected = expected;
        _preview = preview;
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
    final task = sqlCourse[_level].tasks[_task];
    final grade = await gradeSql(task, _sql.text);
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _grading = false;
      _grade = grade;
    });
  }

  void _nextTask() {
    _sql.clear();
    setState(() => _task += 1);
    _loadTask();
  }

  Future<void> _finishLevel() async {
    await progress.markPassed(_level);
    if (!mounted) return;
    setState(() => _stage = _Stage.done);
  }

  @override
  Widget build(BuildContext context) {
    final title = _stage == _Stage.list ? 'Learn SQL' : sqlCourse[_level].title;
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFFEEF3F0),
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
          body: switch (_stage) {
            _Stage.list => _list(),
            _Stage.examples => _examplesView(),
            _Stage.questions => _questionsView(),
            _Stage.practice => _practiceView(),
            _Stage.done => _doneView(),
          },
        );
      },
    );
  }

  Widget _list() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      children: [
        const Text(
          'Twelve levels, from a first query to a full report. Each level shows examples, then questions, then a statement this program runs.',
          style: TextStyle(color: _muted, height: 1.4),
        ),
        const SizedBox(height: 8),
        const Text(
          'This course runs on sqlite_plus. It is a practical path, not every SQLite feature.',
          style: TextStyle(color: _note, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (var index = 0; index < sqlCourse.length; index++)
          _levelCard(index),
      ],
    );
  }

  Widget _levelCard(int index) {
    final level = sqlCourse[index];
    final open = progress.isUnlocked(index);
    final done = progress.isPassed(index);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _line),
        ),
        child: InkWell(
          key: Key('course-level-$index'),
          onTap: open ? () => _openLevel(index) : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: open ? _ok : const Color(0xFFB7C4BE),
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        level.title,
                        style: TextStyle(
                          color: open ? _ink : const Color(0xFFB7C4BE),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        level.summary,
                        style: TextStyle(
                          color: open ? _muted : const Color(0xFFB7C4BE),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (done)
                  const Text(
                    'Passed',
                    style: TextStyle(
                      color: _ok,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  )
                else if (!open)
                  const Icon(Icons.lock_outline, color: Color(0xFFB7C4BE)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _examplesView() {
    final level = sqlCourse[_level];
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Text(
                level.teach,
                style: const TextStyle(color: _ink, height: 1.45),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < level.examples.length; i++)
                _exampleCard(level.examples[i], i),
            ],
          ),
        ),
        _bar(
          FilledButton(
            key: const Key('course-to-questions'),
            onPressed: () {
              setState(() {
                _stage = _Stage.questions;
                _question = 0;
                _choice = null;
                _checked = false;
              });
            },
            child: const Text('Questions'),
          ),
        ),
      ],
    );
  }

  Widget _exampleCard(SqlExample example, int index) {
    final table = index < _examples.length ? _examples[index] : null;
    final error = index < _exampleErrors.length ? _exampleErrors[index] : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
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
                ),
              ),
              const SizedBox(height: 6),
              Text(
                example.note,
                style: const TextStyle(color: _muted, height: 1.4),
              ),
              const SizedBox(height: 12),
              _code(example.statement.trim()),
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
                const Text(
                  'Running the example.',
                  style: TextStyle(color: _note),
                )
              else
                _ResultTable(table),
            ],
          ),
        ),
      ),
    );
  }

  Widget _questionsView() {
    final level = sqlCourse[_level];
    final question = level.questions[_question];
    final correct = _checked && _choice == question.answer;
    final last = _question == level.questions.length - 1;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Text(
                'Question ${_question + 1} of ${level.questions.length}',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w700,
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
              const SizedBox(height: 16),
              for (var i = 0; i < question.choices.length; i++)
                _choiceTile(question, i),
            ],
          ),
        ),
        _bar(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_checked && !correct) ...[
                Text(
                  question.why,
                  style: const TextStyle(color: _error, height: 1.35),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('course-retry'),
                  onPressed: () {
                    setState(() {
                      _choice = null;
                      _checked = false;
                    });
                  },
                  child: const Text('Retry'),
                ),
              ] else if (_checked && correct && last)
                FilledButton(
                  key: const Key('course-to-sql'),
                  onPressed: _startPractice,
                  child: const Text('Write SQL'),
                )
              else
                FilledButton(
                  key: const Key('mcq-next'),
                  onPressed: _choice == null
                      ? null
                      : () {
                          if (!_checked) {
                            setState(() => _checked = true);
                            return;
                          }
                          setState(() {
                            _question += 1;
                            _choice = null;
                            _checked = false;
                          });
                        },
                  child: Text(_checked ? 'Next' : 'Check'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _choiceTile(SqlQuestion question, int index) {
    final selected = _choice == index;
    final show = _checked && selected;
    final correct = index == question.answer;
    final color = !show
        ? (selected ? const Color(0xFFD6EBE4) : Colors.white)
        : (correct ? const Color(0xFFD6EBE4) : const Color(0xFFF8E4E1));
    final side = !show ? (selected ? _ok : _line) : (correct ? _ok : _error);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: side),
        ),
        child: InkWell(
          key: Key('mcq-choice-$index'),
          onTap: _checked ? null : () => setState(() => _choice = index),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text(
              question.choices[index],
              style: const TextStyle(color: _ink, height: 1.3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _practiceView() {
    final level = sqlCourse[_level];
    final task = level.tasks[_task];
    final grade = _grade;
    final passed = grade != null && grade.passed;
    final last = _task == level.tasks.length - 1;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Text(
                'Statement ${_task + 1} of ${level.tasks.length}',
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                task.prompt,
                style: const TextStyle(color: _ink, height: 1.4),
              ),
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
              TextField(
                key: const Key('task-sql'),
                controller: _sql,
                minLines: 3,
                maxLines: 6,
                style: sqlCodeFont.copyWith(color: _ink),
                decoration: const InputDecoration(
                  hintText: 'Write one SQL statement',
                ),
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
              if (passed && last)
                FilledButton(
                  key: const Key('task-finish'),
                  onPressed: _finishLevel,
                  child: const Text('Finish level'),
                )
              else if (passed)
                FilledButton(
                  key: const Key('task-next'),
                  onPressed: _nextTask,
                  child: const Text('Next statement'),
                )
              else
                FilledButton(
                  key: const Key('task-check'),
                  onPressed: _grading ? null : _check,
                  child: Text(_grading ? 'Checking' : 'Check'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _waiting(QueryTable? table) {
    if (!_tablesReady || table == null) {
      return const Text(
        'Running the example.',
        style: TextStyle(color: _note),
      );
    }
    return _ResultTable(table);
  }

  Widget _doneView() {
    final last = _level == sqlCourse.length - 1;
    final title =
        last ? 'You finished the course.' : 'You finished this level.';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                last
                    ? 'You can open any level again from the list.'
                    : 'The next level is open.',
                style: const TextStyle(color: _muted, height: 1.4),
              ),
            ],
          ),
        ),
        _bar(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!last)
                FilledButton(
                  key: const Key('course-next'),
                  onPressed: () => _openLevel(_level + 1),
                  child: const Text('Next level'),
                ),
              if (!last) const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('course-home'),
                onPressed: () => setState(() => _stage = _Stage.list),
                child: const Text('All levels'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _code(String statement) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _ink,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SelectableText(statement, style: sqlCodeFont),
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
        color: _ink,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
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
