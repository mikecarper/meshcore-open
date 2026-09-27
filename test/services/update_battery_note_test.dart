import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/update_battery_note.dart';

void main() {
  final now = DateTime(2026, 9, 26, 12);

  test('shows only a positive recent voltage', () {
    expect(
      updateBatteryNote(
        millivolts: 3800,
        reportedAt: now.subtract(const Duration(minutes: 1)),
        now: now,
      ),
      contains('3.80 V'),
    );
    expect(
      updateBatteryNote(millivolts: 0, reportedAt: now, now: now),
      isEmpty,
    );
    expect(
      updateBatteryNote(millivolts: null, reportedAt: now, now: now),
      isEmpty,
    );
    expect(
      updateBatteryNote(
        millivolts: 3800,
        reportedAt: now.subtract(const Duration(minutes: 16)),
        now: now,
      ),
      isEmpty,
    );
  });
}
