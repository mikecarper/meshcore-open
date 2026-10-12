import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/contact_localization.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../services/node_monitor_service.dart';
import '../storage/node_monitor_store.dart';

class NodeMonitorScreen extends StatefulWidget {
  const NodeMonitorScreen({super.key});

  @override
  State<NodeMonitorScreen> createState() => _NodeMonitorScreenState();
}

class _NodeMonitorScreenState extends State<NodeMonitorScreen>
    with WidgetsBindingObserver {
  late final NodeMonitorService _monitor;
  Timer? _timer;
  Timer? _autoTimer;
  bool _foreground = true;
  bool _paused = false;
  bool _choosing = false;
  String _scheduledCompanion = '';

  @override
  void initState() {
    super.initState();
    _monitor = NodeMonitorService(context.read<MeshCoreConnector>());
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    _schedule();
  }

  void _schedule() {
    _scheduledCompanion = _monitor.companionKey;
    _autoTimer?.cancel();
    if (_monitor.intervalSeconds == 0) return;
    _autoTimer = Timer(Duration(seconds: _monitor.intervalSeconds), () {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == true &&
          _foreground &&
          !_paused &&
          !_choosing &&
          !_monitor.busy &&
          _monitor.selected.isNotEmpty) {
        unawaited(_refresh());
      } else {
        _schedule();
      }
    });
  }

  void _tick() {
    if (!mounted) return;
    if (_scheduledCompanion != _monitor.companionKey) _schedule();
    if (ModalRoute.of(context)?.isCurrent != true || !_foreground) {
      _monitor.stop();
      return;
    }
    setState(() {});
  }

  Future<void> _refresh({String? only}) async {
    await _monitor.refresh(only: only);
    if (mounted) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _monitor.stop();
    if (_foreground) _schedule();
  }

  Future<void> _choose() async {
    _choosing = true;
    final scope = _monitor.companionKey;
    final selected = await Navigator.push<Set<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => _MonitorNodePicker(
          contacts: _monitor.available,
          selected: _monitor.selected,
        ),
      ),
    );
    if (!mounted) return;
    _choosing = false;
    if (selected != null && scope == _monitor.companionKey) {
      try {
        await _monitor.select(selected);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not save the watchlist. Try again.'),
            ),
          );
        }
      }
    }
    _schedule();
  }

  String _age(DateTime? time) {
    if (time == null) return 'Never';
    final age = DateTime.now().difference(time);
    if (age.inSeconds < 60) return 'Just now';
    if (age.inMinutes < 60) return '${age.inMinutes} min ago';
    if (age.inHours < 24) return '${age.inHours} hr ago';
    return '${age.inDays} days ago';
  }

  String _uptime(int seconds) {
    final hours = seconds ~/ 3600;
    return hours >= 24
        ? '${hours ~/ 24}d ${hours % 24}h'
        : '${hours}h ${(seconds ~/ 60) % 60}m';
  }

  Widget _node(String key) {
    final contact = _monitor.contact(key);
    final reading = _monitor.readings[key];
    final stats = reading?.stats;
    final now = DateTime.now();
    final stale =
        reading?.receivedAt != null &&
        now.difference(reading!.receivedAt!).inSeconds >
            (_monitor.intervalSeconds == 0
                ? NodeMonitorStore.defaultIntervalSeconds * 2
                : _monitor.intervalSeconds * 2);
    final details = <String>[
      if (reading?.batteryMv != null)
        'Battery ${(reading!.batteryMv! / 1000).toStringAsFixed(2)} V',
      if (stats != null) ...[
        'Uptime ${_uptime(stats.uptimeSecs)}',
        'Last RX ${stats.lastRssi} dBm / ${stats.lastSnr.toStringAsFixed(1)} dB SNR',
        'Packets RX ${stats.packetsRecv} / TX ${stats.packetsSent}',
        'Queue ${stats.queueLen} / errors ${stats.recvErrors ?? stats.errEvents}',
      ],
      if (reading?.temperature != null)
        'Temperature ${reading!.temperature!.toStringAsFixed(1)} C',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              contact?.name ?? 'Unavailable contact',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(key.substring(0, 12)),
            if (contact != null)
              Text(
                '${contact.typeLabel(context.l10n)} - '
                '${contact.pathLabel(context.l10n, pathHashByteWidth: _monitor.connector.pathHashByteWidth)}',
              ),
            const SizedBox(height: 8),
            Text(reading?.status ?? 'Not refreshed'),
            Text(
              'Last response: ${_age(reading?.receivedAt)}${stale ? ' - stale' : ''}',
            ),
            if (contact != null) Text('Last advert: ${_age(contact.lastSeen)}'),
            for (final detail in details) Text(detail),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed:
                    !_monitor.busy &&
                        contact != null &&
                        _monitor.connector.isConnected
                    ? () => _refresh(only: key)
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh node'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _monitor,
    builder: (context, _) {
      final connected = _monitor.connector.isConnected;
      return Scaffold(
        appBar: AppBar(title: const Text('Node dashboard')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text(
                '${_monitor.selected.length} selected nodes',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        !_monitor.busy &&
                            connected &&
                            _monitor.companionKey.isNotEmpty
                        ? _choose
                        : null,
                    icon: const Icon(Icons.checklist),
                    label: const Text('Select nodes'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        !_monitor.busy &&
                            connected &&
                            _monitor.selected.isNotEmpty
                        ? _refresh
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh all'),
                  ),
                  if (_monitor.busy)
                    OutlinedButton(
                      onPressed: _monitor.stop,
                      child: const Text('Stop refresh'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: ValueKey(
                  '${_monitor.companionKey}:${_monitor.intervalSeconds}',
                ),
                // Flutter 3.32 compatibility; current Flutter still accepts value.
                // ignore: deprecated_member_use
                value: _monitor.intervalSeconds,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Automatic refresh',
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Manual only')),
                  DropdownMenuItem(value: 43200, child: Text('Every 12 hours')),
                  DropdownMenuItem(value: 86400, child: Text('Every 24 hours')),
                  DropdownMenuItem(
                    value: 172800,
                    child: Text('Every 48 hours'),
                  ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  try {
                    await _monitor.setInterval(value);
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not save the refresh interval.'),
                        ),
                      );
                    }
                  }
                  if (mounted) _schedule();
                },
              ),
              if (_monitor.intervalSeconds > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pause automatic monitoring'),
                  value: _paused,
                  onChanged: (value) => setState(() {
                    _paused = value;
                    if (value) _monitor.stop();
                    _schedule();
                  }),
                ),
              const Text(
                'Monitoring runs only while this dashboard is open. '
                'Automatic refresh is at least 12 hours apart. Tap Refresh for an immediate read. '
                'Nodes are read one at a time, with no automatic retries. '
                'Log into repeaters or rooms from Contacts first when required. '
                'Chat and sensor nodes must allow telemetry. A timeout does not prove a node is offline.',
              ),
              if (!connected)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Companion disconnected - monitoring stopped.'),
                ),
              if (_monitor.progress != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_monitor.progress!),
                ),
              if (_monitor.busy) const LinearProgressIndicator(),
              if (_monitor.selected.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Select the nodes you want to monitor. This watchlist is saved separately for each Companion.',
                  ),
                ),
              for (final key in _monitor.selected) _node(key),
            ],
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _autoTimer?.cancel();
    _monitor.dispose();
    super.dispose();
  }
}

class _MonitorNodePicker extends StatefulWidget {
  const _MonitorNodePicker({required this.contacts, required this.selected});
  final List<Contact> contacts;
  final Set<String> selected;

  @override
  State<_MonitorNodePicker> createState() => _MonitorNodePickerState();
}

class _MonitorNodePickerState extends State<_MonitorNodePicker> {
  late final Set<String> _selected = Set.of(widget.selected);
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final visible = widget.contacts.where(
      (c) =>
          c.name.toLowerCase().contains(_search) ||
          c.publicKeyHex.contains(_search),
    );
    final missing = _selected
        .where((key) => !widget.contacts.any((c) => c.publicKeyHex == key))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Select nodes')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Search nodes',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) =>
                    setState(() => _search = value.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final contact in visible)
                    CheckboxListTile(
                      title: Text(contact.name),
                      subtitle: Text(
                        '${contact.typeLabel(context.l10n)} - ${contact.publicKeyHex.substring(0, 12)}',
                      ),
                      value: _selected.contains(contact.publicKeyHex),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(contact.publicKeyHex);
                        } else {
                          _selected.remove(contact.publicKeyHex);
                        }
                      }),
                    ),
                  for (final key in missing)
                    CheckboxListTile(
                      title: const Text('Unavailable contact'),
                      subtitle: Text(key.substring(0, 12)),
                      value: true,
                      onChanged: (_) => setState(() => _selected.remove(key)),
                    ),
                  if (visible.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No matching nodes.'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _selected),
                child: Text('Monitor ${_selected.length} nodes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
