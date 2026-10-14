import 'package:flutter/material.dart' as material;

/// Compatibility adapter for RadioGroup on Flutter 3.32.
class RadioGroup<T> extends material.InheritedWidget {
  final T? groupValue;
  final material.ValueChanged<T?> onChanged;

  const RadioGroup({
    super.key,
    required this.groupValue,
    required this.onChanged,
    required super.child,
  });

  static RadioGroup<T> of<T>(material.BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<RadioGroup<T>>()!;
  }

  @override
  bool updateShouldNotify(RadioGroup<T> oldWidget) =>
      groupValue != oldWidget.groupValue || onChanged != oldWidget.onChanged;
}

class RadioListTile<T> extends material.StatelessWidget {
  final T value;
  final material.Widget? title;
  final material.Widget? subtitle;
  final bool? dense;

  const RadioListTile({
    super.key,
    required this.value,
    this.title,
    this.subtitle,
    this.dense,
  });

  @override
  material.Widget build(material.BuildContext context) {
    final group = RadioGroup.of<T>(context);
    return material.RadioListTile<T>(
      value: value,
      groupValue: group.groupValue,
      onChanged: group.onChanged,
      title: title,
      subtitle: subtitle,
      dense: dense,
    );
  }
}
