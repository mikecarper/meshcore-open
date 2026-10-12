import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/screens/usb_node_update_screen.dart';
import 'package:meshcore_open/services/usb_flash_transport.dart';
import 'package:meshcore_open/services/usb_node_update_service.dart';

class _Transport extends UsbFlashTransport {
  _Transport(this.devices);
  final List<UsbFlashDevice> devices;
  int opens = 0;
  @override
  Future<List<UsbFlashDevice>> listDevices() async => devices;
  @override
  Future<void> open(UsbFlashDevice device, {int baudRate = 115200}) async {
    opens++;
    throw StateError('Rendering must never open USB');
  }
}

void main() {
  testWidgets(
    'expert controls fit a narrow Android phone without opening USB',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final transport = _Transport([]);
      final service = UsbNodeUpdateService(transport: transport);
      await tester.pumpWidget(
        MaterialApp(
          home: UsbNodeUpdateScreen(service: service, nativeUsbSupported: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('usb-install-mode')),
          )
          .onChanged!('expert');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const Key('usb-expert-protocol')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
      tester
          .widget<DropdownButtonFormField<UsbExpertProtocol>>(
            find.byKey(const Key('usb-expert-protocol')),
          )
          .onChanged!(UsbExpertProtocol.nrf52);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(transport.opens, 0);
    },
  );

  for (final newHardware in [false, true]) {
    for (final choice in [
      'Cancel restore',
      'Keep node identity',
      'Import backup identity',
    ]) {
      testWidgets(
        'restore identity choice $choice (newHardware=$newHardware)',
        (tester) async {
          bool? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      selected = await showDialog<bool>(
                        context: context,
                        builder: (context) =>
                            UsbRestoreIdentityDialog(newHardware: newHardware),
                      );
                    },
                    child: const Text('Open restore'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open restore'));
          await tester.pumpAndSettle();
          expect(find.text('Import backup identity'), findsOneWidget);
          await tester.tap(find.text(choice));
          await tester.pumpAndSettle();
          expect(
            selected,
            choice == 'Cancel restore'
                ? isNull
                : choice == 'Import backup identity',
          );
          expect(find.text('Restore identity'), findsNothing);
        },
      );
    }
  }

  testWidgets('Android offers native USB update and safe default backup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final transport = _Transport([
      const UsbFlashDevice(
        deviceName: '/dev/bus/usb/001/002',
        vendorId: 0x1a86,
        productId: 0x7523,
        driver: 'Ch34xSerialDriver',
        productName: 'CH340',
      ),
    ]);
    final service = UsbNodeUpdateService(transport: transport);
    await tester.pumpWidget(
      MaterialApp(
        home: UsbNodeUpdateScreen(service: service, nativeUsbSupported: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update over USB'), findsOneWidget);
    expect(find.text('Firmware URL'), findsOneWidget);
    expect(find.text('Keymind releases'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('usb-backup-first')))
          .value,
      true,
    );
    expect(transport.opens, 0);
    final button = tester.widget<FilledButton>(
      // Flutter 3.32's icon constructor uses a private FilledButton subtype.
      find.ancestor(
        of: find.text('Backup, check and update'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported desktop platform never enumerates Android USB', (
    tester,
  ) async {
    final transport = _Transport([]);
    final service = UsbNodeUpdateService(transport: transport);
    await tester.pumpWidget(
      MaterialApp(
        home: UsbNodeUpdateScreen(service: service, nativeUsbSupported: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('requires the Android'), findsOneWidget);
    expect(transport.opens, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate USB serials keep distinct chooser values', (
    tester,
  ) async {
    final transport = _Transport([
      for (final address in [2, 3])
        UsbFlashDevice(
          deviceName: '/dev/bus/usb/001/$address',
          vendorId: 0x1a86,
          productId: 0x7523,
          serialNumber: 'shared-clone-serial',
          driver: 'Ch34xSerialDriver',
        ),
    ]);
    final service = UsbNodeUpdateService(transport: transport);
    await tester.pumpWidget(
      MaterialApp(
        home: UsbNodeUpdateScreen(service: service, nativeUsbSupported: true),
      ),
    );
    await tester.pumpAndSettle();
    final chooser = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('usb-node-picker')),
    );
    expect(chooser.onChanged, isNotNull);
    chooser.onChanged!.call('/dev/bus/usb/001/3:0');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(transport.opens, 0);
  });
}
