import 'course_models.dart';

const _shelf = '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
INSERT INTO books (title, pages) VALUES ('River Index', 180);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
''';

const _shelfUnsorted = '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('River Index', 180);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
''';

const _twoBooks = '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
''';

const _cities = '''
CREATE TABLE authors (name TEXT, city TEXT);
INSERT INTO authors (name, city) VALUES ('Ada', 'Amman');
INSERT INTO authors (name, city) VALUES ('Grace', 'Amman');
INSERT INTO authors (name, city) VALUES ('Lin', 'Irbid');
''';

const _library = '''
CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT, city TEXT);
CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, pages INTEGER, author_id INTEGER);
INSERT INTO authors (id, name, city) VALUES (1, 'Lin', 'Amman');
INSERT INTO authors (id, name, city) VALUES (2, 'Ada', 'Amman');
INSERT INTO authors (id, name, city) VALUES (3, 'Grace', 'Irbid');
INSERT INTO books (id, title, pages, author_id) VALUES (1, 'Kept Garden', 320, 2);
INSERT INTO books (id, title, pages, author_id) VALUES (2, 'Other Atlas', 40, 2);
INSERT INTO books (id, title, pages, author_id) VALUES (3, 'River Index', 180, 3);
''';

SqlQuestion _ask(
  String prompt,
  List<String> choices,
  int answer,
  String why,
) {
  return SqlQuestion(
    prompt: prompt,
    choices: choices,
    answer: answer,
    why: why,
  );
}

SqlPart _part(
  String title,
  String teach,
  String exampleTitle,
  String setup,
  String statement,
  String note,
  SqlQuestion question, {
  String? probe,
}) {
  return SqlPart(
    title: title,
    teach: teach,
    example: SqlExample(
      title: exampleTitle,
      setup: setup,
      statement: statement,
      note: note,
      probe: probe,
    ),
    question: question,
  );
}

/// Chapters, then the lessons inside each chapter.
final List<SqlChapter> sqlChapters = [
  SqlChapter(
    title: 'Reading rows',
    summary: 'Choose columns, keep a condition, and put the rows in order.',
    mark: CourseMark.reading,
    lessons: [_reading, _filtering, _sorting, _names],
    review: [
      SqlQuestion(
        prompt: 'Which clause names the table a query reads?',
        choices: ['SELECT', 'FROM', 'SET', 'VALUES'],
        answer: 1,
        why: 'FROM names the table. SELECT names the columns that come back.',
      ),
      SqlQuestion(
        prompt: 'A statement has WHERE and ORDER BY. What does WHERE decide?',
        choices: [
          'Which rows are kept.',
          'The order of every stored row.',
          'The name of a new column.',
          'Whether the table is created.',
        ],
        answer: 0,
        why: 'WHERE filters. ORDER BY sorts the rows that remain.',
      ),
      SqlQuestion(
        prompt: 'SELECT title AS name FROM books. What happens to the table?',
        choices: [
          'The column title is renamed in the stored table.',
          'The result column is labeled name. The table is unchanged.',
          'Every title is deleted.',
          'A second table named name is created.',
        ],
        answer: 1,
        why: 'AS names a result column. It does not change the stored table.',
      ),
      SqlQuestion(
        prompt:
            'SELECT * FROM books on this shelf. How many columns come back?',
        choices: ['One.', 'Two.', 'Three.', 'Every table in the database.'],
        answer: 1,
        why: 'books has title and pages, so the star expands to those two.',
      ),
    ],
  ),
  SqlChapter(
    title: 'Changing rows',
    summary: 'Add a row, change one, and remove the rows you name.',
    mark: CourseMark.writing,
    lessons: [_insert, _update, _delete],
    review: [
      SqlQuestion(
        prompt: 'Which statement writes a new row into a table that exists?',
        choices: ['SELECT', 'INSERT', 'FROM', 'ORDER BY'],
        answer: 1,
        why: 'INSERT adds a row. SELECT only reads.',
      ),
      SqlQuestion(
        prompt: 'An UPDATE has no WHERE. Which rows change?',
        choices: [
          'None.',
          'Only the first row.',
          'Every row in the table.',
          'Only the rows that are NULL.',
        ],
        answer: 2,
        why: 'WHERE is the guard. Without it, the assignment covers every row.',
      ),
      SqlQuestion(
        prompt:
            'You want to remove the short books and leave the rest. What do you write?',
        choices: [
          'DELETE FROM books;',
          'DELETE FROM books WHERE pages < 50;',
          'SELECT * FROM books WHERE pages < 50;',
          'DROP TABLE books;',
        ],
        answer: 1,
        why:
            'DELETE removes rows. WHERE keeps the statement on the short books.',
      ),
      SqlQuestion(
        prompt: 'After a successful INSERT, what does a following SELECT see?',
        choices: [
          'The table as it was before the INSERT.',
          'The new row, together with the rows that were already there.',
          'Only the column names.',
          'An empty table.',
        ],
        answer: 1,
        why: 'INSERT stores the row. A later query reads the stored table.',
      ),
    ],
  ),
  SqlChapter(
    title: 'Shaping tables',
    summary:
        'Define a table, then match a list, a pattern, or a missing value.',
    mark: CourseMark.tables,
    lessons: [_creating, _matching],
    review: [
      SqlQuestion(
        prompt: 'An INSERT omits an INTEGER PRIMARY KEY. What is stored there?',
        choices: [
          'NULL.',
          'A number the database assigns.',
          'The text of the next column.',
          'The table name.',
        ],
        answer: 1,
        why:
            'An integer primary key can be filled in when the INSERT leaves it out.',
      ),
      SqlQuestion(
        prompt: 'A column is TEXT NOT NULL. Which INSERT fails?',
        choices: [
          'The INSERT names that column and gives a text value.',
          'The INSERT omits that column.',
          'The INSERT names a different table.',
          'The INSERT is a SELECT.',
        ],
        answer: 1,
        why:
            'NOT NULL rejects a missing value. DEFAULT is what would fill an omitted column.',
      ),
      SqlQuestion(
        prompt: 'author = NULL does not find a missing author. What does?',
        choices: [
          'author == NULL',
          'author IS NULL',
          'author LIKE NULL',
          'author IN NULL'
        ],
        answer: 1,
        why: 'NULL is missing. IS NULL is the test for that.',
      ),
      SqlQuestion(
        prompt: 'LIKE with the pattern %Atlas keeps which titles?',
        choices: [
          'Titles that are exactly one letter.',
          'Titles that end with Atlas.',
          'Titles that start with a digit.',
          'Every title, including NULL.',
        ],
        answer: 1,
        why:
            '% matches any text before Atlas, so the title ends with that word.',
      ),
    ],
  ),
  SqlChapter(
    title: 'Summaries',
    summary: 'Count rows, group them, and keep the groups you want.',
    mark: CourseMark.summaries,
    lessons: [_summaries, _having],
    review: [
      SqlQuestion(
        prompt: 'Which function adds the values in a column?',
        choices: ['COUNT', 'SUM', 'LIKE', 'FROM'],
        answer: 1,
        why: 'SUM adds numbers. COUNT counts rows.',
      ),
      SqlQuestion(
        prompt: 'GROUP BY city on the authors table produces what?',
        choices: [
          'One row per author.',
          'One row per different city.',
          'One row for the whole database.',
          'No rows.',
        ],
        answer: 1,
        why: 'Each different city is one group.',
      ),
      SqlQuestion(
        prompt: 'WHERE and HAVING are both filters. Which one runs first?',
        choices: [
          'HAVING, then WHERE.',
          'WHERE filters rows, then the groups are built, then HAVING filters groups.',
          'They run at the same time on the stored file.',
          'Neither runs if SELECT has AS.',
        ],
        answer: 1,
        why:
            'WHERE chooses the rows that enter the summary. HAVING chooses groups after it.',
      ),
      SqlQuestion(
        prompt: 'Three books have 40, 180, and 320 pages. What is SUM(pages)?',
        choices: ['3', '180', '540', '320'],
        answer: 2,
        why: '40 + 180 + 320 is 540. COUNT(*) would be 3.',
      ),
    ],
  ),
  SqlChapter(
    title: 'Combining tables',
    summary: 'Match a book to an author, keep a missing side, or nest a query.',
    mark: CourseMark.combining,
    lessons: [_joining, _missing, _nested],
    review: [
      SqlQuestion(
        prompt: 'An INNER JOIN drops which rows?',
        choices: [
          'Rows that match ON.',
          'A row on either side that has no partner.',
          'The first row of each table.',
          'Every primary key.',
        ],
        answer: 1,
        why: 'An inner join keeps matches only.',
      ),
      SqlQuestion(
        prompt:
            'You still want an author who wrote nothing. Where does authors go?',
        choices: [
          'On the right of a LEFT JOIN.',
          'On the left of a LEFT JOIN.',
          'Only inside WHERE.',
          'It cannot appear.',
        ],
        answer: 1,
        why: 'LEFT JOIN keeps every row of the left table.',
      ),
      SqlQuestion(
        prompt:
            'IN (SELECT id FROM authors WHERE city = \'Irbid\') compares the outer value with what?',
        choices: [
          'The text of the SELECT keyword.',
          'The ids the inner query returns.',
          'The number of tables.',
          'NULL only.',
        ],
        answer: 1,
        why:
            'The inner query produces a list of values. IN matches any of them.',
      ),
      SqlQuestion(
        prompt:
            'EXISTS (SELECT 1 FROM books WHERE books.author_id = authors.id) is true when?',
        choices: [
          'The inner query returns at least one row for that author.',
          'The inner query is empty.',
          'The author name is NULL.',
          'The outer query has no FROM.',
        ],
        answer: 0,
        why:
            'EXISTS cares that a row came back, not which columns were selected.',
      ),
    ],
  ),
  SqlChapter(
    title: 'Names for queries',
    summary: 'Save a lookup, name a query, and label a full report.',
    mark: CourseMark.naming,
    lessons: [_indexes, _report],
    review: [
      SqlQuestion(
        prompt: 'What does creating an index change in a SELECT result?',
        choices: [
          'Nothing about which rows come back.',
          'The row order is reversed.',
          'Duplicate titles are deleted.',
          'The table is dropped.',
        ],
        answer: 0,
        why: 'An index is a lookup structure. The query result stays the same.',
      ),
      SqlQuestion(
        prompt: 'Selecting from a view runs what?',
        choices: [
          'A stored copy of the old rows.',
          'The query that was saved under that name, against the current rows.',
          'Only sqlite_schema.',
          'An INSERT.',
        ],
        answer: 1,
        why: 'A view stores a query. Reading it runs that query now.',
      ),
      SqlQuestion(
        prompt:
            'An author with no book still emits one left-join row. COUNT(*) on that row returns?',
        choices: ['0', '1', 'NULL', 'The number of authors'],
        answer: 1,
        why:
            'The join emitted one row. COUNT(*) counts it, even though the book columns are NULL.',
      ),
      SqlQuestion(
        prompt: 'COUNT(books.id) for that same unmatched author returns?',
        choices: ['0', '1', 'NULL', '2'],
        answer: 0,
        why:
            'COUNT of a column skips NULL. The missing book id is NULL, so the count is zero.',
      ),
    ],
  ),
];

/// Every lesson, in course order.
final List<SqlLesson> sqlCourse = [
  for (final chapter in sqlChapters) ...chapter.lessons,
];

int chapterOfLesson(int lesson) {
  var start = 0;
  for (var index = 0; index < sqlChapters.length; index++) {
    start += sqlChapters[index].lessons.length;
    if (lesson < start) return index;
  }
  return sqlChapters.length - 1;
}

int firstLessonOf(int chapter) {
  var start = 0;
  for (var index = 0; index < chapter; index++) {
    start += sqlChapters[index].lessons.length;
  }
  return start;
}

const _reading = SqlLesson(
  title: 'Reading rows',
  summary: 'Read columns from a table.',
  parts: [
    SqlPart(
      title: 'Choose the columns',
      teach:
          'A query starts with SELECT. Name the columns you want, then name the table after FROM. The names after SELECT become the result columns, in that order. A query returns rows and does not change the stored table.',
      example: SqlExample(
        title: 'Title and pages',
        setup: _shelf,
        statement: 'SELECT title, pages FROM books;',
        note: 'The result has two columns, title first and pages second.',
      ),
      question: SqlQuestion(
        prompt: 'What does a SELECT statement do?',
        choices: [
          'It stores a new row.',
          'It reads rows from a table.',
          'It removes a table.',
          'It changes a column name.',
        ],
        answer: 1,
        why:
            'SELECT is a query. It returns rows and leaves the stored table as it is.',
      ),
    ),
    SqlPart(
      title: 'Every column',
      teach:
          'The star means every column of the table, in table order. books has title and pages, so SELECT * matches the column list. Naming the columns is clearer when you want a different order.',
      example: SqlExample(
        title: 'The star',
        setup: _shelf,
        statement: 'SELECT * FROM books;',
        note: 'Two columns come back, the same two the table stores.',
      ),
      question: SqlQuestion(
        prompt: 'In SELECT * FROM books, what does the star mean?',
        choices: [
          'The first column.',
          'Every column of books.',
          'Only the numeric columns.',
          'The longest title.',
        ],
        answer: 1,
        why: 'The star expands to every column, in the table order.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'Which statement returns only the titles?',
      choices: [
        'SELECT * FROM books;',
        'SELECT pages FROM books;',
        'SELECT title FROM books;',
        'SELECT books FROM title;',
      ],
      answer: 2,
      why: 'The column list is title, and FROM names the table.',
    ),
    SqlQuestion(
      prompt: 'Which piece of SELECT title, pages FROM books names the table?',
      choices: ['SELECT', 'title', 'pages', 'FROM books'],
      answer: 3,
      why:
          'FROM books is the table. The words before FROM are the result columns.',
    ),
    SqlQuestion(
      prompt: 'After SELECT title FROM books, what is stored in books?',
      choices: [
        'Only the titles.',
        'The same rows as before the query.',
        'No rows.',
        'A new pages column.',
      ],
      answer: 1,
      why:
          'A query reads. It does not remove the columns it left out of the result.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return the title and the pages of every book.',
      setup: _shelf,
      statement: 'SELECT title, pages FROM books;',
      preview: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt: 'Return only the title of every book.',
      setup: _shelf,
      statement: 'SELECT title FROM books;',
      preview: 'SELECT title, pages FROM books;',
    ),
  ],
);

final _filtering = SqlLesson(
  title: 'Filtering rows',
  summary: 'Keep the rows that match a condition.',
  parts: [
    _part(
      'A comparison',
      'WHERE keeps a row when its condition is true. Compare with =, <, >, <=, and >=. Rows that fail the comparison are left out of the result.',
      'Longer books',
      _shelf,
      'SELECT title FROM books WHERE pages > 100;',
      '180 and 320 are greater than 100. The book with 40 pages is left out.',
      _ask(
        'Which keyword keeps the matching rows?',
        ['ORDER BY', 'WHERE', 'INSERT', 'LIMIT'],
        1,
        'WHERE is the filter. Rows that fail it are not returned.',
      ),
    ),
    _part(
      'Both conditions',
      'AND keeps a row only when both comparisons are true. A row that passes one side and fails the other is left out.',
      'A narrow range',
      _shelf,
      'SELECT title, pages FROM books WHERE pages >= 40 AND pages < 180;',
      'AND requires both comparisons. Only the book with 40 pages matches.',
      _ask(
        'When does AND keep a row?',
        [
          'When either comparison is true.',
          'When the first comparison is true.',
          'When both comparisons are true.',
          'When neither comparison is true.',
        ],
        2,
        'AND is stricter than OR. Both sides have to succeed.',
      ),
    ),
    _part(
      'Either condition',
      'OR keeps a row when at least one side is true. Use it when two different kinds of row both belong in the result.',
      'Short or very long',
      _shelf,
      'SELECT title FROM books WHERE pages < 50 OR pages > 300;',
      '40 passes the first comparison. 320 passes the second. 180 passes neither.',
      _ask(
        'A book has 180 pages. Which condition keeps it?',
        ['pages > 180', 'pages >= 180', 'pages < 180', 'pages = 40'],
        1,
        '>= keeps a value that is equal, as well as a value that is larger.',
      ),
    ),
  ],
  review: [
    _ask(
      'Which comparison keeps a book of exactly 100 pages?',
      ['pages > 100', 'pages >= 100', 'pages < 100', 'pages <> 100'],
      1,
      '>= includes the equal value. > does not.',
    ),
    _ask(
      'pages < 50 OR pages > 300. Which book of 320 pages does this keep?',
      [
        'It fails both sides, so it is left out.',
        'It passes pages > 300, so it is kept.',
        'OR ignores the second comparison.',
        'It deletes the row.',
      ],
      1,
      'OR keeps the row when either side is true. 320 is greater than 300.',
    ),
    _ask(
      'A filter and a column list are different. Which statement filters?',
      [
        'SELECT title, pages FROM books;',
        'SELECT title FROM books WHERE pages < 50;',
        'SELECT * FROM books;',
        'SELECT pages FROM books;',
      ],
      1,
      'WHERE is what removes rows. The other three return every row.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return the title of each book with more than 100 pages.',
      setup: _shelf,
      statement: 'SELECT title FROM books WHERE pages > 100;',
      preview: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt:
          'Return the title and the pages of each book with fewer than 50 pages.',
      setup: _shelf,
      statement: 'SELECT title, pages FROM books WHERE pages < 50;',
      preview: 'SELECT title, pages FROM books;',
    ),
  ],
);

const _sorting = SqlLesson(
  title: 'Sorting and limiting',
  summary: 'Put rows in order and keep a prefix.',
  parts: [
    SqlPart(
      title: 'Largest first',
      teach:
          'ORDER BY sorts the result. ASC is the default and goes from small to large. DESC goes from large to small. In this lesson the order is part of the answer.',
      example: SqlExample(
        title: 'Longest first',
        setup: _shelfUnsorted,
        statement: 'SELECT title, pages FROM books ORDER BY pages DESC;',
        note: 'DESC puts the largest page count first.',
      ),
      question: SqlQuestion(
        prompt: 'Which clause sorts the result?',
        choices: ['WHERE', 'ORDER BY', 'FROM', 'VALUES'],
        answer: 1,
        why: 'ORDER BY sets the order of the rows that are returned.',
      ),
    ),
    SqlPart(
      title: 'One row',
      teach:
          'LIMIT keeps the first rows of the sorted result. The sort runs before LIMIT, so ORDER BY pages ASC LIMIT 1 is the shortest book, not the first row that was inserted.',
      example: SqlExample(
        title: 'The shortest book',
        setup: _shelfUnsorted,
        statement: 'SELECT title FROM books ORDER BY pages ASC LIMIT 1;',
        note: 'Other Atlas has 40 pages, so it is the one row LIMIT keeps.',
      ),
      question: SqlQuestion(
        prompt: 'What does DESC mean?',
        choices: [
          'From small to large.',
          'From large to small.',
          'Leave the insert order.',
          'Keep one row.',
        ],
        answer: 1,
        why:
            'DESC reverses the sort. ASC, the default, goes from small to large.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'ORDER BY pages ASC LIMIT 1 returns which book?',
      choices: [
        'The first inserted row.',
        'The shortest book.',
        'The longest book.',
        'Every book.',
      ],
      answer: 1,
      why: 'The sort finishes before LIMIT keeps the first row of that order.',
    ),
    SqlQuestion(
      prompt: 'Which statement lists the longest book first?',
      choices: [
        'SELECT title, pages FROM books ORDER BY pages ASC;',
        'SELECT title, pages FROM books ORDER BY pages DESC;',
        'SELECT title FROM books LIMIT 1;',
        'SELECT * FROM books WHERE pages > 0;',
      ],
      answer: 1,
      why: 'DESC on pages puts 320 ahead of 180 and 40.',
    ),
    SqlQuestion(
      prompt: 'LIMIT without ORDER BY keeps which rows?',
      choices: [
        'A defined sort you chose.',
        'A prefix of whatever order the query already has.',
        'Only the primary key.',
        'The rows WHERE rejected.',
      ],
      answer: 1,
      why:
          'LIMIT counts rows in the result order. ORDER BY is what makes that order explicit.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return title and pages, longest book first.',
      setup: _shelfUnsorted,
      statement: 'SELECT title, pages FROM books ORDER BY pages DESC;',
      preview: 'SELECT title, pages FROM books;',
      orderMatters: true,
    ),
    SqlTask(
      prompt: 'Return the title of the shortest book.',
      setup: _shelfUnsorted,
      statement: 'SELECT title FROM books ORDER BY pages ASC LIMIT 1;',
      preview: 'SELECT title, pages FROM books;',
      orderMatters: true,
    ),
  ],
);

const _names = SqlLesson(
  title: 'Names and calculations',
  summary: 'Label a result column and compute a value.',
  parts: [
    SqlPart(
      title: 'Another label',
      teach:
          'AS gives a result column a name. SELECT title AS name labels that result column name. The stored column is still title. A later query that wants the stored name still writes title.',
      example: SqlExample(
        title: 'Call it name',
        setup: _shelf,
        statement: 'SELECT title AS name FROM books;',
        note:
            'The result header is name. The table still has a column named title.',
      ),
      question: SqlQuestion(
        prompt: 'What does AS change?',
        choices: [
          'The stored column name.',
          'The label of the result column.',
          'The number of rows.',
          'The page count.',
        ],
        answer: 1,
        why:
            'AS is a name for the result. The table definition stays as it was.',
      ),
    ),
    SqlPart(
      title: 'A calculated column',
      teach:
          'An expression can be a result column. pages * 2 doubles the page count in the result and leaves the stored pages alone. Name the expression with AS so the column has a stable header.',
      example: SqlExample(
        title: 'Twice the pages',
        setup: _shelf,
        statement: 'SELECT title, pages * 2 AS doubled FROM books;',
        note: '40, 180, and 320 become 80, 360, and 640 in the result.',
      ),
      question: SqlQuestion(
        prompt:
            'SELECT pages * 2 AS doubled. What is stored in pages afterward?',
        choices: [
          'The doubled number.',
          'The original page count.',
          'NULL.',
          'The text doubled.',
        ],
        answer: 1,
        why:
            'The expression is computed for the result. UPDATE is what would store a new number.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'Which result header does SELECT title AS name produce?',
      choices: ['title', 'name', 'books', 'AS'],
      answer: 1,
      why: 'The word after AS is the result column name.',
    ),
    SqlQuestion(
      prompt: 'Which statement doubles pages in the result only?',
      choices: [
        'UPDATE books SET pages = pages * 2;',
        'SELECT title, pages * 2 AS doubled FROM books;',
        'INSERT INTO books (pages) VALUES (2);',
        'SELECT * FROM books;',
      ],
      answer: 1,
      why:
          'SELECT computes a result column. UPDATE would write the new number back.',
    ),
    SqlQuestion(
      prompt:
          'A calculated column without AS still returns a value. What is the weak part?',
      choices: [
        'The value is wrong.',
        'The result column has no name you chose.',
        'The table is deleted.',
        'WHERE stops working.',
      ],
      answer: 1,
      why: 'AS is how you choose the header. The expression itself still runs.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return every title in a result column named name.',
      setup: _shelf,
      statement: 'SELECT title AS name FROM books;',
      preview: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt: 'Return title and doubled, where doubled is pages times 2.',
      setup: _shelf,
      statement: 'SELECT title, pages * 2 AS doubled FROM books;',
      preview: 'SELECT title, pages FROM books;',
    ),
  ],
);

final _insert = SqlLesson(
  title: 'Inserting rows',
  summary: 'Add one row, columns and values in the same order.',
  parts: [
    _part(
      'One new row',
      'INSERT adds a row to a table that already exists. Name the columns, then give the values in that same order. The check reads the table after the statement.',
      'Add Kept Garden',
      'CREATE TABLE books (title TEXT, pages INTEGER);',
      "INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);",
      'One INSERT writes one row. The table below is the stored result.',
      _ask(
        'Which statement adds a row?',
        ['SELECT', 'INSERT', 'DROP', 'ORDER BY'],
        1,
        'INSERT writes a new row into a table that already exists.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
    _part(
      'The order you name',
      'The values follow the column list, not the order of the columns in the table. Naming pages before title means the first value is the page count.',
      'Pages, then title',
      'CREATE TABLE books (title TEXT, pages INTEGER);',
      "INSERT INTO books (pages, title) VALUES (40, 'Other Atlas');",
      'The stored title is Other Atlas and the stored pages are 40.',
      _ask(
        'INSERT INTO books (pages, title) VALUES (40, \'Other Atlas\'). What is stored in title?',
        ['40', 'Other Atlas', 'pages', 'NULL'],
        1,
        'The second name in the column list receives the second value.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
  review: [
    _ask(
      'INSERT needs a table that already exists. Which statement creates that table?',
      ['INSERT', 'SELECT', 'CREATE TABLE', 'WHERE'],
      2,
      'CREATE TABLE defines the table. INSERT then writes rows into it.',
    ),
    _ask(
      'The column list is (title, pages). Which value order matches it?',
      [
        "VALUES (320, 'Kept Garden')",
        "VALUES ('Kept Garden', 320)",
        "VALUES ('Kept Garden')",
        "VALUES (pages, title)",
      ],
      1,
      'The first value goes to title and the second goes to pages.',
    ),
    _ask(
      'A SELECT after a successful INSERT shows what?',
      [
        'The table before the insert.',
        'The inserted row along with the rows already stored.',
        'Only the column list.',
        'An error, because SELECT cannot follow INSERT.',
      ],
      1,
      'The row is stored. The next query reads it.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Insert a book titled River Index with 180 pages. The check reads title and pages.',
      setup: '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
''',
      statement:
          "INSERT INTO books (title, pages) VALUES ('River Index', 180);",
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt:
          'Insert a book titled Night Market with 90 pages. The check reads title and pages.',
      setup: '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
''',
      statement:
          "INSERT INTO books (title, pages) VALUES ('Night Market', 90);",
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
);

final _update = SqlLesson(
  title: 'Updating rows',
  summary: 'Assign a new value to the rows you name.',
  parts: [
    _part(
      'One row',
      'UPDATE assigns new values. WHERE chooses the rows. Without a matching WHERE, the other rows stay as they are.',
      'Change Other Atlas',
      _twoBooks,
      "UPDATE books SET pages = 48 WHERE title = 'Other Atlas';",
      'WHERE limits the assignment. Kept Garden stays at 320 pages.',
      _ask(
        'What does WHERE do on an UPDATE?',
        [
          'It chooses the rows that receive the new value.',
          'It sorts the table.',
          'It adds a column.',
          'It is required to be omitted.',
        ],
        0,
        'SET is the new value. WHERE decides which rows get it.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
    _part(
      'Every row',
      'If UPDATE has no WHERE, every row in the table changes. Write WHERE unless that is what you mean.',
      'No guard',
      _twoBooks,
      'UPDATE books SET pages = 10;',
      'Both books become 10 pages, because nothing limited the assignment.',
      _ask(
        'What happens if UPDATE has no WHERE?',
        [
          'No row changes.',
          'Only the first row changes.',
          'Every row in the table changes.',
          'The table is deleted.',
        ],
        2,
        'WHERE is the guard. Without it, the assignment runs for every row.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
  review: [
    _ask(
      'Which clause carries the new value?',
      ['WHERE', 'SET', 'FROM', 'ORDER BY'],
      1,
      'SET names the column and the value. WHERE chooses the rows.',
    ),
    _ask(
      "UPDATE books SET pages = 48 WHERE title = 'Other Atlas'. Which row stays at 320?",
      ['Other Atlas', 'Kept Garden', 'Both rows', 'Neither row'],
      1,
      'The WHERE title does not match Kept Garden, so that row is not assigned.',
    ),
    _ask(
      'You want to change one title and leave the page counts. Which shape is that?',
      [
        'UPDATE books SET pages = 0;',
        "UPDATE books SET title = 'Garden Notes' WHERE pages = 320;",
        'DELETE FROM books WHERE pages = 320;',
        'SELECT title FROM books;',
      ],
      1,
      'SET names title, and WHERE limits the write to the 320-page book.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Set the pages of Other Atlas to 48. Leave every other row as it is.',
      setup: _twoBooks,
      statement: "UPDATE books SET pages = 48 WHERE title = 'Other Atlas';",
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt:
          "Rename the 320-page book to Garden Notes. Leave Other Atlas as it is.",
      setup: _twoBooks,
      statement: "UPDATE books SET title = 'Garden Notes' WHERE pages = 320;",
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
);

final _delete = SqlLesson(
  title: 'Deleting rows',
  summary: 'Remove the rows that match.',
  parts: [
    _part(
      'Remove the short books',
      'DELETE removes rows. WHERE chooses which ones. A row that fails the condition stays stored.',
      'Pages under 50',
      _twoBooks,
      'DELETE FROM books WHERE pages < 50;',
      'Other Atlas has 40 pages, so it is removed. Kept Garden stays.',
      _ask(
        'Which statement removes the short books?',
        [
          'DELETE FROM books WHERE pages < 50;',
          'SELECT pages FROM books;',
          'UPDATE books SET pages = 0;',
          "INSERT INTO books (pages) VALUES (50);",
        ],
        0,
        'DELETE removes rows. WHERE still decides which rows.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
    _part(
      'Remove one title',
      'The condition can be the title. DELETE without WHERE removes every row and leaves the empty table. This lesson always names the rows.',
      'One title',
      _twoBooks,
      "DELETE FROM books WHERE title = 'Kept Garden';",
      'Kept Garden is gone. Other Atlas remains.',
      _ask(
        'DELETE FROM books; with no WHERE removes what?',
        [
          'Nothing.',
          'Every row, leaving the table itself.',
          'The table definition.',
          'Only the first row.',
        ],
        1,
        'Without WHERE, DELETE applies to every row. DROP TABLE is what removes the table.',
      ),
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
  review: [
    _ask(
      'DELETE and DROP are different. What does DELETE remove?',
      [
        'Rows.',
        'The table definition.',
        'An index name only.',
        'The database file.'
      ],
      0,
      'DELETE removes rows. The table remains and can receive new rows.',
    ),
    _ask(
      'Which statement leaves Other Atlas and removes Kept Garden?',
      [
        'DELETE FROM books;',
        "DELETE FROM books WHERE title = 'Kept Garden';",
        "UPDATE books SET title = 'Kept Garden';",
        'SELECT * FROM books;',
      ],
      1,
      'WHERE title = \'Kept Garden\' names the row to remove.',
    ),
    _ask(
      'After DELETE FROM books WHERE pages < 50, a later SELECT shows what?',
      [
        'The short books.',
        'The rows that did not match the condition.',
        'An error, because the table was dropped.',
        'The deleted rows, marked NULL.',
      ],
      1,
      'The matching rows are gone. The other stored rows remain.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Delete every book with fewer than 50 pages.',
      setup: _twoBooks,
      statement: 'DELETE FROM books WHERE pages < 50;',
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt: 'Delete the book titled Other Atlas and leave the other row.',
      setup: _twoBooks,
      statement: "DELETE FROM books WHERE title = 'Other Atlas';",
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM books;',
    ),
  ],
);

const _creating = SqlLesson(
  title: 'Creating a table',
  summary: 'Define columns, a key, and a default.',
  parts: [
    SqlPart(
      title: 'A key and a default',
      teach:
          'CREATE TABLE names the table and its columns. INTEGER PRIMARY KEY assigns a number when an INSERT leaves that column out. DEFAULT stores a value when an INSERT omits the column.',
      example: SqlExample(
        title: 'Key and default',
        setup: '',
        statement: '''
CREATE TABLE books (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  pages INTEGER NOT NULL DEFAULT 1
);''',
        note:
            'The INSERT names only the title. The key becomes 1, and pages uses the default.',
        probe: '''
INSERT INTO books (title) VALUES ('Kept Garden');
SELECT id, title, pages FROM books;''',
      ),
      question: SqlQuestion(
        prompt:
            'An INSERT omits an INTEGER PRIMARY KEY. What is stored in that column?',
        choices: [
          'NULL.',
          'A number assigned by the database.',
          'The title of the row.',
          'The table name.',
        ],
        answer: 1,
        why:
            'An integer primary key can be assigned when the INSERT leaves it out.',
      ),
    ),
    SqlPart(
      title: 'A required name',
      teach:
          'NOT NULL rejects a missing value. It is separate from the primary key. A required name has to be present in the INSERT.',
      example: SqlExample(
        title: 'Name is required',
        setup: '',
        statement: '''
CREATE TABLE authors (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);''',
        note: 'name has to be present. The integer primary key is assigned.',
        probe: '''
INSERT INTO authors (name) VALUES ('Ada');
SELECT id, name FROM authors;''',
      ),
      question: SqlQuestion(
        prompt: 'What does NOT NULL mean?',
        choices: [
          'The column may be stored as NULL.',
          'A missing value is rejected.',
          'The column is a key.',
          'The column has to be text.',
        ],
        answer: 1,
        why:
            'NOT NULL is a rule about missing values. It is separate from the primary key.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'When is DEFAULT used?',
      choices: [
        'When a SELECT omits the column.',
        'When an INSERT omits the column.',
        'When the table is dropped.',
        'When the value is zero.',
      ],
      answer: 1,
      why: 'DEFAULT fills a column that the INSERT did not set.',
    ),
    SqlQuestion(
      prompt: 'Which column list puts the key first and requires a title?',
      choices: [
        '(title TEXT, id)',
        '(id INTEGER PRIMARY KEY, title TEXT NOT NULL)',
        '(id DEFAULT 1)',
        '(SELECT id, title)',
      ],
      answer: 1,
      why:
          'INTEGER PRIMARY KEY is the key. TEXT NOT NULL makes title required.',
    ),
    SqlQuestion(
      prompt: 'The check inserts one row and reads it back. Why?',
      choices: [
        'CREATE TABLE itself returns the row.',
        'The new table is empty until an INSERT, so the read happens after that insert.',
        'SELECT cannot read a new table.',
        'DEFAULT runs only during SELECT.',
      ],
      answer: 1,
      why:
          'CREATE TABLE defines columns. The row appears when INSERT writes it.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Create authors with id INTEGER PRIMARY KEY and name TEXT NOT NULL, in that order. The check inserts the name Ada and reads id and name.',
      setup: '',
      statement:
          'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL);',
      probe: '''
INSERT INTO authors (name) VALUES ('Ada');
SELECT id, name FROM authors;''',
    ),
    SqlTask(
      prompt:
          'Create books with title TEXT NOT NULL and pages INTEGER NOT NULL DEFAULT 1, in that order. The check inserts the title Notes and reads title and pages.',
      setup: '',
      statement:
          'CREATE TABLE books (title TEXT NOT NULL, pages INTEGER NOT NULL DEFAULT 1);',
      probe: '''
INSERT INTO books (title) VALUES ('Notes');
SELECT title, pages FROM books;''',
    ),
  ],
);

final _matching = SqlLesson(
  title: 'Matching values',
  summary: 'Match a list, a pattern, a duplicate, or NULL.',
  parts: [
    _part(
      'A pattern',
      "LIKE matches a pattern. % is any text, and _ is one character. LIKE ignores ASCII letter case, so 'k%' matches Kept Garden.",
      'Titles that start with K',
      _shelf,
      "SELECT title FROM books WHERE title LIKE 'k%';",
      'k% matches a title that starts with K. Kept Garden matches.',
      _ask(
        'Which pattern matches a title that ends with Atlas?',
        ["LIKE 'Atlas%'", "LIKE '%Atlas'", "LIKE 'Atlas'", "LIKE '_'"],
        1,
        '%Atlas means any text, then the letters Atlas at the end.',
      ),
    ),
    _part(
      'A missing value',
      'NULL means missing. A comparison with = does not match NULL. IS NULL is the test that does.',
      'No author',
      '''
CREATE TABLE books (title TEXT, author TEXT);
INSERT INTO books (title, author) VALUES ('Kept Garden', 'Ada');
INSERT INTO books (title, author) VALUES ('Other Atlas', NULL);
''',
      'SELECT title FROM books WHERE author IS NULL;',
      'Other Atlas has no author. author = NULL would not return that row.',
      _ask(
        'Which condition matches a missing author?',
        ['author = NULL', 'author IS NULL', "author = ''", 'author LIKE NULL'],
        1,
        'IS NULL is the test for a missing value. Equality does not match NULL.',
      ),
    ),
    _part(
      'A list or a duplicate',
      'IN matches any value in a list. DISTINCT returns each different result row once, so two authors in Amman become one city.',
      'Two page counts',
      _shelf,
      'SELECT title FROM books WHERE pages IN (40, 320);',
      '40 and 320 are in the list. 180 is not.',
      _ask(
        'What does DISTINCT do?',
        [
          'It sorts descending.',
          'It returns each different result row once.',
          'It deletes duplicate stored rows.',
          'It matches NULL.',
        ],
        1,
        'DISTINCT changes the result, not the stored rows. Repeated values collapse to one.',
      ),
    ),
  ],
  review: [
    _ask(
      'Which list keeps page counts 40 and 320?',
      [
        'pages IN (40, 320)',
        'pages BETWEEN 100 AND 180',
        "title LIKE '%'",
        'pages IS NULL'
      ],
      0,
      'IN matches either listed value.',
    ),
    _ask(
      'SELECT DISTINCT city FROM authors. Two authors live in Amman. How many Amman rows come back?',
      ['Two.', 'One.', 'None.', 'One per book.'],
      1,
      'DISTINCT keeps one row for each different city.',
    ),
    _ask(
      'BETWEEN 40 AND 180 keeps which of 40, 180, and 320?',
      ['Only 180.', '40 and 180.', 'Only 320.', 'None of them.'],
      1,
      'BETWEEN includes both ends. 320 is past the upper end.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return each different city once. The column name is city.',
      setup: _cities,
      statement: 'SELECT DISTINCT city FROM authors;',
      preview: 'SELECT name, city FROM authors;',
    ),
    SqlTask(
      prompt: 'Return the title of each book whose page count is 40 or 320.',
      setup: _shelf,
      statement: 'SELECT title FROM books WHERE pages IN (40, 320);',
      preview: 'SELECT title, pages FROM books;',
    ),
  ],
);

const _summaries = SqlLesson(
  title: 'Counts and groups',
  summary: 'Count, total, and make one row per group.',
  parts: [
    SqlPart(
      title: 'One total',
      teach:
          'COUNT(*) counts rows. SUM adds a column. Name a summary with AS so the result column has a stable name. This statement has no GROUP BY, so the whole table is one group.',
      example: SqlExample(
        title: 'Books and pages',
        setup: _shelf,
        statement: 'SELECT COUNT(*) AS books, SUM(pages) AS pages FROM books;',
        note: 'Three books, and the pages add up to 540.',
      ),
      question: SqlQuestion(
        prompt: 'Which function counts rows?',
        choices: ['SUM', 'COUNT', 'MIN', 'LIKE'],
        answer: 1,
        why: 'COUNT(*) counts the rows in the group. SUM adds values.',
      ),
    ),
    SqlPart(
      title: 'One row per city',
      teach:
          'GROUP BY makes one result row per group. The columns you select should be the group key or a summary. GROUP BY city makes one row for Amman and one row for Irbid.',
      example: SqlExample(
        title: 'Authors in each city',
        setup: _cities,
        statement:
            'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city;',
        note: 'Amman has two authors. Irbid has one.',
      ),
      question: SqlQuestion(
        prompt: 'What does GROUP BY city produce?',
        choices: [
          'One row for the whole table.',
          'One row for each author.',
          'One row for each different city.',
          'No rows.',
        ],
        answer: 2,
        why:
            'Each different city becomes one group, and the summary is computed for that group.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'SUM(pages) on 40, 180, and 320 returns what?',
      choices: ['3', '180', '540', 'NULL'],
      answer: 2,
      why: 'SUM adds the values. COUNT(*) is the one that would return 3.',
    ),
    SqlQuestion(
      prompt: 'A summary with no GROUP BY returns how many groups?',
      choices: [
        'One group, the whole table.',
        'One group per row.',
        'No groups.',
        'One group per column.',
      ],
      answer: 0,
      why: 'Without GROUP BY, every selected row belongs to a single summary.',
    ),
    SqlQuestion(
      prompt: 'Which statement returns city and a count named authors?',
      choices: [
        'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city;',
        'SELECT * FROM authors;',
        'SELECT city FROM authors;',
        'SELECT COUNT(*) FROM books;',
      ],
      answer: 0,
      why: 'GROUP BY city builds the groups, and AS names the count.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Return one row. Name the book count books and the total of pages pages.',
      setup: _shelf,
      statement: 'SELECT COUNT(*) AS books, SUM(pages) AS pages FROM books;',
      preview: 'SELECT title, pages FROM books;',
    ),
    SqlTask(
      prompt: 'Return city and authors, the number of authors in that city.',
      setup: _cities,
      statement: 'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city;',
      preview: 'SELECT name, city FROM authors;',
    ),
  ],
);

final _having = SqlLesson(
  title: 'Keeping groups',
  summary: 'Filter a summary after the groups exist.',
  parts: [
    _part(
      'Groups, then a filter',
      'HAVING filters groups after the summary. WHERE filters rows before they are grouped. HAVING COUNT(*) > 1 keeps cities that contain more than one author.',
      'Cities with two authors',
      _cities,
      'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city HAVING COUNT(*) > 1;',
      'Amman has Ada and Grace, so it stays. Irbid has only Lin.',
      _ask(
        'When does HAVING run?',
        [
          'Before any row is read.',
          'After the groups are summarized.',
          'Instead of SELECT.',
          'Only when the table is empty.',
        ],
        1,
        'HAVING filters the grouped result. WHERE filters the rows that enter the group.',
      ),
    ),
    _part(
      'Rows first',
      'WHERE name <> \'Lin\' removes Lin before the groups are built. Irbid then has nobody, so that city does not appear. This is not HAVING: the row was dropped before the count.',
      'Without Lin',
      _cities,
      "SELECT city, COUNT(*) AS authors FROM authors WHERE name <> 'Lin' GROUP BY city;",
      'Both remaining authors live in Amman, so one group remains.',
      _ask(
        'WHERE name <> \'Lin\' runs relative to GROUP BY at what point?',
        [
          'After HAVING.',
          'Before the rows are grouped.',
          'Instead of SELECT.',
          'Only on the stored index.',
        ],
        1,
        'WHERE chooses the rows that enter the group. Lin never reaches a group.',
      ),
    ),
  ],
  review: [
    _ask(
      'You want cities with more than one author. Which clause expresses that?',
      [
        'WHERE COUNT(*) > 1',
        'HAVING COUNT(*) > 1',
        'ORDER BY COUNT(*)',
        'LIMIT 1',
      ],
      1,
      'The count exists only after grouping, so HAVING is the filter that can see it.',
    ),
    _ask(
      'A city has one author. HAVING COUNT(*) > 1 does what with it?',
      [
        'Keeps it.',
        'Drops that group.',
        'Deletes the author.',
        'Splits it into two rows.'
      ],
      1,
      'The group fails the condition, so it is absent from the result.',
    ),
    _ask(
      'Which filter can see a summary?',
      ['WHERE', 'HAVING', 'FROM', 'INSERT'],
      1,
      'HAVING runs after the summary. WHERE runs before it.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return city and authors for cities with more than one author.',
      setup: _cities,
      statement:
          'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city HAVING COUNT(*) > 1;',
      preview: 'SELECT name, city FROM authors;',
    ),
    SqlTask(
      prompt: 'Return city and authors for cities with exactly one author.',
      setup: _cities,
      statement:
          'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city HAVING COUNT(*) = 1;',
      preview: 'SELECT name, city FROM authors;',
    ),
  ],
);

const _joining = SqlLesson(
  title: 'Joining tables',
  summary: 'Combine a book with its author.',
  parts: [
    SqlPart(
      title: 'Titles with names',
      teach:
          'INNER JOIN returns a row only when the ON condition matches a row in both tables. A book with no author, and an author with no book, stay out. Write books.title when you want that table\'s column.',
      example: SqlExample(
        title: 'Each match',
        setup: _library,
        statement: '''
SELECT books.title, authors.name
FROM books
INNER JOIN authors ON books.author_id = authors.id;''',
        note:
            'Each matched book appears with its author. Lin has no book, so Lin is absent.',
      ),
      question: SqlQuestion(
        prompt: 'What does an INNER JOIN return?',
        choices: [
          'Every row of the first table.',
          'Rows where the ON condition matches both tables.',
          'Only the primary keys.',
          'A copy of the schema.',
        ],
        answer: 1,
        why: 'An inner join keeps matches. A side with no partner stays out.',
      ),
    ),
    SqlPart(
      title: 'Then a filter',
      teach:
          'WHERE can still filter the joined rows. The join finds the matches, and WHERE keeps the author you name.',
      example: SqlExample(
        title: "Ada's books",
        setup: _library,
        statement: '''
SELECT books.title
FROM books
INNER JOIN authors ON books.author_id = authors.id
WHERE authors.name = 'Ada';''',
        note: 'Ada wrote Kept Garden and Other Atlas.',
      ),
      question: SqlQuestion(
        prompt: 'What does ON do?',
        choices: [
          'It sorts the join.',
          'It states which rows match.',
          'It creates the table.',
          'It limits the count.',
        ],
        answer: 1,
        why:
            'ON is the match between the two tables. WHERE can filter after that.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'Which rows disappear from this inner join?',
      choices: [
        'Books whose author_id matches an author.',
        'An author who wrote no book.',
        'The author named Ada.',
        'Every book that has a title.',
      ],
      answer: 1,
      why: 'An author who is never referenced has no row to join.',
    ),
    SqlQuestion(
      prompt: 'books.author_id = authors.id belongs in which clause?',
      choices: ['ON', 'CREATE', 'INSERT', 'DEFAULT'],
      answer: 0,
      why:
          'ON carries the match. The two id columns are how a book points at an author.',
    ),
    SqlQuestion(
      prompt:
          'Why write books.title instead of title when both tables are in the query?',
      choices: [
        'The table prefix says which title you mean.',
        'The prefix deletes the other table.',
        'SQL requires a prefix on every word.',
        'It renames the stored column.',
      ],
      answer: 0,
      why:
          'Two tables can both have a column you might name. The prefix chooses one.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Return title and name for each book that has an author. Use the columns title and name.',
      setup: _library,
      statement: '''
SELECT books.title, authors.name
FROM books
INNER JOIN authors ON books.author_id = authors.id;''',
      preview: 'SELECT title, author_id FROM books;',
    ),
    SqlTask(
      prompt: 'Return the title of each book written by Grace.',
      setup: _library,
      statement: '''
SELECT books.title
FROM books
INNER JOIN authors ON books.author_id = authors.id
WHERE authors.name = 'Grace';''',
      preview: 'SELECT name, city FROM authors;',
    ),
  ],
);

const _missing = SqlLesson(
  title: 'Missing matches',
  summary: 'Keep a row that has no partner.',
  parts: [
    SqlPart(
      title: 'Every author',
      teach:
          'LEFT JOIN keeps every row of the left table. When the right table has no match, its columns are NULL. Put the table you still want, even with no partner, on the left.',
      example: SqlExample(
        title: 'Authors, with a book if they have one',
        setup: _library,
        statement: '''
SELECT authors.name, books.title
FROM authors
LEFT JOIN books ON books.author_id = authors.id;''',
        note:
            'Lin stays in the result. The title beside Lin is NULL because Lin has no book.',
      ),
      question: SqlQuestion(
        prompt: 'What does a LEFT JOIN keep from the left table?',
        choices: [
          'Only the matching rows.',
          'Every left row, with NULL on the right when nothing matches.',
          'Only the NULL rows.',
          'The schema.',
        ],
        answer: 1,
        why:
            'The left table is preserved. The right side is NULL when ON finds nothing.',
      ),
    ),
    SqlPart(
      title: 'Only the gaps',
      teach:
          'WHERE books.id IS NULL after a left join finds the left rows that did not match. A match would have filled books.id.',
      example: SqlExample(
        title: 'Authors with no book',
        setup: _library,
        statement: '''
SELECT authors.name
FROM authors
LEFT JOIN books ON books.author_id = authors.id
WHERE books.id IS NULL;''',
        note: 'Lin is the author whose book columns stayed NULL.',
      ),
      question: SqlQuestion(
        prompt:
            'A left join is filtered with WHERE books.id IS NULL. Which authors remain?',
        choices: [
          'Authors who have a book.',
          'Authors who have no book.',
          'Every author.',
          'Books that have no title.',
        ],
        answer: 1,
        why:
            'A match would have put a value in books.id. NULL means the join found no book.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'Which table belongs on the left?',
      choices: [
        'The table whose missing partners you still want to see.',
        'The table with more rows.',
        'The table that was created last.',
        'The table that has no key.',
      ],
      answer: 0,
      why: 'The left table is the one the join preserves.',
    ),
    SqlQuestion(
      prompt:
          'Lin has no book. In a left join from authors to books, Lin\'s title is?',
      choices: ['An empty string.', 'NULL.', 'The word book.', 'Lin.'],
      answer: 1,
      why: 'No matching book leaves the right-hand columns NULL.',
    ),
    SqlQuestion(
      prompt:
          'INNER JOIN and LEFT JOIN differ on Lin. What does the inner join do?',
      choices: [
        'It keeps Lin with NULL.',
        'It leaves Lin out.',
        'It invents a book for Lin.',
        'It deletes Lin.',
      ],
      answer: 1,
      why: 'An inner join has no row for an author with no match.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Return name and pages for every author, including an author with no book. A missing book has NULL pages.',
      setup: _library,
      statement: '''
SELECT authors.name, books.pages
FROM authors
LEFT JOIN books ON books.author_id = authors.id;''',
      preview: 'SELECT name FROM authors;',
    ),
    SqlTask(
      prompt: 'Return the name of each author who has no book.',
      setup: _library,
      statement: '''
SELECT authors.name
FROM authors
LEFT JOIN books ON books.author_id = authors.id
WHERE books.id IS NULL;''',
      preview: 'SELECT name FROM authors;',
    ),
  ],
);

const _nested = SqlLesson(
  title: 'Queries inside queries',
  summary: 'Use a query as a value.',
  parts: [
    SqlPart(
      title: 'A list from another table',
      teach:
          'A subquery is a SELECT inside another statement. IN (SELECT ...) matches any value the inner query returns.',
      example: SqlExample(
        title: 'Books from Amman',
        setup: _library,
        statement: '''
SELECT title FROM books
WHERE author_id IN (SELECT id FROM authors WHERE city = 'Amman');''',
        note:
            'The inner query returns the ids of authors in Amman. IN keeps those books.',
      ),
      question: SqlQuestion(
        prompt: 'What does IN (SELECT ...) do?',
        choices: [
          'It creates a table.',
          'It matches any value returned by the inner query.',
          'It sorts the outer query.',
          'It updates the inner table.',
        ],
        answer: 1,
        why:
            'The inner SELECT produces values. IN keeps an outer row when its value is in that list.',
      ),
    ),
    SqlPart(
      title: 'At least one row',
      teach:
          'EXISTS is true when the inner query returns at least one row. When the inner query uses a column from the outer query, it runs again for each outer row.',
      example: SqlExample(
        title: 'Authors who have a book',
        setup: _library,
        statement: '''
SELECT name FROM authors
WHERE EXISTS (
  SELECT 1 FROM books WHERE books.author_id = authors.id
);''',
        note:
            'EXISTS only cares that the inner query found a row. Lin has none.',
      ),
      question: SqlQuestion(
        prompt: 'When is EXISTS true?',
        choices: [
          'When the inner query is empty.',
          'When the inner query returns at least one row.',
          'When both tables have the same name.',
          'When the outer query has no WHERE.',
        ],
        answer: 1,
        why:
            'EXISTS does not use the selected columns. It cares whether a row came back.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt:
          'A subquery uses authors.id from the outer query. When does that inner query run?',
      choices: [
        'Once, before any outer row is read.',
        'Only while the table is created.',
        'Again for each outer row.',
        'It never runs.',
      ],
      answer: 2,
      why:
          'The inner query depends on the current outer row, so it is evaluated for that row.',
    ),
    SqlQuestion(
      prompt: 'Which statement returns books whose author lives in Irbid?',
      choices: [
        "SELECT title FROM books WHERE author_id IN (SELECT id FROM authors WHERE city = 'Irbid');",
        'SELECT title FROM books;',
        'SELECT city FROM authors;',
        'DELETE FROM books;',
      ],
      answer: 0,
      why:
          'The inner query produces Irbid author ids. IN keeps books with those ids.',
    ),
    SqlQuestion(
      prompt: 'EXISTS (SELECT 1 ...) uses the 1 for what?',
      choices: [
        'As the only thing EXISTS looks at: whether a row exists.',
        'As a page count.',
        'As a table name.',
        'As an UPDATE.',
      ],
      answer: 0,
      why: 'The selected value is unused. A returned row makes EXISTS true.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt: 'Return the title of each book whose author lives in Irbid.',
      setup: _library,
      statement: '''
SELECT title FROM books
WHERE author_id IN (SELECT id FROM authors WHERE city = 'Irbid');''',
      preview: 'SELECT name, city FROM authors;',
    ),
    SqlTask(
      prompt: 'Return the name of each author who has at least one book.',
      setup: _library,
      statement: '''
SELECT name FROM authors
WHERE EXISTS (
  SELECT 1 FROM books WHERE books.author_id = authors.id
);''',
      preview: 'SELECT name, city FROM authors;',
    ),
  ],
);

const _indexes = SqlLesson(
  title: 'Indexes and views',
  summary: 'Speed a lookup and name a query.',
  parts: [
    SqlPart(
      title: 'A lookup',
      teach:
          'CREATE INDEX keeps a lookup structure on a column. The result of a query stays the same. The index name is a row in sqlite_schema. CREATE UNIQUE INDEX also rejects a repeated key.',
      example: SqlExample(
        title: 'A unique title index',
        setup: _shelf,
        statement: 'CREATE UNIQUE INDEX idx_books_title ON books (title);',
        note:
            'sqlite_schema records the index. The books themselves are unchanged.',
        probe:
            "SELECT name FROM sqlite_schema WHERE type = 'index' AND name = 'idx_books_title';",
      ),
      question: SqlQuestion(
        prompt: 'What does an index change about a SELECT result?',
        choices: [
          'The row order is reversed.',
          'The result stays the same.',
          'Duplicate rows are removed.',
          'The table is emptied.',
        ],
        answer: 1,
        why:
            'An index is a lookup structure. It does not change which rows a query returns.',
      ),
    ),
    SqlPart(
      title: 'A saved query',
      teach:
          'CREATE VIEW saves a query under a name. Selecting from the view runs that query against the current rows. The view does not store a private copy of the rows.',
      example: SqlExample(
        title: 'short_books',
        setup: _shelf,
        statement:
            'CREATE VIEW short_books AS SELECT title, pages FROM books WHERE pages < 100;',
        note:
            'Reading short_books runs its SELECT. The short book is Other Atlas.',
        probe: 'SELECT title, pages FROM short_books;',
      ),
      question: SqlQuestion(
        prompt: 'What does a view store?',
        choices: [
          'A copy of the rows.',
          'A primary key.',
          'A query you can select from.',
          'An index.',
        ],
        answer: 2,
        why:
            'Selecting from the view runs the saved query against the current rows.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'Where is the index name recorded?',
      choices: [
        'In the title column.',
        'In sqlite_schema.',
        'In the first data row.',
        'It is not stored.',
      ],
      answer: 1,
      why:
          'sqlite_schema lists tables, indexes, and views. An index has type index.',
    ),
    SqlQuestion(
      prompt: 'CREATE UNIQUE INDEX rejects what?',
      choices: [
        'A repeated key.',
        'Every SELECT.',
        'The first row.',
        'A view.',
      ],
      answer: 0,
      why: 'UNIQUE means the indexed values cannot repeat.',
    ),
    SqlQuestion(
      prompt:
          'You insert another short book after creating short_books. What does selecting from the view return?',
      choices: [
        'The rows from the moment the view was created.',
        'The current rows that pass the saved query.',
        'Nothing, because a view cannot see new rows.',
        'The index name.',
      ],
      answer: 1,
      why: 'The view runs its query when you read it.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          'Create an index named idx_books_pages on the pages column of books. The check reads that name from sqlite_schema.',
      setup: _shelf,
      statement: 'CREATE INDEX idx_books_pages ON books (pages);',
      preview: 'SELECT title, pages FROM books;',
      probe:
          "SELECT name FROM sqlite_schema WHERE type = 'index' AND name = 'idx_books_pages';",
    ),
    SqlTask(
      prompt:
          'Create a view named long_books that returns title and pages for books with at least 100 pages. The check selects title and pages from long_books.',
      setup: _shelf,
      statement:
          'CREATE VIEW long_books AS SELECT title, pages FROM books WHERE pages >= 100;',
      preview: 'SELECT title, pages FROM books;',
      probe: 'SELECT title, pages FROM long_books;',
    ),
  ],
);

const _report = SqlLesson(
  title: 'A full report',
  summary: 'Count each author, including zero.',
  parts: [
    SqlPart(
      title: 'None, one, or many',
      teach:
          "Keep every author with LEFT JOIN. COUNT(*) would count the empty match as one, so count the book id instead: NULL is skipped and an author with no book counts as zero. CASE labels zero as none, one as one, and every larger count as many. GROUP BY makes one row per author. ORDER BY name is part of this result.",
      example: SqlExample(
        title: 'A shelf label',
        setup: _library,
        statement: '''
SELECT authors.name, COUNT(books.id) AS books,
  CASE
    WHEN COUNT(books.id) = 0 THEN 'none'
    WHEN COUNT(books.id) = 1 THEN 'one'
    ELSE 'many'
  END AS shelf
FROM authors
LEFT JOIN books ON books.author_id = authors.id
GROUP BY authors.name
ORDER BY authors.name;''',
        note:
            'Ada has two books, Grace has one, and Lin has none. The names are alphabetical.',
      ),
      question: SqlQuestion(
        prompt:
            'An author has no book. A left join still emits one row for that author. What does COUNT(*) return?',
        choices: ['0', '1', 'NULL', 'The number of authors'],
        answer: 1,
        why:
            'The join emits one row, with NULL book columns. COUNT(*) counts that row.',
      ),
    ),
    SqlPart(
      title: 'A label on one row',
      teach:
          'CASE picks the first matching WHEN. ELSE covers the remaining rows. Here a book of at least 100 pages is long, and the rest are short.',
      example: SqlExample(
        title: 'Long or short',
        setup: _shelf,
        statement: '''
SELECT title,
  CASE WHEN pages >= 100 THEN 'long' ELSE 'short' END AS length
FROM books;''',
        note: 'Other Atlas is short. River Index and Kept Garden are long.',
      ),
      question: SqlQuestion(
        prompt: 'Which CASE label belongs to a count of 2?',
        choices: ['none', 'one', 'many', 'short'],
        answer: 2,
        why: 'Zero is none, one is one, and every larger count is many.',
      ),
    ),
  ],
  review: [
    SqlQuestion(
      prompt: 'What does COUNT(books.id) return for an author with no book?',
      choices: ['0', '1', 'NULL', 'Every book in the table'],
      answer: 0,
      why:
          'COUNT of a column skips NULL. The unmatched book id is NULL, so the count is zero.',
    ),
    SqlQuestion(
      prompt: 'Why is ORDER BY name part of this report?',
      choices: [
        'The names have to come back alphabetically.',
        'GROUP BY requires a descending sort.',
        'CASE only runs after ORDER BY.',
        'It creates the author.',
      ],
      answer: 0,
      why: 'The lesson treats alphabetical names as part of the result.',
    ),
    SqlQuestion(
      prompt:
          'CASE WHEN pages >= 100 THEN \'long\' ELSE \'short\' END. A book of 40 pages is?',
      choices: ['long', 'short', 'NULL', 'many'],
      answer: 1,
      why: '40 fails the WHEN, so ELSE supplies short.',
    ),
  ],
  tasks: [
    SqlTask(
      prompt:
          "Return name, books, and shelf for every author, ordered by name. books is COUNT(books.id). shelf is none, one, or many. Include authors with no books. The order is part of the answer.",
      setup: _library,
      statement: '''
SELECT authors.name, COUNT(books.id) AS books,
  CASE
    WHEN COUNT(books.id) = 0 THEN 'none'
    WHEN COUNT(books.id) = 1 THEN 'one'
    ELSE 'many'
  END AS shelf
FROM authors
LEFT JOIN books ON books.author_id = authors.id
GROUP BY authors.name
ORDER BY authors.name;''',
      preview: 'SELECT name FROM authors;',
      orderMatters: true,
    ),
    SqlTask(
      prompt:
          'Return name and books for each author who has at least two books. books is COUNT(books.id).',
      setup: _library,
      statement: '''
SELECT authors.name, COUNT(books.id) AS books
FROM authors
LEFT JOIN books ON books.author_id = authors.id
GROUP BY authors.name
HAVING COUNT(books.id) >= 2;''',
      preview: 'SELECT name FROM authors;',
    ),
  ],
);
