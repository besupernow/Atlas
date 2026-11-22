import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../features/music/music_strings.dart';
import '../../focus/focusable_action_bar.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../services/music/music_bans.dart';
import '../../services/music/music_history.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/bottom_sheet_page_scaffold.dart';
import '../../widgets/music/edge_fade.dart';
import '../../widgets/music/repeat_mode.dart';
import '../../widgets/music/track_row.dart';
import '../../widgets/overlay_sheet.dart';

/// Open the play-queue sheet. The caller's screen must have an
/// [OverlaySheetHost] ancestor (all now-playing layouts do) so TV back
/// handling stays centralized in the host.
Future<void> showQueueSheet(BuildContext context) {
  return OverlaySheetController.of(context).show<void>(showDragHandle: true, builder: (_) => const QueueSheet());
}

/// Sheet chrome around [QueueList]: header with track count, shuffle/repeat
/// toggles mirroring the service state, and Clear (upcoming) action.
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    final colorScheme = Theme.of(context).colorScheme;

    return BottomSheetPageScaffold(
      title: t.music.queue,
      // Rebuilds when AutoPlay or Mixing flips (settings, not the player).
      action: ListenableBuilder(
        listenable: Listenable.merge([
          SettingsService.instance.listenable(SettingsService.musicAutoplay),
          SettingsService.instance.listenable(SettingsService.musicMixing),
        ]),
        builder: (context, _) => Row(
          mainAxisSize: .min,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                t.music.trackCount(n: service.queue.length),
                style: TextStyle(fontSize: 13, color: tk.textMuted),
              ),
            ),
            FocusableActionBar(
              actions: [
                FocusableAction(
                  icon: Symbols.shuffle_rounded,
                  iconColor: service.shuffled ? colorScheme.primary : tk.textMuted,
                  iconSize: 20,
                  tooltip: t.common.shuffle,
                  onPressed: service.toggleShuffle,
                ),
                FocusableAction(
                  icon: repeatModeIcon(service.repeatMode),
                  iconColor: service.repeatMode == MusicRepeatMode.off ? tk.textMuted : colorScheme.primary,
                  iconSize: 20,
                  tooltip: repeatModeLabel(service.repeatMode),
                  onPressed: () => service.setRepeatMode(nextRepeatMode(service.repeatMode)),
                ),
                // Atlas: AutoPlay (similar music when the queue runs out) and Mixing (coming with
                // AudioMuse), as on the phone's Up Next.
                FocusableAction(
                  icon: Symbols.all_inclusive_rounded,
                  iconColor: SettingsService.instance.read(SettingsService.musicAutoplay)
                      ? colorScheme.primary
                      : tk.textMuted,
                  iconSize: 20,
                  tooltip: MusicStrings.autoplay,
                  onPressed: () async {
                    final settings = SettingsService.instance;
                    await settings.write(SettingsService.musicAutoplay, !settings.read(SettingsService.musicAutoplay));
                    service.autoplayChanged();
                  },
                ),
                FocusableAction(
                  icon: Symbols.instant_mix_rounded,
                  iconColor: SettingsService.instance.read(SettingsService.musicMixing)
                      ? colorScheme.primary
                      : tk.textMuted,
                  iconSize: 20,
                  tooltip: MusicStrings.mixing,
                  onPressed: () async {
                    final settings = SettingsService.instance;
                    await settings.write(SettingsService.musicMixing, !settings.read(SettingsService.musicMixing));
                    if (context.mounted) showAppSnackBar(context, MusicStrings.mixingSoon);
                  },
                ),
                FocusableAction(
                  icon: Symbols.clear_all_rounded,
                  iconColor: tk.textMuted,
                  iconSize: 20,
                  tooltip: t.music.clearQueue,
                  onPressed: service.clearUpcoming,
                ),
              ],
            ),
          ],
        ),
      ),
      child: const QueueList(autofocusCurrent: true),
    );
  }
}

/// The queue body, in three parts like Apple Music: History (what already played, just
/// above, revealed by scrolling up), Up Next (what you queued, shown at the top when it
/// opens) and AutoPlay (the similar music Atlas added after it). With [showCurrent] the song
/// playing now sits between History and Up Next (the sheet, which has no header showing it).
///
/// The list is anchored on Up Next, so when a song finishes it slides up into History and
/// the next one takes its place without the list jumping around.
///
/// Touch: long-press drag to reorder within Up Next or AutoPlay, swipe left to remove, tap to
/// jump. D-pad: rows are focusable, SELECT jumps, RIGHT reaches the remove button;
/// reordering isn't offered on TV. With [autofocusCurrent] (the sheet) initial focus lands on
/// the current song's row.
class QueueList extends StatefulWidget {
  /// Land initial d-pad/keyboard focus on the current track's row,
  /// overriding the overlay host's focus-first-descendant default. The
  /// inline panel keeps this off so building the now-playing screen
  /// never steals focus.
  final bool autofocusCurrent;

  /// Show the song playing now between History and Up Next.
  final bool showCurrent;

  const QueueList({super.key, this.autofocusCurrent = false, this.showCurrent = true});

  @override
  State<QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<QueueList> {
  final _scrollController = ScrollController();
  final _centerKey = const ValueKey('queue_up_next');
  final _currentRowFocusNode = FocusNode(debugLabel: 'QueueCurrentRowFocus');

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    MusicHistory.instance.addListener(_historyChanged);
    if (widget.autofocusCurrent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Timer.run(() {
          if (!mounted || !InputModeTracker.isKeyboardMode(context, listen: false)) return;
          // Schedule after the overlay host's _autoFocus second callback so
          // we override its focus-first-descendant default.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_currentRowFocusNode.context != null) _currentRowFocusNode.requestFocus();
          });
        });
      });
    }
  }

  @override
  void dispose() {
    MusicHistory.instance.removeListener(_historyChanged);
    _scrollController.dispose();
    _currentRowFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    final queue = service.queue;
    final currentIndex = service.currentIndex;
    // Atlas: History is everything played before, across queues (newest first), on top of
    // this queue's own played songs.
    final earlier = MusicHistory.instance.items;

    if (queue.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Text(t.messages.noItemsAvailable, style: TextStyle(fontSize: 13, color: tk.textMuted)),
      );
    }

    // Stable per-item keys that survive reorders; the same track can appear
    // more than once, so disambiguate repeats by occurrence.
    final seen = <String, int>{};
    final itemKeys = [
      for (final item in queue) '${item.globalKey}#${seen.update(item.globalKey, (v) => v + 1, ifAbsent: () => 0)}',
    ];

    final editable = !PlatformDetector.isTV();
    final history = [for (var i = currentIndex - 1; i >= 0; i--) i]; // nearest first
    // Older sessions, nearest first, minus anything hidden since.
    final older = [
      for (var i = earlier.length - 1; i >= 0; i--)
        if (!MusicBans.instance.blocks(earlier[i])) i,
    ];
    final historyCount = history.length + older.length;
    final upNext = <int>[];
    final autoplay = <int>[];
    for (var i = currentIndex + 1; i < queue.length; i++) {
      (service.isAutoplayItem(queue[i]) ? autoplay : upNext).add(i);
    }
    final gap = tk.groupGap;
    const sidePadding = EdgeInsets.symmetric(horizontal: 12);

    Widget row(int index, {required bool first, required bool last, bool dimmed = false}) {
      final isCurrent = index == currentIndex;
      return TrackRow(
        item: queue[index],
        showArtist: true,
        isFirst: first,
        isLast: last,
        enableContextMenu: false,
        isCurrent: isCurrent,
        dimmed: dimmed,
        showTrackNumber: false,
        focusNode: isCurrent ? _currentRowFocusNode : null,
        trailingIcon: isCurrent ? null : Symbols.close_rounded,
        onTrailingTap: isCurrent ? null : () => service.removeAt(index),
        onTap: () => unawaited(service.jumpTo(index)),
      );
    }

    /// Swipe left to remove: the row slides off over a soft red pill (no hard edges), and the
    /// gap closes smoothly.
    Widget removable(int index, Widget child) {
      if (!editable) return child;
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Dismissible(
          key: ValueKey('dismiss:${itemKeys[index]}'),
          direction: DismissDirection.endToStart,
          movementDuration: const Duration(milliseconds: 260),
          resizeDuration: const Duration(milliseconds: 280),
          dismissThresholds: const {DismissDirection.endToStart: 0.35},
          background: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Colors.red.withValues(alpha: 0), Colors.red.withValues(alpha: 0.85)],
              ),
            ),
            child: const Align(
              alignment: .centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: 20),
                child: AppIcon(Symbols.delete_rounded, fill: 1, color: Colors.white, size: 20),
              ),
            ),
          ),
          onDismissed: (_) => service.removeAt(index),
          child: child,
        ),
      );
    }

    /// Up Next or AutoPlay: reorderable among themselves.
    Widget section(List<int> indices) {
      return SliverPadding(
        padding: sidePadding,
        sliver: SliverReorderableList(
          itemCount: indices.length,
          proxyDecorator: _liftWhileDragging,
          onReorder: (oldPos, newPos) {
            if (newPos > oldPos) newPos -= 1;
            if (oldPos == newPos) return;
            service.reorder(indices[oldPos], indices[newPos]);
          },
          itemBuilder: (context, pos) {
            final index = indices[pos];
            Widget child = removable(index, row(index, first: pos == 0, last: pos == indices.length - 1));
            if (editable) child = ReorderableDelayedDragStartListener(index: pos, child: child);
            return Padding(
              key: ValueKey(itemKeys[index]),
              padding: EdgeInsets.only(top: pos == 0 ? 0 : gap),
              child: child,
            );
          },
        ),
      );
    }

    final clear = TextButton(
      onPressed: service.clearUpcoming,
      style: TextButton.styleFrom(foregroundColor: tk.text, visualDensity: VisualDensity.compact),
      child: Text(t.music.clearQueue),
    );

    final list = CustomScrollView(
      controller: _scrollController,
      // Opens on Up Next; History is above it and comes into view scrolling up.
      center: _centerKey,
      slivers: [
        if (historyCount > 0)
          SliverPadding(
            padding: sidePadding,
            // Laid out upward from Up Next: the most recent song sits right above it.
            sliver: SliverList.builder(
              itemCount: historyCount + 1,
              itemBuilder: (context, i) {
                if (i == historyCount) {
                  return _QueueSectionHeader(
                    icon: Symbols.history_rounded,
                    title: MusicStrings.history,
                    trailing: TextButton(
                      onPressed: () {
                        unawaited(HapticFeedback.selectionClick());
                        MusicHistory.instance.clear();
                        // And this queue's played songs (the one playing stays).
                        for (var n = service.currentIndex; n > 0; n--) {
                          service.removeAt(0);
                        }
                      },
                      style: TextButton.styleFrom(foregroundColor: tk.text, visualDensity: VisualDensity.compact),
                      child: const Text(MusicStrings.historyClear),
                    ),
                  );
                }
                final first = i == historyCount - 1;
                final last = i == 0;
                final padding = EdgeInsets.only(bottom: i == 0 ? 18 : gap);
                if (i < history.length) {
                  final index = history[i];
                  return Padding(
                    key: ValueKey('history:${itemKeys[index]}'),
                    padding: padding,
                    child: removable(index, row(index, first: first, last: last, dimmed: true)),
                  );
                }
                final at = older[i - history.length];
                final item = earlier[at];
                return Padding(
                  key: ValueKey('earlier:$at:${item.globalKey}'),
                  padding: padding,
                  child: TrackRow(
                    item: item,
                    showArtist: true,
                    isFirst: first,
                    isLast: last,
                    enableContextMenu: false,
                    isCurrent: false,
                    dimmed: true,
                    showTrackNumber: false,
                    trailingIcon: editable ? Symbols.close_rounded : null,
                    onTrailingTap: editable ? () => MusicHistory.instance.removeAt(at) : null,
                    // Plays it now, right where you are; what's up next stays up next.
                    onTap: () {
                      service.addNext([item]);
                      unawaited(service.jumpTo(service.currentIndex + 1));
                    },
                  ),
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          key: _centerKey,
          child: Padding(
            padding: sidePadding,
            child: Column(
              crossAxisAlignment: .stretch,
              mainAxisSize: .min,
              children: [
                if (widget.showCurrent && currentIndex >= 0 && currentIndex < queue.length) ...[
                  const _QueueSectionHeader(title: MusicStrings.nowPlaying),
                  row(currentIndex, first: true, last: true),
                  const SizedBox(height: 18),
                ],
                _QueueSectionHeader(title: MusicStrings.upNext, trailing: upNext.isEmpty && autoplay.isEmpty ? null : clear),
                if (upNext.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 12),
                    child: Text(MusicStrings.nothingUpNext, style: TextStyle(fontSize: 13, color: tk.textMuted)),
                  ),
              ],
            ),
          ),
        ),
        section(upNext),
        if (autoplay.isNotEmpty) ...[
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(12, 18, 12, 0),
            sliver: SliverToBoxAdapter(
              child: _QueueSectionHeader(
                icon: Symbols.all_inclusive_rounded,
                title: MusicStrings.autoplay,
                subtitle: MusicStrings.autoplayRow,
              ),
            ),
          ),
          section(autoplay),
        ],
        // Room to scroll the last row clear of the bottom fade.
        const SliverToBoxAdapter(child: SizedBox(height: 56)),
      ],
    );

    return EdgeFade(top: 20, bottom: 44, child: list);
  }

  /// A dragged row lifts a little (slightly bigger, soft shadow) instead of snapping out.
  static Widget _liftWhileDragging(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return Transform.scale(
          scale: 1 + 0.025 * t,
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.28 * t), blurRadius: 24 * t, offset: Offset(0, 8 * t)),
                ],
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// A section title in the queue: History, Now Playing, Up Next, AutoPlay.
class _QueueSectionHeader extends StatelessWidget {
  const _QueueSectionHeader({required this.title, this.icon, this.subtitle, this.trailing});

  final String title;
  final IconData? icon;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 6, trailing == null ? 8 : 0, 8),
      child: Row(
        children: [
          if (icon != null) ...[AppIcon(icon!, size: 18, color: tk.text), const SizedBox(width: 8)],
          Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: tk.text)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: tk.textMuted),
              ),
            ),
          ] else
            const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}
