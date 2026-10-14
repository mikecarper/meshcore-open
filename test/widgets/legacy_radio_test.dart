import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/legacy_radio.dart' as legacy_radio;

void main() {
  testWidgets('the compatibility radio preserves selection and callbacks', (tester) async {
    var selected = 'a';
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) => Scaffold(body: legacy_radio.RadioGroup<String>(
        groupValue: selected, onChanged: (value) => setState(() => selected = value!),
        child: const Column(children: [
          legacy_radio.RadioListTile(value: 'a', title: Text('First')),
          legacy_radio.RadioListTile(value: 'b', title: Text('Second')),
        ]),
      )),
    )));
    await tester.tap(find.text('Second'));
    await tester.pump();
    expect(selected, 'b');
    final radios = tester.widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>));
    expect(radios.every((radio) => radio.groupValue == 'b'), isTrue);
  });
}
