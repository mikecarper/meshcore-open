import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/image_codec_support.dart';

/// Only controls reconstruction; sending continues to use the same encoder.
class NativeDecoderModeSetting extends StatelessWidget {
  final AeicDecoderMode mode;
  final ValueChanged<AeicDecoderMode>? onChanged;
  const NativeDecoderModeSetting({
    super.key,
    required this.mode,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<AeicDecoderMode>(
        // Required by the supported Flutter 3.32 Android profile.
        // ignore: deprecated_member_use
        value: mode,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: context.l10n.imageCodec_decoderMode,
        ),
        items: [
          DropdownMenuItem(
            value: AeicDecoderMode.fast,
            child: Text(context.l10n.imageCodec_decoderFast),
          ),
          DropdownMenuItem(
            value: AeicDecoderMode.accurate,
            child: Text(context.l10n.imageCodec_decoderAccurate),
          ),
        ],
        onChanged: onChanged == null
            ? null
            : (value) {
                if (value != null) onChanged!(value);
              },
      ),
      const SizedBox(height: 6),
      Text(
        mode == AeicDecoderMode.fast
            ? context.l10n.imageCodec_decoderFastHelp
            : context.l10n.imageCodec_decoderAccurateHelp,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
