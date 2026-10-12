import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import '../services/firmware_controls.dart';
import '../utils/disconnect_navigation_mixin.dart';

abstract class FirmwareControlsState<W extends StatefulWidget> extends State<W>
    with DisconnectNavigationMixin<W> {
  FirmwareControlEndpoint? _endpoint;
  final ScrollController _scrollController = ScrollController();
  bool busy = false;
  String? status;
  bool failed = false;
  Contact? get remoteTarget => null;
  FirmwareControlEndpoint get endpoint => _endpoint!;
  bool get ready => !busy && (_endpoint?.available ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_endpoint != null) return;
    _endpoint = FirmwareControlEndpoint(
      context.read<MeshCoreConnector>(),
      target: remoteTarget,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) refresh();
    });
  }

  Future<void> refresh();

  Future<void> run(Future<void> Function() operation, {String? success}) async {
    if (!ready) return;
    setState(() {
      busy = true;
      status = null;
      failed = false;
    });
    try {
      await operation();
      if (mounted) {
        setState(() {
          status = success;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          failed = true;
        });
      }
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<bool> confirm(
    String title,
    String description, {
    String button = 'Apply',
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            scrollable: true,
            content: Text(description),
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
        ) ??
        false;
  }

  Future<bool> applyChanges(
    List<String> commands,
    String description, {
    VoidCallback? guard,
  }) async {
    if (!ready || commands.isEmpty) return false;
    try {
      for (final command in commands) {
        validateFirmwareCommand(command, remote: remoteTarget != null);
      }
    } catch (error) {
      setState(() {
        status = error.toString();
        failed = true;
      });
      return false;
    }
    if (!await confirm(
      'Save to ${remoteTarget?.name ?? 'Companion'}?',
      description,
    )) {
      return false;
    }
    if (!mounted || !ready) return false;
    var success = false;
    await run(() async {
      await endpoint.apply(commands, guard: guard);
      success = true;
    }, success: 'Saved to device.');
    if (success && mounted) {
      await refresh();
      if (mounted && !failed) {
        setState(() {
          status = 'Saved to device.';
        });
        if (_scrollController.hasClients) {
          await _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
    }
    return success;
  }

  Widget controlsScaffold(String title, List<Widget> children) {
    final connector = context.watch<MeshCoreConnector>();
    checkConnectionAndNavigate(connector);
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(title),
        ),
        actions: [
          IconButton(
            tooltip: 'Read device',
            onPressed: ready ? refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            Text(
              remoteTarget == null
                  ? 'Companion: ${connector.selfName ?? 'connected device'}'
                  : 'Remote node: ${remoteTarget!.name}',
            ),
            if (!endpoint.available)
              const ControlNote(
                'Connect to a Companion with protocol 14 or newer. If the device changed, reopen this screen.',
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  status!,
                  style: TextStyle(
                    color: failed ? Theme.of(context).colorScheme.error : null,
                  ),
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _endpoint?.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class ControlNote extends StatelessWidget {
  const ControlNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class ControlGroup extends StatelessWidget {
  const ControlGroup(this.title, this.children, {super.key});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}

Widget controlChoice(
  String label,
  String value,
  Map<String, String> choices,
  ValueChanged<String>? onChanged,
) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: DropdownButtonFormField<String>(
    // Flutter 3.32 (Android 5.1 compatibility) predates initialValue.
    key: ValueKey('$label:$value'),
    // ignore: deprecated_member_use
    value: value,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    items: choices.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: onChanged == null
        ? null
        : (v) {
            if (v != null) onChanged(v);
          },
  ),
);

Widget controlField(
  String label,
  TextEditingController controller, {
  bool enabled = true,
  String? hint,
  bool obscure = false,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: TextField(
    controller: controller,
    enabled: enabled,
    obscureText: obscure,
    decoration: InputDecoration(
      labelText: label,
      helperText: hint,
      helperMaxLines: 3,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  ),
);
