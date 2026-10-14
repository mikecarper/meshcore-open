import 'package:flutter/material.dart';

// showDismissibleSnackBar shows  a [SnackBar] with tap to dismiss
// all other properties are default and optional
void showDismissibleSnackBar(
  BuildContext context, {
  Key? key,
  required Widget content,
  Color? backgroundColor,
  double? elevation,
  EdgeInsetsGeometry? margin,
  EdgeInsetsGeometry? padding,
  double? width,
  ShapeBorder? shape,
  HitTestBehavior? hitTestBehavior,
  SnackBarBehavior? behavior,
  SnackBarAction? action,
  double? actionOverflowThreshold,
  bool? showCloseIcon,
  Color? closeIconColor,
  Duration? duration,
  bool? persist,
  Animation<double>? animation,
  void Function()? onVisible,
  DismissDirection? dismissDirection,
  Clip? clipBehavior,
}) {
  // Callers often reach here after an async gap; the context may already be
  // unmounted, or deactivated (popped but not yet disposed) — ancestor
  // lookups on a deactivated element throw. Showing nothing is the right
  // outcome in both cases.
  if (!context.mounted) return;
  var isActive = true;
  assert(() {
    isActive = (context as Element).debugIsActive;
    return true;
  }());
  if (!isActive) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    _compatibleSnackBar({
      #key: key,
      #content: GestureDetector(
        onTap: () => messenger.hideCurrentSnackBar(),
        child: content,
      ),
      #backgroundColor: backgroundColor,
      #elevation: elevation,
      #margin: margin,
      #padding: padding,
      #width: width,
      #shape: shape,
      #hitTestBehavior: hitTestBehavior,
      #behavior: behavior,
      #action: action,
      #actionOverflowThreshold: actionOverflowThreshold,
      #showCloseIcon: showCloseIcon,
      #closeIconColor: closeIconColor,
      #duration: duration ?? const Duration(seconds: 4),
      #persist: persist,
      #animation: animation,
      #onVisible: onVisible,
      #dismissDirection: dismissDirection ?? DismissDirection.down,
      #clipBehavior: clipBehavior ?? Clip.hardEdge,
    }),
  );
}

// Flutter 3.32 lacks `persist`; modern builds keep its native behavior.
SnackBar _compatibleSnackBar(Map<Symbol, dynamic> arguments) {
  try {
    return Function.apply(SnackBar.new, const [], arguments) as SnackBar;
  } on NoSuchMethodError {
    final persistent = arguments.remove(#persist) == true;
    if (persistent) arguments[#duration] = const Duration(days: 365);
    return Function.apply(SnackBar.new, const [], arguments) as SnackBar;
  }
}
