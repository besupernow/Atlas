import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Atlas: how many popups (sheets, dialogs, menus, dropdowns) are open in any navigator that
/// carries one of these observers. The music mini player sits above the navigators, so it
/// steps aside while this is above zero instead of covering a sheet's buttons.
///
/// Each navigator needs its own instance; they share the one count.
class PopupRouteCounter extends NavigatorObserver {
  static final ValueNotifier<int> open = ValueNotifier<int>(0);

  /// The app's root navigator's (one instance, so rebuilding the app doesn't lose track).
  static final PopupRouteCounter root = PopupRouteCounter();

  final Set<Route<dynamic>> _mine = {};

  static bool _counts(Route<dynamic>? route) => route is PopupRoute;

  /// Changes land after the current build: popups get pushed mid-build (a route's first build,
  /// a sheet opened from a callback during layout), and listeners rebuilding then would throw.
  static void _bump(int delta) {
    void apply() => open.value = (open.value + delta).clamp(0, 1 << 20);
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      apply();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  void _add(Route<dynamic>? route) {
    if (_counts(route) && _mine.add(route!)) _bump(1);
  }

  void _drop(Route<dynamic>? route) {
    if (route != null && _mine.remove(route)) _bump(-1);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _drop(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _drop(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _drop(oldRoute);
    _add(newRoute);
  }
}
