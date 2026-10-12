import 'package:flutter/material.dart';

import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../services/firmware_controls.dart';
import '../widgets/firmware_controls_ui.dart';
import 'repeater_filter_batch_screen.dart';
import 'fleet_management_screen.dart';

class NodeFiltersScreen extends StatefulWidget {
  const NodeFiltersScreen({super.key, required this.target});
  final Contact target;
  @override
  State<NodeFiltersScreen> createState() => _NodeFiltersScreenState();
}

class _NodeFiltersScreenState extends FirmwareControlsState<NodeFiltersScreen> {
  @override
  Contact get remoteTarget => widget.target;
  bool get _room => widget.target.type == advTypeRoom;
  bool _supported = false, _blacklistSupported = false, _scopeSupported = false;
  String? _summary, _blacklistSummary, _scopeSummary;
  var _rule = ForwardingRule();
  var _scopeRule = ScopeRewriteRule();
  var _moderationRule = ChannelModerationRule();
  bool _moderationSupported = false;
  String? _moderationSummary;
  final _moderationSlot = TextEditingController(text: '1');
  final _moderationChannel = TextEditingController(text: 'public');
  final _moderationSender = TextEditingController();
  final _moderationPath = TextEditingController(text: '*');
  final _moderationRate = TextEditingController(text: '5');
  final _moderationHops = TextEditingController(text: 'all');
  final _loadSlot = TextEditingController(text: '1');
  final _hops = TextEditingController(text: 'all');
  final _channel = TextEditingController(text: '*');
  final _prefix = TextEditingController();
  final _incoming = TextEditingController(text: 'any');
  final _scope = TextEditingController();
  final _rate = TextEditingController();
  final _priority = TextEditingController(text: '0');
  final _blacklistIds = TextEditingController();
  final _blacklistSlot = TextEditingController(text: '1');
  final _scopeSlot = TextEditingController(text: '1');
  final _scopeChannel = TextEditingController(text: 'txt:*');
  final _scopeTarget = TextEditingController();

  int _slot(TextEditingController controller, int max) {
    final n = int.tryParse(controller.text.trim());
    if (n == null || n < 1 || n > max) {
      throw FormatException('Enter a slot from 1 to $max.');
    }
    return n;
  }

  void _showRule(ForwardingRule rule) {
    _rule = rule;
    _hops.text = rule.hops;
    _channel.text = rule.channel;
    _prefix.text = rule.prefix;
    _incoming.text = rule.incoming;
    _scope.text = rule.scope;
    _rate.text = rule.rate;
    _priority.text = rule.priority;
  }

  Future<void> _loadRule(int slot) async {
    final reply = await endpoint.read('get fr.$slot', allowError: true);
    if (reply.toLowerCase().contains('empty filter slot')) {
      // A legacy FPF6 table also has empty slots, so emptiness alone cannot
      // establish support for the generalized fields exposed by this editor.
      throw const FormatException(
        'Empty slot. Use Add new rule after reading a supported saved row.',
      );
    }
    if (firmwareError(reply)) throw UnsupportedError(reply);
    final rule = ForwardingRule.parse(reply);
    rule.command(remote: true, room: _room);
    if (mounted) {
      _showRule(rule);
      _supported = true;
    }
  }

  @override
  Future<void> refresh() => run(() async {
    try {
      _summary = await endpoint.read('get fr');
      if (!_supported) {
        // Factory rows are normally 1-3. A truncated summary is never treated
        // as a complete inventory; individual slots remain readable below.
        final slot = RegExp(r'\b(\d+)=').firstMatch(_summary!);
        await _loadRule(
          slot == null
              ? _slot(_loadSlot, _room ? 31 : 63)
              : int.parse(slot[1]!),
        );
      }
    } catch (error) {
      _supported = false;
      _summary = error.toString();
    }
    if (!_room) {
      try {
        _moderationSummary = await endpoint.read('get flood.moderation');
        if (!RegExp(r'^(off|\d+=)').hasMatch(_moderationSummary!)) {
          throw const FormatException('Unknown moderation summary.');
        }
        _moderationSupported = true;
      } catch (e) {
        _moderationSummary = e.toString();
        _moderationSupported = false;
      }
      try {
        _blacklistSummary = await endpoint.read('get flood.filter.blacklist');
        if (!RegExp(r'^(off|count=\d+ )').hasMatch(_blacklistSummary!)) {
          throw const FormatException('Unknown blacklist summary.');
        }
        _blacklistSupported = true;
      } catch (e) {
        _blacklistSummary = e.toString();
        _blacklistSupported = false;
      }
      try {
        _scopeSummary = await endpoint.read('get flood.channel.scope');
        if (!RegExp(r'^\d+/\d+').hasMatch(_scopeSummary!)) {
          throw const FormatException('Unknown scope summary.');
        }
        _scopeSupported = true;
      } catch (e) {
        _scopeSummary = e.toString();
        _scopeSupported = false;
      }
    }
  });

  void _newRule() => setState(() {
    _showRule(ForwardingRule());
  });

  ForwardingRule _draftRule() {
    _rule.hops = _hops.text.trim();
    _rule.channel = _channel.text.trim();
    _rule.prefix = _prefix.text.trim();
    _rule.incoming = _incoming.text.trim();
    _rule.scope = _scope.text.trim();
    _rule.rate = _rate.text.trim();
    _rule.priority = _priority.text.trim();
    return _rule;
  }

  Future<void> _applyToRepeaters() async {
    try {
      final rule = _draftRule();
      final command = rule.command(remote: true, insert: true);
      final channel = RegExp(r'^[a-fA-F0-9]{32,64}$').hasMatch(rule.channel)
          ? 'private channel key'
          : rule.channel;
      final details = [
        'Type: ${filterTypeLabels[rule.type]}; traffic: ${rule.mode}; hops: ${rule.hops}',
        'Channel: $channel; action: ${rule.action}; priority: ${rule.priority}',
        'Path: ${rule.prefix.isEmpty ? 'any' : rule.prefix}; incoming: ${rule.incoming}',
        if (rule.scope.isNotEmpty) 'Scope/region: ${rule.scope}',
        if (rule.rate.isNotEmpty) 'Rate: ${rule.rate}',
        if (rule.stop) 'Stop later forward rows',
        if (rule.retry) 'Allow matching flood retries',
        if (rule.slow) 'Slow rewrite timing',
        if (rule.suspend) 'Skip during temporary radio',
      ].join('\n');
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RepeaterFilterBatchScreen(
            command: command,
            description: details,
            sourceKey: widget.target.publicKeyHex,
          ),
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

  Future<void> _sendToFleet() async {
    try {
      // MeshCore head maps both aliases to the same FPF7 parser. Use an
      // unnumbered insert: node-local slot numbers are never copied.
      final command = _draftRule()
          .command(insert: true)
          .replaceFirst('set fr ', 'set flood.rule ');
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

  Future<void> _saveRule() async {
    try {
      _draftRule();
      final command = _rule.command(remote: true, room: _room);
      final slot = _rule.slot;
      final saved = await applyChanges(
        [command],
        '${slot == null ? 'Add in a free slot, or reuse an identical saved rule. Different existing rules are not overwritten.' : 'Replace saved rule $slot, including all its conditions and actions.'} '
        'Dropping or rate-limiting requests, replies, text, or paths can break multi-hop administration. '
        'Bridge/crossover rules can also affect direct traffic at that boundary. '
        '${_rule.retry ? 'Any retry rows turn retries into an allowlist; other traffic may stop retrying. ' : ''}'
        '${_rule.channel.startsWith('hash:') ? 'A one-byte channel hash is unauthenticated and can collide. ' : ''}'
        'Read back the slot to verify the saved configuration.',
      );
      // An insert ACK may be lost. Never automatically repeat it, or leave a
      // second tap able to insert the same draft after a confirmed success.
      if (saved && mounted) {
        if (slot == null) {
          setState(() {
            _showRule(ForwardingRule());
          });
        } else {
          await run(() => _loadRule(slot));
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
    }
  }

  Future<void> _saveBlacklist({bool single = false}) async {
    try {
      final command = filterBlacklistCommand(
        _blacklistIds.text,
        slot: single ? _slot(_blacklistSlot, 255) : null,
      );
      await applyChanges(
        [command],
        single
            ? 'Set blacklist entries starting at slot ${_blacklistSlot.text}. Existing entries there will be replaced; appending must start at the next free slot.'
            : 'Replace the ENTIRE shared blacklist with these IDs. Existing IDs not listed will be removed. Path IDs are truncated and unauthenticated, not proof of identity. Rules referencing the blacklist will use the new set.',
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

  Future<void> _loadScope() => run(() async {
    final rule = ScopeRewriteRule.parse(
      await endpoint.read('get flood.channel.scope.${_slot(_scopeSlot, 255)}'),
    );
    if (mounted) {
      _scopeRule = rule;
      _scopeChannel.text = rule.channel;
      _scopeTarget.text = rule.target;
    }
  });

  Future<void> _saveScope() async {
    try {
      _scopeRule.channel = _scopeChannel.text.trim();
      _scopeRule.target = _scopeTarget.text.trim();
      final saved = await applyChanges(
        [_scopeRule.command(remote: true)],
        '${_scopeRule.slot == null ? 'Save a scope rewrite. A row with the same channel/class and path will be updated; otherwise a free slot is used.' : 'Replace scope rewrite ${_scopeRule.slot}.'} '
        'Scope rewrites run separately from forwarding rows. Region targets must exist and allow flooding. Direct scope targets do not create a region.',
      );
      if (mounted && saved) {
        setState(() {
          _scopeRule = ScopeRewriteRule();
          _scopeChannel.text = 'txt:*';
          _scopeTarget.clear();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
    }
  }

  void _showModeration(ChannelModerationRule rule) {
    _moderationRule = rule;
    _moderationChannel.text = rule.channel;
    _moderationSender.text = rule.sender;
    _moderationPath.text = rule.path;
    _moderationRate.text = rule.rate;
    _moderationHops.text = rule.hops;
  }

  Future<void> _saveModeration() async {
    try {
      _moderationRule.channel = _moderationChannel.text.trim();
      _moderationRule.sender = _moderationSender.text;
      _moderationRule.path = _moderationPath.text.trim();
      _moderationRule.rate = _moderationRate.text.trim();
      _moderationRule.hops = _moderationHops.text.trim();
      final saved = await applyChanges(
        [_moderationRule.command()],
        '${_moderationRule.slot == null ? 'Save a moderation rule. A matching channel, sender, and path row will be updated; otherwise a free slot is used.' : 'Replace moderation row ${_moderationRule.slot}.'} '
        'This affects forwarding of decrypted channel text from the matching sender label, not private messages or local delivery. '
        'Sender labels and path IDs are not proof of identity. Rate limits reset with the firmware\'s per-minute window.',
      );
      if (mounted && saved) {
        setState(() {
          _showModeration(ChannelModerationRule());
        });
      }
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
  Widget build(BuildContext context) => controlsScaffold('Packet filters', [
    const ControlNote(
      'Admin controls for current firmware tables, not the playground\'s prototype JSON/Base64 format. Normal radio rows affect flood forwarding; bridge/crossover rows also cover direct traffic at the boundary. Rules do not authenticate path IDs.',
    ),
    if (_room)
      const ControlNote(
        'Full room-server firmware supports forwarding rows only. Scope rewrites, incoming scope conditions, and the shared blacklist are repeater-only.',
      ),
    ControlGroup('Saved forwarding rules', [
      if (_summary != null) SelectableText(_summary!),
      const ControlNote(
        'A summary ending in ... is incomplete. Read an individual slot to inspect it safely. Older non-compact rows are read-only in this editor.',
      ),
      controlField(
        'Slot to read',
        _loadSlot,
        enabled: ready,
        hint: _room ? '1-31' : '1-63; capacity depends on firmware',
      ),
      Wrap(
        spacing: 6,
        children: [
          OutlinedButton(
            onPressed: ready
                ? () => run(() => _loadRule(_slot(_loadSlot, _room ? 31 : 63)))
                : null,
            child: const Text('Read rule'),
          ),
          OutlinedButton(
            onPressed: ready && _supported ? _newRule : null,
            child: const Text('Add new rule'),
          ),
        ],
      ),
    ]),
    ControlGroup(
      _rule.slot == null
          ? 'New forwarding rule'
          : 'Editing saved rule ${_rule.slot}',
      [
        controlChoice(
          'Packet type',
          _rule.type,
          filterTypeLabels,
          ready && _supported
              ? (v) => setState(() {
                  _rule.type = v;
                })
              : null,
        ),
        controlField(
          'Received hops',
          _hops,
          enabled: ready && _supported,
          hint: 'all, 5+, 2-6, or 3 (0-63)',
        ),
        controlField(
          'Channel match',
          _channel,
          enabled: ready && _supported,
          hint:
              '*, public, #name, hash:XX, or a full key. Hash matches are not authenticated.',
        ),
        controlChoice(
          'Traffic path',
          _rule.mode,
          const {
            'radio': 'Normal radio forwarding',
            'bridge': 'Bridge entry/exit',
            'cross': 'Radio profile crossover',
            'bridge,cross': 'Bridge and crossover',
          },
          ready && _supported
              ? (v) => setState(() {
                  _rule.mode = v;
                })
              : null,
        ),
        controlChoice(
          'Action',
          _rule.action,
          {
            'drop': 'Drop / do not retransmit',
            if (!_room) 'scope': 'Rewrite to direct scope',
            if (!_room) 'region': 'Rewrite to existing region',
            'none': 'Rate / retry / stop only',
          },
          ready && _supported
              ? (v) => setState(() {
                  _rule.action = v;
                })
              : null,
        ),
        if (_rule.action == 'scope' || _rule.action == 'region')
          controlField(
            'Target name',
            _scope,
            enabled: ready && _supported,
            hint: 'Existing region or #scope; firmware resolves it',
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced conditions and actions'),
          children: [
            controlField(
              'Path prefix',
              _prefix,
              enabled: ready && _supported,
              hint: _room
                  ? 'Blank or 1-3 equal-width IDs, e.g. 86,0C'
                  : 'Blank, blacklist, or 1-3 equal-width IDs, e.g. 860C,12A4',
            ),
            if (!_room)
              controlField(
                'Original incoming scope',
                _incoming,
                enabled: ready && _supported,
                hint:
                    'any, none, scoped, allowed, unknown, scope:name, region:name',
              ),
            controlField(
              'Packets per minute',
              _rate,
              enabled: ready && _supported,
              hint: 'Blank means unlimited; 0-65534. 0 blocks all matches.',
            ),
            controlField(
              'Rule priority',
              _priority,
              enabled: ready && _supported,
              hint:
                  '0-255, highest first; equal priority uses channel specificity, then slot',
            ),
            for (final flag in ['stop', 'retry', 'slow', 'suspend'])
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  {
                    'stop': 'Stop later forward rows',
                    'retry': 'Allow matching flood retries',
                    'slow': 'Slow rewrite timing',
                    'suspend': 'Skip rule during temporary radio',
                  }[flag]!,
                ),
                value: {
                  'stop': _rule.stop,
                  'retry': _rule.retry,
                  'slow': _rule.slow,
                  'suspend': _rule.suspend,
                }[flag]!,
                onChanged: ready && _supported
                    ? (v) => setState(() {
                        switch (flag) {
                          case 'stop':
                            _rule.stop = v;
                          case 'retry':
                            _rule.retry = v;
                          case 'slow':
                            _rule.slow = v;
                          case 'suspend':
                            _rule.suspend = v;
                        }
                      })
                    : null,
              ),
          ],
        ),
        FilledButton(
          onPressed: ready && _supported ? _saveRule : null,
          child: Text(
            _rule.slot == null
                ? 'Add rule to device'
                : 'Replace rule ${_rule.slot}',
          ),
        ),
        if (!_room)
          OutlinedButton(
            onPressed: ready && _supported ? _applyToRepeaters : null,
            child: const Text('Apply to selected repeaters'),
          ),
        OutlinedButton(
          onPressed: ready && _supported ? _sendToFleet : null,
          child: const Text('Send rule over fleet channel'),
        ),
        if (_rule.slot != null)
          TextButton(
            onPressed: ready && _supported
                ? () => applyChanges(
                    ['del fr.${_rule.slot}'],
                    'Delete only forwarding rule ${_rule.slot}. Other rules are unchanged.',
                  )
                : null,
            child: const Text('Delete this rule'),
          ),
      ],
    ),
    if (!_room) ...[
      ControlGroup('Scope-rewrite phase', [
        if (_scopeSummary != null) ControlNote(_scopeSummary!),
        controlField(
          'Scope slot to read',
          _scopeSlot,
          enabled: ready && _scopeSupported,
        ),
        Wrap(
          spacing: 6,
          children: [
            OutlinedButton(
              onPressed: ready && _scopeSupported ? _loadScope : null,
              child: const Text('Read scope row'),
            ),
            OutlinedButton(
              onPressed: ready && _scopeSupported
                  ? () => setState(() {
                      _scopeRule = ScopeRewriteRule();
                      _scopeChannel.text = 'txt:*';
                      _scopeTarget.clear();
                    })
                  : null,
              child: const Text('New scope row'),
            ),
          ],
        ),
        Text(
          _scopeRule.slot == null
              ? 'New rewrite'
              : 'Editing rewrite ${_scopeRule.slot}',
        ),
        controlField(
          'Match channel / class',
          _scopeChannel,
          enabled: ready && _scopeSupported,
          hint: 'public, #name, key, txt:*, login:*, or other:*',
        ),
        controlChoice(
          'Target kind',
          _scopeRule.directScope == null
              ? 'unknown'
              : _scopeRule.directScope!
              ? 'scope'
              : 'region',
          const {
            'unknown': 'Choose target kind before saving',
            'scope': 'Direct transport scope',
            'region': 'Existing region',
          },
          ready && _scopeSupported
              ? (v) => setState(() {
                  _scopeRule.directScope = v == 'unknown' ? null : v == 'scope';
                })
              : null,
        ),
        if (_scopeRule.directScope == null)
          const ControlNote(
            'The firmware getter uses scope= for both target kinds. Choose the original kind explicitly before replacing this row.',
          ),
        controlField(
          'Target name',
          _scopeTarget,
          enabled: ready && _scopeSupported,
        ),
        controlChoice(
          'Path condition',
          _scopeRule.path,
          {
            '': 'No path condition',
            'blacklist': 'Shared blacklist',
            for (var n = 1; n <= 6; n++) 'bucket:$n': 'Path bucket $n',
          },
          ready && _scopeSupported
              ? (v) => setState(() {
                  _scopeRule.path = v;
                })
              : null,
        ),
        controlChoice(
          'Rewrite timing',
          _scopeRule.timing,
          const {'fast': 'Fast (default)', 'slow': 'Slow'},
          ready && _scopeSupported
              ? (v) => setState(() {
                  _scopeRule.timing = v;
                })
              : null,
        ),
        FilledButton(
          onPressed: ready && _scopeSupported ? _saveScope : null,
          child: Text(
            _scopeRule.slot == null
                ? 'Save scope rewrite'
                : 'Replace rewrite ${_scopeRule.slot}',
          ),
        ),
        if (_scopeRule.slot != null)
          TextButton(
            onPressed: ready && _scopeSupported
                ? () => applyChanges([
                    'del flood.channel.scope.${_scopeRule.slot}',
                  ], 'Delete only scope rewrite ${_scopeRule.slot}.')
                : null,
            child: const Text('Delete this rewrite'),
          ),
      ]),
      ControlGroup('Shared path blacklist', [
        if (_blacklistSummary != null) SelectableText(_blacklistSummary!),
        const ControlNote(
          'Read individual slots if this summary is truncated. IDs must be 3 bytes (6 hex characters). Replacing the set removes all previous IDs.',
        ),
        controlField(
          'Blacklist slot',
          _blacklistSlot,
          enabled: ready && _blacklistSupported,
        ),
        OutlinedButton(
          onPressed: ready && _blacklistSupported
              ? () => run(() async {
                  final reply = await endpoint.read(
                    'get flood.filter.blacklist.${_slot(_blacklistSlot, 255)}',
                  );
                  final match = RegExp(
                    r'^\d+=([0-9a-fA-F]{6})$',
                  ).firstMatch(reply);
                  if (match == null) {
                    throw const FormatException('Unknown blacklist response.');
                  }
                  if (mounted) _blacklistIds.text = match[1]!;
                })
              : null,
          child: const Text('Read blacklist entry'),
        ),
        controlField(
          'IDs to save',
          _blacklistIds,
          enabled: ready && _blacklistSupported,
          hint: 'ABCDEF,123456 (up to 18 distinct IDs per command)',
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            OutlinedButton(
              onPressed: ready && _blacklistSupported
                  ? () => _saveBlacklist(single: true)
                  : null,
              child: const Text('Set at slot'),
            ),
            OutlinedButton(
              onPressed: ready && _blacklistSupported
                  ? () => _saveBlacklist()
                  : null,
              child: const Text('Replace whole set'),
            ),
            TextButton(
              onPressed: ready && _blacklistSupported
                  ? () async {
                      try {
                        await applyChanges(
                          [
                            'del flood.filter.blacklist.${_slot(_blacklistSlot, 255)}',
                          ],
                          'Remove this blacklist entry. Later entries shift down by one slot.',
                        );
                      } catch (e) {
                        if (mounted) {
                          setState(() {
                            status = e.toString();
                            failed = true;
                          });
                        }
                      }
                    }
                  : null,
              child: const Text('Delete entry'),
            ),
          ],
        ),
      ]),
    ],
    if (!_room)
      ControlGroup('Channel sender moderation', [
        if (_moderationSummary != null) SelectableText(_moderationSummary!),
        const ControlNote(
          'Separate table for decrypted channel text. Sender labels match case-insensitively. This is not an authenticated person blacklist.',
        ),
        controlField(
          'Moderation slot to read',
          _moderationSlot,
          enabled: ready && _moderationSupported,
          hint: '1-16',
        ),
        Wrap(
          spacing: 6,
          children: [
            OutlinedButton(
              onPressed: ready && _moderationSupported
                  ? () => run(() async {
                      final rule = ChannelModerationRule.parse(
                        await endpoint.read(
                          'get flood.moderation.${_slot(_moderationSlot, 16)}',
                        ),
                      );
                      if (mounted) _showModeration(rule);
                    })
                  : null,
              child: const Text('Read moderation row'),
            ),
            OutlinedButton(
              onPressed: ready && _moderationSupported
                  ? () => setState(() {
                      _showModeration(ChannelModerationRule());
                    })
                  : null,
              child: const Text('New moderation row'),
            ),
          ],
        ),
        Text(
          _moderationRule.slot == null
              ? 'New moderation row'
              : 'Editing moderation ${_moderationRule.slot}',
        ),
        controlField(
          'Moderated channel',
          _moderationChannel,
          enabled: ready && _moderationSupported,
          hint: 'public, #name, or a full channel key',
        ),
        controlField(
          'Exact sender label',
          _moderationSender,
          enabled: ready && _moderationSupported,
          hint: '1-31 characters; * only for hop limits',
        ),
        controlChoice(
          'Moderation action',
          _moderationRule.action,
          const {
            'drop': 'Drop sender messages',
            'rate': 'Limit messages per minute',
            'hops': 'Limit forwarding hops',
          },
          ready && _moderationSupported
              ? (v) => setState(() {
                  _moderationRule.action = v;
                })
              : null,
        ),
        if (_moderationRule.action == 'rate')
          controlField(
            'Messages per minute',
            _moderationRate,
            enabled: ready && _moderationSupported,
            hint: '0-65534',
          ),
        controlField(
          'Maximum forwarded hops',
          _moderationHops,
          enabled: ready && _moderationSupported,
          hint: 'all or 0-63; N stops forwarding at N received hops or higher',
        ),
        controlField(
          'Sender path prefix',
          _moderationPath,
          enabled: ready && _moderationSupported,
          hint: '* or 1-3 equal-width IDs, e.g. A1B2C3,D4E5F6',
        ),
        FilledButton(
          onPressed: ready && _moderationSupported ? _saveModeration : null,
          child: Text(
            _moderationRule.slot == null
                ? 'Save moderation row'
                : 'Replace moderation ${_moderationRule.slot}',
          ),
        ),
        if (_moderationRule.slot != null)
          TextButton(
            onPressed: ready && _moderationSupported
                ? () => applyChanges([
                    'del flood.moderation.${_moderationRule.slot}',
                  ], 'Delete only moderation row ${_moderationRule.slot}.')
                : null,
            child: const Text('Delete this moderation row'),
          ),
      ]),
  ]);

  @override
  void dispose() {
    for (final controller in [
      _loadSlot,
      _hops,
      _channel,
      _prefix,
      _incoming,
      _scope,
      _rate,
      _priority,
      _blacklistIds,
      _blacklistSlot,
      _scopeSlot,
      _scopeChannel,
      _scopeTarget,
      _moderationSlot,
      _moderationChannel,
      _moderationSender,
      _moderationPath,
      _moderationRate,
      _moderationHops,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }
}
