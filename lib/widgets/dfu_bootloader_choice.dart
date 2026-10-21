import 'package:flutter/material.dart';

import '../services/nrf_dfu_recovery.dart';

Future<String?> chooseDfuBootloader(
  BuildContext context, {
  required String board,
  required List<DfuAdvertisement> candidates,
}) => showDialog<String>(
  context: context,
  builder: (dialogContext) => SimpleDialog(
    title: const Text('Which radio is in update mode?'),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Text(
          'Several $board updaters are nearby. Choose only the radio '
          'you just enabled. If you cannot identify it, cancel and leave '
          'only your radio in update mode before retrying.',
        ),
      ),
      for (final candidate in candidates)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, candidate.address),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bluetooth),
            title: Text('$board updater'),
            subtitle: Text('${candidate.name}\n${candidate.address}'),
          ),
        ),
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Cancel'),
      ),
    ],
  ),
);
