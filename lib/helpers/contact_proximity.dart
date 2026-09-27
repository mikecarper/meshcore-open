import 'dart:math' as math;

import '../models/app_settings.dart';

class ContactProximity {
  const ContactProximity(this.distanceKm, this.direction);

  final double distanceKm;
  final String direction;

  String format(UnitSystem units) {
    final distance = units == UnitSystem.imperial
        ? distanceKm * 0.621371
        : distanceKm;
    final suffix = units == UnitSystem.imperial ? 'mi' : 'km';
    return '${distance < 10 ? distance.toStringAsFixed(1) : distance.toStringAsFixed(0)} $suffix $direction';
  }

  static ContactProximity? between(
    double? fromLat,
    double? fromLon,
    double? toLat,
    double? toLon,
  ) {
    if (!_valid(fromLat, fromLon) || !_valid(toLat, toLon)) return null;
    final lat1 = fromLat! * math.pi / 180;
    final lat2 = toLat! * math.pi / 180;
    final dLat = lat2 - lat1;
    final dLon = (toLon! - fromLon!) * math.pi / 180;
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
    final distance = 6371.0088 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final bearing = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return ContactProximity(distance, directions[((bearing + 22.5) ~/ 45) % 8]);
  }

  static bool _valid(double? lat, double? lon) =>
      lat != null &&
      lon != null &&
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180 &&
      (lat.abs() > 0.000001 || lon.abs() > 0.000001);
}
