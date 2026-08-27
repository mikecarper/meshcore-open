import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/lora_ota_route_planner.dart';

void main() {
  test('switches and restores farthest routes before nearer routes', () {
    final ordered = loraOtaFarthestFirst(<({String name, int routeBytes})>[
      (name: 'near', routeBytes: 1),
      (name: 'far', routeBytes: 4),
      (name: 'middle', routeBytes: 2),
    ], (entry) => entry.routeBytes);

    expect(ordered.map((entry) => entry.name), <String>[
      'far',
      'middle',
      'near',
    ]);
  });

  test('preserves route-plan order for equal-depth branches', () {
    final ordered = loraOtaFarthestFirst(<String>[
      'first',
      'second',
      'near',
    ], (entry) => entry == 'near' ? 1 : 2);

    expect(ordered, <String>['first', 'second', 'near']);
  });

  test('dependencies beat path length when temporary routes differ', () {
    final near = (
      name: 'near',
      publicKey: <int>[0xA1],
      route: <int>[0xC1, 0xC2, 0xC3],
    );
    final far = (name: 'far', publicKey: <int>[0xB2], route: <int>[0xA1]);

    final ordered = loraOtaDependencyFirst(
      <({String name, List<int> publicKey, List<int> route})>[near, far],
      routeBytes: (entry) => entry.route,
      destinationPublicKey: (entry) => entry.publicKey,
      pathHashByteWidth: 1,
    );

    // Far traverses near, so far must switch first even though near's
    // alternate passive path contains more bytes.
    expect(ordered.map((entry) => entry.name), <String>['far', 'near']);
  });

  test('ignores passive hashes that are not controlled endpoints', () {
    final ordered = loraOtaDependencyFirst(
      <({String name, List<int> publicKey, List<int> route})>[
        (name: 'first', publicKey: <int>[0x11], route: <int>[0xE1, 0xE2]),
        (name: 'second', publicKey: <int>[0x22], route: <int>[0xE3]),
      ],
      routeBytes: (entry) => entry.route,
      destinationPublicKey: (entry) => entry.publicKey,
      pathHashByteWidth: 1,
    );

    expect(ordered.map((entry) => entry.name), <String>['first', 'second']);
  });

  test('rejects cycles and controlled route-hash collisions', () {
    expect(
      () => loraOtaDependencyFirst(
        <({List<int> publicKey, List<int> route})>[
          (publicKey: <int>[0x11], route: <int>[0x22]),
          (publicKey: <int>[0x22], route: <int>[0x11]),
        ],
        routeBytes: (entry) => entry.route,
        destinationPublicKey: (entry) => entry.publicKey,
        pathHashByteWidth: 1,
      ),
      throwsA(isA<LoraOtaRoutePlanException>()),
    );
    expect(
      () => loraOtaDependencyFirst(
        <({List<int> publicKey, List<int> route})>[
          (publicKey: <int>[0x44, 0x01], route: <int>[]),
          (publicKey: <int>[0x44, 0x02], route: <int>[]),
        ],
        routeBytes: (entry) => entry.route,
        destinationPublicKey: (entry) => entry.publicKey,
        pathHashByteWidth: 1,
      ),
      throwsA(isA<LoraOtaRoutePlanException>()),
    );
  });
}
