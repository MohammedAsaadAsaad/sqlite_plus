/// Optional bounded profiling through explicit connections. Browser-safe.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

part 'src/models.dart';
part 'src/collector.dart';
part 'src/connections.dart';
