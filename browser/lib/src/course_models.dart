/// One formatted example. The result is produced by running [statement].
class SqlExample {
  const SqlExample({
    required this.title,
    required this.setup,
    required this.statement,
    required this.note,
    this.probe,
  });

  final String title;

  /// Statements that build the tables this example reads.
  final String setup;

  /// The statement the lesson shows.
  final String statement;

  final String note;

  /// When set, [statement] changes the database and the last statement of
  /// [probe] is the result the lesson shows.
  final String? probe;
}

/// One multiple-choice question. [answer] is the correct choice index.
class SqlQuestion {
  const SqlQuestion({
    required this.prompt,
    required this.choices,
    required this.answer,
    required this.why,
  });

  final String prompt;
  final List<String> choices;
  final int answer;
  final String why;
}

/// One statement the learner writes. The program runs it and compares.
class SqlTask {
  const SqlTask({
    required this.prompt,
    required this.setup,
    required this.statement,
    this.preview,
    this.probe,
    this.orderMatters = false,
  });

  final String prompt;

  /// Statements that prepare a fresh database before the learner's statement.
  final String setup;

  /// A statement that produces the accepted result.
  final String statement;

  /// A query that shows the rows before the learner changes them.
  final String? preview;

  /// When set, the learner's statement changes the database. The last
  /// statement of [probe] is the query both results are compared with.
  final String? probe;

  /// Row order is part of the result.
  final bool orderMatters;
}

/// One course level. Questions come before the statements.
class SqlLevel {
  const SqlLevel({
    required this.title,
    required this.summary,
    required this.teach,
    required this.examples,
    required this.questions,
    required this.tasks,
  });

  final String title;
  final String summary;
  final String teach;
  final List<SqlExample> examples;
  final List<SqlQuestion> questions;
  final List<SqlTask> tasks;
}
