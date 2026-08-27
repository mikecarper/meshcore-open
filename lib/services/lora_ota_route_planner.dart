List<T> loraOtaFarthestFirst<T>(
  Iterable<T> values,
  int Function(T value) routeByteLength,
) {
  final indexed = values.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final distance = routeByteLength(
      right.$2,
    ).compareTo(routeByteLength(left.$2));
    return distance != 0 ? distance : left.$1.compareTo(right.$1);
  });
  return indexed.map((entry) => entry.$2).toList(growable: false);
}

class LoraOtaRoutePlanException implements Exception {
  final String message;

  const LoraOtaRoutePlanException(this.message);

  @override
  String toString() => message;
}

/// Orders controlled endpoints so every node that traverses another
/// controlled endpoint is switched first. Passive route hashes are ignored.
/// Independent branches fall back to longest-route-first and then preserve
/// their original order.
List<T> loraOtaDependencyFirst<T>(
  Iterable<T> values, {
  required List<int> Function(T value) routeBytes,
  required List<int> Function(T value) destinationPublicKey,
  required int pathHashByteWidth,
}) {
  if (pathHashByteWidth < 1 || pathHashByteWidth > 4) {
    throw const LoraOtaRoutePlanException('Path-hash width must be 1-4 bytes');
  }
  final entries = values.toList(growable: false);
  final destinationByHash = <String, int>{};
  for (var index = 0; index < entries.length; index++) {
    final key = destinationPublicKey(entries[index]);
    if (key.length < pathHashByteWidth) {
      throw const LoraOtaRoutePlanException(
        'A controlled endpoint has an invalid public key',
      );
    }
    final hash = _routeHashKey(key, 0, pathHashByteWidth);
    if (destinationByHash.containsKey(hash)) {
      throw LoraOtaRoutePlanException(
        'Controlled endpoints share route hash $hash; use a wider path-hash mode',
      );
    }
    destinationByHash[hash] = index;
  }

  final outgoing = List<Set<int>>.generate(entries.length, (_) => <int>{});
  final incoming = List<int>.filled(entries.length, 0);
  for (var source = 0; source < entries.length; source++) {
    final route = routeBytes(entries[source]);
    if (route.length % pathHashByteWidth != 0) {
      throw const LoraOtaRoutePlanException(
        'A route does not match the active path-hash width',
      );
    }
    for (var offset = 0; offset < route.length; offset += pathHashByteWidth) {
      final dependency =
          destinationByHash[_routeHashKey(route, offset, pathHashByteWidth)];
      if (dependency == null) continue;
      if (dependency == source) {
        throw const LoraOtaRoutePlanException(
          'A controlled endpoint appears inside its own route',
        );
      }
      // source traverses dependency, so source must be switched/restored first.
      if (outgoing[source].add(dependency)) incoming[dependency]++;
    }
  }

  final ready = <int>[
    for (var index = 0; index < entries.length; index++)
      if (incoming[index] == 0) index,
  ];
  void sortReady() {
    ready.sort((left, right) {
      final distance = routeBytes(
        entries[right],
      ).length.compareTo(routeBytes(entries[left]).length);
      return distance != 0 ? distance : left.compareTo(right);
    });
  }

  sortReady();
  final result = <T>[];
  while (ready.isNotEmpty) {
    final source = ready.removeAt(0);
    result.add(entries[source]);
    for (final dependency in outgoing[source]) {
      incoming[dependency]--;
      if (incoming[dependency] == 0) ready.add(dependency);
    }
    sortReady();
  }
  if (result.length != entries.length) {
    throw const LoraOtaRoutePlanException(
      'Controlled routes contain a dependency cycle',
    );
  }
  return result;
}

String _routeHashKey(List<int> bytes, int offset, int width) {
  return bytes
      .sublist(offset, offset + width)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
