import 'dart:async';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import 'repeater_command_service.dart';

String firmwareValue(String reply) =>
    reply.trim().replaceFirst(RegExp(r'^>\s*'), '');

bool firmwareError(String reply) => RegExp(
  r'^(?:\(?\s*)?(?:err(?:or)?\b|unknown\b|unsupported\b)',
  caseSensitive: false,
).hasMatch(reply.trim());

void validateFirmwareCommand(String command, {bool remote = false}) {
  if (command.isEmpty || !RegExp(r'^[\x20-\x7e]+$').hasMatch(command)) {
    throw const FormatException('Use a single line of plain text.');
  }
  // Local: command byte + XX|. Remote: 13-byte header + XX| + NUL.
  if (command.length > (remote ? 155 : 168)) {
    throw const FormatException(
      'These settings exceed the radio command limit. Simplify the rule.',
    );
  }
}

/// Binds every operation to the same Companion identity. Remote replies use
/// the existing authenticated contact message and correlation-token service.
class FirmwareControlEndpoint {
  FirmwareControlEndpoint(this.connector, {this.target})
    : _identity = connector.selfPublicKeyHex {
    if (target != null) {
      _remote = RepeaterCommandService(connector);
      _subscription = connector.receivedFrames.listen((frame) {
        if (frame.isEmpty ||
            (frame[0] != respCodeContactMsgRecv &&
                frame[0] != respCodeContactMsgRecvV3)) {
          return;
        }
        final message = parseContactMessageText(frame);
        final typeOffset = frame[0] == respCodeContactMsgRecvV3 ? 11 : 8;
        if (frame.length <= typeOffset ||
            (frame[typeOffset] != txtTypeCliData &&
                frame[typeOffset] >> 2 != txtTypeCliData)) {
          return;
        }
        if (message == null ||
            message.senderPrefix.length < 6 ||
            target!.publicKey.length < 6) {
          return;
        }
        for (var i = 0; i < 6; i++) {
          if (message.senderPrefix[i] != target!.publicKey[i]) return;
        }
        _remote?.handleResponse(target!, message.text);
      });
    }
  }

  final MeshCoreConnector connector;
  final Contact? target;
  final String _identity;
  RepeaterCommandService? _remote;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  final _closed = Completer<void>();

  bool get available =>
      !_disposed &&
      connector.isConnected &&
      connector.selfPublicKeyHex == _identity &&
      (target != null || (connector.firmwareVerCode ?? 0) >= 14);

  Future<String> read(String command, {bool allowError = false}) async {
    if (!available) {
      throw StateError('Reconnect and reopen this screen before continuing.');
    }
    validateFirmwareCommand(command, remote: target != null);
    final request = target == null
        ? connector.executeLocalCliCommand(command)
        // Never retry writes: an unnumbered filter insert is not idempotent.
        : _remote!.sendCommand(
            target!,
            command,
            retries: 1,
            // Deferred firmware replies and a busy Companion queue can exceed
            // the airtime estimate even over a direct, nearby link.
            minimumTimeoutMs: 30000,
          );
    final reply = await Future.any<String>([
      request,
      _closed.future.then<String>((_) => throw StateError('Screen closed.')),
    ]);
    if (!available) {
      throw StateError('The connected device changed. Reopen this screen.');
    }
    if (!allowError && firmwareError(reply)) {
      throw UnsupportedError(reply.trim());
    }
    return firmwareValue(reply);
  }

  Future<void> apply(List<String> commands, {void Function()? guard}) async {
    // Validate the entire batch before the first write.
    for (final command in commands) {
      validateFirmwareCommand(command, remote: target != null);
    }
    var completed = 0;
    try {
      for (final command in commands) {
        guard?.call();
        final reply = await read(command);
        if (!RegExp(r'^\(?\s*OK\b', caseSensitive: false).hasMatch(reply)) {
          throw StateError('No success acknowledgement: $reply');
        }
        completed++;
      }
    } catch (error) {
      throw StateError(
        '$completed of ${commands.length} changes confirmed. '
        'Earlier changes remain saved; a timed-out change may have applied. '
        'Read the device before retrying. $error',
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _closed.complete();
    _subscription?.cancel();
    _remote?.dispose();
  }
}

const notificationOutputBits = <String, int>{
  'vibration': 1,
  'sound': 2,
  'led': 4,
  'screen': 8,
  'gpio': 16,
};
const notificationRuleFields = <String>[
  'vibration',
  'led',
  'sound',
  'screen',
  'gpio',
  'repeat',
  'gap',
  'stop',
];

class NotificationCapabilities {
  const NotificationCapabilities(this.enabled, this.outputs, this.supported);
  final bool enabled;
  final int outputs;
  final int supported;

  factory NotificationCapabilities.parse(String reply) {
    final match = RegExp(
      r'enabled=(on|off) outputs=(\d+) supported=(\d+)',
    ).firstMatch(firmwareValue(reply));
    if (match == null) {
      throw const FormatException(
        'This firmware does not report programmable alerts.',
      );
    }
    final outputs = int.parse(match[2]!);
    final supported = int.parse(match[3]!);
    if (outputs > 31 || supported > 31) {
      throw const FormatException('Unknown notification output flags.');
    }
    return NotificationCapabilities(match[1] == 'on', outputs, supported);
  }
}

void validateNotificationTarget(String target) {
  if (!RegExp(
    r'^(all|contact:[0-9a-fA-F]{64}|room:[0-9a-fA-F]{64}|channel:(\d{1,3}|[0-9a-fA-F]{32}))(@connected|@disconnected)?$',
  ).hasMatch(target)) {
    throw const FormatException('Select a valid contact, room, or channel.');
  }
}

List<int> parseNotificationPulse(String value) {
  if (value == 'off' || value == 'inherit') return [];
  final tokens = value.split(',');
  if (tokens.length > 12 ||
      tokens.isEmpty ||
      tokens.any(
        (s) =>
            !RegExp(r'^\d+$').hasMatch(s) ||
            int.parse(s) < 1 ||
            int.parse(s) > 60000,
      )) {
    throw const FormatException(
      'Use 1-12 pulse durations, each 1-60000 ms, separated by commas.',
    );
  }
  return tokens.map(int.parse).toList();
}

int notificationSoundDuration(String value) {
  if (value == 'off' || value == 'inherit') return 0;
  final match = RegExp(
    r'^[A-Za-z0-9_]{1,12}:d=([1-9]\d?),o=([4-7]),b=(\d{1,3}):(.+)$',
  ).firstMatch(value);
  if (value.length > 63 || match == null) {
    throw const FormatException(
      'Use a valid RTTTL melody, at most 63 characters.',
    );
  }
  const durations = [1, 2, 4, 8, 16, 32];
  final d = int.parse(match[1]!);
  final b = int.parse(match[3]!);
  if (!durations.contains(d) || b < 25 || b > 900) {
    throw const FormatException(
      'RTTTL needs d=1/2/4/8/16/32, o=4-7, b=25-900.',
    );
  }
  var total = 0;
  for (final token in match[4]!.split(',')) {
    final note = RegExp(
      r'^([1-9]\d?)?([a-gp])(#)?(\.)?([4-7])?(\.)?$',
    ).firstMatch(token);
    if (note == null ||
        (note[4] != null && note[6] != null) ||
        (note[3] != null && !['a', 'c', 'd', 'f', 'g'].contains(note[2]))) {
      throw const FormatException('Invalid RTTTL note or octave.');
    }
    final nd = note[1] == null ? d : int.parse(note[1]!);
    if (!durations.contains(nd)) {
      throw const FormatException('Invalid note duration.');
    }
    var ms = (60000 ~/ b) * 4 ~/ nd;
    if (note[4] != null || note[6] != null) ms += ms ~/ 2;
    total += ms;
  }
  if (total > 60000) {
    throw const FormatException('The melody must finish within 60 seconds.');
  }
  return total;
}

String notificationRuleCommand(
  String target,
  String field,
  String value, {
  Set<int> gpioPins = const {},
}) {
  validateNotificationTarget(target);
  if (field == 'remote') {
    if (!RegExp(r'^(contact|room):[0-9a-fA-F]{64}$').hasMatch(target) ||
        !['on', 'off', 'inherit'].contains(value)) {
      throw const FormatException(
        'Remote alerts require an individual contact or room, without a connection condition.',
      );
    }
  } else if (!notificationRuleFields.contains(field)) {
    throw const FormatException('Unknown alert setting.');
  } else if (value != 'inherit') {
    switch (field) {
      case 'vibration':
      case 'led':
        parseNotificationPulse(value);
      case 'sound':
        notificationSoundDuration(value);
      case 'screen':
        if (!['on', 'off'].contains(value)) {
          throw const FormatException('Screen must be on, off, or inherit.');
        }
      case 'gpio':
        if (value != 'off') {
          final match = RegExp(r'^(\d{1,2}):(.+)$').firstMatch(value);
          if (match == null || !gpioPins.contains(int.parse(match[1]!))) {
            throw const FormatException(
              'Select a GPIO approved by this firmware.',
            );
          }
          parseNotificationPulse(match[2]!);
        }
      case 'repeat':
        if (value != 'forever') _integer(value, 1, 65535, 'Repeat count');
      case 'gap':
        _integer(value, 1, 60000, 'Gap');
      case 'stop':
        if (!['button', 'connected', 'never'].contains(value)) {
          throw const FormatException('Choose a valid stop condition.');
        }
    }
  }
  final command = 'set notify.$field $target $value';
  validateFirmwareCommand(command);
  return command;
}

int _integer(String value, int min, int max, String label) {
  final n = RegExp(r'^\d+$').hasMatch(value) ? int.tryParse(value) : null;
  if (n == null || n < min || n > max) {
    throw FormatException('$label must be $min-$max.');
  }
  return n;
}

const radioRouteLabels = <String, String>{
  'auto': 'Automatic',
  'radio': 'Primary only',
  'radio2': 'Radio 2 only',
  'both': 'Both profiles',
  'off': 'Disable sending',
};
const radioBandwidths = <double>[
  7.8,
  10.4,
  15.6,
  20.8,
  31.25,
  41.7,
  62.5,
  125,
  250,
  500,
  1000,
  812.5,
  1625,
];

class SecondaryRadioProfile {
  const SecondaryRadioProfile({
    this.frequency = 910.525,
    this.bandwidth = 250,
    this.sf = 7,
    this.cr = 5,
    this.mode = 'off',
    this.preamble = 'auto',
  });
  final double frequency;
  final double bandwidth;
  final int sf;
  final int cr;
  final String mode;
  final String preamble;

  factory SecondaryRadioProfile.parse(String reply) {
    final text = firmwareValue(reply);
    if (text == 'off') return const SecondaryRadioProfile();
    final match = RegExp(
      r'^([\d.]+),([\d.]+),(\d+),(\d+),(rx|rxtx|rx&tx),(\d+)(?:\s|;|$)',
    ).firstMatch(text);
    if (match == null) {
      throw const FormatException(
        'This firmware does not report a Radio 2 profile.',
      );
    }
    return SecondaryRadioProfile(
      frequency: double.parse(match[1]!),
      bandwidth: double.parse(match[2]!),
      sf: int.parse(match[3]!),
      cr: int.parse(match[4]!),
      mode: match[5] == 'rx' ? 'rx' : 'rxtx',
      preamble: text.contains('(auto)') ? 'auto' : match[6]!,
    );
  }

  String command({int? minutes}) {
    if (mode == 'off') {
      return 'set ${minutes == null ? 'radio2' : 'tempradio2'} off';
    }
    if (!frequency.isFinite ||
        frequency < 150 ||
        frequency > 2500 ||
        !radioBandwidths.any((b) => (b - bandwidth).abs() < .01) ||
        sf < 5 ||
        sf > 12 ||
        cr < 5 ||
        cr > 8 ||
        !['rx', 'rxtx'].contains(mode)) {
      throw const FormatException(
        'Invalid frequency, bandwidth, spreading factor, or coding rate.',
      );
    }
    if (preamble != 'auto') _integer(preamble, 8, 65528, 'Preamble');
    if (minutes != null && (minutes < 1 || minutes > 10080)) {
      throw const FormatException(
        'Temporary duration must be 1-10080 minutes.',
      );
    }
    return 'set ${minutes == null ? 'radio2' : 'tempradio2'} $frequency,$bandwidth,$sf,$cr,$mode${minutes == null ? '' : ',$minutes'},$preamble';
  }
}

String parseChannelRadioRoute(String reply) {
  final match = RegExp(
    r'\s(auto|radio|radio2|both|off); active=',
  ).firstMatch(firmwareValue(reply));
  if (match == null) {
    throw const FormatException(
      'Per-channel radio routing is unavailable on this firmware.',
    );
  }
  return match[1]!;
}

String channelRadioRouteCommand(int index, String route) {
  if (index < 0 || index > 255 || !radioRouteLabels.containsKey(route)) {
    throw const FormatException('Invalid channel or route.');
  }
  return 'set tx.channel $index $route';
}

const filterTypeLabels = <String, String>{
  'any': 'Any packet',
  '0': 'Request',
  '1': 'Response',
  '2': 'Direct text',
  '3': 'Acknowledgement',
  '4': 'Advertisement',
  '5': 'Channel text',
  '6': 'Channel data',
  '7': 'Anonymous request',
  '8': 'Path',
  '9': 'Trace',
  '10': 'Multipart',
  '11': 'Control',
  '12': 'LoRa OTA',
  '13': 'Reserved 13',
  '14': 'Reserved 14',
  '15': 'Raw custom',
};

/// Matches the firmware's compact FPF7 writer. Unknown fields are rejected so
/// loading an old/newer row can never silently erase an unrepresented option.
class ForwardingRule {
  String type = 'any',
      mode = 'radio',
      hops = 'all',
      channel = '*',
      prefix = '',
      incoming = 'any';
  String action = 'drop', scope = '', rate = '', priority = '0';
  bool stop = false, slow = false, suspend = false, retry = false;
  int? slot;

  factory ForwardingRule.parse(String reply) {
    final text = firmwareValue(reply);
    final match = RegExp(r'^set fr\.(\d+) (.+)$').firstMatch(text);
    if (match == null) {
      throw const FormatException(
        'This row cannot be safely edited. Firmware must support compact FPF7 rows.',
      );
    }
    final rule = ForwardingRule()
      ..slot = int.parse(match[1]!)
      ..action = 'none';
    final tokens = match[2]!.split(' ');
    rule.type = tokens.removeAt(0);
    for (final t in tokens) {
      if (t.startsWith('m=')) {
        rule.mode =
            {'r': 'radio', 'b': 'bridge', 'c': 'cross', 'bc': 'bridge,cross'}[t
                .substring(2)] ??
            t.substring(2);
      } else if (t.startsWith('c=')) {
        rule.channel = t.substring(2);
      } else if (t.startsWith('p=')) {
        rule.prefix = t.substring(2) == 'bl' ? 'blacklist' : t.substring(2);
      } else if (t.startsWith('i=')) {
        final v = t.substring(2);
        rule.incoming =
            {'n': 'none', 's': 'scoped', 'a': 'allowed', 'u': 'unknown'}[v] ??
            (v.startsWith('s:')
                ? 'scope:${v.substring(2)}'
                : v.startsWith('r:')
                ? 'region:${v.substring(2)}'
                : v);
      } else if (t == 'd') {
        rule.action = 'drop';
      } else if (t.startsWith('s=')) {
        rule.action = 'scope';
        rule.scope = t.substring(2);
      } else if (t.startsWith('r=')) {
        rule.action = 'region';
        rule.scope = t.substring(2);
      } else if (t.startsWith('q=')) {
        rule.rate = t.substring(2);
      } else if (t.startsWith('pri=')) {
        rule.priority = t.substring(4);
      } else if (t == 's') {
        rule.stop = true;
      } else if (t == 'r') {
        rule.retry = true;
      } else if (RegExp(r'^f=[str]+$').hasMatch(t)) {
        rule.slow = t.contains('s');
        rule.suspend = t.contains('t');
        rule.retry = t.contains('r');
      } else if (RegExp(r'^\d+(?:\+|-\d+)?$').hasMatch(t)) {
        rule.hops = t;
      } else {
        throw FormatException('Unrecognized saved rule option: $t');
      }
    }
    rule.command();
    return rule;
  }

  ForwardingRule();

  String command({
    bool remote = false,
    bool room = false,
    bool insert = false,
  }) {
    if (!filterTypeLabels.containsKey(type) ||
        !['radio', 'bridge', 'cross', 'bridge,cross'].contains(mode)) {
      throw const FormatException('Choose a packet type and forwarding mode.');
    }
    if (slot != null && (slot! < 1 || slot! > (room ? 31 : 63))) {
      throw const FormatException('Invalid filter slot.');
    }
    if (hops != 'all') {
      final match = RegExp(r'^(\d+)(\+|-(\d+))?$').firstMatch(hops);
      if (match == null) {
        throw const FormatException('Hops: all, N, N+, or N-M (0-63).');
      }
      final min = _integer(match[1]!, 0, 63, 'Hops');
      if (match[3] != null && _integer(match[3]!, 0, 63, 'Hops') < min) {
        throw const FormatException('Hop range is reversed.');
      }
    }
    if (!RegExp(
      r'^(\*|public|#[A-Za-z0-9_.-]{1,30}|hash:[0-9A-Fa-f]{2}|key:[0-9A-Fa-f]{8}|[0-9a-fA-F]{32}|[0-9a-fA-F]{64})$',
    ).hasMatch(channel)) {
      throw const FormatException(
        'Channel: *, public, #name, hash:XX, or a full channel key.',
      );
    }
    if (prefix.isNotEmpty && prefix != 'blacklist') {
      final ids = prefix.split(',');
      if (ids.length > 3 ||
          ![2, 4, 6].contains(ids.first.length) ||
          ids.any(
            (id) =>
                id.length != ids.first.length ||
                !RegExp(r'^[0-9a-fA-F]+$').hasMatch(id),
          )) {
        throw const FormatException(
          'Path prefix: 1-3 equal-width IDs of 2, 4, or 6 hex characters.',
        );
      }
    }
    if (!['any', 'none', 'scoped', 'allowed', 'unknown'].contains(incoming) &&
        !RegExp(
          r'^(scope|region):#?[A-Za-z0-9_.-]{1,30}$',
        ).hasMatch(incoming)) {
      throw const FormatException('Choose a valid incoming scope.');
    }
    if (!['drop', 'scope', 'region', 'none'].contains(action)) {
      throw const FormatException('Choose a filter action.');
    }
    if (action == 'scope' || action == 'region') {
      if (!RegExp(r'^#?[A-Za-z0-9_.-]{1,30}$').hasMatch(scope)) {
        throw const FormatException('Enter a scope or region name.');
      }
    }
    if (room &&
        (prefix == 'blacklist' ||
            incoming != 'any' ||
            action == 'scope' ||
            action == 'region')) {
      throw const FormatException(
        'Room-server filters do not support scopes or the shared blacklist.',
      );
    }
    if (rate.isNotEmpty) _integer(rate, 0, 65534, 'Packets per minute');
    _integer(priority, 0, 255, 'Priority');
    if (retry && action == 'drop') {
      throw const FormatException('A rule cannot both drop and permit retry.');
    }
    if (action == 'none' && rate.isEmpty && !retry && !stop) {
      throw const FormatException(
        'Choose an action, rate limit, retry, or stop.',
      );
    }
    final tokens = <String>[
      'set fr${slot == null || insert ? '' : '.$slot'}',
      type,
    ];
    if (mode != 'radio') {
      tokens.add(
        'm=${{'bridge': 'b', 'cross': 'c', 'bridge,cross': 'bc'}[mode]}',
      );
    }
    if (hops != 'all') tokens.add(hops);
    if (channel != '*') tokens.add('c=$channel');
    if (prefix.isNotEmpty) {
      tokens.add('p=${prefix == 'blacklist' ? 'bl' : prefix}');
    }
    if (incoming != 'any') {
      tokens.add(
        'i=${{'none': 'n', 'scoped': 's', 'allowed': 'a', 'unknown': 'u'}[incoming] ?? incoming.replaceFirst('scope:', 's:').replaceFirst('region:', 'r:')}',
      );
    }
    if (action == 'drop') tokens.add('d');
    if (action == 'scope') tokens.add('s=$scope');
    if (action == 'region') tokens.add('r=$scope');
    if (rate.isNotEmpty) tokens.add('q=$rate');
    if (priority != '0') tokens.add('pri=$priority');
    if (stop) tokens.add('s');
    if (slow || suspend || retry) {
      tokens.add(
        'f=${slow ? 's' : ''}${suspend ? 't' : ''}${retry ? 'r' : ''}',
      );
    }
    final command = tokens.join(' ');
    validateFirmwareCommand(command, remote: remote);
    return command;
  }
}

String filterBlacklistCommand(String ids, {int? slot}) {
  final entries = ids
      .trim()
      .split(',')
      .map((id) => id.trim().toUpperCase())
      .toList();
  if (entries.isEmpty ||
      entries.length > 18 ||
      entries.toSet().length != entries.length ||
      entries.any((id) => !RegExp(r'^[0-9A-F]{6}$').hasMatch(id))) {
    throw const FormatException(
      'Use 1-18 distinct 6-character hex IDs, separated by commas.',
    );
  }
  if (slot != null && (slot < 1 || slot > 255)) {
    throw const FormatException('Invalid blacklist slot.');
  }
  return 'set flood.filter.blacklist${slot == null ? '' : '.$slot'} ${entries.join(',')}';
}

class ScopeRewriteRule {
  String channel = 'txt:*', target = '', path = '', timing = 'fast';
  bool? directScope = true;
  int? slot;
  ScopeRewriteRule();
  factory ScopeRewriteRule.parse(String reply) {
    final match = RegExp(
      r'^(\d+) match=(\S+)(?: path=(\S+))? scope=(\S+)(?: tx=(slow))?$',
    ).firstMatch(firmwareValue(reply));
    if (match == null || match[4]!.contains('?')) {
      throw const FormatException('This scope row cannot be safely edited.');
    }
    return ScopeRewriteRule()
      ..slot = int.parse(match[1]!)
      ..channel = match[2]!
      ..path = match[3] ?? ''
      ..target = match[4]!
      // The getter does not distinguish a region from a direct scope.
      ..directScope = null
      ..timing = match[5] ?? 'fast';
  }
  String command({bool remote = false}) {
    if (directScope == null) {
      throw const FormatException(
        'Choose whether this target is a region or a direct scope before replacing the saved row.',
      );
    }
    if (slot != null && (slot! < 1 || slot! > 255)) {
      throw const FormatException('Invalid scope slot.');
    }
    if (!RegExp(
      r'^(txt:\*|login:\*|other:\*|public|#[A-Za-z0-9_.-]{1,30}|[0-9a-fA-F]{32}|[0-9a-fA-F]{64})$',
    ).hasMatch(channel)) {
      throw const FormatException(
        'Select a channel or txt:*, login:*, other:*.',
      );
    }
    if (!RegExp(r'^#?[A-Za-z0-9_.-]{1,30}$').hasMatch(target)) {
      throw const FormatException('Enter a valid target scope or region.');
    }
    if (![
          '',
          'blacklist',
          'bucket:1',
          'bucket:2',
          'bucket:3',
          'bucket:4',
          'bucket:5',
          'bucket:6',
        ].contains(path) ||
        !['fast', 'slow'].contains(timing)) {
      throw const FormatException('Choose a valid path and timing.');
    }
    final command =
        'set flood.channel.scope${slot == null ? '' : '.$slot'} $channel ${directScope! ? 'scope=$target' : target}${path.isEmpty ? '' : ' path=$path'}${timing == 'slow' ? ' tx=slow' : ''}';
    validateFirmwareCommand(command, remote: remote);
    return command;
  }
}

class ChannelModerationRule {
  String channel = 'public', sender = '', path = '*', rate = '5', hops = 'all';
  String action = 'rate';
  int? slot;
  ChannelModerationRule();
  factory ChannelModerationRule.parse(String reply) {
    final match = RegExp(
      r'^(\d+) channel=(\S+) sender="([^"]+)" path=(\S+) rate=(unlimited|\d+/min) hops=(all|\d+)$',
    ).firstMatch(firmwareValue(reply));
    if (match == null) {
      throw const FormatException(
        'This moderation row cannot be safely edited.',
      );
    }
    final rate = match[5]!;
    return ChannelModerationRule()
      ..slot = int.parse(match[1]!)
      ..channel = match[2]!
      ..sender = match[3]!
      ..path = match[4]!
      ..hops = match[6]!
      ..action = rate == 'unlimited'
          ? 'hops'
          : rate == '0/min'
          ? 'drop'
          : 'rate'
      ..rate = rate == 'unlimited' ? '' : rate.split('/').first;
  }
  String command() {
    if (slot != null && (slot! < 1 || slot! > 16)) {
      throw const FormatException('Moderation slots are 1-16.');
    }
    if (!RegExp(
      r'^(public|#[A-Za-z0-9_.-]{1,30}|[0-9a-fA-F]{32}|[0-9a-fA-F]{64})$',
    ).hasMatch(channel)) {
      throw const FormatException(
        'Use public, #name, or a full channel key. Saved key fingerprints require the original full key to edit.',
      );
    }
    if (sender.isEmpty ||
        sender.length > 31 ||
        !RegExp(r'^[\x20-\x7e]+$').hasMatch(sender) ||
        sender.contains('"') ||
        sender.contains("'") ||
        sender.contains(':')) {
      throw const FormatException(
        'Sender names must be 1-31 plain-text characters, without quotation marks.',
      );
    }
    if (!['drop', 'rate', 'hops'].contains(action)) {
      throw const FormatException('Choose a moderation action.');
    }
    if (sender == '*' && action != 'hops') {
      throw const FormatException(
        'Dropping or rate-limiting needs an exact sender name. Use * only for a hop limit.',
      );
    }
    if (hops != 'all') _integer(hops, 0, 63, 'Maximum forwarded hops');
    if (action == 'rate') _integer(rate, 0, 65534, 'Messages per minute');
    if (action == 'hops' && hops == 'all') {
      throw const FormatException('Choose a hop limit from 0 to 63.');
    }
    if (path != '*') {
      final ids = path.split(',');
      if (ids.length > 3 ||
          ![2, 4, 6].contains(ids.first.length) ||
          ids.any(
            (id) =>
                id.length != ids.first.length ||
                !RegExp(r'^[0-9a-fA-F]+$').hasMatch(id),
          )) {
        throw const FormatException('Path: * or 1-3 equal-width hex IDs.');
      }
    }
    final command =
        'set flood.moderation${slot == null ? '' : '.$slot'} $channel "$sender" ${action == 'drop'
                ? 'drop'
                : action == 'rate'
                ? 'rate=$rate/min'
                : ''}${hops == 'all' ? '' : ' hops=$hops'}${path == '*' ? '' : ' path=$path'}'
            .trim();
    validateFirmwareCommand(command, remote: true);
    return command;
  }
}
