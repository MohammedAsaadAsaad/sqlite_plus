import 'tokenizer.dart';
import 'values.dart';

const percentileFunctionNames = {
  'median',
  'percentile',
  'percentile_cont',
  'percentile_disc',
};

/// Percentile's fraction is checked even for NULL inputs and remains fixed
/// after the first step. Numeric strings are accepted only for the fraction.
final class PercentileValidator {
  PercentileValidator(this.name, {this.fraction});
  final String name;
  double? fraction;

  double? step(List<Object?> arguments) {
    if (name == 'median') {
      fraction = 0.5;
    } else {
      final argument = arguments[1];
      final Object? number;
      if (argument is String) {
        final text = argument.split('\u0000').first;
        number =
            RegExp(r'^[\t\n\v\f\r ]*[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[\t\n\v\f\r ]*$')
                    .hasMatch(text)
                ? numeric(text)
                : null;
      } else {
        number = argument;
      }
      final value = number is BigInt
          ? number.toDouble()
          : number is double
              ? number
              : double.nan;
      final maximum = name == 'percentile' ? 100.0 : 1.0;
      if (!value.isFinite || value < 0 || value > maximum) {
        throw SqlException(
            'The fraction argument to $name() is not between 0.0 and $maximum');
      }
      final normalized = value / maximum;
      if (fraction != null && (fraction! - normalized).abs() > 0.001) {
        throw SqlException(
            'The fraction argument to $name() is not the same for all input rows');
      }
      fraction ??= normalized;
    }
    final argument = arguments.first;
    if (argument == null) return null;
    if (argument is! BigInt && argument is! double) {
      throw SqlException('Input to $name() is not numeric');
    }
    final value = argument is BigInt ? argument.toDouble() : argument as double;
    if (!value.isFinite) {
      throw SqlException('Inf input to $name()');
    }
    return value;
  }
}

Object? percentileAggregate(String name, Iterable<List<Object?>> arguments,
    {double? fraction}) {
  final validator = PercentileValidator(name, fraction: fraction);
  final values = <double>[];
  for (final row in arguments) {
    final value = validator.step(row);
    if (value != null) values.add(value);
  }
  if (values.isEmpty) return null;
  values.sort();
  final position = validator.fraction! * (values.length - 1);
  final lower = position.floor();
  if (name == 'percentile_disc' || position == lower) return values[lower];
  // Preserve the reference's arithmetic, including overflow between finite
  // endpoints with opposite signs.
  return values[lower] +
      (values[lower + 1] - values[lower]) * (position - lower);
}
