import 'dart:async';
import 'dart:math' as math;
import 'values.dart';
import 'tokenizer.dart';

final Object sqlStatementTimeKey = Object();
const dateFunctionArities = <String, (int, int)>{
  'current_date': (0, 0),
  'current_time': (0, 0),
  'current_timestamp': (0, 0),
  'date': (0, 1000),
  'time': (0, 1000),
  'datetime': (0, 1000),
  'julianday': (0, 1000),
  'unixepoch': (0, 1000),
  'strftime': (1, 1000),
  'timediff': (2, 2)
};
const _day = 86400000;
const _epoch = 2440587.5;

Object? dateFunction(String key, List<Object?> arguments, int encoding) {
  key = const {
        'current_date': 'date',
        'current_time': 'time',
        'current_timestamp': 'datetime'
      }[key] ??
      key;
  if (arguments.any((v) => v == null)) return null;
  if (key == 'timediff') {
    final a = dateFunction('julianday', [arguments[0]], encoding),
        b = dateFunction('julianday', [arguments[1]], encoding);
    if (a is! double || b is! double) return null;
    final first = DateTime.fromMillisecondsSinceEpoch(
        ((a - _epoch) * _day).round(),
        isUtc: true);
    final second = DateTime.fromMillisecondsSinceEpoch(
        ((b - _epoch) * _day).round(),
        isUtc: true);
    final direction = first.isBefore(second) ? -1 : 1;
    var months =
        ((first.year - second.year) * 12 + first.month - second.month).abs();
    DateTime shift(int count) => DateTime.utc(
        second.year,
        second.month + direction * count,
        second.day,
        second.hour,
        second.minute,
        second.second,
        second.millisecond);
    var candidate = shift(months);
    while (months > 0 &&
        (direction > 0
            ? candidate.isAfter(first)
            : candidate.isBefore(first))) {
      candidate = shift(--months);
    }
    final remainder = first.difference(candidate).inMilliseconds.abs();
    String pad(int value, [int length = 2]) =>
        value.toString().padLeft(length, '0');
    return '${direction > 0 ? '+' : '-'}${pad(months ~/ 12, 4)}-${pad(months % 12)}-${pad(remainder ~/ _day)} ${pad(remainder ~/ 3600000 % 24)}:${pad(remainder ~/ 60000 % 60)}:${pad(remainder ~/ 1000 % 60)}.${pad(remainder % 1000, 3)}';
  }
  final args = arguments.map((v) => stringify(v!, encoding)).toList();
  String? format;
  if (key == 'strftime') {
    format = args.removeAt(0);
    if (format.length > 16 * 1024 * 1024) {
      throw const SqlException('Function output limit exceeded');
    }
  }
  var subsec = false, retain24 = false;
  final raw = args.isEmpty ? 'now' : args.removeAt(0);
  DateTime? moment;
  double? number;
  if (['now', 'subsec', 'subsecond'].contains(asciiLower(raw))) {
    moment = Zone.current[sqlStatementTimeKey] as DateTime? ??
        DateTime.now().toUtc();
    subsec = asciiLower(raw) != 'now';
  } else {
    number = double.tryParse(raw);
    if (number == null) {
      final date = RegExp(
              r'^(\d{4})-(\d\d)-(\d\d)(?:[ T]+(\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?)?\s*(Z|[+-]\d\d:\d\d)?$')
          .firstMatch(raw);
      final time =
          RegExp(r'^(\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?\s*(Z|[+-]\d\d:\d\d)?$')
              .firstMatch(raw);
      if (date == null && time == null) return null;
      final year = date == null ? 2000 : int.parse(date[1]!);
      final month = date == null ? 1 : int.parse(date[2]!);
      final day = date == null ? 1 : int.parse(date[3]!);
      final hour = int.parse(date?[4] ?? time?[1] ?? '0');
      final minute = int.parse(date?[5] ?? time?[2] ?? '0');
      final second = int.parse(date?[6] ?? time?[3] ?? '0');
      final fraction = double.parse(date?[7] ?? time?[4] ?? '0');
      if (month < 1 ||
          month > 12 ||
          day < 1 ||
          day > 31 ||
          hour > 24 ||
          minute > 59 ||
          second > 59) {
        return null;
      }
      final millis = math.min(999, (fraction * 1000 + 0.5).floor());
      moment = DateTime.utc(year, month, day, hour, minute, second, millis);
      retain24 = hour == 24;
      final zone = date?[8] ?? time?[5];
      if (zone != null && zone != 'Z') {
        final zh = int.parse(zone.substring(1, 3)),
            zm = int.parse(zone.substring(4, 6));
        if (zh > 14 || zm > 59) return null;
        moment = moment.subtract(
            Duration(minutes: (zh * 60 + zm) * (zone[0] == '-' ? -1 : 1)));
        retain24 = false;
      }
    }
  }
  DateTime? fromJulian(double value) {
    if (!value.isFinite || value < 0 || value >= 5373484.5) return null;
    return DateTime.fromMillisecondsSinceEpoch(
        ((value - _epoch) * _day).round(),
        isUtc: true);
  }

  if (number != null) {
    if (args.isNotEmpty &&
        ['unixepoch', 'auto', 'julianday'].contains(asciiLower(args.first))) {
      final mode = asciiLower(args.removeAt(0));
      if (mode == 'unixepoch' ||
          mode == 'auto' && (number < 0 || number >= 5373484.5)) {
        if (!number.isFinite ||
            number < -210866760000 ||
            number >= 253402300800) {
          return null;
        }
        moment = DateTime.fromMillisecondsSinceEpoch((number * 1000).round(),
            isUtc: true);
      } else {
        moment = fromJulian(number);
      }
    } else {
      moment = fromJulian(number);
    }
  }
  if (moment == null) return null;
  DateTime? floorAlternative;
  for (final rawModifier in args) {
    final modifier = asciiLower(rawModifier.trim());
    if (modifier == 'subsec' || modifier == 'subsecond') {
      subsec = true;
      continue;
    }
    if (modifier == 'floor') {
      moment = floorAlternative ?? moment;
      floorAlternative = null;
      retain24 = false;
      continue;
    }
    if (modifier == 'ceiling') {
      floorAlternative = null;
      retain24 = false;
      continue;
    }
    floorAlternative = null;
    retain24 = false;
    if (modifier == 'localtime') {
      moment = moment!.toLocal();
      continue;
    }
    if (modifier == 'utc') {
      moment = DateTime(moment!.year, moment.month, moment.day, moment.hour,
              moment.minute, moment.second, moment.millisecond)
          .toUtc();
      continue;
    }
    if (modifier.startsWith('start of ')) {
      moment = switch (modifier) {
        'start of day' => DateTime.utc(moment!.year, moment.month, moment.day),
        'start of month' => DateTime.utc(moment!.year, moment.month, 1),
        'start of year' => DateTime.utc(moment!.year, 1, 1),
        _ => null
      };
      if (moment == null) return null;
      continue;
    }
    final weekday = RegExp(r'^weekday ([0-6])$').firstMatch(modifier);
    if (weekday != null) {
      moment = moment!.add(Duration(
          days: (int.parse(weekday[1]!) - moment.weekday % 7 + 7) % 7));
      continue;
    }
    final calendar = RegExp(
            r'^([+-])(\d{4})-(\d\d)-(\d\d)(?: (\d\d):(\d\d):(\d\d)(\.\d+)?)?$')
        .firstMatch(modifier);
    final clock = RegExp(r'^([+-])(\d\d):(\d\d)(?::(\d\d)(\.\d+)?)?$')
        .firstMatch(modifier);
    if (calendar != null || clock != null) {
      final sign = (calendar?[1] ?? clock![1]) == '-' ? -1 : 1;
      final years = calendar == null ? 0 : int.parse(calendar[2]!);
      final months = calendar == null ? 0 : int.parse(calendar[3]!);
      final days = calendar == null ? 0 : int.parse(calendar[4]!);
      final hours = int.parse(calendar?[5] ?? clock?[2] ?? '0'),
          minutes = int.parse(calendar?[6] ?? clock?[3] ?? '0'),
          seconds = int.parse(calendar?[7] ?? clock?[4] ?? '0');
      final fraction = double.parse(calendar?[8] ?? clock?[5] ?? '0');
      if (months > 11 ||
          days > 30 ||
          hours > 23 ||
          minutes > 59 ||
          seconds > 59) {
        return null;
      }
      final old = moment!;
      final year = old.year + sign * years;
      final month = old.month + sign * months;
      if (year < -5000 || year > 11000) return null;
      moment = DateTime.utc(year, month, old.day, old.hour, old.minute,
              old.second, old.millisecond)
          .add(Duration(
              milliseconds: sign *
                  (days * _day +
                      hours * 3600000 +
                      minutes * 60000 +
                      seconds * 1000 +
                      (fraction * 1000).round())));
      continue;
    }
    final shift = RegExp(
            r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+)) (day|hour|minute|second|month|year)s?$')
        .firstMatch(modifier);
    if (shift == null) return null;
    final amount = double.parse(shift[1]!);
    if (!amount.isFinite || amount.abs() > 1e9) return null;
    final unit = shift[2]!;
    if (unit == 'month' || unit == 'year') {
      final whole = amount.truncate();
      final old = moment!;
      final year = old.year + (unit == 'year' ? whole : 0);
      final month = old.month + (unit == 'month' ? whole : 0);
      if (year < -5000 || year > 11000 || month.abs() > 200000) return null;
      final first = DateTime.utc(year, month, 1);
      final lastDay = DateTime.utc(first.year, first.month + 1, 0).day;
      moment = DateTime.utc(year, month, old.day, old.hour, old.minute,
          old.second, old.millisecond);
      if (old.day > lastDay) {
        floorAlternative = DateTime.utc(first.year, first.month, lastDay,
            old.hour, old.minute, old.second, old.millisecond);
      }
      final fractional =
          ((amount - whole) * (unit == 'year' ? 365 : 30) * _day).round();
      moment = moment.add(Duration(milliseconds: fractional));
      floorAlternative =
          floorAlternative?.add(Duration(milliseconds: fractional));
    } else {
      final scale = switch (unit) {
        'day' => _day,
        'hour' => 3600000,
        'minute' => 60000,
        _ => 1000
      };
      final millis = (amount * scale).round();
      if ((moment!.millisecondsSinceEpoch + millis).abs() > 8640000000000000) {
        return null;
      }
      moment = moment.add(Duration(milliseconds: millis));
    }
  }
  final instant = moment!;
  final julian = instant.millisecondsSinceEpoch / _day + _epoch;
  if (julian < 0 || julian >= 5373484.5) return null;
  final display =
      retain24 ? instant.subtract(const Duration(days: 1)) : instant;
  String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
  String year(int n) => n < 0 ? '-${pad(-n, 4)}' : pad(n, 4);
  final date =
      '${year(display.year)}-${pad(display.month)}-${pad(display.day)}';
  final h = retain24 ? 24 : display.hour;
  final seconds =
      '${pad(display.second)}${subsec ? '.${pad(display.millisecond, 3)}' : ''}';
  final time = '${pad(h)}:${pad(display.minute)}:$seconds';
  if (key == 'julianday') return julian;
  if (key == 'unixepoch') {
    return subsec
        ? instant.millisecondsSinceEpoch / 1000
        : BigInt.from((instant.millisecondsSinceEpoch / 1000).floor());
  }
  if (key == 'date') return date;
  if (key == 'time') return time;
  if (key == 'datetime') return '$date $time';
  final midnight = DateTime.utc(display.year, display.month, display.day);
  final dayOfYear =
      midnight.difference(DateTime.utc(display.year, 1, 1)).inDays + 1;
  final thursday = midnight.add(Duration(days: 4 - midnight.weekday));
  final isoFirst = DateTime.utc(thursday.year, 1, 4);
  final isoMonday = isoFirst.subtract(Duration(days: isoFirst.weekday - 1));
  final isoWeek = midnight.difference(isoMonday).inDays ~/ 7 + 1;
  final specs = <String, String>{
    'd': pad(display.day),
    'e': display.day.toString().padLeft(2),
    'F': date,
    'f': '${pad(display.second)}.${pad(display.millisecond, 3)}',
    'G': year(thursday.year),
    'g': pad(thursday.year % 100),
    'H': pad(h),
    'I': pad(h % 12 == 0 ? 12 : h % 12),
    'j': pad(dayOfYear, 3),
    'J': sqlRealText(julian, 16),
    'k': h.toString().padLeft(2),
    'l': (h % 12 == 0 ? 12 : h % 12).toString().padLeft(2),
    'm': pad(display.month),
    'M': pad(display.minute),
    'p': h % 24 < 12 ? 'AM' : 'PM',
    'P': h % 24 < 12 ? 'am' : 'pm',
    'R': '${pad(h)}:${pad(display.minute)}',
    's': (instant.millisecondsSinceEpoch / 1000).floor().toString(),
    'S': pad(display.second),
    'T': '${pad(h)}:${pad(display.minute)}:${pad(display.second)}',
    'u': display.weekday.toString(),
    'U': pad((dayOfYear - 1 + 7 - display.weekday % 7) ~/ 7),
    'V': pad(isoWeek),
    'w': (display.weekday % 7).toString(),
    'W': pad((dayOfYear - 1 + 7 - (display.weekday - 1)) ~/ 7),
    'Y': year(display.year),
    '%': '%',
  };
  if (subsec) {
    specs['s'] = (instant.millisecondsSinceEpoch / 1000).toStringAsFixed(3);
  }
  final result = StringBuffer();
  for (var i = 0; i < format!.length; i++) {
    if (format[i] != '%') {
      result.write(format[i]);
      continue;
    }
    if (++i == format.length || !specs.containsKey(format[i])) return null;
    result.write(specs[format[i]]);
    if (result.length > 16 * 1024 * 1024) {
      throw const SqlException('Function output limit exceeded');
    }
  }
  return result.toString();
}
