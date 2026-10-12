import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../services/fleet_management.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../widgets/firmware_controls_ui.dart';

class FleetManagementScreen extends StatefulWidget {
  const FleetManagementScreen({super.key, this.initialCommand});
  final String? initialCommand;

  @override
  State<FleetManagementScreen> createState() => _FleetManagementScreenState();
}

class _FleetManagementScreenState extends State<FleetManagementScreen>
    with DisconnectNavigationMixin<FleetManagementScreen> {
  FleetManagementService? _fleet;
  Channel? _channel;
  final Set<String> _selected = {};
  final _region = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  final _radius = TextEditingController(text: '25');
  final _value = TextEditingController();
  final _slot = TextEditingController();
  final _scroll = ScrollController();
  String _targetKind = 'selected', _action = 'get', _setting = 'radio2';
  bool _prefixes = false, _dialog = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final command = widget.initialCommand;
    if (command != null) {
      final parts = command.split(' ');
      _action = parts.first;
      _setting = parts.length > 1 ? parts[1] : 'radio2';
      _value.text = parts.skip(2).join(' ');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fleet != null) return;
    _fleet = FleetManagementService(context.read<MeshCoreConnector>())
      ..addListener(_changed);
    if (_fleet!.channels.length == 1) _channel = _fleet!.channels.single;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _ready => _fleet!.available && !_fleet!.busy && !_dialog;

  void _showStatus(String status) {
    if (!mounted) return;
    setState(() => _status = status);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _run(Future<String> Function() operation) async {
    if (!_ready) return;
    setState(() => _status = null);
    try {
      final result = await operation();
      _showStatus(result);
    } catch (error) {
      _showStatus(error.toString());
    }
  }

  Future<bool> _confirm(String title, String text, String button) async {
    _dialog = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: SelectableText(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(button),
          ),
        ],
      ),
    );
    _dialog = false;
    return result == true;
  }

  FleetRequest _request() {
    final channel = _channel;
    if (channel == null) {
      throw const FormatException('Select a private fleet channel.');
    }
    String token;
    if (_targetKind == 'all') {
      token = 'all';
    } else if (_targetKind == 'selected') {
      if (_selected.isEmpty) {
        throw const FormatException('Select at least one node.');
      }
      final contacts = _fleet!.connector.contacts;
      final keys = _selected.toList()..sort();
      for (final key in keys) {
        if (!contacts.any(
          (c) =>
              c.publicKeyHex == key &&
              c.isActive &&
              (c.type == advTypeRepeater || c.type == advTypeRoom),
        )) {
          throw const FormatException(
            'A selected node is no longer available. Select again.',
          );
        }
        if (_prefixes &&
            contacts
                    .where(
                      (c) => c.publicKeyHex.startsWith(key.substring(0, 12)),
                    )
                    .length !=
                1) {
          throw const FormatException(
            'A selected prefix is ambiguous. Use full public keys.',
          );
        }
      }
      token = keys
          .map((key) => _prefixes ? key.substring(0, 12) : key)
          .join(';');
    } else if (_targetKind == 'region' || _targetKind == 'home') {
      // Explicit prefix prevents names such as "all" from broadening scope.
      token = _region.text
          .trim()
          .split(';')
          .map((name) => '$_targetKind:$name')
          .join(';');
    } else {
      token =
          'gps:${_latitude.text.trim()},${_longitude.text.trim()}:${_radius.text.trim()}';
    }
    String command;
    if (_setting == 'clock') {
      command = _action == 'get' ? 'clock' : 'clock sync';
    } else {
      final slot = _slot.text.trim();
      final scheduled = [
        'radioat',
        'tempradioat',
        'radioat2',
        'tempradioat2',
      ].contains(_setting);
      if (slot.isNotEmpty && !RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(slot)) {
        throw const FormatException(
          'Use a positive row number or leave it empty.',
        );
      }
      final key = _setting + (slot.isEmpty || scheduled ? '' : '.$slot');
      final args = scheduled && _action != 'set' ? slot : _value.text.trim();
      command = '$_action $key${args.isEmpty ? '' : ' $args'}';
    }
    return FleetRequest(channel, FleetTargets.parse(token), command);
  }

  Future<void> _send() async {
    if (!_ready) return;
    try {
      final request = _request();
      final summary = _targetKind == 'selected'
          ? _fleet!.connector.contacts
                .where((c) => _selected.contains(c.publicKeyHex))
                .map(
                  (c) =>
                      '${c.name} (${_prefixes ? 'prefix' : 'exact identity'})',
                )
                .join('\n')
          : request.targets.token;
      if (!await _confirm(
        'Send fleet control?',
        'Channel: ${request.channel.name}\nTargets: $summary\n\n'
            '${request.command}\n${request.packets} LoRa packet(s).\n\n'
            '${_prefixes && _targetKind == 'selected' ? 'Prefixes match every enrolled node with that prefix, including unknown nodes.\n\n' : ''}'
            'The Companion signs this control. Queued does not mean applied. '
            'Channel reports are not authenticated; verify critical changes using individual admin access. '
            'Filters and schedules can cut off downstream access. No automatic retries.',
        'Send control',
      )) {
        return;
      }
      if (!mounted) return;
      // If the Companion/channel/contacts changed while confirming, do not
      // silently send a new request in place of the one the user saw.
      final current = _request();
      if (current.localCommand != request.localCommand ||
          current.channel.pskHex != request.channel.pskHex) {
        throw StateError('Selection changed. Review and confirm again.');
      }
      await _run(() async {
        final result = await _fleet!.send(request);
        return 'Queued sequence ${result.sequence}. Waiting for unverified channel reports; no automatic retry.';
      });
    } catch (error) {
      _showStatus(error.toString());
    }
  }

  Future<void> _chooseNodes() async {
    final selected = Set<String>.of(_selected);
    final nodes =
        _fleet!.connector.contacts
            .where(
              (c) =>
                  c.isActive &&
                  c.publicKey.length == 32 &&
                  (c.type == advTypeRepeater || c.type == advTypeRoom),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Choose fleet targets'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Only nodes enrolled in this private channel can execute. Names are for display; full public keys select identities.',
                    ),
                  ),
                  for (final node in nodes)
                    CheckboxListTile(
                      title: Text(node.name, softWrap: true),
                      subtitle: Text(node.publicKeyHex.substring(0, 12)),
                      value: selected.contains(node.publicKeyHex),
                      onChanged: (value) => update(() {
                        value == true
                            ? selected.add(node.publicKeyHex)
                            : selected.remove(node.publicKeyHex);
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Use selection'),
            ),
          ],
        ),
      ),
    );
    if (mounted && save == true) {
      setState(() {
        _selected
          ..clear()
          ..addAll(selected);
      });
    }
  }

  Future<void> _enroll(Contact node, {bool disable = false}) async {
    final channel = _channel;
    if (channel == null || !_ready) return;
    if (!await _confirm(
      disable ? 'Remove fleet enrollment?' : 'Enroll node?',
      '${node.name}\nChannel: ${channel.name}\n\n'
      '${disable ? 'Disable reception and revoke the publisher.' : 'Replace this node fleet enrollment with this private channel and this Companion public identity. The signing private key never leaves the Companion.'}\n\n'
      'Uses the individually authenticated admin connection. Two separate writes can partially succeed. '
      'Read enrollment again after completion or a lost reply. No automatic retry.',
      disable ? 'Remove enrollment' : 'Enroll',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() async {
      await _fleet!.enroll(node, channel, disable: disable);
      return '${node.name}: enrollment writes acknowledged. Read enrollment again to verify the saved controller and channel state.';
    });
  }

  Future<void> _createChannel() async {
    if (!_ready) return;
    final int index;
    try {
      index = _fleet!.freeChannelSlot;
    } catch (error) {
      _showStatus(error.toString());
      return;
    }
    if (!await _confirm(
      'Create private fleet channel?',
      'Create Fleet in free channel slot $index using a random key generated on this phone. '
          'No existing channel is replaced. Enroll receivers separately using their admin connection.',
      'Create channel',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() async {
      await _fleet!.createPrivateChannel(index);
      return 'Private channel creation requested. Select Fleet when channel synchronization finishes.';
    });
  }

  String get _hint => switch (_setting) {
    'radio2' => 'MHz,BW,SF,CR,rx|rxtx[,preamble] or off',
    'tempradio2' => 'MHz,BW,SF,CR,rx|rxtx,minutes[,preamble] or off',
    'radio2.cross' => 'auto, on, or off',
    'radioat' => 'MHz,BW,SF,CR,start UTC[,preamble]',
    'tempradioat' => 'MHz,BW,SF,CR,start UTC,end UTC[,preamble]',
    'radioat2' => 'MHz,BW,SF,CR,rx|rxtx,start UTC[,preamble]',
    'tempradioat2' => 'MHz,BW,SF,CR,rx|rxtx,start UTC,end UTC[,preamble]',
    'flood.rule' =>
      'Example: type=grp_txt hops=6+ drop; or copy from Packet filters',
    'flood.filter.blacklist' => 'Path IDs, as supported by the receiver',
    'flood.moderation' => 'Channel, sender, and rate/hop options',
    'flood.channel.scope' => 'Channel and scope/region options',
    'flood.channel.scope.require' => 'Channel and required scope options',
    'flood.channel.data' => 'on or off',
    _ => 'Value supported by the receiver',
  };

  @override
  Widget build(BuildContext context) {
    final fleet = _fleet!;
    checkConnectionAndNavigate(fleet.connector);
    final channels = fleet.channels;
    final selectedChannel =
        channels.any(
          (c) =>
              c.index == _channel?.index &&
              c.pskHex == _channel?.pskHex &&
              c.name == _channel?.name,
        )
        ? _channel
        : null;
    final isRow =
        _setting.startsWith('flood.') &&
        [
          'flood.rule',
          'flood.filter.blacklist',
          'flood.moderation',
          'flood.channel.scope',
          'flood.channel.scope.require',
        ].contains(_setting);
    final schedule = [
      'radioat',
      'tempradioat',
      'radioat2',
      'tempradioat2',
    ].contains(_setting);
    final actions = _setting == 'clock'
        ? ['get', 'set']
        : _setting == 'radio2.status' || _setting == 'radio2.timing'
        ? ['get']
        : isRow || schedule
        ? ['get', 'set', 'del']
        : ['get', 'set'];
    return Scaffold(
      appBar: AppBar(title: const FittedBox(child: Text('Fleet management'))),
      body: SafeArea(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          children: [
            const ControlNote(
              'Signed controls over a private shared channel. Repeaters and room servers need fleet-capable MeshCore head; fixed-size STM32 builds omit it. No requests are sent merely by opening this screen.',
            ),
            if (!fleet.available)
              const ControlNote(
                'Connect to the same supported Companion to continue. Reopen this screen after changing Companions.',
              ),
            if (_status != null) SelectableText(_status!),
            if (fleet.busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _ready
                  ? () => _run(() async {
                      await fleet.checkPublisher();
                      return 'Publisher supports signed fleet controls.';
                    })
                  : null,
              child: const Text('Check publisher support'),
            ),
            _dropdown(
              'Private channel',
              selectedChannel?.index,
              {for (final c in channels) c.index: '${c.name} (CH ${c.index})'},
              (value) => setState(() {
                _channel = channels.firstWhere((c) => c.index == value);
              }),
            ),
            if (channels.isEmpty)
              const ControlNote(
                'No eligible private channel. Public, hashtag, empty, and predictable hashtag-derived keys are not allowed.',
              ),
            TextButton(
              onPressed: _ready ? _createChannel : null,
              child: const Text('Create private fleet channel'),
            ),
            ExpansionTile(
              title: const Text('Enroll or inspect nodes'),
              children: [
                const ControlNote(
                  'Log in as admin from Contacts first. Enrollment uses individual admin access, never a fleet broadcast. Receiver clocks must already be reasonably close to UTC.',
                ),
                if (fleet.administrators.isEmpty)
                  const ControlNote(
                    'No confirmed infrastructure admin logins for this Companion.',
                  ),
                for (final node in fleet.administrators)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            node.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (fleet.checked[node.publicKeyHex]
                              case final enrollment?) ...[
                            Text(enrollment.summary),
                            Text(
                              enrollment.controller.toLowerCase() ==
                                      fleet.connector.selfPublicKeyHex
                                          .toLowerCase()
                                  ? 'Publisher matches this Companion'
                                  : 'Publisher unset or different',
                            ),
                          ],
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: _ready
                                    ? () => _run(() async {
                                        await fleet.inspect(node);
                                        return '${node.name}: enrollment read. Channel key is not disclosed by firmware.';
                                      })
                                    : null,
                                child: const Text('Read enrollment'),
                              ),
                              FilledButton(
                                onPressed:
                                    _ready &&
                                        selectedChannel != null &&
                                        fleet.publisherSupported &&
                                        fleet.checked.containsKey(
                                          node.publicKeyHex,
                                        )
                                    ? () => _enroll(node)
                                    : null,
                                child: const Text('Enroll'),
                              ),
                              TextButton(
                                onPressed:
                                    _ready &&
                                        selectedChannel != null &&
                                        fleet.publisherSupported &&
                                        fleet.checked.containsKey(
                                          node.publicKeyHex,
                                        )
                                    ? () => _enroll(node, disable: true)
                                    : null,
                                child: const Text('Remove enrollment'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _dropdown('Targets', _targetKind, const {
              'selected': 'Selected nodes',
              'region': 'Configured regions',
              'home': 'Home region ancestry',
              'gps': 'Geographic radius',
              'all': 'All enrolled nodes',
            }, (value) => setState(() => _targetKind = value)),
            if (_targetKind == 'selected') ...[
              OutlinedButton(
                onPressed: _ready ? _chooseNodes : null,
                child: Text('Choose nodes (${_selected.length})'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Compact public-key prefixes'),
                subtitle: const Text(
                  'Optional 12-character prefixes fit more nodes but may match unknown nodes. Full identities are the default.',
                ),
                value: _prefixes,
                onChanged: _ready ? (v) => setState(() => _prefixes = v) : null,
              ),
            ],
            if (_targetKind == 'all')
              const ControlNote(
                'This explicitly addresses EVERY node enrolled in the private channel, not just your Contacts.',
              ),
            if (_targetKind == 'region' || _targetKind == 'home') ...[
              _field(
                _region,
                'Region names',
                hint: 'Case-sensitive; separate names with ;',
              ),
              const ControlNote(
                'Matches receiver-side configured regions or home ancestry. This does not change the channel routing scope. Unknown regions match no nodes.',
              ),
            ],
            if (_targetKind == 'gps') ...[
              _field(_latitude, 'Center latitude'),
              _field(_longitude, 'Center longitude'),
              _field(_radius, 'Radius (km)'),
              const ControlNote(
                'Coordinates: up to 6 decimal places. Radius: 0.001-20050 km, up to 3 decimal places. Uses receiver fixed position or an existing GPS cache no older than 12 hours; never wakes GPS.',
              ),
            ],
            _dropdown(
              'Control',
              _setting,
              fleetSettingLabels,
              (value) => setState(() {
                _setting = value;
                _action = 'get';
                _value.clear();
                _slot.clear();
              }),
            ),
            _dropdown(
              'Operation',
              _action,
              {
                for (final action in actions)
                  action: action == 'get'
                      ? 'Read'
                      : action == 'del'
                      ? 'Delete'
                      : _setting == 'clock'
                      ? 'Synchronize forward'
                      : 'Set',
              },
              (value) => setState(() {
                _action = value;
                _value.clear();
              }),
            ),
            if (isRow || schedule && _action != 'set')
              _field(
                _slot,
                'Optional row number',
                hint:
                    'Empty: add a rule, list all, or delete according to firmware',
              ),
            if (_setting != 'clock' &&
                (_action == 'set' || _action == 'del' && isRow))
              _field(
                _value,
                _action == 'del' ? 'Delete argument' : 'Setting value',
                hint: _action == 'del'
                    ? 'Empty for selected row; all for entire table'
                    : _hint,
              ),
            if (schedule)
              const ControlNote(
                'For coordinated switches, use the same absolute UTC timestamps. +N is relative to each receiver acceptance time. Schedules do not survive reboot.',
              ),
            const ControlNote(
              'Firmware rejects unsupported values per node. Controls are not atomic across the fleet. OTA, reboot, passwords, identity export, ACLs, and arbitrary CLI are NOT permitted here. Use the individual node tools for those.',
            ),
            FilledButton.icon(
              onPressed:
                  _ready && fleet.publisherSupported && selectedChannel != null
                  ? _send
                  : null,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Review and send control'),
            ),
            if (fleet.dispatch != null) ...[
              const SizedBox(height: 16),
              Text(
                'Unverified channel reports - sequence ${fleet.dispatch!.sequence}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const ControlNote(
                'Ordinary channel text is not a signed receipt. Sender names and prefixes can be forged. Missing reports do not prove failure. Confirm critical changes using individual admin access.',
              ),
              if (fleet.reports.isEmpty)
                const Text('No matching reports received.'),
              for (final report in fleet.reports)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${report.sender} - ${report.prefix}'),
                        SelectableText(report.reply),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: controller,
      enabled: _ready,
      maxLines: 2,
      minLines: 1,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 4,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _dropdown<T>(
    String label,
    T? value,
    Map<T, String> options,
    ValueChanged<T> changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value:${options.keys.join(',')}'),
      // Flutter 3.32 compatibility.
      // ignore: deprecated_member_use
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: options.entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, maxLines: 2),
            ),
          )
          .toList(),
      onChanged: _ready
          ? (v) {
              if (v != null) changed(v);
            }
          : null,
    ),
  );

  @override
  void dispose() {
    _fleet
      ?..removeListener(_changed)
      ..dispose();
    _scroll.dispose();
    for (final controller in [
      _region,
      _latitude,
      _longitude,
      _radius,
      _value,
      _slot,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }
}
