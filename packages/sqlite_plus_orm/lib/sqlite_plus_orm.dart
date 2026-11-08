/// Browser-safe, metadata-driven ORM for the Pure Dart sqlite_plus engine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
export 'package:sqlite_plus/sqlite_plus.dart'
    show SqlPage, PageCursor, PageOrder;
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart';

export 'package:sqlite_plus_reactive/sqlite_plus_reactive.dart'
    show
        ReactiveQuery,
        ReactiveSnapshot,
        ReactiveRowChange,
        ReactiveChangeKind,
        ReactiveLimitException;

import 'src/orm_file_handle.dart';
import 'src/orm_file_stub.dart' if (dart.library.io) 'src/orm_file_io.dart'
    as orm_file;

part 'src/annotations.dart';
part 'src/names.dart';
part 'src/codecs.dart';
part 'src/connection.dart';
part 'src/errors.dart';
part 'src/metadata.dart';
part 'src/query.dart';
part 'src/context.dart';
part 'src/relationships.dart';
part 'src/migrations.dart';

part 'src/reactive.dart';
part 'src/writes.dart';
