import 'package:flutter/widgets.dart';

/// Implemented by players whose picture is a DOM element rather than a native
/// plane. `Video` asks the player for the widget instead of positioning a rect.
abstract interface class WebVideoSurface {
  Widget buildVideoSurface(BuildContext context);
}
