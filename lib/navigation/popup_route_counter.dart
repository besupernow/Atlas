import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Atlas: how many popups (sheets, dialogs, menus, dropdowns) are showing on top of a navigator
/// that carries one of these observers. The music mini player sits above the navigators, so it
/// steps aside while this is above zero instead of covering a sheet's buttons.
///
/// Each navigator needs its own instance; they share the one count. The count isn't kept by
/// adding and subtracting: it's worked out again from the popups that are still on screen and
/// on top of their navigator, so a navigator torn down with a menu open (a profile switch, the
/// music shell going away) can't leave it stuck above zero and the mini player hidden for good.
class PopupRouteCounter extends NavigatorObserver {
  PopupRouteCounter() {
    _all.add(this);
  }

  static final ValueNotifier<int> open = ValueNotifier<int>(0);

  /// The app's root navigator's (one instance, so rebuilding the app doesn't lose track).
  static final PopupRouteCounter root = PopupRouteCounter();

  static final Set<PopupRouteCounter> _all = {};
  static bool _scheduled = false;

  final Set<Route<dynamic>> _popups = {};

  /// Works the count out again after this frame (routes change mid-build, and listeners
  /// rebuilding then would throw; by then a pushed route is current and a popped one isn't).
  static void refresh() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      var count = 0;
      for (final counter in _all) {
        counter._popups.removeWhere((route) => !route.isActive);
        for (final route in counter._popups) {
          // Only popups on top (a dialog left under a pushed page isn't covering anything), in
          // a navigator that's on screen (not a music tab you switched away from).
          final navigator = route.navigator;
          final onScreen = navigator == null ||
              !navigator.mounted ||
              (navigator.context.findAncestorWidgetOfExactType<TickerMode>()?.enabled ?? true);
          if (route.isCurrent && onScreen) count++;
        }
      }
      open.value = count;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _popups.add(route);
    refresh();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popups.remove(route);
    refresh();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popups.remove(route);
    refresh();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _popups.remove(oldRoute);
    if (newRoute is PopupRoute) _popups.add(newRoute);
    refresh();
  }
}
