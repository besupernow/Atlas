import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_mode.dart';
import '../../../app/app_mode_switch.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/music/mini_player.dart';
import 'music_profile_button.dart';

/// Atlas: the frame every music tab page uses: a big bold title (Apple Music style), the switch
/// back to movies and TV and the profile picture in the top-right on phones and desktop (TV has
/// both in the rail), then the page's content, with room at the bottom for the mini player.
class MusicPage extends StatelessWidget {
  const MusicPage({super.key, required this.title, required this.children, this.actions = const [], this.onRefresh});

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;

  static EdgeInsets padding(BuildContext context) =>
      EdgeInsets.symmetric(horizontal: PlatformDetector.isTV() ? 48 : 16);

  /// Room the mini player takes at the bottom (rebuilds when it changes).
  static double bottomRoom(BuildContext context) =>
      context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTV = PlatformDetector.isTV();
    final miniPlayerRoom = context.watch<MiniPlayerInsetController?>()?.overlayHeight ?? 0;
    final list = ListView(
      padding: EdgeInsets.only(bottom: 24 + miniPlayerRoom),
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: padding(context).add(EdgeInsets.only(top: isTV ? 24 : 12, bottom: 8)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: (isTV ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                ...actions,
                // The rail (tablet landscape, desktop, TV) has its own switch.
                if (!PlatformDetector.shouldUseSideNavigation(context) && AppModeSwitch.available(context))
                  IconButton(
                    tooltip: AppModeSwitch.label(AppMode.music),
                    icon: AppIcon(AppModeSwitch.icon(AppMode.music)),
                    onPressed: AppModeSwitch.toggle,
                  ),
                // Atlas: the profile picture, like the movies Discover page (TV has Settings in
                // the rail instead).
                if (!isTV) ...[const SizedBox(width: 4), const MusicProfileButton()],
              ],
            ),
          ),
        ),
        ...children,
      ],
    );
    return Scaffold(
      body: Stack(
        children: [
          const Positioned(top: 0, left: 0, right: 0, child: _Aurora()),
          onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
        ],
      ),
    );
  }
}

/// A small section heading inside a music page.
class MusicSectionTitle extends StatelessWidget {
  const MusicSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 20, bottom: 8)),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Shown while a page loads, and when it has nothing.
class MusicPagePlaceholder extends StatelessWidget {
  const MusicPagePlaceholder({super.key, this.message});

  /// Null while loading.
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Center(
        child: message == null
            ? const CircularProgressIndicator()
            : Text(
          message!,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}

/// Atlas: music mode's signature: a soft wash of the accent color (and its neighbor on the
/// color wheel) glowing down from the top of every page, fading out before the content.
class _Aurora extends StatelessWidget {
  const _Aurora();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final height = MediaQuery.sizeOf(context).height * 0.45;
    final strength = dark ? 0.32 : 0.18;
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.9, -1.1),
                  radius: 1.1,
                  colors: [scheme.primary.withValues(alpha: strength), scheme.primary.withValues(alpha: 0)],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(1, -1.2),
                  radius: 0.9,
                  colors: [scheme.tertiary.withValues(alpha: strength * 0.8), scheme.tertiary.withValues(alpha: 0)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
