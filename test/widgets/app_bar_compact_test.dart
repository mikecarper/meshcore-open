import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/app_bar.dart';
import 'package:provider/provider.dart';

class _TitleConnector extends MeshCoreConnector {
  @override
  bool get isConnected => true;
  @override
  String? get selfName => 'F336F80E';
  @override
  int? get batteryMillivolts => 4140;
  @override
  int? get batteryPercent => 95;
  @override
  int? get currentSf => 7;
  @override
  List<DirectRepeater> get directRepeaters => [
    DirectRepeater(
      pubkeyPrefix: [0x93, 0x1c, 0x5d],
      pathHashWidth: 1,
      snr: 12,
      lastUpdated: DateTime.now(),
    ),
  ];
  @override
  bool get supportsCompanionRadioStats => true;
}

void main() {
  testWidgets('Channels title remains complete with battery voltage', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 854);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connector = _TitleConnector();
    addTearDown(connector.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: connector,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(appBar: _TestAppBar()),
        ),
      ),
    );
    await tester.tap(find.text('95%'));
    await tester.pump();
    expect(find.text('4.14V'), findsOneWidget);
    expect(find.text('12.0 dB'), findsOneWidget);
    final title = tester.renderObject<RenderParagraph>(find.text('Channels'));
    expect(
      title.didExceedMaxLines,
      isFalse,
      reason:
          'title=${title.size}, intrinsic=${title.getMaxIntrinsicWidth(double.infinity)}',
    );
    expect(tester.takeException(), isNull);
  });
}

class _TestAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _TestAppBar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(
    titleSpacing: 0,
    title: const AppBarTitle('Channels', shrinkTitleOnCompact: true),
    actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert))],
  );
}
