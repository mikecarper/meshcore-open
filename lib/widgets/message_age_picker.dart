import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/app_settings_service.dart';

Future<int?> showMessageAgePicker(BuildContext context, int selectedHours) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: math.min(MediaQuery.sizeOf(sheetContext).height * 0.78, 560),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Keep messages for',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('Older messages are removed from this phone only.'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: AppSettingsService.messageAgeOptionsHours.length,
                itemBuilder: (context, index) {
                  final hours =
                      AppSettingsService.messageAgeOptionsHours[index];
                  return ListTile(
                    title: Text(AppSettingsService.messageAgeLabel(hours)),
                    trailing: hours == selectedHours
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(sheetContext, hours),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
