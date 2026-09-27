import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gpx/gpx.dart';
import 'package:meshcore_open/services/sparse_location_logger.dart';

Position position(
  double lat,
  double lon, {
  double heading = 0,
  double speed = 0,
}) => Position(
  latitude: lat,
  longitude: lon,
  timestamp: DateTime.utc(2026),
  accuracy: 1,
  altitude: 1,
  altitudeAccuracy: 1,
  heading: heading,
  headingAccuracy: 1,
  speed: speed,
  speedAccuracy: 1,
);

void main() {
  late Directory directory;
  late StreamController<Position> positions;
  late SparseLocationLogger logger;
  late List<Position> updates;
  late List<String> shares;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('meshcore-gps-test-');
    positions = StreamController<Position>.broadcast();
    updates = [];
    shares = [];
    logger =
        SparseLocationLogger(
          requestAccess: () async => true,
          positions: () => positions.stream,
          currentPosition: () async => position(47, -122),
          documentsDirectory: () async => directory,
          shareTrack: (path) async {
            shares.add(path);
          },
        )..initialize((point) async {
          updates.add(point);
        });
  });
  tearDown(() async {
    await logger.stopLogging(share: false);
    logger.dispose();
    await positions.close();
    await directory.delete(recursive: true);
  });

  test('concurrent starts create only one subscription', () async {
    expect(await Future.wait([logger.startLogging(), logger.startLogging()]), [
      true,
      true,
    ]);
    expect(logger.isLogging(), isTrue);
  });

  test('denied permission does not subscribe or create a track', () async {
    final denied = SparseLocationLogger(requestAccess: () async => false);
    expect(await denied.startLogging(), isFalse);
    expect(await denied.updateMyLocation(), isFalse);
    expect(denied.isLogging(), isFalse);
    denied.dispose();
  });

  test('samples distance and turns and retains exported file', () async {
    await logger.startLogging();
    positions.add(position(47, -122));
    positions.add(position(47.0001, -122)); // Stationary jitter.
    positions.add(position(47.005, -122));
    positions.add(position(47.0051, -122, heading: 90, speed: 5));
    await Future<void>.delayed(Duration.zero);
    await logger.stopLogging();
    expect(updates, hasLength(3));
    expect(logger.getPointCount(), 3);
    expect(shares, hasLength(1));
    final file = File(shares.single);
    expect(await file.exists(), isTrue);
    expect(
      GpxReader()
          .fromString(await file.readAsString())
          .trks
          .single
          .trksegs
          .single
          .trkpts,
      hasLength(3),
    );
    expect(logger.isLogging(), isFalse);
  });

  test('a radio update failure does not lose the saved point', () async {
    logger.initialize((_) async => throw StateError('Disconnected'));
    await logger.startLogging();
    positions.add(position(47, -122));
    await Future<void>.delayed(Duration.zero);
    await logger.stopLogging(share: false);
    expect(logger.lastError, isA<StateError>());
    expect(await File(await logger.getGpxFilePath()).exists(), isTrue);
    expect(shares, isEmpty);
  });

  test(
    'explicit update awaits the callback without creating a track',
    () async {
      expect(await logger.updateMyLocation(), isTrue);
      expect(updates, hasLength(1));
      expect(logger.isLogging(), isFalse);
      expect(logger.getPointCount(), 0);
    },
  );

  test('coordinate grid uses degrees and handles negative longitude', () {
    final snapped = logger.snapToGridCenter(
      position: position(47.1234, -122.1234),
    );
    expect(snapped.latitude, closeTo(47.1235, 0.000001));
    expect(snapped.longitude, closeTo(-122.1235, 0.000001));
    expect(
      () => logger.snapToGridCenter(
        position: position(47, -122),
        cellSizeDegrees: 0,
      ),
      throwsArgumentError,
    );
  });

  test('disposed logger cannot resume tracking', () async {
    logger.dispose();
    expect(await logger.startLogging(), isFalse);
    expect(await logger.updateMyLocation(), isFalse);
  });
}
