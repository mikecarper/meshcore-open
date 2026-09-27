import 'package:flutter/material.dart';

import 'mesh_ui.dart';

/// Consistent, readable feedback for the phone's update and backup workflows.
class UpdateStatusCard extends StatelessWidget {
  const UpdateStatusCard({
    super.key,
    required this.message,
    this.busy = false,
    this.progress,
    this.isError = false,
    this.details,
  });

  final String message;
  final bool busy;
  final int? progress;
  final bool isError;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.primary;
    return MeshCard(
      margin: EdgeInsets.zero,
      color: color.withValues(alpha: 0.06),
      borderColor: color.withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.info_outline,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
          if (busy || progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress == null ? null : progress!.clamp(0, 100) / 100,
              minHeight: 5,
              borderRadius: BorderRadius.circular(4),
            ),
            if (progress != null) ...[
              const SizedBox(height: 6),
              Text('$progress%', style: Theme.of(context).textTheme.labelLarge),
            ],
          ],
          if (details != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Technical details'),
              children: [SelectableText(details!)],
            ),
        ],
      ),
    );
  }
}
