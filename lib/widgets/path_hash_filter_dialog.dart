import 'package:flutter/material.dart';

import '../helpers/path_hash_filter_command.dart';
import '../l10n/l10n.dart';

/// Returns a draft CLI command. Opening or completing this dialog sends nothing.
class PathHashFilterDialog extends StatefulWidget {
  const PathHashFilterDialog({super.key});

  @override
  State<PathHashFilterDialog> createState() => _PathHashFilterDialogState();
}

class _PathHashFilterDialogState extends State<PathHashFilterDialog> {
  final _formKey = GlobalKey<FormState>();
  final _rateController = TextEditingController(text: '10');
  int _hashBytes = 1;
  String _mode = 'radio';
  bool _limitRate = false;

  @override
  void dispose() {
    _rateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(l10n.repeater_pathHashFilter),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.repeater_pathHashFilterWarning),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _hashBytes,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.repeater_pathHashFilterWidth,
                ),
                items: [
                  DropdownMenuItem(
                    value: 0,
                    child: Text(l10n.repeater_pathHashFilterAny),
                  ),
                  for (final width in [1, 2, 3])
                    DropdownMenuItem(
                      value: width,
                      child: Text(l10n.repeater_pathHashFilterBytes(width)),
                    ),
                ],
                onChanged: (value) => setState(() => _hashBytes = value!),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.repeater_pathHashFilterMode,
                ),
                items: [
                  for (final mode in [
                    'radio',
                    'bridge',
                    'cross',
                    'bridge,cross',
                  ])
                    DropdownMenuItem(value: mode, child: Text(mode)),
                ],
                onChanged: (value) => setState(() => _mode = value!),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.repeater_pathHashFilterRate),
                subtitle: Text(l10n.repeater_pathHashFilterDrop),
                value: _limitRate,
                onChanged: (value) => setState(() => _limitRate = value),
              ),
              if (_limitRate)
                TextFormField(
                  controller: _rateController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.repeater_pathHashFilterRate,
                  ),
                  validator: (value) {
                    final rate = int.tryParse(value?.trim() ?? '');
                    return rate == null || rate < 1 || rate > 65534
                        ? l10n.repeater_pathHashFilterInvalidRate
                        : null;
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              buildPathHashFilterCommand(
                hashBytes: _hashBytes,
                mode: _mode,
                ratePerMinute: _limitRate
                    ? int.parse(_rateController.text.trim())
                    : null,
              ),
            );
          },
          child: Text(l10n.repeater_pathHashFilterPrepare),
        ),
      ],
    );
  }
}
