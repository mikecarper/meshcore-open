import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analyzer_packet_service.dart';
import '../services/ble_debug_log_service.dart';
import '../services/management_packet_decoder.dart';
import '../services/mesh_packet_decoder.dart';
import '../services/telemetry_packet_decoder.dart';
import 'companion_cli_screen.dart';

enum PacketToolMode { telemetry, raw, management }

PacketToolMode? detectPacketToolMode(String input) {
  try {
    decodeTelemetry(input);
    return PacketToolMode.telemetry;
  } on FormatException {
    /* Try management. */
  }
  try {
    decodeManagement(input);
    return PacketToolMode.management;
  } on FormatException {
    /* Try raw. */
  }
  try {
    packetInputBytes(input).map(decodeMeshPacket).toList();
    return PacketToolMode.raw;
  } on FormatException {
    return null;
  }
}

class PacketToolsScreen extends StatefulWidget {
  const PacketToolsScreen({
    super.key,
    this.initialInput = '',
    this.initialMode = PacketToolMode.telemetry,
    this.analyzer,
  });
  final String initialInput;
  final PacketToolMode initialMode;
  final AnalyzerPacketService? analyzer;
  @override
  State<PacketToolsScreen> createState() => _PacketToolsScreenState();
}

class _PacketToolsScreenState extends State<PacketToolsScreen> {
  final _input = TextEditingController();
  final _password = TextEditingController();
  final _candidate = TextEditingController();
  final _regionInput = TextEditingController();
  late final AnalyzerPacketService _analyzer;
  late PacketToolMode _mode;
  String? _region;
  String? _error;
  String? _analyzerStatus;
  bool _fetching = false;
  DecodedTelemetry? _telemetry;
  DecodedManagement? _management;
  List<DecodedMeshPacket>? _raw;
  List<AnalyzerPacket> _packets = [];
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _analyzer = widget.analyzer ?? AnalyzerPacketService();
    _mode = widget.initialMode;
    _input.text = widget.initialInput;
    unawaited(_loadRegion());
    if (_input.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _decode();
      });
    }
  }

  Future<void> _loadRegion() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('packet_tools_analyzer_region');
    if (!mounted || _region != null || value == null) return;
    try {
      setState(() {
        _region = AnalyzerPacketService.regionCode(value);
        _regionInput.text = _region!;
      });
    } on FormatException {
      /* Ignore a stale/invalid preference. */
    }
  }

  @override
  void dispose() {
    if (widget.analyzer == null) _analyzer.dispose();
    for (final controller in [_input, _password, _candidate, _regionInput]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _resetResult() {
    _telemetry = null;
    _management = null;
    _raw = null;
    _error = null;
  }

  void _decode() {
    FocusScope.of(context).unfocus();
    setState(() {
      _resetResult();
      try {
        switch (_mode) {
          case PacketToolMode.telemetry:
            _telemetry = decodeTelemetry(_input.text);
          case PacketToolMode.raw:
            _raw = packetInputBytes(_input.text).map(decodeMeshPacket).toList();
          case PacketToolMode.management:
            _management = decodeManagement(
              _input.text,
              password: _password.text,
              candidate: _candidate.text,
            );
        }
      } on FormatException catch (error) {
        _error = error.message;
      }
    });
  }

  Future<void> _selectRegion() async {
    try {
      final region = AnalyzerPacketService.regionCode(_regionInput.text);
      _requestGeneration++;
      setState(() {
        _region = region;
        _packets = [];
        _analyzerStatus = null;
        _fetching = false;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('packet_tools_analyzer_region', region);
    } on FormatException catch (error) {
      if (mounted) setState(() => _analyzerStatus = error.message);
    }
  }

  Future<void> _fetch() async {
    if (_region == null || _fetching) return;
    final generation = ++_requestGeneration;
    final region = _region!;
    setState(() {
      _fetching = true;
      _analyzerStatus = null;
      _packets = [];
    });
    try {
      final packets = await _analyzer.fetchPackets(region);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _packets = packets;
        _analyzerStatus = packets.isEmpty
            ? 'No raw packets returned for $region.'
            : '${packets.length} packets from $region. Tap one to decode.';
      });
    } catch (error) {
      if (mounted && generation == _requestGeneration) {
        setState(
          () => _analyzerStatus = error is FormatException
              ? error.message
              : 'Analyzer request failed: $error',
        );
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _fetching = false);
      }
    }
  }

  void _usePacket(String raw) {
    _input.text = raw;
    PacketToolMode mode = PacketToolMode.raw;
    try {
      final packet = decodeMeshPacket(packetHexBytes(raw));
      final magic = packetAscii(packet.payload, 0, 4);
      if (magic == 'MGR1') mode = PacketToolMode.management;
      if (['TTB1', 'TVB1', 'IVB1'].contains(magic)) {
        mode = PacketToolMode.telemetry;
      }
    } on FormatException {
      /* Show malformed packets in the raw decoder. */
    }
    setState(() {
      _mode = mode;
      _resetResult();
    });
    _decode();
  }

  void _radioPackets() {
    _requestGeneration++;
    final entries = context
        .read<BleDebugLogService>()
        .rawLogRxEntries
        .reversed
        .take(100)
        .toList();
    setState(() {
      _fetching = false;
      _packets = [
        for (final e in entries)
          AnalyzerPacket(
            raw: packetHex(e.payload),
            label: 'Radio RX - ${e.timestamp}',
          ),
      ];
      _analyzerStatus = entries.isEmpty
          ? 'No radio packets captured yet. Connect a companion that provides RX logs.'
          : '${entries.length} recent radio packets. Tap one to decode.';
    });
  }

  void _example() {
    setState(() {
      _resetResult();
      if (_mode == PacketToolMode.management) {
        _input.text = managementExamplePage;
        _password.text = managementExamplePassword;
        _candidate.clear();
      } else {
        _input.text =
            '3E00545642311122334455667788800092651E000800010264C8FEFFDC';
      }
    });
    _decode();
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clipboard?.text == null) return;
    setState(() {
      _input.text = clipboard!.text!.length > 32768
          ? clipboard.text!.substring(0, 32768)
          : clipboard.text!;
      _resetResult();
    });
  }

  Future<void> _open(Uri uri) async {
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException('No browser is available.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _analyzerStatus = 'Could not open browser: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _telemetry != null || _management != null || _raw != null;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Packet tools'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Packet tool actions',
            onSelected: (value) {
              if (value == 'cli') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const CompanionCliScreen(),
                  ),
                );
              }
              if (value == 'telemetry') {
                unawaited(
                  _open(
                    Uri.parse(
                      'https://mikecarper.github.io/MeshCore/telemetry_decoder/',
                    ),
                  ),
                );
              }
              if (value == 'management') {
                unawaited(
                  _open(
                    Uri.parse(
                      'https://mikecarper.github.io/MeshCore/management_decoder/',
                    ),
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cli', child: Text('Companion CLI')),
              PopupMenuItem(
                value: 'telemetry',
                child: Text('Telemetry documentation'),
              ),
              PopupMenuItem(
                value: 'management',
                child: Text('Management documentation'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            const Text(
              'Decode locally. Reports, management passwords, and candidate keys stay on this phone.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final mode in PacketToolMode.values)
                  ChoiceChip(
                    label: Text(switch (mode) {
                      PacketToolMode.telemetry => 'Telemetry',
                      PacketToolMode.raw => 'Raw packet',
                      PacketToolMode.management => 'Management',
                    }),
                    selected: mode == _mode,
                    onSelected: (_) => setState(() {
                      _mode = mode;
                      _resetResult();
                    }),
                  ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                'Analyzer region${_region == null ? '' : ': $_region'}',
              ),
              subtitle: const Text(
                'Download recent packets after selecting a region',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                TextField(
                  key: const Key('analyzer-region'),
                  controller: _regionInput,
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Analyzer region code',
                    helperText: 'IATA region (e.g. SEA), not LoRa.',
                    helperMaxLines: 2,
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _selectRegion(),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _selectRegion,
                      child: const Text('Select region'),
                    ),
                    FilledButton.icon(
                      onPressed: _region == null || _fetching ? null : _fetch,
                      icon: _fetching
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 18),
                      label: const Text('Pull packets'),
                    ),
                    TextButton(
                      onPressed: _region == null
                          ? null
                          : () =>
                                _open(AnalyzerPacketService.website(_region!)),
                      child: const Text('Open analyzer'),
                    ),
                  ],
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _radioPackets,
                  icon: const Icon(Icons.sensors, size: 18),
                  label: const Text('Radio packets'),
                ),
                TextButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.paste, size: 18),
                  label: const Text('Paste'),
                ),
                TextButton(
                  onPressed: _example,
                  child: const Text('Load example'),
                ),
              ],
            ),
            if (_analyzerStatus != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _analyzerStatus!,
                  key: const Key('analyzer-status'),
                ),
              ),
            if (_packets.isNotEmpty)
              SizedBox(
                height: 160,
                child: ListView.builder(
                  itemCount: _packets.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _packets[i].label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _packets[i].raw,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _usePacket(_packets[i].raw),
                  ),
                ),
              ),
            TextField(
              key: const Key('packet-input'),
              controller: _input,
              minLines: 3,
              maxLines: 6,
              maxLength: 32768,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              autocorrect: false,
              decoration: InputDecoration(
                labelText: _mode == PacketToolMode.telemetry
                    ? 'Raw hex or CLI Base64 replies'
                    : 'Packet or payload hex',
                border: const OutlineInputBorder(),
                counterText: '',
              ),
              onChanged: (_) => setState(_resetResult),
            ),
            if (_mode == PacketToolMode.management) ...[
              const SizedBox(height: 10),
              TextField(
                key: const Key('management-password'),
                controller: _password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onChanged: (_) => setState(_resetResult),
                decoration: const InputDecoration(
                  labelText: 'Management password (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('management-candidate'),
                controller: _candidate,
                maxLength: 64,
                autocorrect: false,
                onChanged: (_) => setState(_resetResult),
                decoration: const InputDecoration(
                  labelText: 'Candidate public key (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: _decode, child: const Text('Decode')),
                OutlinedButton(
                  onPressed: () => setState(() {
                    _input.clear();
                    _password.clear();
                    _candidate.clear();
                    _resetResult();
                  }),
                  child: const Text('Clear local data'),
                ),
                if (_telemetry != null)
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: _telemetry!.csv),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('CSV copied')),
                        );
                      }
                    },
                    child: const Text('Copy CSV'),
                  ),
              ],
            ),
            if (_error != null)
              Text(
                _error!,
                key: const Key('decode-error'),
                style: TextStyle(color: scheme.error),
              ),
            if (hasResult) const Divider(),
            if (_telemetry case final result?) ...[
              Text(
                '${result.kind}${result.channel == null ? '' : ' - channel ${result.channel}'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (result.source != null)
                SelectableText('Source: ${result.source}'),
              Text(
                '${result.samples.length} samples - every ${result.interval} min',
              ),
              if (result.packet != null)
                Text('${result.packet!.route} - ${result.packet!.hops} hops'),
              for (final warning in result.warnings) Text(warning),
              for (final row in result.samples)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${row.value.isEmpty ? row.status : row.value} - ${row.status}',
                  ),
                  subtitle: Text(
                    '${row.utc}\nRaw: ${row.raw}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
            if (_raw case final packets?) ...[
              for (final packet in packets) ...[
                Text(
                  packet.typeName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${packet.route} - ${packet.hops} hops - version ${packet.version}',
                ),
                Text('Path hashes: ${packet.pathWidth} byte(s)'),
                SelectableText('Path: ${packet.pathText}'),
                if (packet.transport.isNotEmpty)
                  SelectableText('Transport: ${packetHex(packet.transport)}'),
                SelectableText(
                  'Payload (${packet.payload.length} bytes):\n${packetHex(packet.payload)}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                const Text(
                  'Encrypted payloads are shown as bytes; no decryption or sender identity is guessed.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
            if (_management case final result?) ...[
              Text(
                result.authenticated
                    ? 'Password-authenticated ${result.suppliedPages}/${result.pageCount} pages'
                    : 'Public-only - NOT authenticated',
                key: const Key('management-auth'),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: result.authenticated ? scheme.primary : scheme.error,
                ),
              ),
              for (final warning in result.warnings)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(warning),
                ),
              for (final field in result.fields.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: SelectableText('${field.key}: ${field.value}'),
                ),
              const Divider(),
              const Text('ACL fingerprints (not recoverable public keys)'),
              for (final entry in result.acl)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: SelectableText(
                    '${entry.index + 1}: ${entry.fingerprint}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    '${entry.permissions}${entry.candidateMatch == null
                        ? ''
                        : entry.candidateMatch!
                        ? ' - candidate matches'
                        : ' - candidate does not match'}',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
