import 'dart:math';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import 'firmware_controls.dart';

// Match MeshCore HEAD FleetCommand/FleetChannel, not the filter playground.
// The Companion owns Ed25519 signing and the one/two-packet transmission.
class FleetTargets {
  const FleetTargets._(this.token, this.recordBytes, this.count, this.exactKey);
  factory FleetTargets.parse(String token) {
    if (token == 'all') return const FleetTargets._('all', 0, 0, false);
    final entries = token.split(';');
    if (entries.isEmpty || entries.length > 17) {
      throw const FormatException(
        'Choose 1-17 targets, or All enrolled nodes.',
      );
    }
    var bytes = 0;
    for (final entry in entries) {
      if (RegExp(
        r'^(?:[a-fA-F0-9]{8}|[a-fA-F0-9]{12}|[a-fA-F0-9]{64})$',
      ).hasMatch(entry)) {
        if (entry.length == 64 && RegExp(r'^0+$').hasMatch(entry)) {
          throw const FormatException(
            'A zero public identity is not a target.',
          );
        }
        bytes += entry.length == 64 ? 17 : 1 + entry.length ~/ 2;
      } else if (entry.startsWith('gps:')) {
        final match = RegExp(r'^gps:([^,]+),([^:]+):(.+)$').firstMatch(entry);
        if (match == null) throw const FormatException('Invalid GPS target.');
        _decimal(match[1]!, 6, 90, signed: true);
        _decimal(match[2]!, 6, 180, signed: true);
        final radius = _decimal(match[3]!, 3, 20050);
        if (radius < .001) {
          throw const FormatException('Radius must be 0.001-20050 km.');
        }
        bytes += 13;
      } else {
        // Always require an explicit kind; never interpret a malformed key
        // or missing selection as a region or an all-fleet request.
        final match = RegExp(r'^(region|home):(#?)(.+)$').firstMatch(entry);
        final name = match?[3];
        if (name == null ||
            name.length > 30 ||
            !name.codeUnits.every(
              (c) =>
                  c == 45 ||
                  c == 36 ||
                  c == 35 ||
                  (c >= 48 && c <= 57) ||
                  (c >= 65 && c <= 126),
            ) ||
            name.contains(';') ||
            name.contains('|') ||
            name.contains('&') ||
            name.contains('`') ||
            name.contains('\\')) {
          throw const FormatException(
            'Use an explicit region/home name (1-30 ASCII characters).',
          );
        }
        bytes += 2 + name.length;
      }
    }
    if (bytes > 86) {
      throw const FormatException(
        'Targets exceed the firmware record budget. Narrow the selection.',
      );
    }
    return FleetTargets._(
      token,
      bytes,
      entries.length,
      entries.length == 1 && entries.single.length == 64,
    );
  }
  final String token;
  final int recordBytes, count;
  final bool exactKey;
  int get headerBytes => exactKey ? 29 : 14 + recordBytes;
}

double _decimal(
  String text,
  int precision,
  double maximum, {
  bool signed = false,
}) {
  final sign = signed ? r'[+-]?' : '';
  if (!RegExp(
    '^$sign(?:0|[1-9][0-9]*)(?:\\.[0-9]{1,$precision})?\$',
  ).hasMatch(text)) {
    throw const FormatException(
      'Use ordinary decimals without excess precision or leading zeros.',
    );
  }
  final value = double.tryParse(text);
  if (value == null || !value.isFinite || value.abs() > maximum) {
    throw const FormatException(
      'Coordinate, radius, or radio value is out of range.',
    );
  }
  return value;
}

const fleetSettingLabels = <String, String>{
  'radio2': 'Saved Radio 2 profile',
  'tempradio2': 'Temporary Radio 2 profile',
  'radio2.cross': 'Radio 2 crossover',
  'radio2.status': 'Radio 2 status',
  'radio2.timing': 'Radio 2 timing',
  'radioat': 'Scheduled primary radio',
  'tempradioat': 'Temporary primary schedule',
  'radioat2': 'Scheduled Radio 2',
  'tempradioat2': 'Temporary Radio 2 schedule',
  'flood.rule': 'Forwarding filter rules',
  'flood.filter.blacklist': 'Path blacklist',
  'flood.moderation': 'Channel moderation',
  'flood.channel.scope': 'Channel scope policy',
  'flood.channel.scope.require': 'Required channel scope',
  'flood.channel.data': 'Group-data forwarding',
  'flood.channel.data.hops': 'Group-data hop limit',
  'flood.max': 'Flood hop limit',
  'flood.max.unscoped': 'Unscoped flood hop limit',
  'flood.max.advert': 'Advertisement hop limit',
  'clock': 'UTC clock',
};

const _rowFamilies = [
  'flood.filter',
  'flood.rule',
  'flood.filter.blacklist',
  'flood.moderation',
  'flood.channel.scope',
  'flood.channel.scope.require',
];
const _schedules = ['radioat', 'tempradioat', 'radioat2', 'tempradioat2'];

void validateFleetCommand(String command) {
  if (command.isEmpty ||
      command.length > 230 ||
      command.trim() != command ||
      !RegExp(r'^[\x20-\x7e]+$').hasMatch(command) ||
      RegExp(r'[;|&`\\]').hasMatch(command)) {
    throw const FormatException(
      'Use one bounded firmware control, without command separators.',
    );
  }
  if (command == 'clock' || command == 'clock sync') return;
  if (command.startsWith('time ')) {
    final value = int.tryParse(command.substring(5));
    if (!RegExp(r'^time [0-9]+$').hasMatch(command) ||
        value == null ||
        value < 1735689600 ||
        value > 0xffffffff) {
      throw const FormatException('Use a valid UTC epoch (2025 or later).');
    }
    return;
  }
  final match = RegExp(
    r'^(get|set|del) ([^ ]+)(?: (.+))?$',
  ).firstMatch(command);
  if (match == null || (match[3]?.startsWith(' ') ?? false)) {
    throw const FormatException('This operation is not a fleet control.');
  }
  final action = match[1]!, key = match[2]!, args = match[3] ?? '';
  final row = _rowFamilies.any(
    (family) =>
        key == family ||
        RegExp(
              '^${RegExp.escape(family)}\\.([1-9][0-9]{0,2})\$',
            ).hasMatch(key) &&
            int.parse(key.split('.').last) <= 255,
  );
  if (row) {
    if (action == 'get' && args.isEmpty ||
        action == 'set' && args.isNotEmpty ||
        action == 'del' && (args.isEmpty || args == 'all')) {
      return;
    }
  } else if (_schedules.contains(key)) {
    if (action == 'get' || action == 'del') {
      final slot = int.tryParse(args);
      if (args.isEmpty ||
          args == 'all' ||
          RegExp(r'^[1-9][0-9]*$').hasMatch(args) &&
              slot != null &&
              slot <= (key.endsWith('2') ? 4 : 255)) {
        return;
      }
    } else {
      _validateRadioTuple(
        args,
        temporary: key.startsWith('temp'),
        secondary: key.endsWith('2'),
        scheduled: true,
      );
      return;
    }
  } else if (key == 'radio2' || key == 'tempradio2') {
    if (action == 'get' && args.isEmpty) return;
    if (action == 'set') {
      if (args == 'off') return;
      _validateRadioTuple(
        args,
        temporary: key == 'tempradio2',
        secondary: true,
      );
      return;
    }
  } else if (key == 'radio2.status' || key == 'radio2.timing') {
    if (action == 'get' && args.isEmpty) return;
  } else if (key == 'radio2.cross') {
    if (action == 'get' && args.isEmpty ||
        action == 'set' && ['auto', 'on', 'off'].contains(args)) {
      return;
    }
  } else if ([
    'flood.channel.data',
    'flood.channel.data.hops',
    'flood.max',
    'flood.max.unscoped',
    'flood.max.advert',
  ].contains(key)) {
    if (action == 'get' && args.isEmpty || action == 'set' && args.isNotEmpty) {
      return;
    }
  }
  throw const FormatException(
    'Firmware does not permit this operation over the fleet channel.',
  );
}

void _validateRadioTuple(
  String args, {
  required bool temporary,
  required bool secondary,
  bool scheduled = false,
}) {
  final fields = args.split(',');
  final base = secondary ? 5 : 4;
  final expected =
      base +
      (scheduled
          ? temporary
                ? 2
                : 1
          : temporary
          ? 1
          : 0);
  if (fields.length != expected && fields.length != expected + 1) {
    throw const FormatException('Incomplete radio profile or schedule.');
  }
  _decimal(fields[0], 6, 2500);
  _decimal(fields[1], 6, 1000);
  for (final index in [2, 3]) {
    if (!RegExp(r'^[0-9]+$').hasMatch(fields[index]) ||
        int.parse(fields[index]) > 255) {
      throw const FormatException('Invalid spreading factor or coding rate.');
    }
  }
  if (secondary && !['rx', 'rxtx'].contains(fields[4])) {
    throw const FormatException('Radio 2 mode must be rx or rxtx.');
  }
  for (var i = base; i < expected; i++) {
    final field = fields[i];
    if (!RegExp(scheduled ? r'^\+?[0-9]+$' : r'^[0-9]+$').hasMatch(field)) {
      throw const FormatException(
        'Use UTC seconds or +N whole minutes for schedules.',
      );
    }
    final relative = field.startsWith('+');
    final value = int.parse(relative ? field.substring(1) : field);
    if (value < 1 || value > (relative ? 0xffffffff ~/ 60 : 0xffffffff)) {
      throw const FormatException('Invalid schedule time or duration.');
    }
  }
  if (fields.length == expected + 1 && fields.last != 'auto') {
    final value = int.tryParse(fields.last);
    if (!RegExp(r'^[0-9]+$').hasMatch(fields.last) ||
        value == null ||
        value > 65528 ||
        (value != 0 && value < 8)) {
      throw const FormatException('Invalid preamble.');
    }
  }
}

bool isFleetChannel(Channel channel) =>
    channel.index >= 0 &&
    channel.index <= 255 &&
    channel.name.isNotEmpty &&
    channel.isPrivateChannel &&
    channel.psk.length == 16 &&
    channel.psk.any((byte) => byte != 0) &&
    channel.pskHex !=
        Channel.derivePskFromHashtag(
          channel.name,
        ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List generateFleetChannelKey() {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
}

class FleetRequest {
  FleetRequest(Channel selected, this.targets, this.command)
    : channel = Channel(
        index: selected.index,
        name: selected.name,
        psk: Uint8List.fromList(selected.psk),
      ) {
    if (!isFleetChannel(channel)) {
      throw const FormatException(
        'Select a private random-key channel, not Public or a hashtag.',
      );
    }
    validateFleetCommand(command);
    envelopeBytes = targets.headerBytes + command.length + 64;
    if (envelopeBytes > 308) {
      throw const FormatException(
        'Targets and control exceed two LoRa packets. Narrow the selection.',
      );
    }
    localCommand = 'fleet send ${channel.index} ${targets.token} $command';
    // 172 byte app frame: command byte and a three-byte correlation tag.
    validateFirmwareCommand(localCommand);
    buildRunCliCommandFrame(localCommand, correlationTag: '00');
  }
  final Channel channel;
  final FleetTargets targets;
  final String command;
  late final String localCommand;
  late final int envelopeBytes;
  int get packets => envelopeBytes <= 165 ? 1 : 2;
}

class FleetReport {
  const FleetReport(this.sender, this.prefix, this.reply);
  final String sender, prefix, reply;
}

class FleetDispatch {
  FleetDispatch(this.request, this.sequence, this.previousMessages);
  final FleetRequest request;
  final int sequence;
  final Set<String> previousMessages;
}

class FleetEnrollment {
  const FleetEnrollment(
    this.target,
    this.enabled,
    this.controller,
    this.summary,
  );
  final Contact target;
  final bool enabled;
  final String controller, summary;
}

/// Explicit user actions only. No broadcasts on open, retry, or timer. Private
/// signing identity stays on the Companion; the app sends command 66.
class FleetManagementService extends ChangeNotifier {
  FleetManagementService(this.connector, {DateTime Function()? now})
    : _identity = connector.selfPublicKeyHex,
      _now = now ?? DateTime.now {
    connector.addListener(_changed);
  }
  final MeshCoreConnector connector;
  final String _identity;
  final DateTime Function() _now;
  static final Expando<DateTime> _lastSend = Expando();
  final Map<String, FleetEnrollment> checked = {};
  bool busy = false, _disposed = false, publisherSupported = false;
  FleetDispatch? dispatch;

  bool get available =>
      !_disposed &&
      connector.isConnected &&
      connector.selfPublicKeyHex == _identity &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(_identity) &&
      !RegExp(r'^0+$').hasMatch(_identity) &&
      (connector.firmwareVerCode ?? 0) >= 14;

  List<Contact> get administrators => connector.repeaterAdminSessions
      .infrastructure(connector.contacts, _identity);
  List<Channel> get channels =>
      connector.channels.where(isFleetChannel).toList();

  void _changed() {
    if (!available) {
      publisherSupported = false;
      checked.clear();
      dispatch = null;
    }
    if (!_disposed) notifyListeners();
  }

  void _guard([Channel? channel]) {
    if (!available) {
      throw StateError(
        'Companion changed or disconnected. Reopen Fleet management.',
      );
    }
    if (channel != null &&
        !connector.channels.any(
          (c) =>
              c.index == channel.index &&
              c.pskHex == channel.pskHex &&
              c.name == channel.name &&
              isFleetChannel(c),
        )) {
      throw StateError(
        'The selected private channel changed. Select it again.',
      );
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _guard();
    if (busy) throw StateError('A fleet operation is already pending.');
    busy = true;
    notifyListeners();
    try {
      return await operation();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> checkPublisher() => _run(() async {
    publisherSupported = false;
    final reply = await connector.executeLocalCliCommand('fleet');
    _guard();
    publisherSupported = reply.contains('use fleet send <channel>');
    if (!publisherSupported) {
      throw UnsupportedError(
        'This Companion does not report fleet publishing support. Install fleet-capable MeshCore head.',
      );
    }
  });

  int get freeChannelSlot {
    _guard();
    if (!connector.hasLoadedChannels ||
        connector.isLoadingChannels ||
        connector.isSyncingChannels) {
      throw StateError(
        'Wait for a complete channel synchronization before creating a channel.',
      );
    }
    for (var index = 1; index < connector.maxChannels; index++) {
      if (!connector.channels.any((c) => c.index == index && !c.isEmpty)) {
        return index;
      }
    }
    throw StateError('No free channel slot. Manage channels first.');
  }

  Future<void> createPrivateChannel(int index) => _run(() async {
    if (index != freeChannelSlot) {
      throw StateError('Channel slot changed. Review creation again.');
    }
    await connector.setChannel(index, 'Fleet', generateFleetChannelKey());
    _guard();
  });

  Future<FleetDispatch> send(FleetRequest request) => _run(() async {
    _guard(request.channel);
    if (!publisherSupported) throw StateError('Check publisher support first.');
    // Reconstruct immediately before sending. Caller-owned channel bytes or
    // form changes must never bypass limits or broaden a target selection.
    final validated = FleetRequest(
      request.channel,
      FleetTargets.parse(request.targets.token),
      request.command,
    );
    final previous = connector
        .getChannelMessages(request.channel)
        .map((m) => m.messageId)
        .toSet();
    final now = _now();
    final last = _lastSend[connector];
    if (last != null && now.difference(last).inMilliseconds < 1100) {
      throw StateError(
        'Wait at least one second between fleet commands. No request was sent.',
      );
    }
    _lastSend[connector] = now;
    // Reserve the interval even on timeout: a lost reply may mean queued.
    final reply = firmwareValue(
      await connector.executeLocalCliCommand(validated.localCommand),
    );
    _guard(request.channel);
    final match = RegExp(
      r'^OK - fleet command queued; seq=([0-9]+)$',
    ).firstMatch(reply);
    if (match == null) {
      throw StateError(
        'Queueing was not confirmed. Do not automatically retry. $reply',
      );
    }
    final sequence = int.parse(match[1]!);
    if (sequence < 1735689600 || sequence > 0xffffffff - 600) {
      throw const FormatException(
        'Companion returned an invalid fleet sequence.',
      );
    }
    return dispatch = FleetDispatch(validated, sequence, previous);
  });

  List<FleetReport> get reports {
    final current = dispatch;
    if (current == null ||
        !available ||
        !connector.channels.any(
          (c) =>
              c.index == current.request.channel.index &&
              c.pskHex == current.request.channel.pskHex,
        )) {
      return [];
    }
    final reports = <FleetReport>[];
    for (final message in connector.getChannelMessages(
      current.request.channel,
    )) {
      if (message.isOutgoing ||
          current.previousMessages.contains(message.messageId)) {
        continue;
      }
      final match = RegExp(
        r'^fleet ([0-9]+) ([0-9a-fA-F]{12}): (.*)$',
      ).firstMatch(message.text);
      if (match != null && int.tryParse(match[1]!) == current.sequence) {
        reports.add(FleetReport(message.senderName, match[2]!, match[3]!));
      }
    }
    return reports.take(100).toList();
  }

  Contact _admin(Contact target, int generation) {
    _guard();
    if (connector.repeaterAdminSessions.generation != generation) {
      throw StateError('Admin session changed. Check enrollment again.');
    }
    final matches = administrators
        .where((c) => c.publicKeyHex == target.publicKeyHex)
        .toList();
    if (matches.length != 1) {
      throw StateError('Confirmed admin login required. Log in from Contacts.');
    }
    return matches.single;
  }

  Future<FleetEnrollment> inspect(Contact target) => _run(() async {
    final generation = connector.repeaterAdminSessions.generation;
    final current = _admin(target, generation);
    checked.remove(current.publicKeyHex);
    final endpoint = FirmwareControlEndpoint(connector, target: current);
    try {
      final summary = await endpoint.read('get fleet.channel');
      final controller = await endpoint.read('get fleet.controller');
      _admin(target, generation);
      final match = RegExp(
        r'^(on|off),controller=(set|unset),store=ok,hash=[0-9a-fA-F]{2},last=[0-9]+$',
      ).firstMatch(summary);
      if (match == null ||
          (controller != 'unset' &&
              !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(controller))) {
        throw const FormatException(
          'Fleet enrollment is unsupported or its durable store is unhealthy.',
        );
      }
      final result = FleetEnrollment(
        current,
        match[1] == 'on',
        controller,
        summary,
      );
      checked[current.publicKeyHex] = result;
      return result;
    } finally {
      endpoint.dispose();
    }
  });

  Future<void> enroll(
    Contact target,
    Channel channel, {
    bool disable = false,
  }) => _run(() async {
    _guard(channel);
    if (!publisherSupported) {
      throw StateError('Check publisher support before enrollment.');
    }
    final generation = connector.repeaterAdminSessions.generation;
    final current = _admin(target, generation);
    if (!checked.containsKey(current.publicKeyHex)) {
      throw StateError('Read this node enrollment before changing it.');
    }
    checked.remove(current.publicKeyHex);
    final endpoint = FirmwareControlEndpoint(connector, target: current);
    try {
      await endpoint.apply(
        disable
            ? ['set fleet.channel off', 'set fleet.controller off']
            : [
                'set fleet.controller $_identity',
                'set fleet.channel ${channel.pskHex}',
              ],
        guard: () {
          _guard(channel);
          _admin(target, generation);
        },
      );
      _guard(channel);
      _admin(target, generation);
    } finally {
      endpoint.dispose();
    }
  });

  @override
  void dispose() {
    _disposed = true;
    connector.removeListener(_changed);
    super.dispose();
  }
}
