import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/contact_proximity.dart';
import 'package:meshcore_open/models/app_settings.dart';

void main() {
  test('distance and direction follow radio coordinates', () {
    final east = ContactProximity.between(45, -122, 45, -121);
    expect(east, isNotNull);
    expect(east!.direction, 'E');
    expect(east.distanceKm, closeTo(78.6, 0.5));
    expect(east.format(UnitSystem.metric), '79 km E');
    expect(east.format(UnitSystem.imperial), '49 mi E');
  });

  test('missing and invalid radio coordinates do not invent proximity', () {
    expect(ContactProximity.between(null, null, 45, -121), isNull);
    expect(ContactProximity.between(0, 0, 45, -121), isNull);
    expect(ContactProximity.between(45, -122, 100, -121), isNull);
  });
}
