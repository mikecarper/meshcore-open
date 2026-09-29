import 'dart:convert';

typedef LoraOtaHopCommand = Future<String> Function(String command);

int loraOtaMinimumHopLimit(Iterable<List<int>> routes, int hashWidth) {
  if (hashWidth < 1 || hashWidth > 4) {
    throw const FormatException('Path-hash width must be 1-4 bytes.');
  }
  var minimum = 0;
  for (final route in routes) {
    if (route.length % hashWidth != 0) {
      throw const FormatException('Route does not match the path-hash width.');
    }
    final hops = route.length ~/ hashWidth;
    if (hops > 8) {
      throw StateError('LoRa OTA supports a maximum of eight relay hops.');
    }
    if (hops > minimum) minimum = hops;
  }
  return minimum;
}

int parseLoraOtaHops(String reply) {
  final lines = const LineSplitter().convert(reply);
  final config = lines.where(
    (line) => line.trimLeft().startsWith('ota config:'),
  );
  if (config.length != 1) {
    throw FormatException('Missing or ambiguous OTA hop-limit setting: $reply');
  }
  final tokens = RegExp(r'(?:^|\s)hops=([^\s]+)').allMatches(config.single);
  if (tokens.length != 1 || !RegExp(r'^[0-8]$').hasMatch(tokens.single[1]!)) {
    throw FormatException('Invalid OTA hop-limit setting: $reply');
  }
  return int.parse(tokens.single[1]!);
}

bool isLoraOtaOpaqueRelay(String reply) => RegExp(
  r'^(?:ERR\s+)?LoRa OTA is not included in this build(?:[.;].*)?$',
  caseSensitive: false,
).hasMatch(reply.trim());

/// Password-free recovery data, saved before a persistent radio setting changes.
class LoraOtaHopRecovery {
  final String publicKey;
  final String name;
  final bool local;
  final int original;
  final int transfer;
  final List<int> normalPath;
  final List<int> temporaryPath;
  final int hashWidth;

  LoraOtaHopRecovery({
    required this.publicKey,
    required this.name,
    required this.local,
    required this.original,
    required this.transfer,
    required List<int> normalPath,
    required List<int> temporaryPath,
    required this.hashWidth,
  }) : normalPath = List<int>.unmodifiable(normalPath),
       temporaryPath = List<int>.unmodifiable(temporaryPath) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKey) ||
        original < 0 ||
        original > 8 ||
        transfer <= original ||
        transfer > 8) {
      throw const FormatException('Invalid OTA hop-limit recovery record.');
    }
    loraOtaMinimumHopLimit([this.temporaryPath], hashWidth);
    if (this.normalPath.length % hashWidth != 0 ||
        this.normalPath.length > 64 ||
        [
          ...this.normalPath,
          ...this.temporaryPath,
        ].any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Invalid OTA recovery route.');
    }
  }

  String get restoreCommand => 'ota config hops $original';

  Map<String, Object> toJson() => {
    'publicKey': publicKey,
    'name': name,
    'local': local,
    'original': original,
    'transfer': transfer,
    'normalPath': normalPath,
    'temporaryPath': temporaryPath,
    'hashWidth': hashWidth,
  };

  factory LoraOtaHopRecovery.fromJson(Map<String, dynamic> json) =>
      LoraOtaHopRecovery(
        publicKey: json['publicKey'] as String,
        name: json['name'] as String,
        local: json['local'] as bool,
        original: json['original'] as int,
        transfer: json['transfer'] as int,
        normalPath: (json['normalPath'] as List).cast<int>(),
        temporaryPath: (json['temporaryPath'] as List).cast<int>(),
        hashWidth: json['hashWidth'] as int,
      );
}

class LoraOtaHopParticipant {
  final String publicKey;
  final String name;
  final bool local;
  final bool allowOpaque;
  final List<int> normalPath;
  final List<int> temporaryPath;
  final int hashWidth;
  final LoraOtaHopCommand command;

  const LoraOtaHopParticipant({
    required this.publicKey,
    required this.name,
    required this.command,
    this.local = false,
    this.allowOpaque = false,
    this.normalPath = const [],
    this.temporaryPath = const [],
    this.hashWidth = 1,
  });
}

class LoraOtaHopSession {
  final Future<void> Function(List<LoraOtaHopRecovery>) persist;
  final void Function(String) log;
  final List<({LoraOtaHopParticipant node, int original})> _prepared = [];
  final List<({LoraOtaHopParticipant node, LoraOtaHopRecovery record})>
  _pending = [];
  int _minimum = 0;
  bool _preparedReady = false;

  LoraOtaHopSession({required this.persist, required this.log});

  bool get needsRecovery => _pending.isNotEmpty;
  List<LoraOtaHopRecovery> get recovery =>
      _pending.map((entry) => entry.record).toList(growable: false);

  void resumeRecovery(LoraOtaHopParticipant node, LoraOtaHopRecovery record) {
    if (node.publicKey != record.publicKey) {
      throw StateError('OTA hop recovery belongs to a different radio.');
    }
    _pending.add((node: node, record: record));
  }

  Future<void> prepare(List<LoraOtaHopParticipant> nodes, int minimum) async {
    if (minimum < 0 || minimum > 8 || needsRecovery) {
      throw StateError('Invalid OTA route or unresolved hop-limit recovery.');
    }
    _prepared.clear();
    _preparedReady = false;
    _minimum = minimum;
    if (minimum == 0) {
      _preparedReady = true;
      return; // Direct updates leave hop policies untouched.
    }
    for (final node in nodes) {
      final reply = await node.command('ota config');
      if (node.allowOpaque && isLoraOtaOpaqueRelay(reply)) {
        log('${node.name}: opaque non-OTA relay; no hop setting to change.');
        continue;
      }
      final original = parseLoraOtaHops(reply);
      _prepared.add((node: node, original: original));
      log(
        '${node.name}: OTA hops $original -> '
        '${original < minimum ? '$minimum (temporary, saved for recovery)' : '$original (unchanged)'}.',
      );
    }
    _preparedReady = true;
  }

  Future<void> apply() async {
    if (!_preparedReady) throw StateError('OTA hop preflight has not passed.');
    // Verify every policy again before the first write; do not claim another
    // administrator's intervening setting as this session's original value.
    for (final entry in _prepared) {
      final current = parseLoraOtaHops(await entry.node.command('ota config'));
      if (current != entry.original) {
        throw StateError(
          '${entry.node.name}: OTA hop limit changed during setup.',
        );
      }
    }
    for (final entry in _prepared) {
      if (entry.original >= _minimum) continue;
      final node = entry.node;
      final record = LoraOtaHopRecovery(
        publicKey: node.publicKey,
        name: node.name,
        local: node.local,
        original: entry.original,
        transfer: _minimum,
        normalPath: node.normalPath,
        temporaryPath: node.temporaryPath,
        hashWidth: node.hashWidth,
      );
      await persist([...recovery, record]);
      // Own cleanup even if the setter reached the radio but its reply is lost.
      _pending.add((node: node, record: record));
      await _setVerified(node, _minimum);
      log('${node.name}: OTA hop limit $_minimum verified.');
    }
  }

  Future<void> verifyTransfer() async {
    for (final entry in _prepared) {
      final expected = entry.original < _minimum ? _minimum : entry.original;
      if (parseLoraOtaHops(await entry.node.command('ota config')) !=
          expected) {
        throw StateError(
          '${entry.node.name}: OTA hop policy changed; stop and restore before restarting.',
        );
      }
    }
  }

  Future<void> _setVerified(LoraOtaHopParticipant node, int hops) async {
    String? reply;
    try {
      reply = await node.command('ota config hops $hops');
    } catch (_) {
      // Never blindly resend a persistent write after losing its reply.
    }
    final current = parseLoraOtaHops(await node.command('ota config'));
    final ack = RegExp(
      '^OK OTA reach = $hops hops? \\(saved\\)(?: - direct only)?\$',
    );
    if (current != hops || (reply != null && !ack.hasMatch(reply.trim()))) {
      throw StateError(
        '${node.name}: could not verify OTA hops $hops '
        '(read $current; reply ${reply ?? 'lost'}).',
      );
    }
  }

  Future<void> restore() async {
    final errors = <String>[];
    for (final entry in _pending.reversed.toList()) {
      try {
        final current = parseLoraOtaHops(
          await entry.node.command('ota config'),
        );
        if (current != entry.record.original) {
          if (current != entry.record.transfer) {
            throw StateError('setting changed to $current; left untouched');
          }
          await _setVerified(entry.node, entry.record.original);
        }
        final remaining = _pending.where((item) => item != entry).toList();
        await persist(remaining.map((item) => item.record).toList());
        _pending.remove(entry);
        log(
          '${entry.node.name}: original OTA hops ${entry.record.original} restored.',
        );
      } catch (error) {
        errors.add('${entry.node.name}: $error');
      }
    }
    if (errors.isNotEmpty) {
      throw StateError(
        'OTA hop-limit recovery still required: ${errors.join('; ')}',
      );
    }
  }
}
