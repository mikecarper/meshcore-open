import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../services/firmware_controls.dart';
import '../widgets/firmware_controls_ui.dart';

class NodeNotificationsScreen extends StatefulWidget {
  const NodeNotificationsScreen({super.key, this.channel});
  final Channel? channel;
  @override
  State<NodeNotificationsScreen> createState() =>
      _NodeNotificationsScreenState();
}

class _NodeNotificationsScreenState
    extends FirmwareControlsState<NodeNotificationsScreen> {
  NotificationCapabilities? _capabilities;
  Set<int> _gpioPins = {};
  final Map<String, String> _targets = {'all': 'All messages'};
  final _fields = {
    for (final field in notificationRuleFields)
      field: TextEditingController(text: 'inherit'),
  };
  final Map<String, String> _loaded = {};
  final Map<int, String> _channelKeys = {};
  String _target = 'all',
      _condition = '',
      _remote = 'off',
      _loadedRemote = 'off';
  bool _ruleLoaded = false;
  String? _preview;

  String get _selector => '$_target$_condition';
  bool get _remoteAllowed =>
      _condition.isEmpty &&
      (_target.startsWith('contact:') || _target.startsWith('room:'));
  bool get _editable => ready && _capabilities != null && _ruleLoaded;

  @override
  void initState() {
    super.initState();
    if (widget.channel != null) _target = 'channel:${widget.channel!.index}';
  }

  bool _channelStillMatches() {
    final initial = widget.channel;
    final index = _target.startsWith('channel:')
        ? int.tryParse(_target.substring(8))
        : null;
    if (index == null) return true;
    final expected = initial?.index == index
        ? initial!.pskHex
        : _channelKeys[index];
    return context.read<MeshCoreConnector>().channels.any(
      (c) => c.index == index && c.pskHex == expected && !c.isEmpty,
    );
  }

  void _checkTarget() {
    if (!_channelStillMatches()) {
      throw StateError('This channel was replaced. Reopen its alert settings.');
    }
  }

  @override
  Future<void> refresh() => run(() async {
    _capabilities = null;
    _ruleLoaded = false;
    _preview = null;
    final caps = NotificationCapabilities.parse(
      await endpoint.read('get notify'),
    );
    final pins = caps.supported & 16 == 0
        ? <int>{}
        : RegExp(r'\d+')
              .allMatches(await endpoint.read('get notify.gpio.pins'))
              .map((m) => int.parse(m[0]!))
              .toSet();
    if (!mounted) return;
    final connector = context.read<MeshCoreConnector>();
    _targets.clear();
    _targets['all'] = 'All messages';
    for (final channel in connector.channels.where((c) => !c.isEmpty)) {
      _channelKeys.putIfAbsent(channel.index, () => channel.pskHex);
      _targets['channel:${channel.index}'] =
          '${channel.name} (channel ${channel.index})';
    }
    for (final contact in connector.contacts.where(
      (c) => c.type == advTypeChat || c.type == advTypeRoom,
    )) {
      _targets['${contact.type == advTypeRoom ? 'room' : 'contact'}:${contact.publicKeyHex.toLowerCase()}'] =
          contact.name;
    }
    // Include orphaned saved rules without revealing channel secrets in labels.
    final slots = await endpoint.read('get notify.rules');
    for (final slot in RegExp(
      r'\d+',
    ).allMatches(slots).map((m) => int.parse(m[0]!))) {
      if (slot > 11) throw const FormatException('Unknown notification slot.');
      final selector = await endpoint.read('get notify.rules $slot');
      validateNotificationTarget(selector);
      final base = selector.split('@').first.toLowerCase();
      var known = _targets.containsKey(base);
      if (base.startsWith('channel:')) {
        final key = base.substring(8).toLowerCase();
        known |= connector.channels.any((c) => c.pskHex.toLowerCase() == key);
      }
      if (base.startsWith('contact:')) {
        known |= _targets.containsKey(base.replaceFirst('contact:', 'room:'));
      }
      if (!known) _targets[base] = 'Saved rule ${slot + 1} (unlisted target)';
    }
    if (!_targets.containsKey(_target)) {
      _targets[_target] = 'Previously selected target';
    }
    if (!_channelStillMatches()) {
      throw StateError('This channel was replaced. Reopen its alert settings.');
    }
    _capabilities = caps;
    _gpioPins = pins;
    await _readRule();
  });

  Future<void> _readRule() async {
    _ruleLoaded = false;
    _checkTarget();
    final values = <String, String>{};
    for (final field in notificationRuleFields) {
      values[field] = await endpoint.read('get notify.$field $_selector');
    }
    final remote = _remoteAllowed
        ? await endpoint.read('get notify.remote $_selector')
        : 'off';
    if (!mounted) return;
    for (final field in notificationRuleFields) {
      _fields[field]!.text = values[field]!;
    }
    _loaded
      ..clear()
      ..addAll(values);
    _remote = remote;
    _loadedRemote = remote;
    _ruleLoaded = true;
  }

  Future<void> _select(String target, String condition) async {
    if (!ready) return;
    setState(() {
      _target = target;
      _condition = condition;
      _preview = null;
      _ruleLoaded = false;
    });
    await run(_readRule);
  }

  void _preset(String preset) {
    setState(() {
      for (final f in _fields.values) {
        f.text = 'inherit';
      }
      if (_capabilities!.supported & 1 != 0) {
        _fields['vibration']!.text = preset == 'vip'
            ? '120,100,120'
            : '100,250,100,250,500';
      }
      if (_capabilities!.supported & 4 != 0) {
        _fields['led']!.text = '200,200,200,200,600';
      }
      if (_capabilities!.supported & 2 != 0) {
        _fields['sound']!.text = 'Alert:d=8,o=5,b=120:c,e,g';
      }
      if (_capabilities!.supported & 8 != 0) _fields['screen']!.text = 'on';
      _fields['repeat']!.text = preset == 'find' ? '10' : '2';
      _fields['gap']!.text = '500';
      _fields['stop']!.text = 'button';
      _preview = null;
    });
  }

  List<String> _commands({bool changedOnly = true}) {
    if (!_channelStillMatches()) {
      throw StateError('This channel was replaced. Reopen this screen.');
    }
    return [
      for (final field in notificationRuleFields)
        if (!changedOnly || _fields[field]!.text != _loaded[field])
          notificationRuleCommand(
            _selector,
            field,
            _fields[field]!.text.trim(),
            gpioPins: _gpioPins,
          ),
      if (_remoteAllowed && _remote != _loadedRemote)
        notificationRuleCommand(_selector, 'remote', _remote),
    ];
  }

  Future<void> _save() async {
    try {
      final commands = _commands();
      if (commands.isEmpty) {
        setState(() {
          status = 'No changes to save.';
          failed = false;
        });
        return;
      }
      await applyChanges(
        commands,
        'Save this message rule on the Companion. This enables the programmable alert engine. '
        'Master outputs still control which hardware can run. Changes save one at a time.'
        '${_remoteAllowed && _remote == 'on' ? '\n\nRemote alerts will be trusted from this target. For a room, this trusts every poster delivered by that room server. Remote alerts are limited to 15 seconds and cannot select GPIOs.' : ''}',
        guard: _checkTarget,
      );
    } catch (error) {
      setState(() {
        status = error.toString();
        failed = true;
      });
    }
  }

  void _previewRule() {
    try {
      _commands(changedOnly: false);
      final vibration = parseNotificationPulse(
        _fields['vibration']!.text.trim(),
      );
      final led = parseNotificationPulse(_fields['led']!.text.trim());
      final sound = notificationSoundDuration(_fields['sound']!.text.trim());
      final duration = math.max(
        sound,
        math.max(
          vibration.fold<int>(0, (a, b) => a + b),
          led.fold<int>(0, (a, b) => a + b),
        ),
      );
      setState(() {
        _preview =
            'One cycle: ${duration == 0 ? 'inherited / screen-only' : '$duration ms'}. '
            'Pulses alternate ON/OFF starting ON. Preview does not drive hardware; save before testing on the node.';
        status = null;
      });
    } catch (error) {
      setState(() {
        status = error.toString();
        failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = _capabilities;
    return controlsScaffold('Node alerts', [
      const ControlNote(
        'These alerts run on the radio, not Android notifications. Rules apply to incoming messages, not connection events. Unsupported outputs are disabled.',
      ),
      if (caps != null)
        ControlGroup('Hardware outputs', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Programmable alerts'),
            subtitle: const Text(
              'Off restores legacy alerts; it does not mute the node.',
            ),
            value: caps.enabled,
            onChanged: ready
                ? (v) => applyChanges(
                    ['set notify.enabled ${v ? 'on' : 'off'}'],
                    v
                        ? 'Enable programmable alerts.'
                        : 'Restore the firmware\'s legacy alert behavior.',
                  )
                : null,
          ),
          for (final output in notificationOutputBits.entries)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                {'led': 'LED', 'gpio': 'GPIO'}[output.key] ??
                    '${output.key[0].toUpperCase()}${output.key.substring(1)}',
              ),
              subtitle: caps.supported & output.value == 0
                  ? const Text('Not supported by this board/build')
                  : null,
              value: caps.supported & caps.outputs & output.value != 0,
              onChanged: ready && caps.supported & output.value != 0
                  ? (v) => applyChanges(
                      ['set notify.${output.key} ${v ? 'on' : 'off'}'],
                      '${v ? 'Allow' : 'Disable'} this hardware output for all programmable alerts. This enables the alert engine.',
                    )
                  : null,
            ),
        ]),
      ControlGroup('Message rule', [
        controlChoice(
          'Messages from',
          _target,
          _targets,
          ready && caps != null ? (v) => _select(v, _condition) : null,
        ),
        controlChoice('Connection condition', _condition, const {
          '': 'Any state',
          '@connected': 'While connected',
          '@disconnected': 'While disconnected',
        }, ready && caps != null ? (v) => _select(_target, v) : null),
        const ControlNote(
          'Inherit leaves that field to broader rules or normal firmware behavior. All-message rules apply first; target and connection-specific fields override them.',
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: _editable ? () => _preset('find') : null,
              child: const Text('Find my node'),
            ),
            OutlinedButton(
              onPressed: _editable ? () => _preset('vip') : null,
              child: const Text('VIP message'),
            ),
          ],
        ),
        for (final field in ['vibration', 'led', 'sound'])
          controlField(
            {
              'vibration': 'Vibration pulses (ms)',
              'led': 'LED pulses (ms)',
              'sound': 'Sound (RTTTL)',
            }[field]!,
            _fields[field]!,
            enabled:
                _editable &&
                caps!.supported & notificationOutputBits[field]! != 0,
            hint: field == 'sound'
                ? 'inherit, off, or Alert:d=8,o=5,b=120:c,e,g'
                : 'inherit, off, or 100,250,100',
          ),
        controlChoice(
          'Screen',
          _fields['screen']!.text,
          const {'inherit': 'Inherit', 'on': 'On', 'off': 'Off'},
          _editable && caps!.supported & 8 != 0
              ? (v) => setState(() {
                  _fields['screen']!.text = v;
                })
              : null,
        ),
        if (caps != null && caps.supported & 16 != 0) ...[
          ControlNote(
            'Approved GPIOs: ${_gpioPins.isEmpty ? 'none' : (_gpioPins.toList()..sort()).join(', ')}. Reserved pins cannot be used.',
          ),
          controlField(
            'GPIO pin and pulses',
            _fields['gpio']!,
            enabled: _editable,
            hint: 'inherit, off, or approvedPin:100,250,100',
          ),
        ],
        controlField(
          'Repeat count',
          _fields['repeat']!,
          enabled: _editable,
          hint: 'inherit, 1-65535, or forever',
        ),
        controlField(
          'Gap between cycles (ms)',
          _fields['gap']!,
          enabled: _editable,
          hint: 'inherit or 1-60000',
        ),
        controlChoice(
          'Stop condition',
          _fields['stop']!.text,
          const {
            'inherit': 'Inherit',
            'button': 'Node button',
            'connected': 'Next connection',
            'never': 'Until finished / stopped',
          },
          _editable
              ? (v) => setState(() {
                  _fields['stop']!.text = v;
                })
              : null,
        ),
        if (_remoteAllowed)
          controlChoice(
            'Trust remote !notify messages',
            _remote,
            const {
              'off': 'Disabled',
              'on': 'Allow for this target',
              'inherit': 'Remove permission override',
            },
            _editable
                ? (v) => setState(() {
                    _remote = v;
                  })
                : null,
          ),
        if (_preview != null) ControlNote(_preview!),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: _editable ? _previewRule : null,
              child: const Text('Preview'),
            ),
            FilledButton(
              onPressed: _editable ? _save : null,
              child: const Text('Save rule'),
            ),
            OutlinedButton(
              onPressed: _editable
                  ? () async {
                      if (await confirm(
                            'Test saved alert?',
                            'This runs the saved matching rule on the node, including its hardware outputs. Unsaved edits are not used.',
                            button: 'Test',
                          ) &&
                          mounted) {
                        await run(
                          () async {
                            await endpoint.apply([
                              'notify.test $_selector',
                            ], guard: _checkTarget);
                          },
                          success:
                              'Saved alert started. Use Stop alert to end it.',
                        );
                      }
                    }
                  : null,
              child: const Text('Test on node'),
            ),
            OutlinedButton(
              onPressed: ready && caps != null
                  ? () => run(
                      () => endpoint.apply(['notify.stop']),
                      success: 'Alert stopped.',
                    )
                  : null,
              child: const Text('Stop alert'),
            ),
            TextButton(
              onPressed: _editable
                  ? () => applyChanges(
                      ['notify.delete $_selector'],
                      'Delete only this rule. Other targets and master outputs are unchanged.',
                      guard: _checkTarget,
                    )
                  : null,
              child: const Text('Delete rule'),
            ),
          ],
        ),
      ]),
    ]);
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }
}
