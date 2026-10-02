import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/path_hash_filter_command.dart';

void main() {
  test('width-only rules use a free slot, support wildcard and all widths', () {
    expect(buildPathHashFilterCommand(hashBytes: 0), 'set fr any pb=* d');
    for (final width in [1, 2, 3]) {
      expect(
        buildPathHashFilterCommand(hashBytes: width),
        'set fr any pb=$width d',
      );
    }
  });

  test('transport modes and rate limits use supported compact options', () {
    for (final entry in {
      'radio': '',
      'bridge': ' m=b',
      'cross': ' m=c',
      'bridge,cross': ' m=bc',
    }.entries) {
      expect(
        buildPathHashFilterCommand(
          hashBytes: 2,
          mode: entry.key,
          ratePerMinute: 10,
        ),
        'set fr any pb=2${entry.value} q=10',
      );
    }
  });

  test('invalid values cannot become commands', () {
    for (final width in [-1, 4, 255]) {
      expect(
        () => buildPathHashFilterCommand(hashBytes: width),
        throwsArgumentError,
      );
    }
    for (final mode in ['all', 'radio,cross', 'radio d']) {
      expect(
        () => buildPathHashFilterCommand(hashBytes: 1, mode: mode),
        throwsArgumentError,
      );
    }
    for (final rate in [0, -1, 65535]) {
      expect(
        () => buildPathHashFilterCommand(hashBytes: 1, ratePerMinute: rate),
        throwsArgumentError,
      );
    }
  });
}
