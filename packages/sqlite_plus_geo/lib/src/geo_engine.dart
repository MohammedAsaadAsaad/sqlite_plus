/// Geometry, predicates, SQL registration, and spatial tables.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

part 'core/model.dart';
part 'core/exact.dart';
part 'geometry/geometries.dart';
part 'serialization/wkt.dart';
part 'serialization/wkb.dart';
part 'serialization/geojson.dart';
part 'predicates/locate.dart';
part 'predicates/relate.dart';
part 'operations/measures.dart';
part 'operations/edit.dart';
part 'operations/overlay.dart';
part 'operations/buffer.dart';
part 'operations/hull.dart';
part 'geodesy/geodesy.dart';
part 'crs/crs.dart';
part 'validation/repair.dart';
part 'sql/functions.dart';
part 'indexing/store.dart';
part 'query/spatial_query.dart';
part 'serialization/exchange.dart';
part 'optimization/isolate_compute.dart';
