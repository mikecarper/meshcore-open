/// A stale or absent reading should not look like a live power check.
String updateBatteryNote({
  required int? millivolts,
  required DateTime? reportedAt,
  DateTime? now,
}) {
  if (millivolts == null || millivolts <= 0 || reportedAt == null) return '';
  final age = (now ?? DateTime.now()).difference(reportedAt);
  if (age.isNegative || age > const Duration(minutes: 15)) return '';
  return ' Last reported battery: '
      '${(millivolts / 1000).toStringAsFixed(2)} V.';
}
