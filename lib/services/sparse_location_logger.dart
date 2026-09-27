import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:gpx/gpx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Opt-in phone GPS tracking. Tracks are retained even when sharing is canceled.
class SparseLocationLogger {
  static const double distanceThresholdMeters = 0.25 * 1609.34;
  static const double headingChangeThresholdDeg = 35;
  static const double minSpeedForTurnKmh = 8;
  static const _settings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 152,
    timeLimit: Duration(seconds: 30),
  );

  SparseLocationLogger({
    Future<bool> Function()? requestAccess,
    Stream<Position> Function()? positions,
    Future<Position> Function()? currentPosition,
    Future<Directory> Function()? documentsDirectory,
    Future<void> Function(String)? shareTrack,
  }) : _requestAccess = requestAccess ?? _requestLocationAccess,
       _positions =
           positions ??
           (() => Geolocator.getPositionStream(
             locationSettings: const LocationSettings(
               accuracy: LocationAccuracy.high,
               distanceFilter: 152,
             ),
           )),
       _currentPosition =
           currentPosition ??
           (() => Geolocator.getCurrentPosition(locationSettings: _settings)),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _shareTrack = shareTrack ?? _shareFile;

  final Future<bool> Function() _requestAccess;
  final Stream<Position> Function() _positions;
  final Future<Position> Function() _currentPosition;
  final Future<Directory> Function() _documentsDirectory;
  final Future<void> Function(String) _shareTrack;
  Future<void> Function(Position)? _onNewLogPoint;
  StreamSubscription<Position>? _positionStream;
  Future<bool>? _starting;
  Future<void> _pending = Future<void>.value();
  Position? _lastPosition;
  Gpx _gpx = Gpx();
  Trkseg _segment = Trkseg();
  File? _gpxFile;
  bool _disposed = false;
  Object? lastError;

  void initialize(Future<void> Function(Position) onNewLogPoint) {
    _onNewLogPoint = onNewLogPoint;
  }

  static Future<bool> _requestLocationAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  static Future<void> _shareFile(String path) async {
    await SharePlus.instance.share(
      ShareParams(
        text: 'Sparse GPS track',
        subject: 'Sparse GPS track',
        files: [XFile(path)],
      ),
    );
  }

  Future<bool> startLogging() async {
    if (_disposed) return false;
    if (isLogging()) return true;
    if (_starting != null) return _starting!;
    final operation = _startLogging();
    _starting = operation;
    try {
      return await operation;
    } finally {
      _starting = null;
    }
  }

  Future<bool> _startLogging() async {
    lastError = null;
    if (!await _requestAccess() || _disposed) return false;
    final directory = await _documentsDirectory();
    if (_disposed) return false;
    _lastPosition = null;
    _segment = Trkseg();
    _gpx = Gpx()
      ..creator = 'MeshCore Open'
      ..trks.add(Trk(name: 'Sparse phone GPS track', trksegs: [_segment]));
    _gpxFile = File(
      '${directory.path}/track_${DateTime.now().microsecondsSinceEpoch}.gpx',
    );
    _positionStream = _positions().listen(
      (position) {
        _pending = _pending.then((_) => _record(position)).catchError((
          Object error,
        ) {
          lastError = error;
        });
      },
      onError: (Object error) {
        lastError = error;
      },
    );
    return true;
  }

  Future<void> stopLogging({bool share = true}) async {
    await _starting;
    final subscription = _positionStream;
    _positionStream = null;
    await subscription?.cancel();
    await _pending;
    if (subscription != null && share && _segment.trkpts.isNotEmpty) {
      await _shareTrack(_gpxFile!.path);
    }
  }

  Future<bool> updateMyLocation() async {
    if (_disposed || !await _requestAccess()) return false;
    final position = await _currentPosition();
    if (_disposed) return false;
    await _onNewLogPoint?.call(position);
    return true;
  }

  Future<void> _record(Position position) async {
    if (_disposed) return;
    final last = _lastPosition;
    if (last != null) {
      final distance = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        position.latitude,
        position.longitude,
      );
      var turn = (position.heading - last.heading).abs() % 360;
      turn = math.min(turn, 360 - turn);
      if (distance < distanceThresholdMeters &&
          !(position.speed * 3.6 > minSpeedForTurnKmh &&
              last.heading >= 0 &&
              position.heading >= 0 &&
              turn > headingChangeThresholdDeg)) {
        return;
      }
    }
    _segment.trkpts.add(
      Wpt(
        lat: position.latitude,
        lon: position.longitude,
        ele: position.altitude,
        time: position.timestamp,
        extensions: {
          if (position.heading.isFinite) 'course': position.heading,
          if (position.speed > 0) 'speed': position.speed,
        },
      ),
    );
    // Persist each sampled point before attempting a radio update.
    await _gpxFile!.writeAsString(GpxWriter().asString(_gpx, pretty: true));
    _lastPosition = position;
    await _onNewLogPoint?.call(position);
  }

  /// Quantize transmitted coordinates; GPX keeps the original phone position.
  Position snapToGridCenter({
    required Position position,
    double cellSizeDegrees = 0.001,
  }) {
    if (!cellSizeDegrees.isFinite || cellSizeDegrees <= 0) {
      throw ArgumentError.value(cellSizeDegrees, 'cellSizeDegrees');
    }
    double snap(double value, double limit) =>
        (((value / cellSizeDegrees).floor() + 0.5) * cellSizeDegrees)
            .clamp(-limit, limit)
            .toDouble();
    return Position(
      latitude: snap(position.latitude, 90),
      longitude: snap(position.longitude, 180),
      timestamp: position.timestamp,
      accuracy: position.accuracy,
      altitude: position.altitude,
      altitudeAccuracy: position.altitudeAccuracy,
      heading: position.heading,
      headingAccuracy: position.headingAccuracy,
      speed: position.speed,
      speedAccuracy: position.speedAccuracy,
    );
  }

  Future<String> getGpxFilePath() async => _gpxFile?.path ?? 'Not started';
  bool isLogging() => _positionStream != null;
  int getPointCount() => _segment.trkpts.length;

  void dispose() {
    _disposed = true;
    unawaited(_positionStream?.cancel());
    _positionStream = null;
  }
}
