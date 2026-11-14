import 'package:flutter/widgets.dart';

/// Atlas: lets a music page hand TV focus back to music mode's rail (left from a row's first
/// card). Phones have no rail, so there it's absent.
class MusicShellFocus extends InheritedWidget {
  const MusicShellFocus({super.key, required this.focusRail, required super.child});

  final VoidCallback focusRail;

  static MusicShellFocus? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MusicShellFocus>();

  @override
  bool updateShouldNotify(MusicShellFocus oldWidget) => false;
}
