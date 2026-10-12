import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import '../services/repeater_filter_batch.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../widgets/firmware_controls_ui.dart';
import 'node_filters_screen.dart';

class LoggedInRepeaterFiltersScreen extends StatelessWidget {
  const LoggedInRepeaterFiltersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final repeaters = loggedInFilterRepeaters(connector);
    return Scaffold(
      appBar: AppBar(title: const Text('Repeater filters')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const ControlNote(
              'Choose a logged-in repeater to build or copy a filter. In its editor, use Apply to selected repeaters to choose where it goes.',
            ),
            if (repeaters.isEmpty)
              const ControlNote(
                'No confirmed admin logins for this Companion. Log into repeaters as admin from Contacts first. Saved passwords and guest logins do not count.',
              ),
            for (final target in repeaters)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cell_tower),
                  title: Text(target.name),
                  subtitle: Text(
                    'Admin login - ${target.publicKeyHex.substring(0, 12)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => NodeFiltersScreen(target: target),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RepeaterFilterBatchScreen extends StatefulWidget {
  const RepeaterFilterBatchScreen({
    super.key,
    required this.command,
    required this.description,
    required this.sourceKey,
  });
  final String command;
  final String description;
  final String sourceKey;

  @override
  State<RepeaterFilterBatchScreen> createState() =>
      _RepeaterFilterBatchScreenState();
}

class _RepeaterFilterBatchScreenState extends State<RepeaterFilterBatchScreen>
    with DisconnectNavigationMixin<RepeaterFilterBatchScreen> {
  final Set<String> _selected = {};
  final Map<String, RepeaterFilterCheck> _checks = {};
  final Map<String, RepeaterFilterResult> _results = {};
  RepeaterFilterBatch? _batch;
  bool _busy = false, _applying = false, _stopping = false, _attempted = false;
  String? _progress, _error;

  @override
  void initState() {
    super.initState();
    _selected.add(widget.sourceKey);
  }

  List<Contact> get _eligible =>
      loggedInFilterRepeaters(context.read<MeshCoreConnector>());

  bool get _readyToApply =>
      !_busy &&
      !_attempted &&
      _selected.isNotEmpty &&
      _selected.every(
        (key) =>
            _checks[key]?.ready == true &&
            _eligible.any((target) => target.publicKeyHex == key),
      );

  Future<void> _check() async {
    if (_busy || _selected.isEmpty) return;
    final targets = _eligible
        .where((t) => _selected.contains(t.publicKeyHex))
        .toList();
    if (targets.length != _selected.length) {
      setState(() => _error = 'A selected admin login is no longer available.');
      return;
    }
    _batch?.dispose();
    _batch = RepeaterFilterBatch(context.read<MeshCoreConnector>());
    setState(() {
      _busy = true;
      _error = null;
      _attempted = false;
      _stopping = false;
      _checks.clear();
      _results.clear();
    });
    for (var i = 0; i < targets.length; i++) {
      if (!mounted) return;
      setState(
        () => _progress =
            'Checking ${targets[i].name} (${i + 1}/${targets.length})',
      );
      final check = await _batch!.check(targets[i]);
      if (!mounted) return;
      setState(() => _checks[check.target.publicKeyHex] = check);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = _checks.values.every((c) => c.ready)
          ? 'All selected repeaters are ready. No settings have changed.'
          : 'Some repeaters are not ready. Inspect their results or uncheck them.';
    });
  }

  Future<void> _apply() async {
    if (!_readyToApply) return;
    final selected = Set<String>.of(_selected);
    final checks = [for (final key in selected) _checks[key]!];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Apply to ${checks.length} repeater(s)?'),
        scrollable: true,
        content: Text(
          '${widget.description}\n\n${checks.map((c) => c.target.name).join('\n')}\n\n'
          'Each node adds this rule in a free slot, or reuses an identical rule. '
          'Different saved rules are not overwritten. This is not an atomic operation: '
          'one node may save while another fails. Filtering requests, replies, text, '
          'or paths can break multi-hop administration, including access to later nodes. '
          'A lost reply may mean the rule was saved; inspect before retrying. No automatic retries.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply filter'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !_readyToApply) return;
    if (selected.length != _selected.length ||
        !selected.containsAll(_selected)) {
      setState(() => _error = 'Selection changed. Check the repeaters again.');
      return;
    }
    setState(() {
      _busy = true;
      _applying = true;
      _attempted = true;
      _error = null;
      _results.clear();
    });
    try {
      await _batch!.apply(
        checks,
        widget.command,
        onSending: (target) {
          if (mounted) setState(() => _progress = 'Applying to ${target.name}');
        },
        onResult: (result) {
          if (mounted) {
            setState(() => _results[result.target.publicKeyHex] = result);
          }
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _applying = false;
          _progress =
              '${_results.values.where((r) => r.applied).length}'
              ' of ${checks.length} repeater(s) acknowledged the filter. '
              'Inspect unconfirmed nodes before checking and applying again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    checkConnectionAndNavigate(connector);
    final eligible = loggedInFilterRepeaters(connector);
    final byKey = {for (final t in eligible) t.publicKeyHex: t};
    final displayed = {
      ...byKey,
      for (final c in _checks.values)
        if (_selected.contains(c.target.publicKeyHex))
          c.target.publicKeyHex: c.target,
    };
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const FittedBox(child: Text('Apply repeater filter')),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Text(widget.description),
              const ControlNote(
                'Only confirmed admin logins on this Companion are listed. Logins are remembered during this app session, including reconnecting the same Companion. Changing Companions clears them. Remote permissions may still change.',
              ),
              if (_progress != null) Text(_progress!),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (displayed.isEmpty)
                const ControlNote(
                  'Log into repeaters as admin from Contacts first.',
                ),
              for (final target in displayed.values)
                Card(
                  child: CheckboxListTile(
                    title: Text(target.name),
                    subtitle: Text(
                      '${target.publicKeyHex.substring(0, 12)}\n'
                      '${_results[target.publicKeyHex]?.message ?? _checks[target.publicKeyHex]?.message ?? 'Admin login - not checked'}'
                      '${byKey.containsKey(target.publicKeyHex) ? '' : '\nAdmin login unavailable - log in again'}',
                    ),
                    value: _selected.contains(target.publicKeyHex),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _selected.add(target.publicKeyHex);
                            } else {
                              _selected.remove(target.publicKeyHex);
                            }
                            _attempted = false;
                            _checks.clear();
                            _progress = null;
                          }),
                  ),
                ),
              if (_selected.any((key) => !displayed.containsKey(key)))
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _selected.removeWhere(
                            (key) => !byKey.containsKey(key),
                          );
                          _checks.clear();
                          _attempted = false;
                        }),
                  child: const Text('Remove unavailable selections'),
                ),
              const ControlNote(
                'Check reads firmware support without changing settings. Apply sends one new forwarding rule to each selected repeater. It does not copy an entire filter table.',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: !_busy && _selected.isNotEmpty ? _check : null,
                    child: const Text('Check selected repeaters'),
                  ),
                  FilledButton(
                    onPressed: _readyToApply ? _apply : null,
                    child: const Text('Apply to selected repeaters'),
                  ),
                  if (_busy)
                    OutlinedButton(
                      onPressed: _stopping
                          ? null
                          : () => setState(() {
                              _stopping = true;
                              if (_applying) {
                                _batch!.stopAfterCurrent();
                                _progress =
                                    'Stopping after the current repeater.';
                              } else {
                                _batch!.dispose();
                                _progress = 'Cancelling read-only checks.';
                              }
                            }),
                      child: Text(
                        _applying
                            ? 'Stop after current repeater'
                            : 'Cancel checks',
                      ),
                    ),
                ],
              ),
              if (_results.isNotEmpty) ...[
                const ControlNote(
                  'An acknowledgement confirms the setter response, not a full read-back. Open each node to inspect saved slots. Unconfirmed writes are never retried automatically.',
                ),
                for (final result in _results.values)
                  OutlinedButton(
                    onPressed:
                        !_busy && byKey.containsKey(result.target.publicKeyHex)
                        ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  NodeFiltersScreen(target: result.target),
                            ),
                          )
                        : null,
                    child: Text('Inspect ${result.target.name}'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _batch?.dispose();
    super.dispose();
  }
}
