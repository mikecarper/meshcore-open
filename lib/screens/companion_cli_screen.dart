import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../theme/mesh_theme.dart';

class CompanionCliScreen extends StatefulWidget {
  const CompanionCliScreen({super.key});

  @override
  State<CompanionCliScreen> createState() => _CompanionCliScreenState();
}

class _CompanionCliScreenState extends State<CompanionCliScreen> {
  final TextEditingController _commandController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<({String text, bool isCommand, bool isError})> _history = [];
  bool _sending = false;

  @override
  void dispose() {
    _commandController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _append(String text, {bool isCommand = false, bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _history.add((text: text, isCommand: isCommand, isError: isError));
      if (_history.length > 100) _history.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendCommand() async {
    final connector = context.read<MeshCoreConnector>();
    final command = _commandController.text.trim();
    if (_sending ||
        !connector.isConnected ||
        (connector.firmwareVerCode ?? 0) < 14 ||
        command.isEmpty) {
      return;
    }

    _commandController.clear();
    setState(() => _sending = true);
    _append(command, isCommand: true);
    try {
      final reply = await connector.executeLocalCliCommand(command);
      if (!mounted) return;
      _append(reply.isEmpty ? context.l10n.companionCli_noReply : reply);
    } catch (error) {
      if (!mounted) return;
      _append(context.l10n.companionCli_error(error.toString()), isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Consumer<MeshCoreConnector>(
      builder: (context, connector, _) {
        final available =
            connector.isConnected && (connector.firmwareVerCode ?? 0) >= 14;
        final canSend =
            available && !_sending && _commandController.text.trim().isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.companionCli_title),
            actions: [
              if (_history.isNotEmpty)
                IconButton(
                  tooltip: l10n.common_clear,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(_history.clear),
                ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.companionCli_description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!available) ...[
                        const SizedBox(height: 8),
                        Text(
                          connector.isConnected
                              ? l10n.companionCli_unsupported
                              : l10n.companionCli_notConnected,
                          style: TextStyle(color: scheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _history.isEmpty
                      ? Center(child: Text(l10n.companionCli_empty))
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: _history.length,
                          itemBuilder: (context, index) {
                            final entry = _history[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: SelectableText(
                                entry.isCommand
                                    ? '> ${entry.text}'
                                    : entry.text,
                                style: MeshTheme.mono(
                                  fontSize: 13,
                                  color: entry.isError
                                      ? scheme.error
                                      : entry.isCommand
                                      ? scheme.primary
                                      : scheme.onSurface,
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _commandController,
                          enabled: available && !_sending,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _sendCommand(),
                          textInputAction: TextInputAction.send,
                          minLines: 1,
                          maxLines: 3,
                          decoration: InputDecoration(
                            hintText: l10n.companionCli_hint,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: l10n.companionCli_send,
                        onPressed: canSend ? _sendCommand : null,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
