import 'package:test/test.dart';

import '../benchmark/scenarios_10k.dart';

void main() {
  test('a row count above 10000 is rejected', () {
    expect(measureScenarios(rows: 10001, samples: 1, includeFile: false),
        throwsArgumentError);
    expect(measureScenarios(rows: 0, samples: 1, includeFile: false),
        throwsArgumentError);
    expect(measureScenarios(rows: 1, samples: 0, includeFile: false),
        throwsArgumentError);
  });

  test('two memory rows keep the scenario shape', () async {
    final result =
        await measureScenarios(rows: 2, samples: 1, includeFile: false);
    expect(result['rows'], 2);
    expect(result['row_ceiling'], 10000);
    expect(result['samples'], 1);
    expect(result['sizes_not_run'], [100000, 1000000]);
    expect(result['cold_definition'], isA<String>());
    expect(result['warm_definition'], isA<String>());
    _expectOperation(result['memory_sql'], 'insert', 1);
    _expectOperation(result['memory_sql'], 'point_cold', 1);
    _expectOperation(result['memory_sql'], 'point_warm', 1);
    _expectOperation(result['memory_sql'], 'range_cold', 1);
    _expectOperation(result['memory_sql'], 'update', 1);
    _expectOperation(result['memory_sql'], 'delete', 1);
    _expectOperation(result['memory_orm'], 'track', 1);
    _expectOperation(result['memory_orm'], 'save', 1);
    _expectOperation(result['memory_orm'], 'point_cold', 1);
    expect((result['memory_sql'] as Map)['image_bytes'], hasLength(1));
    expect((result['memory_orm'] as Map)['image_bytes'], hasLength(1));
    final file = result['file_sql'] as Map;
    expect(file['ran'], isFalse);
    expect(result['peak_process_rss_bytes'], isA<int>());
  });
}

void _expectOperation(Object? scenario, String name, int samples) {
  final operation = (scenario as Map)[name] as Map;
  expect(operation['microseconds'], hasLength(samples));
  expect(operation['population_variance'], isA<int>());
  expect(operation['rows_per_second'], hasLength(samples));
}
