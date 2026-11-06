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

/// The mark drawn beside a chapter.
enum CourseMark { reading, writing, tables, summaries, combining, naming }

/// One explanation, its example, and the question that checks that part.
class SqlPart {
  const SqlPart({
    required this.title,
    required this.teach,
    required this.example,
    required this.question,
  });

  final String title;
  final String teach;
  final SqlExample example;
  final SqlQuestion question;
}

/// One lesson. [parts] are taught in order. [review] covers the whole lesson.
class SqlLesson {
  const SqlLesson({
    required this.title,
    required this.summary,
    required this.parts,
    required this.review,
    required this.tasks,
  });

  final String title;
  final String summary;
  final List<SqlPart> parts;
  final List<SqlQuestion> review;
  final List<SqlTask> tasks;

  List<SqlExample> get examples => [for (final part in parts) part.example];
}

/// One chapter. [review] opens after every lesson in the chapter is passed.
class SqlChapter {
  const SqlChapter({
    required this.title,
    required this.summary,
    required this.mark,
    required this.lessons,
    required this.review,
  });

  final String title;
  final String summary;
  final CourseMark mark;
  final List<SqlLesson> lessons;
  final List<SqlQuestion> review;
}
