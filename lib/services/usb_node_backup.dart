import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'usb_flash_transport.dart';
import 'usb_serial_frame_codec.dart';

class UsbBackupUnavailable implements Exception {
  const UsbBackupUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

class UsbNodeInfo {
  const UsbNodeInfo({
    required this.publicKey,
    required this.role,
    this.hardwareModel,
    this.firmwareVersion,
  });
  final String publicKey;
  final String role;
  final String? hardwareModel;
  final String? firmwareVersion;
}

/// Same logical archive/schema as firmware.cmd/mcfirmware.sh. Contains secrets:
/// never log this object or its JSON, and save only in private app storage.
class UsbNodeBackupArchive {
  UsbNodeBackupArchive.fromJson(Map<String, dynamic> document)
    : _document = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(document)) as Map,
      ) {
    verify();
  }
  final Map<String, dynamic> _document;
  Map<String, dynamic> toJson() =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(_document)) as Map);
  Map<String, dynamic> get _payload => _map(_document['payload']);
  Map<String, dynamic> get _sections => _map(_payload['sections']);
  String get sha256 => _map(_document['integrity'])['sha256'] as String;
  String get publicKey =>
      _map(_map(_payload['source'])['node'])['public_key'] as String;
  String get deviceName {
    final self = _map(_sections['self_info']);
    if (self['state'] == 'complete') {
      return _map(self['data'])['name'] as String;
    }
    return _map(_map(_payload['source'])['node'])['device_hint'] as String? ??
        'MeshCore';
  }

  bool get isComplete =>
      _map(_payload['completeness'])['status'] == 'api-snapshot-complete';
  List<String> get warnings =>
      List<String>.from(_map(_payload['completeness'])['reasons'] as List);

  void verify() {
    if (_document['schema'] != 'org.meshfirmware.meshcore-backup/v1' ||
        _document['kind'] != 'meshcore-logical-usb') {
      throw const FormatException('Unsupported MeshCore backup schema');
    }
    final integrity = _map(_document['integrity']);
    final covered = Map<String, dynamic>.from(_document)..remove('integrity');
    if (integrity['algorithm'] != 'sha256' ||
        integrity['scope'] != 'canonical-json-document-without-integrity' ||
        integrity['sha256'] !=
            crypto.sha256
                .convert(utf8.encode(_canonical(covered)))
                .toString()) {
      throw const FormatException('Backup checksum verification failed');
    }
    _hex(publicKey, 32);
    final source = _map(_payload['source']);
    final node = _map(source['node']);
    if (source['transport'] != 'usb-serial' ||
        ![
          'companion-api',
          'meshcore-cli-common-cli',
        ].contains(source['capture_api']) ||
        ![
          'companion',
          'repeater',
          'room-server',
          'sensor',
          'common-cli',
        ].contains(node['role'])) {
      throw const FormatException('Backup source/role is invalid');
    }
    final physical = _map(source['physical_usb_identity']);
    if (!['serial', 'location', 'parent'].any(
      (key) => physical[key] is String && (physical[key] as String).isNotEmpty,
    )) {
      throw const FormatException('Backup has no physical USB identity');
    }
    final missing = <String>[];
    final optionalErrors = <String>[];
    for (final entry in _sections.entries) {
      final section = _map(entry.value);
      if (section['required'] is! bool ||
          ![
            'complete',
            'error',
            'unsupported',
            'disabled',
            'not_applicable',
          ].contains(section['state'])) {
        throw const FormatException('Invalid backup section metadata');
      }
      if (section['required'] == true && section['state'] != 'complete') {
        missing.add(entry.key);
      }
      if (section['required'] == false && section['state'] == 'error') {
        optionalErrors.add(entry.key);
      }
    }
    missing.sort();
    optionalErrors.sort();
    final completeness = _map(_payload['completeness']);
    final expectedComplete =
        source['capture_api'] == 'companion-api' &&
        missing.isEmpty &&
        optionalErrors.isEmpty;
    if (_canonical(missing) != _canonical(completeness['missing_required']) ||
        _canonical(optionalErrors) !=
            _canonical(completeness['optional_errors']) ||
        completeness['status'] !=
            (expectedComplete ? 'api-snapshot-complete' : 'partial') ||
        completeness['safe_for_wipe'] != false ||
        completeness['safe_for_restore'] != false) {
      throw const FormatException(
        'Backup completeness metadata is inconsistent',
      );
    }
    final stability = _map(_sections['identity_stability']);
    if (stability['state'] != 'complete' ||
        _map(stability['data'])['stable'] != true) {
      throw const FormatException('Backup identity was not stable');
    }
    final private = _map(_sections['identity_private_key']);
    if (private['state'] == 'complete' &&
        meshCoreExpandedPublicKey(
              _hex(_map(private['data'])['private_key'], 64),
            ) !=
            publicKey) {
      throw const FormatException(
        'Backup private key does not match public identity',
      );
    }
    if (source['capture_api'] == 'companion-api') {
      const required = [
        'self_info',
        'device_info',
        'identity_private_key',
        'contacts',
        'channels',
        'autoadd',
        'default_flood_scope',
        'tuning',
        'custom_vars',
        'identity_stability',
      ];
      if (required.any(
        (name) =>
            !_sections.containsKey(name) ||
            _map(_sections[name])['required'] != true,
      )) {
        throw const FormatException('Companion backup lacks core sections');
      }
      final self = _map(_map(_sections['self_info'])['data']);
      if (self['public_key'] != publicKey || self['adv_type'] != 1) {
        throw const FormatException('Backup SELF_INFO identity/role mismatch');
      }
      _validateSelf(self);
      final device = _map(_map(_sections['device_info'])['data']);
      if (_map(_sections['device_info'])['state'] == 'complete') {
        _validateDevice(device);
      }
      for (final name in ['contacts', 'channels']) {
        final section = _map(_sections[name]);
        if (section['state'] != 'complete') continue;
        final counts = _map(section['counts']);
        final data = section['data'];
        if ((data is! Map && data is! List) ||
            counts['received'] != (data as dynamic).length ||
            counts['declared'] != counts['received']) {
          throw const FormatException('Backup inventory count mismatch');
        }
        if (name == 'channels') {
          if (data is! List || data.length != device['max_channels']) {
            throw const FormatException('Backup channel capacity mismatch');
          }
          for (var index = 0; index < data.length; index++) {
            _validateChannel(_map(data[index]), index);
          }
        } else {
          for (final entry in (data as Map).entries) {
            final row = _map(entry.value);
            _validateContact(row);
            if (entry.key != row['public_key']) {
              throw const FormatException('Contact map identity mismatch');
            }
          }
        }
      }
    }
  }
}

class UsbNodeBackupService {
  UsbNodeBackupService(
    this.transport, {
    this.timeout = const Duration(seconds: 3),
  });
  final UsbFlashTransport transport;
  final Duration timeout;
  _CompanionClient? _client;
  String? _originalLogging;
  String? _originalLoggingReply;
  bool _terminalHandoff = false;

  Future<UsbNodeInfo> inspect(
    UsbFlashDevice device, {
    bool isDfu = false,
  }) async {
    _rejectDfu(device, isDfu);
    await transport.open(device);
    try {
      final self = await _connectCompanion();
      final info = _parseDevice(await _client!.query([22, 3], 13));
      String? full;
      try {
        full = _fullVersion(await _client!.cli('version'));
      } catch (_) {
        /* optional */
      }
      return UsbNodeInfo(
        publicKey: self['public_key'] as String,
        role: 'companion',
        hardwareModel: info['model'] as String?,
        firmwareVersion: full ?? info['ver'] as String?,
      );
    } on UsbBackupUnavailable {
      final public = await _text('get public.key');
      final key = _findHex(public, 32);
      if (key == null) rethrow;
      final version = await _text('ver');
      final role = _role(await _text('get role'));
      return UsbNodeInfo(
        publicKey: key,
        role: role,
        firmwareVersion: version.trim(),
      );
    } finally {
      await _finish();
    }
  }

  Future<UsbNodeBackupArchive> capture(
    UsbFlashDevice device, {
    bool isDfu = false,
  }) async {
    _rejectDfu(device, isDfu);
    await transport.open(device);
    try {
      Map<String, dynamic>? self;
      try {
        self = await _connectCompanion();
      } on UsbBackupUnavailable {
        /* CommonCLI fallback */
      }
      final opened = transport.activeDevice ?? device;
      final payload = self == null
          ? await _captureCli(opened)
          : await _captureCompanion(opened, self);
      final doc = <String, dynamic>{
        'schema': 'org.meshfirmware.meshcore-backup/v1',
        'kind': 'meshcore-logical-usb',
        'created_utc': DateTime.now().toUtc().toIso8601String(),
        'tool': {'name': 'MeshCore Open USB backup', 'version': '1.0.0'},
        'payload': payload,
      };
      doc['integrity'] = {
        'algorithm': 'sha256',
        'scope': 'canonical-json-document-without-integrity',
        'sha256': crypto.sha256
            .convert(utf8.encode(_canonical(doc)))
            .toString(),
      };
      return UsbNodeBackupArchive.fromJson(doc);
    } finally {
      await _finish();
    }
  }

  void _rejectDfu(UsbFlashDevice device, bool isDfu) {
    if (isDfu || device.isNrfDfu) {
      throw const UsbBackupUnavailable(
        'Backup cannot be done in DFU mode: the bootloader does not expose MeshCore configuration. Boot the application first, or explicitly continue without a backup.',
      );
    }
  }

  Future<Map<String, dynamic>> _connectCompanion() async {
    // TinyUSB application CDC needs DTR at 115200 (not a 1200-baud touch).
    // Espressif's hardware USB-Serial/JTAG instead uses these lines for
    // reset/download control and has no application DTR session requirement.
    // Its Arduino HWCDC uses FIFO progress, not TinyUSB line-state gating.
    final endpoint = transport.activeDevice;
    if (endpoint == null ||
        endpoint.vendorId != 0x303a ||
        endpoint.productId != 0x1001) {
      await transport.setSignals(dtr: true, rts: false);
    }
    _terminalHandoff = false;
    _originalLogging = null;
    _originalLoggingReply = null;
    _client = _CompanionClient(transport, timeout);
    try {
      return _parseSelf(
        await _client!.query([1, 3, ...ascii.encode('      mcopen')], 5),
      );
    } on TimeoutException {
      /* Full Companion may currently be a text terminal. */
    } on _NodeRejected {
      /* CommonCLI can reject binary framing. */
    }
    await transport.purge();
    final start = await _text('+++MESHCORE-TERM-START');
    if (!start.contains('Terminal') && !start.contains('terminal')) {
      throw const UsbBackupUnavailable(
        'USB node did not answer as a companion',
      );
    }
    final logging = await _text('get usb.logging');
    final match = RegExp(
      r'\busb\.logging\s+(on|off|stream)\b',
      caseSensitive: false,
    ).firstMatch(logging);
    if (match == null) {
      throw const UsbBackupUnavailable(
        'USB terminal did not report its logging state',
      );
    }
    _originalLogging = match.group(1)!.toLowerCase();
    _originalLoggingReply = logging;
    _terminalHandoff = true;
    if (_originalLogging != 'off') {
      final reply = await _text('set usb.logging off');
      if (!reply.contains('OK - USB logging off (saved)') ||
          reply.contains('reboot required')) {
        throw const UsbBackupUnavailable(
          'USB logging cannot be disabled without a reboot',
        );
      }
    }
    final stop = await _text('+++MESHCORE-TERM-STOP');
    if (!stop.contains('OK - Binary mode')) {
      throw const UsbBackupUnavailable(
        'USB terminal did not enter binary mode',
      );
    }
    _client = _CompanionClient(transport, timeout);
    try {
      return _parseSelf(
        await _client!.query([1, 3, ...ascii.encode('      mcopen')], 5),
      );
    } on TimeoutException {
      throw const UsbBackupUnavailable(
        'USB node did not answer after terminal handoff',
      );
    }
  }

  Future<void> _finish() async {
    try {
      if (_terminalHandoff) {
        await _text('+++MESHCORE-TERM-START');
        final state = _originalLogging;
        if (state != null) {
          final reply = await _text('set usb.logging $state');
          if (!reply.contains('OK - USB logging $state')) {
            throw const UsbBackupUnavailable(
              'Could not restore the original USB logging state',
            );
          }
        }
      }
    } finally {
      _terminalHandoff = false;
      _originalLogging = null;
      _originalLoggingReply = null;
      _client = null;
      await transport.close();
    }
  }

  Future<String> _text(String command) async {
    if (!RegExp(r'^[\x20-\x7e]+$').hasMatch(command) || command.length > 256) {
      throw const FormatException('Unsafe USB CLI command');
    }
    await transport.purge();
    await transport.write(Uint8List.fromList(ascii.encode('$command\n')));
    final bytes = BytesBuilder();
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final chunk = await transport.read(
        timeout: const Duration(milliseconds: 100),
      );
      bytes.add(chunk);
      if (bytes.length > 16384) {
        throw const FormatException('USB CLI reply exceeds limit');
      }
      final text = utf8.decode(bytes.toBytes(), allowMalformed: true);
      if (chunk.isEmpty &&
          bytes.length > 0 &&
          (text.contains('\n') || text.contains('>'))) {
        break;
      }
    }
    return utf8
        .decode(bytes.takeBytes(), allowMalformed: true)
        .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '')
        .replaceAll('\r', '');
  }

  Future<Map<String, dynamic>> _captureCompanion(
    UsbFlashDevice device,
    Map<String, dynamic> self,
  ) async {
    if (self['adv_type'] != 1) {
      throw const UsbBackupUnavailable('Node is not a companion');
    }
    final sections = <String, dynamic>{
      'self_info': _section(self, required: true),
    };
    final c = _client!;
    await _captureSection(
      sections,
      'device_info',
      true,
      () async => _parseDevice(await c.query([22, 3], 13)),
    );
    final info = _map(_map(sections['device_info'])['data']);
    await _captureSection(sections, 'identity_private_key', true, () async {
      final frame = await c.query([23], 14);
      if (frame.length != 65) {
        throw const FormatException('Invalid private-key response length');
      }
      final key = frame.sublist(1);
      if (meshCoreExpandedPublicKey(key) != self['public_key']) {
        throw const FormatException('Private/public identity mismatch');
      }
      return {'private_key': _hexEncode(key)};
    });
    await _captureSection(sections, 'contacts', true, c.contacts);
    if (_map(sections['contacts'])['state'] == 'complete') {
      final rows = _map(_map(sections['contacts'])['data']);
      _map(sections['contacts'])['counts'] = {
        'declared': rows.length,
        'received': rows.length,
      };
    }
    await _captureSection(sections, 'channels', true, () async {
      final capacity = info['max_channels'];
      if (capacity is! int || capacity < 0 || capacity > 255) {
        throw const FormatException('Invalid channel capacity');
      }
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < capacity; i++) {
        rows.add(_parseChannel(await c.query([31, i], 18), i));
      }
      return rows;
    });
    if (_map(sections['channels'])['state'] == 'complete') {
      final rows = _map(sections['channels'])['data'] as List;
      _map(sections['channels'])['counts'] = {
        'declared': info['max_channels'],
        'received': rows.length,
      };
    }
    await _captureSection(sections, 'battery_and_storage', false, () async {
      final f = await c.query([20], 12);
      if (f.length != 3 && f.length != 11) {
        throw const FormatException('Invalid battery/storage response');
      }
      final v = ByteData.sublistView(f);
      return {
        'level': v.getUint16(1, Endian.little),
        if (f.length == 11) 'used_kb': v.getUint32(3, Endian.little),
        if (f.length == 11) 'total_kb': v.getUint32(7, Endian.little),
      };
    });
    await _captureSection(sections, 'autoadd', true, () async {
      final f = await c.query([59], 25);
      if (f.length != 2) {
        throw const FormatException('Invalid autoadd response');
      }
      return {'config': f[1]};
    });
    await _captureSection(sections, 'default_flood_scope', true, () async {
      final f = await c.query([64], 27);
      if (f.length == 1) return <String, dynamic>{};
      if (f.length != 48) {
        throw const FormatException('Invalid flood-scope response');
      }
      return {
        'scope_name': _cstring(f.sublist(1, 32)),
        'scope_key': _hexEncode(f.sublist(32, 48)),
      };
    });
    await _captureSection(sections, 'tuning', true, () async {
      final f = await c.query([43], 23);
      if (f.length != 9) throw const FormatException('Invalid tuning response');
      final v = ByteData.sublistView(f);
      return {
        'rx_delay': v.getUint32(1, Endian.little),
        'airtime_factor': v.getUint32(5, Endian.little),
      };
    });
    await _captureSection(sections, 'custom_vars', true, () async {
      final f = await c.query([40], 21);
      final text = utf8.decode(f.sublist(1));
      final vars = <String, dynamic>{};
      if (text.isEmpty) return vars;
      for (final pair in text.split(',')) {
        final colon = pair.indexOf(':');
        if (colon < 1 || vars.containsKey(pair.substring(0, colon))) {
          throw const FormatException('Invalid custom vars');
        }
        vars[pair.substring(0, colon)] = pair.substring(colon + 1);
      }
      return vars;
    });
    for (final entry in _cliQueries.entries) {
      await _captureSection(sections, entry.key, false, () async {
        final text = entry.key == 'usb_logging' && _originalLoggingReply != null
            ? _originalLoggingReply!.trim()
            : await c.cli(entry.value);
        if (entry.key == 'bluetooth_name') {
          final match = RegExp(
            r'^>\s*(.*?)\s+\((default from node name|custom)\)\s*$',
            caseSensitive: false,
          ).firstMatch(text.trim());
          if (match == null) {
            throw const FormatException('Unrecognized Bluetooth name reply');
          }
          return {
            'name': match.group(1)!,
            'default':
                match.group(2)!.toLowerCase() == 'default from node name',
          };
        }
        return {'text': text};
      });
      _map(sections[entry.key])['command'] = entry.value;
    }
    try {
      final version = _fullVersion(await c.cli('version'));
      if (version != null &&
          _map(sections['device_info'])['state'] == 'complete') {
        info['ver_full'] = version;
      }
    } catch (_) {
      /* Raw protocol version remains preserved. */
    }
    final last = _parseSelf(
      await c.query([1, 3, ...ascii.encode('      mcopen')], 5),
    );
    if (last['public_key'] != self['public_key']) {
      throw const UsbBackupUnavailable('Node identity changed during backup');
    }
    sections['identity_stability'] = _section({'stable': true}, required: true);
    return _payload(
      device,
      self['public_key'] as String,
      'companion',
      'companion-api',
      sections,
    );
  }

  Future<Map<String, dynamic>> _captureCli(UsbFlashDevice device) async {
    final key = _findHex(await _text('get public.key'), 32);
    if (key == null) {
      throw const UsbBackupUnavailable(
        'USB node did not answer as MeshCore CommonCLI; backup is unavailable in DFU or unsupported firmware',
      );
    }
    final private = _findHex(await _text('get prv.key'), 64);
    final sections = <String, dynamic>{
      'identity_public_key': _section({'public_key': key}, required: true),
      'identity_private_key':
          private != null && meshCoreExpandedPublicKey(_hex(private, 64)) == key
          ? _section({'private_key': private}, required: true)
          : _unavailable(
              'error',
              true,
              'Private identity export unavailable or mismatched',
            ),
      'contacts': _unavailable(
        'not_applicable',
        false,
        'Not exposed by this role',
      ),
      'channels': _unavailable(
        'not_applicable',
        false,
        'Not exposed by this role',
      ),
    };
    final role = _role(await _text('get role'));
    final settings = <String, dynamic>{};
    for (final command in ['ver', 'get role', ..._textSettings]) {
      final text = await _text(command);
      settings[command] = {'ok': _supportedText(text), 'text': text};
    }
    sections['settings'] = _section(settings, required: true);
    for (final command in ['get acl', 'region']) {
      final reply = await _text(command);
      final required = role != 'sensor';
      sections[command == 'region' ? 'regions' : 'acl'] = _supportedText(reply)
          ? _section({'raw': reply}, required: required)
          : _unavailable(
              'unsupported',
              required,
              'Firmware does not expose this query',
            );
    }
    if (_findHex(await _text('get public.key'), 32) != key) {
      throw const UsbBackupUnavailable('Node identity changed during backup');
    }
    sections['identity_stability'] = _section({'stable': true}, required: true);
    return _payload(device, key, role, 'meshcore-cli-common-cli', sections);
  }

  Future<void> _captureSection(
    Map<String, dynamic> sections,
    String name,
    bool required,
    Future<dynamic> Function() query,
  ) async {
    try {
      sections[name] = _section(await query(), required: required);
    } on _NodeRejected catch (e) {
      sections[name] = _unavailable(
        e.disabled ? 'disabled' : 'unsupported',
        required,
        'Firmware does not expose this query',
      );
    } on TimeoutException {
      sections[name] = _unavailable('error', required, 'USB query timed out');
    } on FormatException {
      sections[name] = _unavailable(
        'error',
        required,
        'USB response failed validation',
      );
    }
  }

  /// Restore writable configuration only. Firmware/build/model metadata are
  /// always observations and are never commands. New hardware/identity each
  /// require separate explicit caller authorization.
  Future<void> restore(
    UsbFlashDevice device,
    UsbNodeBackupArchive archive, {
    bool replaceIdentity = false,
    bool newHardware = false,
    void Function(double progress, String stage)? onProgress,
  }) async {
    archive.verify();
    if (!archive.isComplete ||
        _map(_map(archive._payload['source'])['node'])['role'] != 'companion') {
      throw const UsbBackupUnavailable(
        'Restore requires a complete companion backup; CommonCLI snapshots are partial and cannot be automatically restored',
      );
    }
    _rejectDfu(device, false);
    await transport.open(device);
    try {
      final self = await _connectCompanion();
      final c = _client!;
      final liveDevice = _parseDevice(await c.query([22, 3], 13));
      final sections = archive._sections;
      final savedDevice = _map(_map(sections['device_info'])['data']);
      final savedSelf = _map(_map(sections['self_info'])['data']);
      final savedPhysical = _map(
        _map(archive._payload['source'])['physical_usb_identity'],
      );
      final actual = transport.activeDevice ?? device;
      if (!newHardware &&
          (savedPhysical['serial'] is String &&
                  (savedPhysical['serial'] as String).isNotEmpty
              ? actual.serialNumber != savedPhysical['serial']
              : actual.deviceName != savedPhysical['location'])) {
        throw const UsbBackupUnavailable(
          'Target USB identity differs; explicitly authorize restoring to new hardware',
        );
      }
      if (liveDevice['model'] != savedDevice['model'] && !newHardware) {
        throw const UsbBackupUnavailable(
          'Target model differs; explicitly authorize restoring to new hardware',
        );
      }
      final channels = _map(sections['channels'])['data'] as List;
      final contacts = _map(_map(sections['contacts'])['data']);
      final capacity = liveDevice['max_channels'] as int;
      if ((channels.length > capacity &&
              channels
                  .skip(capacity)
                  .any((r) => _map(r)['channel_name'] != '')) ||
          contacts.length > (liveDevice['max_contacts'] as int)) {
        throw const UsbBackupUnavailable(
          'Target has insufficient channel/contact capacity',
        );
      }
      if (self['public_key'] != archive.publicKey) {
        if (!replaceIdentity && !newHardware) {
          throw const UsbBackupUnavailable(
            'Target public key differs; explicitly authorize identity replacement',
          );
        }
      }
      final expectedIdentity = replaceIdentity
          ? archive.publicKey
          : self['public_key'] as String;
      if (self['public_key'] != archive.publicKey && replaceIdentity) {
        await c.ok([
          24,
          ..._hex(
            _map(_map(sections['identity_private_key'])['data'])['private_key'],
            64,
          ),
        ]);
        final verified = _parseSelf(
          await c.query([1, 3, ...ascii.encode('      mcopen')], 5),
        );
        if (verified['public_key'] != archive.publicKey) {
          throw const UsbBackupUnavailable(
            'Imported identity did not verify; stopped before settings',
          );
        }
      }
      onProgress?.call(.1, 'Identity verified');
      for (var i = 0; i < channels.length && i < capacity; i++) {
        final row = _map(channels[i]);
        final current = _parseChannel(await c.query([31, i], 18), i);
        if (_canonical(current) != _canonical(row)) {
          await c.ok([
            32,
            i,
            ..._padded(row['channel_name'] as String, 32),
            ..._hex(row['channel_secret'], 16),
          ]);
          if (_canonical(_parseChannel(await c.query([31, i], 18), i)) !=
              _canonical(row)) {
            throw const UsbBackupUnavailable('Channel verification failed');
          }
        }
      }
      onProgress?.call(.3, 'Channels verified');
      final existing = await c.contacts();
      const fields = [
        'public_key',
        'type',
        'flags',
        'out_path_len',
        'out_path_hash_mode',
        'out_path',
        'adv_name',
        'adv_lat',
        'adv_lon',
      ];
      for (final entry in contacts.entries) {
        final row = _map(entry.value);
        if (!_equalFields(row, existing[entry.key], fields)) {
          await c.ok(_contactWrite(row));
        }
      }
      final afterContacts = await c.contacts();
      if (contacts.entries.any(
        (e) => !_equalFields(_map(e.value), afterContacts[e.key], fields),
      )) {
        throw const UsbBackupUnavailable('Contact verification failed');
      }
      onProgress?.call(.5, 'Contacts verified');
      await c.ok([8, ...utf8.encode(savedSelf['name'] as String)]);
      await c.ok([
        14,
        ..._ints([
          (savedSelf['adv_lat'] as num).toDouble() * 1e6,
          (savedSelf['adv_lon'] as num).toDouble() * 1e6,
          0,
        ], signed: true),
      ]);
      // TX capability differs across boards. Never exceed the target maximum.
      final tx = (savedSelf['tx_power'] as int).clamp(
        0,
        self['max_tx_power'] as int,
      );
      await c.ok([12, tx]);
      await c.ok([
        11,
        ..._ints([
          (savedSelf['radio_freq'] as num) * 1000,
          (savedSelf['radio_bw'] as num) * 1000,
        ]),
        savedSelf['radio_sf'] as int,
        savedSelf['radio_cr'] as int,
        if (liveDevice['repeat'] is bool)
          (savedDevice['repeat'] == true ? 1 : 0),
      ]);
      await c.ok([
        38,
        savedSelf['manual_add_contacts'] == true ? 1 : 0,
        (savedSelf['telemetry_mode_base'] as int) |
            ((savedSelf['telemetry_mode_loc'] as int) << 2) |
            ((savedSelf['telemetry_mode_env'] as int) << 4),
        savedSelf['adv_loc_policy'] as int,
        savedSelf['multi_acks'] as int,
      ]);
      final afterSelf = _parseSelf(
        await c.query([1, 3, ...ascii.encode('      mcopen')], 5),
      );
      final expected = Map<String, dynamic>.from(savedSelf)..['tx_power'] = tx;
      if (!_equalFields(expected, afterSelf, [
            'name',
            'tx_power',
            'radio_freq',
            'radio_bw',
            'radio_sf',
            'radio_cr',
            'manual_add_contacts',
            'telemetry_mode_base',
            'telemetry_mode_loc',
            'telemetry_mode_env',
            'adv_loc_policy',
            'multi_acks',
          ]) ||
          ((afterSelf['adv_lat'] as num) - (savedSelf['adv_lat'] as num))
                  .abs() >
              .000002 ||
          ((afterSelf['adv_lon'] as num) - (savedSelf['adv_lon'] as num))
                  .abs() >
              .000002) {
        throw const UsbBackupUnavailable(
          'Companion settings verification failed',
        );
      }
      if (savedDevice['ble_pin'] is int) {
        await c.ok([
          37,
          ..._ints([savedDevice['ble_pin'] as int]),
        ]);
        if (_parseDevice(await c.query([22, 3], 13))['ble_pin'] !=
            savedDevice['ble_pin']) {
          throw const UsbBackupUnavailable('Bluetooth PIN verification failed');
        }
      }
      final auto = _map(_map(sections['autoadd'])['data'])['config'] as int;
      await c.ok([58, auto]);
      final autoAfter = await c.query([59], 25);
      if (autoAfter.length != 2 || autoAfter[1] != auto) {
        throw const UsbBackupUnavailable('Auto-add verification failed');
      }
      final tuning = _map(_map(sections['tuning'])['data']);
      await c.ok([
        21,
        ..._ints([tuning['rx_delay'] as int, tuning['airtime_factor'] as int]),
        0,
        0,
      ]);
      final tuneAfter = await c.query([43], 23);
      if (tuneAfter.length != 9 ||
          !_bytesEqual(
            tuneAfter.sublist(1),
            _ints([tuning['rx_delay'] as int, tuning['airtime_factor'] as int]),
          )) {
        throw const UsbBackupUnavailable('Radio tuning verification failed');
      }
      final custom = _map(_map(sections['custom_vars'])['data']);
      // Board-specific calibration variables should never cross platforms.
      if (!newHardware) {
        for (final entry in custom.entries) {
          if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(entry.key) ||
              entry.value is! String ||
              (entry.value as String).contains(RegExp(r'[:,\r\n]'))) {
            throw const FormatException('Unsafe custom variable');
          }
          await c.ok([41, ...utf8.encode('${entry.key}:${entry.value}')]);
        }
        final varsAfter = utf8.decode((await c.query([40], 21)).sublist(1));
        final current = <String, String>{};
        for (final pair in varsAfter.split(',')) {
          final split = pair.indexOf(':');
          if (split > 0) {
            current[pair.substring(0, split)] = pair.substring(split + 1);
          }
        }
        if (custom.entries.any((e) => current[e.key] != e.value)) {
          throw const UsbBackupUnavailable(
            'Custom variables verification failed',
          );
        }
      }
      final scope = _map(_map(sections['default_flood_scope'])['data']);
      final scopeName = scope['scope_name'] as String? ?? '';
      final scopeKey = scopeName.isEmpty
          ? Uint8List(16)
          : _hex(scope['scope_key'], 16);
      await c.ok([63, ..._padded(scopeName, 31), ...scopeKey]);
      final scopeAfter = await c.query([64], 27);
      if (scopeName.isEmpty
          ? scopeAfter.length != 1
          : (scopeAfter.length != 48 ||
                _cstring(scopeAfter.sublist(1, 32)) != scopeName ||
                !_bytesEqual(scopeAfter.sublist(32), scopeKey))) {
        throw const UsbBackupUnavailable('Flood scope verification failed');
      }
      onProgress?.call(.8, 'Companion settings verified');
      await _restoreCliSettings(c, sections, newHardware);
      // Phone apps need a new sync after restore. Only cycle previously-on BLE.
      String? bluetooth;
      try {
        bluetooth = await c.cli('get bluetooth');
      } on _NodeRejected {
        /* Older firmware */
      }
      if (bluetooth != null &&
          RegExp(
            r'\bbluetooth\s+on\b',
            caseSensitive: false,
          ).hasMatch(bluetooth)) {
        try {
          await c.cli('set bluetooth off');
        } finally {
          await c.cli('set bluetooth on');
        }
        if (!RegExp(
          r'\bbluetooth\s+on\b',
          caseSensitive: false,
        ).hasMatch(await c.cli('get bluetooth'))) {
          throw const UsbBackupUnavailable('Bluetooth could not be re-enabled');
        }
      }
      final identityAfterRestore = _parseSelf(
        await c.query([1, 3, ...ascii.encode('      mcopen')], 5),
      );
      if (identityAfterRestore['public_key'] != expectedIdentity) {
        throw const UsbBackupUnavailable(
          'Target private identity changed during restore',
        );
      }
      onProgress?.call(1, 'Restore verified; reconnect the phone app');
    } finally {
      await _finish();
    }
  }

  Future<void> _restoreCliSettings(
    _CompanionClient c,
    Map<String, dynamic> sections,
    bool newHardware,
  ) async {
    for (final entry in _cliQueries.entries) {
      final section = _map(sections[entry.key]);
      if (section['state'] != 'complete' || entry.key == 'storage_layout') {
        continue;
      }
      if (newHardware &&
          [
            'radio_fem_rxgain',
            'radio_fem_txgain',
            'radio_rxgain',
            'display_rotation',
            'power_saving',
            'radio_rxps',
          ].contains(entry.key)) {
        continue;
      }
      final data = _map(section['data']);
      if (entry.key == 'bluetooth_name') {
        final desired = data['name'] as String;
        final isDefault = data['default'] as bool;
        if (!RegExp(r'^[\x20-\x7e]{1,31}$').hasMatch(desired)) {
          throw const FormatException('Invalid Bluetooth name');
        }
        final current = RegExp(
          r'^>\s*(.*?)\s+\((default from node name|custom)\)\s*$',
          caseSensitive: false,
        ).firstMatch((await c.cli('get bluetooth.name')).trim());
        if (current != null &&
            (isDefault
                ? current.group(2)!.toLowerCase() == 'default from node name'
                : current.group(1) == desired &&
                      current.group(2)!.toLowerCase() == 'custom')) {
          continue;
        }
        final reply = await c.cli(
          isDefault
              ? 'set bluetooth.name default'
              : 'set bluetooth.name $desired',
        );
        if (!reply.contains('OK')) {
          throw const UsbBackupUnavailable('Bluetooth name restore failed');
        }
        final after = await c.cli('get bluetooth.name');
        final match = RegExp(
          r'^>\s*(.*?)\s+\((default from node name|custom)\)\s*$',
          caseSensitive: false,
        ).firstMatch(after.trim());
        if (match == null ||
            (!isDefault && match.group(1) != desired) ||
            (match.group(2)!.toLowerCase() == 'default from node name') !=
                isDefault) {
          throw const UsbBackupUnavailable(
            'Bluetooth name verification failed',
          );
        }
        continue;
      }
      final text = data['text'] as String;
      final setting = entry.value.substring(4);
      final current = await c.cli(entry.value);
      if (current.trim() == text.trim()) continue;
      String? value;
      if (entry.key == 'radio_cad') {
        final match = RegExp(
          r'radio\.cad\s+(on|off),\s*scan=(auto|\d+)(?:\(\d+\))?\s+ms,\s*retry=(auto|\d+)\s+ms,\s*max=(auto|\d+)\s+ms',
          caseSensitive: false,
        ).firstMatch(text);
        if (match == null) {
          throw const FormatException('Unrecognized radio CAD backup');
        }
        final timings = '${match.group(2)} ${match.group(3)} ${match.group(4)}';
        if (!(await c.cli('set radio.cad timings $timings')).contains('OK') ||
            !(await c.cli('set radio.cad ${match.group(1)}')).contains('OK')) {
          throw const UsbBackupUnavailable(
            'Radio CAD restore was not confirmed',
          );
        }
        final after = RegExp(
          r'radio\.cad\s+(on|off),\s*scan=(auto|\d+)(?:\(\d+\))?\s+ms,\s*retry=(auto|\d+)\s+ms,\s*max=(auto|\d+)\s+ms',
          caseSensitive: false,
        ).firstMatch(await c.cli(entry.value));
        if (after == null ||
            List.generate(4, (i) => after.group(i + 1)).join(',') !=
                List.generate(4, (i) => match.group(i + 1)).join(',')) {
          throw const UsbBackupUnavailable('Radio CAD verification failed');
        }
        continue;
      } else if (entry.key == 'radio_rxps') {
        final match = RegExp(
          r'^>\s*(on|off),level=(\d+),preamble=(16|32),rx=(\d+),sleep=(\d+)\s*$',
        ).firstMatch(text);
        if (match == null) {
          throw const FormatException('Unrecognized RX power saving backup');
        }
        final level = int.parse(match.group(2)!);
        final value = level > 0
            ? 'level $level preamble ${match.group(3)}'
            : '${match.group(4)} ${match.group(5)}';
        if (!(await c.cli('set radio.rxps $value')).contains('OK')) {
          throw const UsbBackupUnavailable('RX power saving restore failed');
        }
        if (match.group(1) == 'off' &&
            !(await c.cli('set radio.rxps off')).contains('OK')) {
          throw const UsbBackupUnavailable(
            'RX power saving off was not confirmed',
          );
        }
        if ((await c.cli(entry.value)).trim() != text.trim()) {
          throw const UsbBackupUnavailable(
            'RX power saving verification failed',
          );
        }
        continue;
      } else if (entry.key == 'usb_logging') {
        value = RegExp(
          r'\busb\.logging\s+(on|off|stream)\b',
        ).firstMatch(text)?.group(1);
      } else {
        final trimmed = text.trim().replaceFirst(RegExp(r'^>\s*'), '');
        value = trimmed.startsWith('$setting ')
            ? trimmed.substring(setting.length + 1).trim()
            : trimmed;
        if (entry.key == 'display_rotation' && value == 'default') value = '0';
      }
      if (value == null ||
          !RegExp(r'^[A-Za-z0-9+.,_-]{1,100}$').hasMatch(value)) {
        throw UsbBackupUnavailable(
          'Captured ${entry.key} uses an unsupported restore format; no guessed setting was written',
        );
      }
      final command = entry.key == 'power_saving'
          ? 'powersaving $value'
          : entry.key == 'radio_rxps'
          ? 'set radio.rxps $value'
          : 'set $setting $value';
      if (!(await c.cli(command)).contains('OK')) {
        throw UsbBackupUnavailable('${entry.key} restore was not confirmed');
      }
      final after = await c.cli(entry.value);
      if (entry.key == 'usb_logging'
          ? RegExp(
                  r'\busb\.logging\s+(on|off|stream)\b',
                ).firstMatch(after)?.group(1) !=
                value
          : after.trim() != text.trim()) {
        throw UsbBackupUnavailable('${entry.key} did not verify');
      }
      if (entry.key == 'usb_logging' && _terminalHandoff) {
        _originalLogging = value;
      }
    }
  }
}

class _NodeRejected implements Exception {
  const _NodeRejected({this.disabled = false});
  final bool disabled;
}

class _CompanionClient {
  _CompanionClient(this.transport, this.timeout);
  final UsbFlashTransport transport;
  final Duration timeout;
  final _decoder = UsbSerialFrameDecoder();
  final List<Uint8List> _frames = [];

  Future<Uint8List> query(List<int> command, int expected) async {
    _frames.clear();
    _decoder.reset();
    await transport.write(wrapUsbSerialTxFrame(Uint8List.fromList(command)));
    while (true) {
      final frame = await _next();
      if (frame[0] == expected) return frame;
      if (frame[0] == 1 || frame[0] == 15) {
        throw _NodeRejected(disabled: frame[0] == 15);
      }
    }
  }

  Future<void> ok(List<int> command) async {
    final result = await query(command, 0);
    if (result.length != 1) {
      throw const FormatException('Malformed command acknowledgement');
    }
  }

  Future<String> cli(String command) async {
    if (command.contains(RegExp(r'[\r\n\x00]'))) {
      throw const FormatException('Invalid framed CLI command');
    }
    final text = utf8
        .decode((await query([66, ...utf8.encode(command)], 29)).sublist(1))
        .trimRight();
    if (!_supportedText(text)) throw const _NodeRejected();
    return text;
  }

  Future<Map<String, dynamic>> contacts() async {
    _frames.clear();
    _decoder.reset();
    await transport.write(wrapUsbSerialTxFrame(Uint8List.fromList([4])));
    int? declared;
    final rows = <String, dynamic>{};
    while (true) {
      final frame = await _next();
      if (frame[0] == 1) throw const _NodeRejected();
      if (frame[0] == 2) {
        if (frame.length != 5 || declared != null) {
          throw const FormatException('Invalid contacts start');
        }
        declared = ByteData.sublistView(frame).getUint32(1, Endian.little);
        if (declared > 4096) {
          throw const FormatException('Contact inventory exceeds limit');
        }
      } else if (frame[0] == 3) {
        if (declared == null) {
          throw const FormatException('Contact before inventory start');
        }
        final row = _parseContact(frame);
        if (rows.containsKey(row['public_key'])) {
          throw const FormatException('Duplicate contact identity');
        }
        rows[row['public_key'] as String] = row;
      } else if (frame[0] == 4) {
        if (frame.length != 5 || declared != rows.length) {
          throw const FormatException('Contact inventory count mismatch');
        }
        return rows;
      }
    }
  }

  Future<Uint8List> _next() async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      if (_frames.isNotEmpty) return _frames.removeAt(0);
      final input = await transport.read(
        timeout: const Duration(milliseconds: 100),
      );
      _frames.addAll(
        _decoder
            .ingest(input)
            .where((p) => p.isRxFrame && p.payload.isNotEmpty)
            .map((p) => p.payload),
      );
    }
    throw TimeoutException('MeshCore USB response timed out');
  }
}

Map<String, dynamic> _payload(
  UsbFlashDevice device,
  String key,
  String role,
  String capture,
  Map<String, dynamic> sections,
) {
  final missing =
      sections.entries
          .where(
            (e) =>
                _map(e.value)['required'] == true &&
                _map(e.value)['state'] != 'complete',
          )
          .map((e) => e.key)
          .toList()
        ..sort();
  final errors =
      sections.entries
          .where(
            (e) =>
                _map(e.value)['required'] == false &&
                _map(e.value)['state'] == 'error',
          )
          .map((e) => e.key)
          .toList()
        ..sort();
  return {
    'source': {
      'transport': 'usb-serial',
      'port_at_capture': device.deviceName,
      'physical_usb_identity': {
        'serial': device.serialNumber,
        'location': device.deviceName,
        'parent': null,
        'interface': device.portNumber.toString(),
        'device_hint': device.productName,
        'attestation': 'caller-provided',
      },
      'node': {
        'public_key': key,
        'role': role,
        'device_hint': device.productName,
      },
      'capture_api': capture,
    },
    'sections': sections,
    'excluded': {
      'messages': 'Reading consumes unread messages; not exported',
      'logs': 'Runtime logs are not configuration',
      'unexposed_preferences':
          'No versioned export for every board-specific preference',
    },
    'completeness': {
      'status': capture == 'companion-api' && missing.isEmpty && errors.isEmpty
          ? 'api-snapshot-complete'
          : 'partial',
      'safe_for_wipe': false,
      'safe_for_restore': false,
      'missing_required': missing,
      'optional_errors': errors,
      'reasons': [
        ...missing.map((v) => 'required section incomplete: $v'),
        ...errors.map((v) => 'optional query failed: $v'),
        'Unread messages and unexposed role-specific preferences are not backed up',
        if (capture != 'companion-api')
          'CommonCLI has no versioned bulk export; automatic restore is unavailable',
      ],
    },
    'restore_plan': {
      'executor_implemented': false,
      'requires_separate_explicit_confirmation': true,
      'requires_target_public_key_or_blank_identity_gate': true,
      'strategy': 'role-aware MeshCore APIs',
      'ordered_sections': sections.entries
          .where((e) => _map(e.value)['state'] == 'complete')
          .map((e) => e.key)
          .toList(),
      'unavailable_sections': sections.entries
          .where((e) => _map(e.value)['state'] != 'complete')
          .map(
            (e) => {
              'section': e.key,
              'state': _map(e.value)['state'],
              'reason': _map(e.value)['reason'],
            },
          )
          .toList(),
      'post_restore_verification': [
        'Re-query identity and each writable restored section',
      ],
    },
  };
}

Map<String, dynamic> _section(dynamic data, {required bool required}) => {
  'state': 'complete',
  'required': required,
  'data': data,
};
Map<String, dynamic> _unavailable(String state, bool required, String reason) =>
    {'state': state, 'required': required, 'reason': reason};
Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Expected backup object');
}

String _hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
Uint8List _hex(dynamic value, int length) {
  if (value is! String ||
      !RegExp('^[0-9a-f]{${length * 2}}\$').hasMatch(value)) {
    throw const FormatException('Invalid hexadecimal key/data');
  }
  return Uint8List.fromList([
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ]);
}

String? _findHex(String text, int length) => RegExp(
  '(?<![0-9A-Fa-f])[0-9A-Fa-f]{${length * 2}}(?![0-9A-Fa-f])',
).firstMatch(text)?.group(0)?.toLowerCase();
String _cstring(List<int> bytes) =>
    utf8.decode(bytes.takeWhile((b) => b != 0).toList());
Uint8List _padded(String text, int length) {
  final bytes = utf8.encode(text);
  if (bytes.length > length) {
    throw const FormatException('Name exceeds target capacity');
  }
  return Uint8List(length)..setRange(0, bytes.length, bytes);
}

Uint8List _ints(List<num> values, {bool signed = false}) {
  final bytes = Uint8List(values.length * 4);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    if (signed) {
      view.setInt32(i * 4, values[i].round(), Endian.little);
    } else {
      view.setUint32(i * 4, values[i].round(), Endian.little);
    }
  }
  return bytes;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

bool _equalFields(Map<String, dynamic> a, dynamic b, List<String> fields) =>
    b is Map && fields.every((f) => a[f] == b[f]);
bool _supportedText(String text) =>
    text.trim().isNotEmpty &&
    !text.toLowerCase().contains('unknown command') &&
    !text.toLowerCase().contains('unsupported') &&
    !RegExp(r'^(?:>\s*)?error', caseSensitive: false).hasMatch(text.trim());
String _role(String text) {
  final lower = text.toLowerCase();
  for (final role in ['repeater', 'room-server', 'sensor']) {
    if (lower.contains(role) || lower.contains(role.replaceAll('-', ' '))) {
      return role;
    }
  }
  return 'common-cli';
}

String? _fullVersion(String text) => RegExp(
  r'\bCompanion\s+(\S+)\s+\(protocol\b',
  caseSensitive: false,
).firstMatch(text)?.group(1);

Map<String, dynamic> _parseSelf(Uint8List frame) {
  if (frame.length < 58 || frame[0] != 5) {
    throw const FormatException('Malformed SELF_INFO');
  }
  final v = ByteData.sublistView(frame);
  final telemetry = frame[46];
  final self = <String, dynamic>{
    'adv_type': frame[1],
    'tx_power': frame[2],
    'max_tx_power': frame[3],
    'public_key': _hexEncode(frame.sublist(4, 36)),
    'adv_lat': v.getInt32(36, Endian.little) / 1e6,
    'adv_lon': v.getInt32(40, Endian.little) / 1e6,
    'multi_acks': frame[44],
    'adv_loc_policy': frame[45],
    'telemetry_mode_base': telemetry & 3,
    'telemetry_mode_loc': (telemetry >> 2) & 3,
    'telemetry_mode_env': (telemetry >> 4) & 3,
    'manual_add_contacts': frame[47] != 0,
    'radio_freq': v.getUint32(48, Endian.little) / 1000,
    'radio_bw': v.getUint32(52, Endian.little) / 1000,
    'radio_sf': frame[56],
    'radio_cr': frame[57],
    'name': _cstring(frame.sublist(58)),
  };
  _validateSelf(self);
  return self;
}

void _validateSelf(Map<String, dynamic> self) {
  _hex(self['public_key'], 32);
  if (self['name'] is! String ||
      (self['name'] as String).isEmpty ||
      utf8.encode(self['name'] as String).length > 32 ||
      self['radio_sf'] is! int ||
      (self['radio_sf'] as int) < 5 ||
      (self['radio_sf'] as int) > 12 ||
      self['radio_cr'] is! int ||
      (self['radio_cr'] as int) < 5 ||
      (self['radio_cr'] as int) > 8 ||
      self['radio_freq'] is! num ||
      (self['radio_freq'] as num) < 100 ||
      (self['radio_freq'] as num) > 3000 ||
      self['radio_bw'] is! num ||
      (self['radio_bw'] as num) < 7 ||
      (self['radio_bw'] as num) > 500 ||
      self['adv_lat'] is! num ||
      (self['adv_lat'] as num).abs() > 90 ||
      self['adv_lon'] is! num ||
      (self['adv_lon'] as num).abs() > 180) {
    throw const FormatException('SELF_INFO values are invalid');
  }
}

Map<String, dynamic> _parseDevice(Uint8List frame) {
  if (frame.length < 80 || frame[0] != 13 || frame[1] < 3) {
    throw const FormatException('Malformed DEVICE_INFO');
  }
  final data = <String, dynamic>{
    'fw ver': frame[1],
    'max_contacts': frame[2] * 2,
    'max_channels': frame[3],
    'ble_pin': ByteData.sublistView(frame).getUint32(4, Endian.little),
    'fw_build': _cstring(frame.sublist(8, 20)),
    'model': _cstring(frame.sublist(20, 60)),
    'ver': _cstring(frame.sublist(60, 80)),
    if (frame[1] >= 9 && frame.length >= 81) 'repeat': frame[80] != 0,
    if (frame[1] >= 10 && frame.length >= 82) 'path_hash_mode': frame[81],
  };
  _validateDevice(data);
  return data;
}

void _validateDevice(Map<String, dynamic> data) {
  if (data['max_channels'] is! int ||
      (data['max_channels'] as int) < 0 ||
      (data['max_channels'] as int) > 255 ||
      data['max_contacts'] is! int ||
      (data['max_contacts'] as int) < 0 ||
      (data['max_contacts'] as int) > 510 ||
      data['model'] is! String ||
      (data['model'] as String).isEmpty ||
      data['ver'] is! String ||
      (data['ver'] as String).isEmpty ||
      data['ble_pin'] is! int ||
      (data['ble_pin'] != 0 &&
          ((data['ble_pin'] as int) < 100000 ||
              (data['ble_pin'] as int) > 999999)) ||
      (data['fw ver'] as int) >= 9 && data['repeat'] is! bool ||
      (data['fw ver'] as int) >= 10 &&
          (data['path_hash_mode'] is! int ||
              (data['path_hash_mode'] as int) < 0 ||
              (data['path_hash_mode'] as int) > 3)) {
    throw const FormatException('Invalid DEVICE_INFO capacities/model');
  }
}

Map<String, dynamic> _parseChannel(Uint8List frame, int index) {
  if (frame.length != 50 || frame[0] != 18 || frame[1] != index) {
    throw const FormatException('Malformed channel record');
  }
  final row = <String, dynamic>{
    'channel_idx': index,
    'channel_name': _cstring(frame.sublist(2, 34)),
    'channel_secret': _hexEncode(frame.sublist(34, 50)),
  };
  _validateChannel(row, index);
  return row;
}

void _validateChannel(Map<String, dynamic> row, int index) {
  if (row['channel_idx'] != index ||
      row['channel_name'] is! String ||
      utf8.encode(row['channel_name'] as String).length > 32) {
    throw const FormatException('Invalid channel record');
  }
  _hex(row['channel_secret'], 16);
}

Map<String, dynamic> _parseContact(Uint8List frame) {
  if (frame.length != 148 || frame[0] != 3) {
    throw const FormatException('Malformed contact record');
  }
  final v = ByteData.sublistView(frame);
  final plen = frame[35];
  final mode = plen == 255 ? -1 : plen >> 6;
  final hops = plen == 255 ? -1 : plen & 63;
  if (hops * (mode + 1) > 64) {
    throw const FormatException('Contact path exceeds capacity');
  }
  final row = <String, dynamic>{
    'public_key': _hexEncode(frame.sublist(1, 33)),
    'type': frame[33],
    'flags': frame[34],
    'out_path_len': hops,
    'out_path_hash_mode': mode,
    'out_path': _hexEncode(
      frame.sublist(36, 36 + (hops > 0 ? hops * (mode + 1) : 0)),
    ),
    'adv_name': _cstring(frame.sublist(100, 132)),
    'last_advert': v.getUint32(132, Endian.little),
    'adv_lat': v.getInt32(136, Endian.little) / 1e6,
    'adv_lon': v.getInt32(140, Endian.little) / 1e6,
    'lastmod': v.getUint32(144, Endian.little),
  };
  _validateContact(row);
  return row;
}

void _validateContact(Map<String, dynamic> row) {
  _hex(row['public_key'], 32);
  final hops = row['out_path_len'];
  final mode = row['out_path_hash_mode'];
  final path = row['out_path'];
  if (hops is! int ||
      mode is! int ||
      hops < -1 ||
      hops > 63 ||
      mode < -1 ||
      mode > 3 ||
      path is! String ||
      !RegExp(r'^(?:[0-9a-f]{2})*$').hasMatch(path) ||
      path.length > 128 ||
      (hops > 0 && path.length != hops * (mode + 1) * 2) ||
      (hops <= 0 && path.isNotEmpty) ||
      row['adv_name'] is! String ||
      utf8.encode(row['adv_name'] as String).length > 32 ||
      row['adv_lat'] is! num ||
      (row['adv_lat'] as num).abs() > 90 ||
      row['adv_lon'] is! num ||
      (row['adv_lon'] as num).abs() > 180) {
    throw const FormatException('Invalid contact record');
  }
}

List<int> _contactWrite(Map<String, dynamic> row) {
  final path = _hex(row['out_path'], (row['out_path'] as String).length ~/ 2);
  final hops = row['out_path_len'] as int;
  final mode = row['out_path_hash_mode'] as int;
  return [
    9,
    ..._hex(row['public_key'], 32),
    row['type'] as int,
    row['flags'] as int,
    hops < 0 ? 255 : hops | (mode << 6),
    ...path,
    ...List.filled(64 - path.length, 0),
    ..._padded(row['adv_name'] as String, 32),
    ..._ints([row['last_advert'] as int]),
    ..._ints([
      (row['adv_lat'] as num) * 1e6,
      (row['adv_lon'] as num) * 1e6,
    ], signed: true),
  ];
}

const _cliQueries = <String, String>{
  'storage_layout': 'get storage.layout',
  'radio_cad': 'get radio.cad',
  'radio_rxgain': 'get radio.rxgain',
  'radio_fem_rxgain': 'get radio.fem.rxgain',
  'radio_fem_txgain': 'get radio.fem.txgain',
  'bluetooth_name': 'get bluetooth.name',
  'display_rotation': 'get display.rotation',
  'power_saving': 'get powersaving',
  'usb_logging': 'get usb.logging',
  'radio_rxps': 'get radio.rxps.config',
};
const _textSettings = [
  'get name',
  'get radio',
  'get lat',
  'get lon',
  'get tx',
  'get repeat',
  'get rxdelay',
  'get txdelay',
  'get af',
  'get multi.acks',
  'get advert.interval',
  'get flood.advert.interval',
  'get flood.max',
  'get flood.max.advert',
  'get flood.max.unscoped',
  'get flood.channel.data',
  'get allow.read.only',
  'get telemetry.access',
  'get system.watchdog',
  'get storage.layout',
];

// Python's canonical JSON floats use exponent form below 1e-4/at >=1e16,
// and signed, at-least-two-digit exponents. Preserve cross-tool SHA compatibility.
String _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key as String).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Non-finite backup number');
    }
    final magnitude = value.abs();
    if (magnitude != 0 && (magnitude < .0001 || magnitude >= 1e16)) {
      final split = value.toStringAsExponential().split('e');
      final exponent = int.parse(split[1]);
      var mantissa = split[0];
      if (mantissa.endsWith('.0')) {
        mantissa = mantissa.substring(0, mantissa.length - 2);
      }
      return '${mantissa}e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
    }
  }
  return jsonEncode(value);
}

/// MeshCore stores an expanded Ed25519 secret, NOT a 32-byte seed. Multiplying
/// its first 32 bytes by the standard basepoint matches libsodium's
/// crypto_scalarmult_ed25519_base_noclamp used by meshfirmware backup validation.
String meshCoreExpandedPublicKey(Uint8List expanded) {
  if (expanded.length != 64) {
    throw const FormatException('Expanded identity must be 64 bytes');
  }
  final p = (BigInt.one << 255) - BigInt.from(19);
  final d = (-BigInt.from(121665) * BigInt.from(121666).modInverse(p)) % p;
  final baseX = BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202',
  );
  final baseY = BigInt.parse(
    '46316835694926478169428394003475163141307993866256225615783033603165251855960',
  );
  List<BigInt> add(List<BigInt> a, List<BigInt> b) {
    final aa = ((a[1] - a[0]) * (b[1] - b[0])) % p;
    final bb = ((a[1] + a[0]) * (b[1] + b[0])) % p;
    final cc = (BigInt.two * d * a[3] * b[3]) % p;
    final dd = (BigInt.two * a[2] * b[2]) % p;
    final e = (bb - aa) % p;
    final f = (dd - cc) % p;
    final g = (dd + cc) % p;
    final h = (bb + aa) % p;
    return [(e * f) % p, (g * h) % p, (f * g) % p, (e * h) % p];
  }

  var point = [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
  var base = [baseX, baseY, BigInt.one, (baseX * baseY) % p];
  var scalar = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    scalar = (scalar << 8) | BigInt.from(expanded[i]);
  }
  scalar %= BigInt.parse(
    '7237005577332262213973186563042994240857116359379907606001950938285454250989',
  );
  if (scalar == BigInt.zero) {
    throw const FormatException('Invalid expanded identity scalar');
  }
  while (scalar > BigInt.zero) {
    if (scalar.isOdd) point = add(point, base);
    base = add(base, base);
    scalar >>= 1;
  }
  final inv = point[2].modInverse(p);
  final x = (point[0] * inv) % p;
  var y = (point[1] * inv) % p;
  final output = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    output[i] = (y & BigInt.from(255)).toInt();
    y >>= 8;
  }
  if (x.isOdd) output[31] |= 0x80;
  return _hexEncode(output);
}
