import 'package:flutter/widgets.dart';

/// Atlas: whether the shell a widget sits in is the one on screen.
///
/// Both shells stay mounted under the same route, so a back handler (PopScope, a sheet host's
/// system-back hook) in the hidden shell would still be called on Android's back gesture. Back
/// handlers check this and leave the hidden shell alone. Outside any shell it reads as active.
class ShellActivity extends InheritedWidget {
  const ShellActivity({super.key, required this.active, required super.child});

  final bool active;

  static bool isActive(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellActivity>()?.active ?? true;

  /// Like [isActive], and rebuilds the caller when it changes.
  static bool watch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellActivity>()?.active ?? true;

  @override
  bool updateShouldNotify(ShellActivity oldWidget) => active != oldWidget.active;
}
