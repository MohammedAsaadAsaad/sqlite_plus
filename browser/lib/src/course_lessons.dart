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

/// Twelve levels, from a first query to one report.
const List<SqlLevel> sqlCourse = [
  SqlLevel(
    title: 'Reading rows',
    summary: 'Read columns from a table.',
    teach:
        'A query starts with SELECT. Name the columns you want, then name the table after FROM. SELECT * reads every column. A query returns rows and does not change the stored table.',
    examples: [
      SqlExample(
        title: 'Choose the columns',
        setup: _shelf,
        statement: 'SELECT title, pages FROM books;',
        note:
            'The names after SELECT become the result columns, in that order.',
      ),
      SqlExample(
        title: 'Every column',
        setup: _shelf,
        statement: 'SELECT * FROM books;',
        note:
            'The star means every column of books. This table has two, so the result matches the column list.',
      ),
    ],
    questions: [
      SqlQuestion(
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
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'Filtering rows',
    summary: 'Keep the rows that match a condition.',
    teach:
        'WHERE keeps a row when its condition is true. Compare with =, <, >, <=, and >=. AND keeps a row only when both parts are true. OR keeps a row when either part is true.',
    examples: [
      SqlExample(
        title: 'Longer books',
        setup: _shelf,
        statement: 'SELECT title FROM books WHERE pages > 100;',
        note:
            '180 and 320 are greater than 100. The book with 40 pages is left out.',
      ),
      SqlExample(
        title: 'Both conditions',
        setup: _shelf,
        statement:
            'SELECT title, pages FROM books WHERE pages >= 40 AND pages < 180;',
        note:
            'AND requires both comparisons. Only the book with 40 pages matches.',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt: 'Which keyword keeps the matching rows?',
        choices: ['ORDER BY', 'WHERE', 'INSERT', 'LIMIT'],
        answer: 1,
        why: 'WHERE is the filter. Rows that fail it are not returned.',
      ),
      SqlQuestion(
        prompt: 'A book has 180 pages. Which condition keeps it?',
        choices: ['pages > 180', 'pages >= 180', 'pages < 180', 'pages = 40'],
        answer: 1,
        why:
            '>= keeps a value that is equal, as well as a value that is larger.',
      ),
      SqlQuestion(
        prompt: 'When does AND keep a row?',
        choices: [
          'When either comparison is true.',
          'When the first comparison is true.',
          'When both comparisons are true.',
          'When neither comparison is true.',
        ],
        answer: 2,
        why: 'AND is stricter than OR. Both sides have to succeed.',
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
  ),
  SqlLevel(
    title: 'Sorting and limiting',
    summary: 'Put rows in order and keep a prefix.',
    teach:
        'ORDER BY sorts the result. ASC is the default and goes from small to large. DESC goes from large to small. LIMIT keeps the first rows of that sorted result. In this level the order is part of the answer.',
    examples: [
      SqlExample(
        title: 'Longest first',
        setup: _shelfUnsorted,
        statement: 'SELECT title, pages FROM books ORDER BY pages DESC;',
        note: 'DESC puts the largest page count first.',
      ),
      SqlExample(
        title: 'The shortest book',
        setup: _shelfUnsorted,
        statement: 'SELECT title FROM books ORDER BY pages ASC LIMIT 1;',
        note:
            'The sort runs before LIMIT, so this is the shortest book rather than the first inserted row.',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt: 'Which clause sorts the result?',
        choices: ['WHERE', 'ORDER BY', 'FROM', 'VALUES'],
        answer: 1,
        why: 'ORDER BY sets the order of the rows that are returned.',
      ),
      SqlQuestion(
        prompt: 'What does DESC mean?',
        choices: [
          'Smallest first.',
          'Largest first.',
          'Skip the first row.',
          'Keep matching rows.',
        ],
        answer: 1,
        why: 'DESC is descending. Numbers go from large to small.',
      ),
      SqlQuestion(
        prompt:
            'A result is sorted by pages descending. What does LIMIT 1 return?',
        choices: [
          'Every row.',
          'The first inserted row.',
          'The row that sorts first.',
          'A new row with one page.',
        ],
        answer: 2,
        why:
            'LIMIT counts rows after the sort. The first row is the longest book.',
      ),
    ],
    tasks: [
      SqlTask(
        prompt:
            'Return title and pages, with the longest book first. The order is part of the answer.',
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
  ),
  SqlLevel(
    title: 'Insert, update, and delete',
    summary: 'Add, change, and remove rows.',
    teach:
        'INSERT adds a row. Name the columns, then give the values in the same order. UPDATE assigns new values, and WHERE chooses the rows. Without WHERE, every row changes. DELETE removes rows, and WHERE chooses which ones. The check reads the table after your statement.',
    examples: [
      SqlExample(
        title: 'Add one book',
        setup: 'CREATE TABLE books (title TEXT, pages INTEGER);',
        statement:
            "INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);",
        note:
            'One INSERT writes one row. The table below is the stored result.',
        probe: 'SELECT title, pages FROM books;',
      ),
      SqlExample(
        title: 'Change one row',
        setup: '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
''',
        statement: "UPDATE books SET pages = 48 WHERE title = 'Other Atlas';",
        note: 'WHERE limits the assignment. Kept Garden stays at 320 pages.',
        probe: 'SELECT title, pages FROM books;',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt: 'Which statement adds a row?',
        choices: ['SELECT', 'INSERT', 'DROP', 'ORDER BY'],
        answer: 1,
        why: 'INSERT writes a new row into a table that already exists.',
      ),
      SqlQuestion(
        prompt: 'What happens if UPDATE has no WHERE?',
        choices: [
          'No row changes.',
          'Only the first row changes.',
          'Every row in the table changes.',
          'The table is deleted.',
        ],
        answer: 2,
        why:
            'WHERE is the guard. Without it, the assignment runs for every row.',
      ),
      SqlQuestion(
        prompt: 'Which statement removes the short books?',
        choices: [
          'DELETE FROM books WHERE pages < 50;',
          'SELECT pages FROM books;',
          'UPDATE books SET pages = 0;',
          "INSERT INTO books (pages) VALUES (50);",
        ],
        answer: 0,
        why: 'DELETE removes rows. WHERE still decides which rows.',
      ),
    ],
    tasks: [
      SqlTask(
        prompt:
            "Insert a book titled River Index with 180 pages. The check reads title and pages.",
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
            "Set the pages of Other Atlas to 48. Leave every other row as it is.",
        setup: '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
''',
        statement: "UPDATE books SET pages = 48 WHERE title = 'Other Atlas';",
        preview: 'SELECT title, pages FROM books;',
        probe: 'SELECT title, pages FROM books;',
      ),
      SqlTask(
        prompt: 'Delete every book with fewer than 50 pages.',
        setup: '''
CREATE TABLE books (title TEXT, pages INTEGER);
INSERT INTO books (title, pages) VALUES ('Kept Garden', 320);
INSERT INTO books (title, pages) VALUES ('Other Atlas', 40);
''',
        statement: 'DELETE FROM books WHERE pages < 50;',
        preview: 'SELECT title, pages FROM books;',
        probe: 'SELECT title, pages FROM books;',
      ),
    ],
  ),
  SqlLevel(
    title: 'Creating a table',
    summary: 'Define columns, a key, and a default.',
    teach:
        'CREATE TABLE names the table and its columns. INTEGER PRIMARY KEY assigns a number when an INSERT leaves that column out. NOT NULL rejects a missing value. DEFAULT stores a value when an INSERT omits the column. The check runs your statement, inserts one row, and reads it back.',
    examples: [
      SqlExample(
        title: 'A key and a default',
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
      SqlExample(
        title: 'A required name',
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
    ],
    questions: [
      SqlQuestion(
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
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'Matching values',
    summary: 'Match a list, a pattern, a duplicate, or NULL.',
    teach:
        "IN matches any value in a list. BETWEEN matches both ends and everything between them. LIKE matches a pattern: % is any text, and _ is one character. LIKE ignores ASCII letter case. NULL means missing. A comparison with = does not match NULL, so use IS NULL. DISTINCT returns each different result row once.",
    examples: [
      SqlExample(
        title: 'A title pattern',
        setup: _shelf,
        statement: "SELECT title FROM books WHERE title LIKE 'k%';",
        note:
            'k% matches a title that starts with K. LIKE folds ASCII letters, so Kept Garden matches.',
      ),
      SqlExample(
        title: 'A missing author',
        setup: '''
CREATE TABLE books (title TEXT, author TEXT);
INSERT INTO books (title, author) VALUES ('Kept Garden', 'Ada');
INSERT INTO books (title, author) VALUES ('Other Atlas', NULL);
''',
        statement: 'SELECT title FROM books WHERE author IS NULL;',
        note:
            'Other Atlas has no author. author = NULL would not return that row.',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt: 'Which pattern matches a title that ends with Atlas?',
        choices: ["'Atlas%'", "'%Atlas'", "'_Atlas'", "'Atlas'"],
        answer: 1,
        why:
            '% matches any text before Atlas. Without %, the pattern has to match the whole title.',
      ),
      SqlQuestion(
        prompt: 'Which condition matches a missing author?',
        choices: [
          'author = NULL',
          'author IS NULL',
          "author = ''",
          'author LIKE NULL',
        ],
        answer: 1,
        why:
            'NULL is not equal to NULL in a comparison. IS NULL tests for a missing value.',
      ),
      SqlQuestion(
        prompt: 'What does DISTINCT do?',
        choices: [
          'It sorts the rows.',
          'It deletes stored rows.',
          'It returns each different result row once.',
          'It keeps the first table only.',
        ],
        answer: 2,
        why:
            'DISTINCT compares the result rows and drops repeats. The stored table stays as it is.',
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
  ),
  SqlLevel(
    title: 'Summaries',
    summary: 'Count, total, and group rows.',
    teach:
        'COUNT(*) counts rows. SUM adds a column. MIN and MAX pick an extreme. GROUP BY makes one result row per group. WHERE filters rows before the summary. HAVING filters groups after the summary. Name a summary with AS so the result column has a stable name.',
    examples: [
      SqlExample(
        title: 'One total',
        setup: _shelf,
        statement: 'SELECT COUNT(*) AS books, SUM(pages) AS pages FROM books;',
        note: 'Three books, and the pages add up to 540.',
      ),
      SqlExample(
        title: 'A row per city',
        setup: _cities,
        statement:
            'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city;',
        note: 'GROUP BY city makes one row for Amman and one row for Irbid.',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt: 'Which function counts rows?',
        choices: ['SUM', 'COUNT', 'MIN', 'LIKE'],
        answer: 1,
        why: 'COUNT(*) counts the rows in the group. SUM adds values.',
      ),
      SqlQuestion(
        prompt: 'When does HAVING run?',
        choices: [
          'Before any row is read.',
          'After the groups are summarized.',
          'Instead of SELECT.',
          'Only when the table is empty.',
        ],
        answer: 1,
        why:
            'HAVING filters the grouped result. WHERE filters the rows that enter the group.',
      ),
      SqlQuestion(
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
        prompt:
            'Return city and authors, the number of authors in that city, for cities with more than one author.',
        setup: _cities,
        statement:
            'SELECT city, COUNT(*) AS authors FROM authors GROUP BY city HAVING COUNT(*) > 1;',
        preview: 'SELECT name, city FROM authors;',
      ),
    ],
  ),
  SqlLevel(
    title: 'Joining tables',
    summary: 'Combine a book with its author.',
    teach:
        'INNER JOIN returns a row only when the ON condition matches a row in both tables. A book with no author, and an author with no book, stay out. Write books.title when you want that table column. WHERE can still filter the joined rows.',
    examples: [
      SqlExample(
        title: 'Titles with names',
        setup: _library,
        statement: '''
SELECT books.title, authors.name
FROM books
INNER JOIN authors ON books.author_id = authors.id;''',
        note:
            'Each matched book appears with its author. Lin has no book, so Lin is absent.',
      ),
      SqlExample(
        title: "One author's books",
        setup: _library,
        statement: '''
SELECT books.title
FROM books
INNER JOIN authors ON books.author_id = authors.id
WHERE authors.name = 'Ada';''',
        note: 'The join finds the matches, and WHERE keeps Ada.',
      ),
    ],
    questions: [
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'Missing matches',
    summary: 'Keep a row that has no partner.',
    teach:
        'LEFT JOIN keeps every row of the left table. When the right table has no match, its columns are NULL. Put the table you still want, even with no partner, on the left. WHERE books.id IS NULL then finds the left rows that did not match.',
    examples: [
      SqlExample(
        title: 'Every author',
        setup: _library,
        statement: '''
SELECT authors.name, books.title
FROM authors
LEFT JOIN books ON books.author_id = authors.id;''',
        note:
            'Lin stays in the result. The title beside Lin is NULL because Lin has no book.',
      ),
      SqlExample(
        title: 'Authors with no book',
        setup: _library,
        statement: '''
SELECT authors.name
FROM authors
LEFT JOIN books ON books.author_id = authors.id
WHERE books.id IS NULL;''',
        note:
            'A match would have filled books.id. NULL there means the author has no book.',
      ),
    ],
    questions: [
      SqlQuestion(
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
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'Queries inside queries',
    summary: 'Use a query as a value.',
    teach:
        'A subquery is a SELECT inside another statement. IN (SELECT ...) matches any value the inner query returns. EXISTS is true when the inner query returns at least one row. When the inner query uses a column from the outer query, it runs again for each outer row.',
    examples: [
      SqlExample(
        title: 'Books from one city',
        setup: _library,
        statement: '''
SELECT title FROM books
WHERE author_id IN (SELECT id FROM authors WHERE city = 'Amman');''',
        note:
            'The inner query returns the ids of authors in Amman. IN keeps those books.',
      ),
      SqlExample(
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
    ],
    questions: [
      SqlQuestion(
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
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'Indexes and views',
    summary: 'Speed a lookup and name a query.',
    teach:
        'CREATE INDEX keeps a lookup structure on a column. The result of a query stays the same. The index name is a row in sqlite_schema. CREATE UNIQUE INDEX also rejects a repeated key. CREATE VIEW saves a query under a name. Selecting from the view runs that query against the current rows.',
    examples: [
      SqlExample(
        title: 'A unique title index',
        setup: _shelf,
        statement: 'CREATE UNIQUE INDEX idx_books_title ON books (title);',
        note:
            'sqlite_schema records the index. The books themselves are unchanged.',
        probe:
            "SELECT name FROM sqlite_schema WHERE type = 'index' AND name = 'idx_books_title';",
      ),
      SqlExample(
        title: 'A named query',
        setup: _shelf,
        statement:
            'CREATE VIEW short_books AS SELECT title, pages FROM books WHERE pages < 100;',
        note:
            'Reading short_books runs its SELECT. The short book is Other Atlas.',
        probe: 'SELECT title, pages FROM short_books;',
      ),
    ],
    questions: [
      SqlQuestion(
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
  ),
  SqlLevel(
    title: 'A full report',
    summary: 'Count each author, including zero.',
    teach:
        "Keep every author with LEFT JOIN. COUNT(*) would count the empty match as one, so count the book id instead: NULL is skipped and an author with no book counts as zero. CASE labels zero as none, one as one, and every larger count as many. GROUP BY makes one row per author. ORDER BY name is part of this result.",
    examples: [
      SqlExample(
        title: 'None, one, or many',
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
      SqlExample(
        title: 'A label on one row',
        setup: _shelf,
        statement: '''
SELECT title,
  CASE WHEN pages >= 100 THEN 'long' ELSE 'short' END AS length
FROM books;''',
        note:
            'CASE picks the first matching WHEN. ELSE covers the remaining rows.',
      ),
    ],
    questions: [
      SqlQuestion(
        prompt:
            'An author has no book. A left join still emits one row for that author. What does COUNT(*) return?',
        choices: ['0', '1', 'NULL', 'The number of authors'],
        answer: 1,
        why:
            'The join emits one row, with NULL book columns. COUNT(*) counts that row.',
      ),
      SqlQuestion(
        prompt: 'What does COUNT(books.id) return for that same author?',
        choices: ['0', '1', 'NULL', 'Every book in the table'],
        answer: 0,
        why:
            'COUNT of a column skips NULL. The unmatched book id is NULL, so the count is zero.',
      ),
      SqlQuestion(
        prompt: 'Which CASE label belongs to a count of 2?',
        choices: ['none', 'one', 'many', 'short'],
        answer: 2,
        why: 'Zero is none, one is one, and every larger count is many.',
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
  ),
];
