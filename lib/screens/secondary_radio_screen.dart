import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../services/firmware_controls.dart';
import '../widgets/firmware_controls_ui.dart';
import 'fleet_management_screen.dart';

class SecondaryRadioScreen extends StatefulWidget {
  const SecondaryRadioScreen({super.key, this.channel});
  final Channel? channel;
  @override
  State<SecondaryRadioScreen> createState() => _SecondaryRadioScreenState();
}

class _SecondaryRadioScreenState
    extends FirmwareControlsState<SecondaryRadioScreen> {
  final _frequency = TextEditingController();
  final _preamble = TextEditingController(text: 'auto');
  final _minutes = TextEditingController(text: '120');
  double _bandwidth = 250;
  String _sf = '7', _cr = '5', _mode = 'off', _cross = 'auto', _route = 'auto';
  bool _supported = false, _routeSupported = false, _crossSupported = false;
  String? _radioStatus, _temporary, _routeStatus, _timing;
  final Map<int, String> _channelKeys = {};
  final Map<String, String> _channelLabels = {};
  int? _selectedChannel;

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.channel?.index;
  }

  void _checkChannel() {
    final index = _selectedChannel;
    if (index == null) throw StateError('Select a channel.');
    final channels = context.read<MeshCoreConnector>().channels;
    if (!channels.any(
      (c) => c.index == index && c.pskHex == _channelKeys[index] && !c.isEmpty,
    )) {
      throw StateError('This channel changed. Reopen its radio settings.');
    }
  }

  Future<void> _readRoute() async {
    _routeSupported = false;
    _routeStatus = null;
    if (_selectedChannel == null) return;
    _checkChannel();
    final reply = await endpoint.read('get tx.channel $_selectedChannel');
    _route = parseChannelRadioRoute(reply);
    _routeStatus = reply;
    _routeSupported = true;
  }

  @override
  Future<void> refresh() => run(() async {
    _supported = false;
    _routeSupported = false;
    _crossSupported = false;
    final profile = SecondaryRadioProfile.parse(
      await endpoint.read('get radio2'),
    );
    final status = await endpoint.read('get radio2.status');
    if (!mounted) return;
    final connector = context.read<MeshCoreConnector>();
    if (_channelKeys.isEmpty) {
      for (final channel in connector.channels.where((c) => !c.isEmpty)) {
        _channelKeys[channel.index] = channel.pskHex;
        _channelLabels['${channel.index}'] =
            '${channel.name} (channel ${channel.index})';
      }
      final initial = widget.channel;
      if (initial != null) _channelKeys[initial.index] = initial.pskHex;
    }
    _frequency.text = '${profile.frequency}';
    _preamble.text = profile.preamble;
    _bandwidth = profile.bandwidth;
    _sf = '${profile.sf}';
    _cr = '${profile.cr}';
    _mode = profile.mode;
    _radioStatus = status;
    _supported = true;
    // Optional features fail independently: a working radio2 must not hide
    // just because this older firmware lacks per-channel routing or timing.
    try {
      _temporary = await endpoint.read('get tempradio2');
    } catch (e) {
      _temporary = e.toString();
    }
    try {
      final crossing = await endpoint.read('get radio2.cross');
      if (!['auto', 'on', 'off'].contains(crossing)) {
        throw const FormatException('Unknown crossing mode.');
      }
      _cross = crossing;
      _crossSupported = true;
    } catch (e) {
      _crossSupported = false;
    }
    try {
      _timing = await endpoint.read('get radio2.timing');
    } catch (e) {
      _timing = e.toString();
    }
    try {
      await _readRoute();
    } catch (e) {
      _routeStatus = e.toString();
    }
  });

  Future<void> _saveProfile({bool temporary = false}) async {
    try {
      final frequency = double.tryParse(_frequency.text.trim());
      if (frequency == null) {
        throw const FormatException('Enter a frequency in MHz.');
      }
      final minutes = temporary ? int.tryParse(_minutes.text.trim()) : null;
      if (temporary && minutes == null) {
        throw const FormatException('Enter a duration in minutes.');
      }
      final command = SecondaryRadioProfile(
        frequency: frequency,
        bandwidth: _bandwidth,
        sf: int.parse(_sf),
        cr: int.parse(_cr),
        mode: _mode,
        preamble: _preamble.text.trim(),
      ).command(minutes: minutes);
      await applyChanges(
        [command],
        'Change ${temporary ? 'the temporary' : 'the saved'} second profile. '
        'Use legal frequencies and power settings for your location and hardware. '
        'This is one time-shared radio, not simultaneous reception. Dual-profile listening reduces power saving. '
        '${_mode == 'off' ? 'Turning it off cancels affected schedules and may make Radio 2-only channels unable to send.' : 'Peers must use compatible settings. Changing a profile can interrupt traffic on it.'}',
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
    }
  }

  Future<void> _sendProfileToFleet({bool temporary = false}) async {
    try {
      final frequency = double.tryParse(_frequency.text.trim());
      final minutes = temporary ? int.tryParse(_minutes.text.trim()) : null;
      if (frequency == null || temporary && minutes == null) {
        throw const FormatException(
          'Enter the profile frequency and temporary duration.',
        );
      }
      final command = SecondaryRadioProfile(
        frequency: frequency,
        bandwidth: _bandwidth,
        sf: int.parse(_sf),
        cr: int.parse(_cr),
        mode: _mode,
        preamble: _preamble.text.trim(),
      ).command(minutes: minutes);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FleetManagementScreen(initialCommand: command),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
    }
  }

  Future<void> _saveRoute() async {
    try {
      _checkChannel();
      final command = channelRadioRouteCommand(_selectedChannel!, _route);
      await applyChanges(
        [command],
        '${radioRouteLabels[_route]} for ${_channelLabels['$_selectedChannel']}. '
        'This changes sending only; receiving remains enabled. '
        'Radio 2-only sending fails while the second profile is off or receive-only. '
        'Both uses Radio 2 only when it is TX-capable. Explicit choices override global crossing and temporary isolation.',
        guard: _checkChannel,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => controlsScaffold('Radio 2', [
    const ControlNote(
      'Two profiles share one physical LoRa radio. Per-channel choices do not turn Radio 2 on. Read the active status before relying on a second-profile-only channel.',
    ),
    ControlGroup('Channel sending', [
      if (_channelLabels.isNotEmpty)
        controlChoice(
          'Channel',
          '${_selectedChannel ?? ''}',
          {'': 'Select a channel', ..._channelLabels},
          ready && _supported
              ? (v) async {
                  setState(() {
                    _selectedChannel = int.tryParse(v);
                    _routeSupported = false;
                  });
                  await run(_readRoute);
                }
              : null,
        ),
      if (_routeStatus != null) ControlNote(_routeStatus!),
      controlChoice(
        'Transmit on',
        _route,
        radioRouteLabels,
        ready && _routeSupported
            ? (v) => setState(() {
                _route = v;
              })
            : null,
      ),
      FilledButton(
        onPressed: ready && _routeSupported ? _saveRoute : null,
        child: const Text('Save channel route'),
      ),
    ]),
    ControlGroup('Second profile', [
      if (_radioStatus != null) ControlNote('Active: $_radioStatus'),
      controlChoice(
        'Mode',
        _mode,
        const {
          'off': 'Off',
          'rx': 'Receive only',
          'rxtx': 'Receive and transmit',
        },
        ready && _supported
            ? (v) => setState(() {
                _mode = v;
              })
            : null,
      ),
      controlField(
        'Frequency (MHz)',
        _frequency,
        enabled: ready && _supported && _mode != 'off',
      ),
      controlChoice(
        'Bandwidth (kHz)',
        '$_bandwidth',
        {for (final b in radioBandwidths) '$b': '$b'},
        ready && _supported && _mode != 'off'
            ? (v) => setState(() {
                _bandwidth = double.parse(v);
              })
            : null,
      ),
      controlChoice(
        'Spreading factor',
        _sf,
        {for (var n = 5; n <= 12; n++) '$n': 'SF $n'},
        ready && _supported && _mode != 'off'
            ? (v) => setState(() {
                _sf = v;
              })
            : null,
      ),
      controlChoice(
        'Coding rate',
        _cr,
        {for (var n = 5; n <= 8; n++) '$n': '4/$n'},
        ready && _supported && _mode != 'off'
            ? (v) => setState(() {
                _cr = v;
              })
            : null,
      ),
      controlField(
        'Preamble (symbols)',
        _preamble,
        enabled: ready && _supported && _mode != 'off',
        hint: 'auto or 8-65528; firmware validates timing and board limits',
      ),
      FilledButton(
        onPressed: ready && _supported ? () => _saveProfile() : null,
        child: const Text('Save permanent profile'),
      ),
      OutlinedButton(
        onPressed: ready && _supported ? () => _sendProfileToFleet() : null,
        child: const Text('Send profile over fleet channel'),
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Temporary profile'),
        children: [
          if (_temporary != null) ControlNote('Current: $_temporary'),
          controlField(
            'Duration (minutes)',
            _minutes,
            enabled: ready && _supported,
            hint:
                '1-10080; uses the fields above, restores saved profile at expiry',
          ),
          Wrap(
            spacing: 6,
            children: [
              OutlinedButton(
                onPressed: ready && _supported
                    ? () => _saveProfile(temporary: true)
                    : null,
                child: const Text('Start temporary'),
              ),
              OutlinedButton(
                onPressed: ready && _supported
                    ? () => _sendProfileToFleet(temporary: true)
                    : null,
                child: const Text('Send temporary profile to fleet'),
              ),
              OutlinedButton(
                onPressed: ready && _supported
                    ? () => applyChanges(
                        ['set tempradio2 off'],
                        'End the temporary second profile and its temporary schedules. Restore the saved Radio 2 profile.',
                      )
                    : null,
                child: const Text('End temporary'),
              ),
            ],
          ),
        ],
      ),
    ]),
    ControlGroup('Crossing and diagnostics', [
      controlChoice(
        'Global crossing',
        _cross,
        const {
          'auto': 'Automatic isolation',
          'on': 'Allow crossing',
          'off': 'No crossing',
        },
        ready && _crossSupported
            ? (v) => setState(() {
                _cross = v;
              })
            : null,
      ),
      const ControlNote(
        'Crossing affects forwarding and automatic sends, including OTA traffic. Per-channel explicit routes override it.',
      ),
      OutlinedButton(
        onPressed: ready && _crossSupported
            ? () => applyChanges(
                ['set radio2.cross $_cross'],
                'Save the global crossing policy. This can copy traffic between networks and persists after temporary sessions end.',
              )
            : null,
        child: const Text('Save crossing'),
      ),
      if (_timing != null) ControlNote('Timing: $_timing'),
    ]),
  ]);

  @override
  void dispose() {
    _frequency.dispose();
    _preamble.dispose();
    _minutes.dispose();
    super.dispose();
  }
}
