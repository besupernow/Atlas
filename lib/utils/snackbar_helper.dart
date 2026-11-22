import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation/profile_navigation_scope.dart';
import '../widgets/music/mini_player.dart';
import 'layout_constants.dart';
import 'platform_detector.dart';

/// Global key for the root ScaffoldMessenger, allowing snackbars to survive navigation.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Types of snackbars available in the app
enum SnackBarType { info, success, error }

const double _kDesktopSnackBarMaxWidth = 480.0;
const double _kDesktopSnackBarHorizontalInset = 16.0;
const EdgeInsets _kDismissibleSnackBarPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 14);

/// Utility functions for showing snackbars throughout the application

SnackBar _buildSnackBar(
    BuildContext context,
    ScaffoldMessengerState messenger, {
      required Widget content,
      required Color? backgroundColor,
      required Duration duration,
      bool? dismissible,
    }) {
  final isDesktop = PlatformDetector.hasPointerUI();
  final tapToDismiss = dismissible ?? isDesktop;
  final body = tapToDismiss
      ? MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
      child: Padding(padding: _kDismissibleSnackBarPadding, child: content),
    ),
  )
      : content;

  // Atlas: notifications float as a rounded card above whatever sits at the bottom (the
  // navigation bar, and the music mini player when it's showing) instead of covering it.
  return SnackBar(
    content: body,
    backgroundColor: backgroundColor,
    duration: duration,
    behavior: SnackBarBehavior.floating,
    width: isDesktop ? _desktopSnackBarWidth(context) : null,
    margin: isDesktop ? null : EdgeInsets.fromLTRB(12, 0, 12, 8 + _miniPlayerRoom(context)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    padding: tapToDismiss ? EdgeInsets.zero : null,
  );
}

/// Height the music mini player takes above the bottom bar (0 when it's hidden).
double _miniPlayerRoom(BuildContext context) {
  try {
    return Provider.of<MiniPlayerInsetController?>(context, listen: false)?.overlayHeight ?? 0;
  } catch (_) {
    return 0;
  }
}

double _desktopSnackBarWidth(BuildContext context) {
  final windowWidth = MediaQuery.maybeSizeOf(context)?.width;
  if (windowWidth == null) return _kDesktopSnackBarMaxWidth;

  final insetPadding = SnackBarTheme.of(context).insetPadding;
  final horizontalInset = insetPadding == null
      ? _kDesktopSnackBarHorizontalInset * 2
      : insetPadding.left + insetPadding.right;
  final availableWidth = windowWidth - horizontalInset;
  final width = availableWidth > 0 ? availableWidth : windowWidth;
  return width < _kDesktopSnackBarMaxWidth ? width : _kDesktopSnackBarMaxWidth;
}

(Color?, Duration) _snackBarStyle(SnackBarType type) => switch (type) {
  SnackBarType.info => (null, AppDurations.snackBarDefault),
  SnackBarType.success => (Colors.green, AppDurations.snackBarDefault),
  SnackBarType.error => (Colors.red, AppDurations.snackBarLong),
};

void showSnackBar(
    BuildContext context,
    String message, {
      SnackBarType type = SnackBarType.info,
      Duration? duration,
      bool? dismissible,
    }) {
  if (!context.mounted) return;

  final (backgroundColor, defaultDuration) = _snackBarStyle(type);
  final messenger = ScaffoldMessenger.of(context);
  // A new one replaces the last instead of queueing up behind it.
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    _buildSnackBar(
      context,
      messenger,
      content: Text(message),
      backgroundColor: backgroundColor,
      duration: duration ?? defaultDuration,
      dismissible: dismissible,
    ),
  );
}

void showAppSnackBar(BuildContext context, String message, {Duration? duration}) {
  showSnackBar(context, message, type: SnackBarType.info, duration: duration);
}

void showErrorSnackBar(BuildContext context, String message) {
  showSnackBar(context, message, type: SnackBarType.error);
}

/// Shows an error snackbar using the root ScaffoldMessenger (survives navigation).
void showGlobalErrorSnackBar(String message) {
  final messenger = rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger.showSnackBar(
    _buildSnackBar(
      messenger.context,
      messenger,
      content: Text(message),
      backgroundColor: Colors.red,
      duration: AppDurations.snackBarLong,
    ),
  );
}

/// Shows an info snackbar through the main-screen messenger when available
/// (so it floats above the mobile NavigationBar), falling back to the root
/// messenger when the main screen is not mounted.
void showMainSnackBar(String message, {Duration duration = AppDurations.snackBarDefault}) {
  final messenger = profileNavigationRegistry.mainScaffoldMessenger ?? rootScaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      _buildSnackBar(messenger.context, messenger, content: Text(message), backgroundColor: null, duration: duration),
    );
}

void showSuccessSnackBar(BuildContext context, String message) {
  showSnackBar(context, message, type: SnackBarType.success);
}
