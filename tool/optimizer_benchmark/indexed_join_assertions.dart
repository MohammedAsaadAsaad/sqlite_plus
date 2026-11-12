import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  for (final encoding in [1, 2, 3]) {
    final db = await MutableSqliteDatabase.create(encoding: encoding);
    await db.execute(
        'CREATE TABLE a(id INTEGER PRIMARY KEY,k TEXT COLLATE NOCASE)');
    await db.execute(
        'CREATE TABLE b(id INTEGER PRIMARY KEY,k TEXT COLLATE NOCASE,v TEXT)');
    await db.execute('CREATE INDEX bk ON b(k DESC)');
    await db.execute(
        "INSERT INTO a VALUES(1,'A'),(2,'a'),(3,NULL),(4,'b'),(5,'missing')");
    await db.execute(
        "INSERT INTO b VALUES(1,'a','x'),(2,'A','y'),(3,NULL,'n'),(4,'B','z')");
    final ro =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    const sql =
        'SELECT a.id AS aid,b.id AS bid,b.v FROM a INNER JOIN b ON a.k=b.k ORDER BY aid,bid';
    final expected = [
      [BigInt.one, BigInt.one, 'x'],
      [BigInt.one, BigInt.two, 'y'],
      [BigInt.two, BigInt.one, 'x'],
      [BigInt.two, BigInt.two, 'y'],
      [BigInt.from(4), BigInt.from(4), 'z']
    ];
    for (final query in [db.query, ro.query]) {
      final result = await query(sql);
      if (result.rows.toString() != expected.toString() ||
          result.columns.join(',') != 'aid,bid,v') {
        throw StateError(
            'Indexed join mismatch encoding=$encoding: ${result.rows}');
      }
      final scan =
          await query(sql.replaceFirst('JOIN b ON', 'JOIN b NOT INDEXED ON'));
      if (scan.rows.toString() != expected.toString())
        throw StateError('Scan mismatch');
    }
    if (ro.describeQueryPlan(sql).last != 'SEARCH b USING INDEX bk (k=?)') {
      throw StateError('Physical seek was not selected');
    }
    await ro.close();
    await db.close();
  }
  print(
      'Indexed join VM/JS assertions passed: encodings, duplicate/NULL/NOCASE keys, index direction, output order, scan fallback.');
}
