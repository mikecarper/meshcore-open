import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/utils/disconnect_navigation_mixin.dart';

class _ConnectedPage extends StatefulWidget {
  const _ConnectedPage(this.connector);

  final MeshCoreConnector connector;

  @override
  State<_ConnectedPage> createState() => _ConnectedPageState();
}

class _ConnectedPageState extends State<_ConnectedPage>
    with DisconnectNavigationMixin<_ConnectedPage> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (!checkConnectionAndNavigate(widget.connector)) {
      return const SizedBox.shrink();
    }
    return const Scaffold(body: Text('Firmware update progress'));
  }
}

void main() {
  testWidgets('keeps the update route during an intentional DFU disconnect', (
    tester,
  ) async {
    final connector = MeshCoreConnector();
    connector.setPreserveUpdateScreenOnDisconnect(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _ConnectedPage(connector),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Firmware update progress'), findsOneWidget);

    connector.setPreserveUpdateScreenOnDisconnect(false);
    tester.state<_ConnectedPageState>(find.byType(_ConnectedPage)).rebuild();
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Firmware update progress'), findsNothing);
    connector.dispose();
  });
}
