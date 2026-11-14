import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/music/shell/music_shell.dart';
import '../providers/libraries_provider.dart';
import 'app_mode.dart';
import 'shell_activity.dart';

/// Atlas: hosts the video shell (the existing app) and the music shell side by side and shows
/// the one for the current [AppMode].
///
/// Both stay mounted: the hidden one keeps its widgets, scroll positions and navigation, but
/// doesn't animate (TickerMode), can't take focus (ExcludeFocus, so TV D-pad focus never lands
/// in it), isn't hit-tested or painted once faded out, and ignores system back
/// ([ShellActivity]). This is the
/// only place that may import both the video and the music side.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.videoShell});

  /// The existing app (MainScreen and everything under it).
  final Widget videoShell;

  @override
  Widget build(BuildContext context) {
    final controller = AppModeController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Music mode only when the servers have music. Until libraries load, trust the saved
        // mode (no flash of the wrong shell on launch).
        final mode = controller.isMusic && _musicMissing(context) ? AppMode.video : controller.mode;
        return Stack(
          fit: StackFit.expand,
          children: [
            _ShellSlot(
              active: mode == AppMode.video,
              child: VideoShell(child: videoShell),
            ),
            _ShellSlot(active: mode == AppMode.music, child: const MusicShell()),
          ],
        );
      },
    );
  }
}

bool _musicMissing(BuildContext context) {
  try {
    final libraries = context.watch<LibrariesProvider>();
    return libraries.hasLoaded && !libraries.hasMusicLibraries;
  } on ProviderNotFoundException {
    return false;
  }
}

/// The video side of the app. Today it's exactly the existing UI.
class VideoShell extends StatelessWidget {
  const VideoShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

const _switchDuration = Duration(milliseconds: 260);

class _ShellSlot extends StatelessWidget {
  const _ShellSlot({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // A short cross-fade with a slight zoom. A fully faded-out shell isn't painted, can't be
    // tapped (IgnorePointer) or focused, and doesn't animate.
    return ShellActivity(
      active: active,
      child: IgnorePointer(
        ignoring: !active,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0,
          duration: _switchDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: active ? 1 : 0.97,
            duration: _switchDuration,
            curve: Curves.easeOutCubic,
            child: TickerMode(
              enabled: active,
              child: ExcludeFocus(excluding: !active, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
