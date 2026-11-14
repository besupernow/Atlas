import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../app/app_mode.dart';
import '../../../app/app_mode_switch.dart';
import '../../../app/music_detail_scope.dart';
import '../../../app/shell_activity.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../services/music/music_playback_service.dart';
import '../../../utils/music_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/atlas_native_tab_bar.dart';
import '../../../widgets/music/mini_player.dart';
import '../music_strings.dart';
import '../pages/music_artist_page.dart';
import '../pages/music_home_page.dart';
import '../pages/music_library_page.dart';
import '../pages/music_new_page.dart';
import '../pages/music_radio_page.dart';
import '../pages/music_search_page.dart';
import '../theme/music_theme.dart';
import 'music_shell_focus.dart';

enum _MusicTab {
  home(MusicStrings.home, Symbols.home_rounded, 'house.fill'),
  newTab(MusicStrings.newTab, Symbols.grid_view_rounded, 'square.grid.2x2.fill'),
  radio(MusicStrings.radio, Symbols.radio_rounded, 'dot.radiowaves.left.and.right'),
  library(MusicStrings.library, Symbols.library_music_rounded, 'square.stack.fill'),
  search(MusicStrings.search, Symbols.search_rounded, 'magnifyingglass');

  const _MusicTab(this.label, this.icon, this.symbol);

  final String label;
  final IconData icon;
  final String symbol;
}

/// Atlas: music mode. Five tabs like Apple Music (Home, New, Radio, Library, Search), each with
/// its own navigator, so an album or artist opened in a tab stays in that tab with the tab bar
/// and mini player still showing, and every tab keeps its place when you switch away and back
/// (or flip to movies and TV and back).
///
/// Phones get a bottom tab bar (UIKit's own on iPhone and iPad); tablets in landscape, desktop
/// and TV get a rail on the left with the switch back to movies and TV, and on TV a Now Playing
/// item while music plays (TV has no mini player).
class MusicShell extends StatefulWidget {
  const MusicShell({super.key});

  @override
  State<MusicShell> createState() => _MusicShellState();
}

class _MusicShellState extends State<MusicShell> {
  final Map<_MusicTab, GlobalKey<NavigatorState>> _navigators = {
    for (final tab in _MusicTab.values) tab: GlobalKey<NavigatorState>(debugLabel: 'music.${tab.name}'),
  };
  final _searchKey = GlobalKey<MusicSearchPageState>();
  final _barKey = GlobalKey();
  final Map<String, FocusNode> _railFocus = {};

  _MusicTab _tab = _MusicTab.home;

  /// Tabs built so far; the rest wait until first opened.
  final Set<_MusicTab> _built = {_MusicTab.home};

  MiniPlayerInsetController? _insets;
  bool _active = false;

  FocusNode _railNode(String id) => _railFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'music.rail.$id'));

  @override
  void initState() {
    super.initState();
    AppModeController.instance.addListener(_onModeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _insets = context.read<MiniPlayerInsetController?>();
    _active = ShellActivity.watch(context);
    if (!_active) _insets?.setMusicShellInsets(null);
  }

  @override
  void dispose() {
    AppModeController.instance.removeListener(_onModeChanged);
    _insets?.setMusicShellInsets(null);
    for (final node in _railFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Arriving in music mode on TV: focus starts on the current tab in the rail.
  void _onModeChanged() {
    if (!AppModeController.instance.isMusic || !PlatformDetector.isTV()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusRail();
    });
  }

  void _focusRail() => _railNode(_tab.name).requestFocus();

  void _select(_MusicTab tab) {
    if (tab == _tab) {
      // Picking the tab you're on goes back to its first page (and to the field, on Search).
      final navigator = _navigators[tab]!.currentState;
      if (navigator != null && navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      } else if (tab == _MusicTab.search) {
        _searchKey.currentState?.focusField();
      }
      return;
    }
    setState(() {
      _tab = tab;
      _built.add(tab);
    });
  }

  /// Back: pop the tab's own pages, then (TV) return to the rail, then go Home, then leave the
  /// app the way the platform does. It never switches modes.
  void _onBack() {
    final navigator = _navigators[_tab]!.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }
    if (PlatformDetector.isTV() && !_railFocus.values.any((node) => node.hasFocus)) {
      _focusRail();
      return;
    }
    if (_tab != _MusicTab.home) {
      _select(_MusicTab.home);
      if (PlatformDetector.isTV()) WidgetsBinding.instance.addPostFrameCallback((_) => _focusRail());
      return;
    }
    if (!kIsWeb && Platform.isAndroid) SystemNavigator.pop();
  }

  /// Tell the mini player how much room the tab bar or rail takes, after layout.
  void _reportInsets({required bool rail}) {
    if (!_active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_active) return;
      final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      _insets?.setMusicShellInsets(
        rail ? (bottom: 0, start: box.size.width) : (bottom: box.size.height, start: 0),
      );
    });
  }

  Widget _page(_MusicTab tab) => switch (tab) {
    _MusicTab.home => const MusicHomePage(),
    _MusicTab.newTab => const MusicNewPage(),
    _MusicTab.radio => const MusicRadioPage(),
    _MusicTab.library => const MusicLibraryPage(),
    _MusicTab.search => MusicSearchPage(key: _searchKey),
  };

  Widget _tabs() {
    return IndexedStack(
      index: _tab.index,
      children: [
        for (final tab in _MusicTab.values)
          if (!_built.contains(tab))
            const SizedBox.shrink()
          else
            TickerMode(
              enabled: tab == _tab,
              child: ExcludeFocus(
                excluding: tab != _tab,
                child: HeroControllerScope.none(
                  child: Navigator(
                    key: _navigators[tab],
                    onGenerateRoute: (settings) =>
                        MaterialPageRoute<void>(settings: settings, builder: (_) => _page(tab)),
                  ),
                ),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final useRail = PlatformDetector.shouldUseSideNavigation(context);
    _reportInsets(rail: useRail);

    final content = MusicDetailScope(
      artistPage: (artist) => MusicArtistPage(artist: artist),
      child: MusicShellFocus(focusRail: useRail ? _focusRail : () {}, child: _tabs()),
    );

    return Theme(
      data: MusicTheme.of(Theme.of(context)),
      child: Builder(
        builder: (context) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !ShellActivity.isActive(context)) return;
            _onBack();
          },
          child: Scaffold(
            body: useRail
                ? Row(
              children: [
                KeyedSubtree(key: _barKey, child: _rail(context)),
                Expanded(child: content),
              ],
            )
                : content,
            bottomNavigationBar: useRail ? null : KeyedSubtree(key: _barKey, child: _bottomBar(context)),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    if (AtlasNativeTabBar.supported) {
      return AtlasNativeTabBar(
        items: [for (final tab in _MusicTab.values) (title: tab.label, symbol: tab.symbol)],
        selectedIndex: _tab.index,
        showLabels: true,
        onSelected: (index) => _select(_MusicTab.values[index]),
      );
    }
    return NavigationBar(
      selectedIndex: _tab.index,
      onDestinationSelected: (index) => _select(_MusicTab.values[index]),
      destinations: [
        for (final tab in _MusicTab.values) NavigationDestination(icon: AppIcon(tab.icon), label: tab.label),
      ],
    );
  }

  Widget _rail(BuildContext context) {
    final theme = Theme.of(context);
    final isTV = PlatformDetector.isTV();
    final playing = isTV ? context.select<MusicPlaybackService?, bool>((s) => s?.currentTrack != null) : false;
    final canSwitch = AppModeSwitch.available(context);

    Widget item({required String id, required IconData icon, required String label, required bool selected, required VoidCallback onSelect}) {
      final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: FocusableWrapper(
          focusNode: _railNode(id),
          borderRadius: 14,
          onSelect: onSelect,
          onNavigateRight: () => FocusScope.of(context).focusInDirection(TraversalDirection.right),
          child: Material(
            color: selected ? theme.colorScheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              canRequestFocus: false,
              onTap: onSelect,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    AppIcon(icon, color: color, fill: selected ? 1.0 : 0.0),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: selected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: isTV ? 240 : 220,
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Row(
                children: [
                  AppIcon(Symbols.music_note_rounded, color: theme.colorScheme.primary, fill: 1.0),
                  const SizedBox(width: 8),
                  Text(
                    AppModeSwitch.label(AppMode.video),
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            for (final tab in _MusicTab.values)
              item(
                id: tab.name,
                icon: tab.icon,
                label: tab.label,
                selected: tab == _tab,
                onSelect: () => _select(tab),
              ),
            if (playing) ...[
              const SizedBox(height: 12),
              item(
                id: 'nowPlaying',
                icon: Symbols.equalizer_rounded,
                label: MusicStrings.nowPlaying,
                selected: false,
                onSelect: () => unawaited(openNowPlaying(context)),
              ),
            ],
            const Spacer(),
            if (canSwitch)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: item(
                  id: 'appMode',
                  icon: AppModeSwitch.icon(AppMode.music),
                  label: AppModeSwitch.label(AppMode.music),
                  selected: false,
                  onSelect: AppModeSwitch.toggle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
