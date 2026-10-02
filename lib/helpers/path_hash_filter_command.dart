/// Builds a width-only forwarding rule without overwriting an occupied slot.
/// The receiving firmware must support `hashbytes` / `pb` selectors.
String buildPathHashFilterCommand({
  required int hashBytes,
  String mode = 'radio',
  int? ratePerMinute,
}) {
  if (hashBytes < 0 || hashBytes > 3) {
    throw ArgumentError.value(hashBytes, 'hashBytes', 'Must be 0, 1, 2, or 3');
  }
  const modes = {
    'radio': 'r',
    'bridge': 'b',
    'cross': 'c',
    'bridge,cross': 'bc',
  };
  final shortMode = modes[mode];
  if (shortMode == null) {
    throw ArgumentError.value(mode, 'mode', 'Unsupported admission path');
  }
  if (ratePerMinute != null && (ratePerMinute < 1 || ratePerMinute > 65534)) {
    throw ArgumentError.value(
      ratePerMinute,
      'ratePerMinute',
      'Must be 1–65534',
    );
  }
  final width = hashBytes == 0 ? '*' : '$hashBytes';
  final transport = mode == 'radio' ? '' : ' m=$shortMode';
  final action = ratePerMinute == null ? 'd' : 'q=$ratePerMinute';
  return 'set fr any pb=$width$transport $action';
}
