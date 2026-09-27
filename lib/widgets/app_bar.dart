import 'package:flutter/material.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/widgets/battery_indicator.dart';
import 'package:provider/provider.dart';

import 'radio_stats_entry.dart';
import 'snr_indicator.dart';

class AppBarTitle extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget? trailing;
  final bool indicators;
  final bool showBatteryIndicator;
  final bool subtitle;
  final bool shrinkTitleOnCompact;
  const AppBarTitle(
    this.title, {
    this.leading,
    this.trailing,
    this.indicators = true,
    this.showBatteryIndicator = true,
    this.subtitle = true,
    this.shrinkTitleOnCompact = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final selfName = connector.selfName;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final compact = availableWidth < 170;
        final showSubtitle =
            !compact && connector.isConnected && selfName != null && subtitle;
        final showBattery = showBatteryIndicator && availableWidth >= 60;
        final showSnr = availableWidth >= 110;
        final showIndicators = (showBattery || showSnr) && indicators;

        return Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            leading ?? const SizedBox.shrink(),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        shrinkTitleOnCompact &&
                            MediaQuery.sizeOf(context).width <= 360
                        ? const TextStyle(fontSize: 16.5)
                        : null,
                  ),
                  if (showSubtitle)
                    Text(
                      selfName,
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (showIndicators) SizedBox(width: shrinkTitleOnCompact ? 2 : 6),
            if (showIndicators)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showBattery) BatteryIndicator(connector: connector),
                  if (showSnr)
                    SNRIndicator(
                      connector: connector,
                      compact: shrinkTitleOnCompact,
                    ),
                  if (connector.supportsCompanionRadioStats)
                    if (connector.isConnected)
                      const RadioStatsIconButton(compact: true),
                ],
              ),
            trailing ?? const SizedBox.shrink(),
          ],
        );
      },
    );
  }
}
