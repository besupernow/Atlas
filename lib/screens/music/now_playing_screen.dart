import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/focus_theme.dart';
import '../../focus/focusable_action_bar.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_slider.dart';
import '../../focus/input_mode_tracker.dart';
import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/lyrics.dart';
import '../../media/media_item.dart';
import '../../media/stepped_seek.dart';
import '../../media/media_server_client.dart';
import '../../mixins/context_menu_tap_mixin.dart';
import '../../mpv/mpv.dart';
import '../../services/device_performance.dart';
import '../../services/music/music_bans.dart';
import '../../services/music/music_playback_service.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_motion.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/formatters.dart';
import '../../utils/desktop_window_padding.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/music_navigation.dart';
import '../../utils/platform_detector.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/music/lyrics_view.dart';
import '../../widgets/music/edge_fade.dart';
import '../../widgets/music/music_art_cache.dart';
import '../../widgets/music/music_glass.dart';
import '../../widgets/music/repeat_mode.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/overlay_sheet.dart';
import 'now_playing_route.dart';
import 'queue_sheet.dart';
import '../../app/app_mode.dart';
import '../../app/music_detail_scope.dart';
import '../../features/music/discover/discover_feed.dart';
import '../../features/music/discover/discover_models.dart';
import '../../features/music/discover/discover_widgets.dart';
import '../../features/music/music_strings.dart';
import '../../features/music/widgets/lyric_share.dart';
import '../../utils/error_message_utils.dart';

/// Full-screen music player. Pushed via [openNowPlaying]; popping never
/// touches playback — audio continues under the mini-player.
///
/// Layouts: mobile portrait (big art / transport stack), desktop & landscape
/// (two-pane: art beside the song and controls; Atlas dropped the inline
/// queue list, Up Next is the queue button), and TV (full-bleed art with a
/// d-pad transport chain). With nothing playing it shows a "Nothing playing"
/// card instead of closing.
///
/// D-pad chain (TV): transport row autofocuses play/pause (LEFT/RIGHT rove,
/// edges trapped) · UP → seek bar (LEFT/RIGHT = ±10s with key-repeat
/// acceleration) · seek UP → ⋮ overflow · transport DOWN → utility row
/// (Lyrics, Queue) · Lyrics toggle focuses the lyrics pane (BACK/DOWN-out
/// returns to transport) · BACK pops. Focus is always a text-based
/// background fill.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with ContextMenuTapMixin<NowPlayingScreen>, SingleTickerProviderStateMixin {
  MusicPlaybackService? _service;
  StreamSubscription<Object>? _errorsSub;

  bool _showLyrics = false;

  /// Atlas: the switcher at the top: lyrics, the player, or what's up next.
  _NowPlayingTab _tab = _NowPlayingTab.playing;

  /// Atlas: accent colors taken from the album art (null until worked out, or when there's no
  /// art or the device runs in reduced-performance mode).
  ColorScheme? _artScheme;
  String? _artSchemeKey;
  final Map<String, Future<Lyrics?>> _lyricsCache = {};

  /// Key for getting a context below this screen's own OverlaySheetHost —
  /// the State's context sits ABOVE it, so sheet calls made with `context`
  /// would miss the host and fall back to a hostless modal sheet.
  final GlobalKey _overlayChildKey = GlobalKey();

  BuildContext get _sheetContext => _overlayChildKey.currentContext ?? context;

  /// Swipe-down-to-dismiss (mobile portrait). The offset feeds a
  /// ValueListenableBuilder-wrapped Transform so drag frames never rebuild
  /// the screen.
  final ValueNotifier<double> _dismissDrag = ValueNotifier<double>(0);
  late final AnimationController _dismissSettle;
  double _dismissSettleFrom = 0;

  final FocusNode _seekFocusNode = FocusNode(debugLabel: 'now_playing_seek');
  final FocusNode _overflowFocusNode = FocusNode(debugLabel: 'now_playing_overflow');
  final FocusNode _playPauseFocusNode = FocusNode(debugLabel: 'now_playing_play_pause');
  final FocusNode _lyricsPaneFocusNode = FocusNode(debugLabel: 'now_playing_lyrics_pane');
  final GlobalKey<FocusableActionBarState> _utilityBarKey = GlobalKey<FocusableActionBarState>();


  @override
  void initState() {
    super.initState();
    _dismissSettle = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
      ..addListener(_onDismissSettleTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<MusicPlaybackService>();
    if (service != _service) {
      _errorsSub?.cancel();
      _service = service;
      // Surface playback failures while the screen is open — the service
      // already recovers (skip / stop) by itself.
      _errorsSub = service.errors.listen((error) {
        if (!mounted) return;
        // The init sentinel deliberately carries no prose, so `toString()`
        // would put its class name in front of the user; it gets the same
        // localized copy the video player shows.
        showErrorSnackBar(
          context,
          error is PlayerInitializationException
              ? t.messages.playbackFailed
              : t.messages.errorLoading(error: localizedErrorReason(error)),
        );
      });
    }
  }

  @override
  void dispose() {
    _errorsSub?.cancel();
    _dismissSettle.dispose();
    _dismissDrag.dispose();
    _seekFocusNode.dispose();
    _overflowFocusNode.dispose();
    _playPauseFocusNode.dispose();
    _lyricsPaneFocusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------

  Future<Lyrics?> _lyricsFutureFor(MediaItem track) =>
      _lyricsCache.putIfAbsent(track.globalKey, () => context.read<MusicPlaybackService>().fetchLyrics(track));

  void _toggleLyrics() => _selectTab(_tab == _NowPlayingTab.lyrics ? _NowPlayingTab.playing : _NowPlayingTab.lyrics);

  /// Atlas: the queue opens in place of the artwork (TV keeps its sheet).
  void _toggleQueue() {
    if (PlatformDetector.isTV()) {
      unawaited(showQueueSheet(_sheetContext));
      return;
    }
    _selectTab(_tab == _NowPlayingTab.queue ? _NowPlayingTab.playing : _NowPlayingTab.queue);
  }

  void _selectTab(_NowPlayingTab tab) {
    setState(() {
      _tab = tab;
      _showLyrics = tab == _NowPlayingTab.lyrics;
    });
    if (_showLyrics && InputModeTracker.isKeyboardMode(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showLyrics) _lyricsPaneFocusNode.requestFocus();
      });
    }
  }

  void _focusTransport() => _playPauseFocusNode.requestFocus();

  void _pop() => Navigator.pop(context);

  // Swipe-down anywhere above the transport controls closes the screen —
  // the standard music-player gesture. The content follows the finger;
  // releasing past the threshold pops (the route's reverse slide+fade
  // continues the motion from where the finger left off), otherwise the
  // content settles back.

  void _onDismissSettleTick() {
    _dismissDrag.value = _dismissSettleFrom * (1 - Curves.easeOutCubic.transform(_dismissSettle.value));
  }

  /// Atlas: opened as a [NowPlayingRoute], the swipe drags the route's own card (with the
  /// page underneath coming back into view) and a throw carries through; otherwise the
  /// content follows the finger as before.
  NowPlayingRoute? get _cardRoute {
    final route = ModalRoute.of(context);
    return route is NowPlayingRoute ? route : null;
  }

  void _onDismissDragStart(DragStartDetails details) {
    final route = _cardRoute;
    if (route != null) {
      route.dragStart();
      return;
    }
    _dismissSettle.stop();
  }

  void _onDismissDragUpdate(DragUpdateDetails details) {
    final route = _cardRoute;
    if (route != null) {
      route.dragUpdate(context, details.delta.dy);
      return;
    }
    _dismissDrag.value = math.max(0, _dismissDrag.value + details.delta.dy);
  }

  void _onDismissDragEnd(DragEndDetails details) {
    final route = _cardRoute;
    if (route != null) {
      route.dragEnd(context, details.primaryVelocity ?? 0);
      return;
    }
    final offset = _dismissDrag.value;
    if (offset <= 0) return;
    // Same thresholds as the overlay sheet system's drag-to-dismiss.
    if (offset > MediaQuery.sizeOf(context).height * 0.25 || (details.primaryVelocity ?? 0) > 500) {
      _pop();
    } else {
      _onDismissDragCancel();
    }
  }

  void _onDismissDragCancel() {
    final route = _cardRoute;
    if (route != null) {
      route.dragCancel(context);
      return;
    }
    if (_dismissDrag.value <= 0) return;
    _dismissSettleFrom = _dismissDrag.value;
    _dismissSettle.forward(from: 0);
  }

  /// Artist line tap — the track's grandparent is the artist. Shares the
  /// album screen's fetch-then-navigate flow via [openArtistById].
  Future<void> _openArtist(MediaItem track) async {
    final artistId = track.grandparentId;
    final client = context.getMediaClientForItemOrNull(track);
    if (artistId == null || client == null) return;
    if (await _openInMusicMode(client, artistId)) return;
    if (mounted) await openArtistById(context, client, artistId);
  }

  /// Atlas: the album name opens the album.
  Future<void> _openAlbum(MediaItem track) async {
    final albumId = track.parentId;
    final client = context.getMediaClientForItemOrNull(track);
    if (albumId == null || client == null) return;
    if (await _openInMusicMode(client, albumId)) return;
    final album = await client.fetchItem(albumId).catchError((Object _) => null);
    if (album != null && mounted) await navigateToAlbum(context, album);
  }

  /// Atlas: a name in the artist line. The album artist opens by id; anyone else credited
  /// (a feature) is looked up by name: their page in music mode when they're on the server,
  /// otherwise their discovery sheet over Now Playing.
  Future<void> _openArtistNamed(MediaItem track, String name) async {
    final albumArtist = ArtistCredit.parse(track.albumArtistTitle ?? '').main;
    if (albumArtist.isNotEmpty && albumArtist.first == name) return _openArtist(track);
    final found = await MusicDiscovery.of(context).resolveArtists([DiscoverArtist(mbid: 'name:$name', name: name)]);
    if (!mounted || found.isEmpty) return;
    final item = found.first;
    final open = MusicModeLinks.open;
    if (item is ServerFeedItem && open != null && AppModeController.instance.isMusic) {
      _pop();
      open(item.item);
      return;
    }
    await openFeedItem(context, item);
  }

  /// In music mode, close Now Playing and open the page on the current music tab (where the
  /// tab bar and mini player are), like Apple Music.
  Future<bool> _openInMusicMode(MediaServerClient client, String id) async {
    final open = MusicModeLinks.open;
    if (open == null || !AppModeController.instance.isMusic) return false;
    final item = await client.fetchItem(id).catchError((Object _) => null);
    if (item == null) return false;
    if (!mounted) return true;
    _pop();
    open(item);
    return true;
  }

  Future<void> _showSleepTimerSheet() async {
    final service = context.read<MusicPlaybackService>();
    final timed = service.sleepTimerActive && !service.sleepTimerEndOfTrack;
    final selected = await OverlaySheetController.showAdaptive<String>(
      _sheetContext,
      showDragHandle: true,
      builder: (context) => AppMenuSheet<String>(
        title: t.music.sleepTimer,
        entries: [
          AppMenuItem(
            value: 'off',
            icon: Symbols.timer_off_rounded,
            label: t.common.off,
            selected: !service.sleepTimerActive,
          ),
          for (final minutes in const [15, 30, 60])
            AppMenuItem(
              value: '$minutes',
              icon: Symbols.timer_rounded,
              label: t.music.sleepTimerMinutes(n: minutes),
              selected: timed && service.sleepTimerDuration == Duration(minutes: minutes),
            ),
          AppMenuItem(
            value: 'end_of_track',
            icon: Symbols.music_note_rounded,
            label: t.music.sleepTimerEndOfTrack,
            selected: service.sleepTimerEndOfTrack,
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case 'off':
        service.setSleepTimer(null);
      case 'end_of_track':
        service.setSleepTimer(null, endOfTrack: true);
      default:
        final minutes = int.tryParse(selected);
        if (minutes != null) service.setSleepTimer(Duration(minutes: minutes));
    }
  }

  // -------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.watch<MusicPlaybackService>();
    final track = service.currentTrack;

    if (track == null) {
      // Atlas: nothing playing (never played, or the session was stopped): say so and offer a
      // way back, instead of an empty screen or vanishing.
      return _NothingPlaying(onBrowse: _pop);
    }

    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(track.serverId));
    final isTV = PlatformDetector.isTV();
    _updateArtScheme(track, client, Theme.of(context).brightness);

    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        // Atlas: the next song's colors drift in over the last one's (slow cross-fade) instead
        // of the backdrop snapping.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: _Background(key: ValueKey(track.globalKey), track: track, client: client, heavyScrim: isTV),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (isTV) return _buildTvLayout(service, track, client);
              final twoPane = constraints.maxWidth >= 800 && constraints.maxWidth > constraints.maxHeight;
              return twoPane ? _buildWideLayout(service, track, client) : _buildPortraitLayout(service, track, client);
            },
          ),
        ),
      ],
    );

    if (PlatformDetector.isDesktopOS() && !isTV) {
      content = CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.space): () => unawaited(service.togglePlayPause())},
        child: FocusScope(child: Focus(autofocus: true, skipTraversal: true, child: content)),
      );
    }

    // Own OverlaySheetHost so the queue / sleep-timer sheets have a host on
    // TV; the host also owns system back (a back with a sheet open closes
    // the sheet, otherwise the route pops natively — audio continues).
    final host = OverlaySheetHost(
      canPop: true,
      // Atlas: pulled down, the whole sheet (art wash and all) slides down as one rounded card
      // over the page underneath, which shows through dimmed, like Apple Music. The route is
      // see-through for this; the card itself is opaque.
      child: Scaffold(
        key: _overlayChildKey,
        backgroundColor: Colors.transparent,
        body: ValueListenableBuilder<double>(
          valueListenable: _dismissDrag,
          builder: (context, offset, child) {
            final pulled = (offset / 400).clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                if (offset > 0) ColoredBox(color: Colors.black.withValues(alpha: 0.45 * (1 - pulled))),
                Transform.translate(
                  offset: Offset(0, offset),
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(offset > 0 ? 28 : 0)),
                    child: ColoredBox(color: tk.bg, child: child),
                  ),
                ),
              ],
            );
          },
          child: content,
        ),
      ),
    );
    final artScheme = _artScheme;
    if (artScheme == null) return host;
    // Atlas: the scrubber, buttons and highlights take the album art's color.
    final theme = Theme.of(context);
    return AnimatedTheme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: artScheme.primary,
          onPrimary: artScheme.onPrimary,
          primaryContainer: artScheme.primaryContainer,
          onPrimaryContainer: artScheme.onPrimaryContainer,
          secondary: artScheme.secondary,
          onSecondary: artScheme.onSecondary,
        ),
        sliderTheme: theme.sliderTheme.copyWith(activeTrackColor: artScheme.primary, thumbColor: artScheme.primary),
      ),
      child: host,
    );
  }

  /// Atlas: works out accent colors from the current track's album art (a small thumbnail, once
  /// per track and light/dark mode).
  void _updateArtScheme(MediaItem track, MediaServerClient? client, Brightness brightness) {
    final path = track.thumbPath;
    if (DevicePerformance.isReduced || client == null || path == null) {
      _artSchemeKey = null;
      _artScheme = null;
      return;
    }
    final key = '$path|${brightness.name}';
    if (key == _artSchemeKey) return;
    _artSchemeKey = key;
    final url = client.thumbnailUrl(path, width: 96, height: 96);
    unawaited(
      ColorScheme.fromImageProvider(provider: NetworkImage(url), brightness: brightness)
          .then((scheme) {
        if (mounted && _artSchemeKey == key) setState(() => _artScheme = scheme);
      })
          .catchError((Object _) {}),
    );
  }

  // -------------------------------------------------------------------
  // Layouts
  // -------------------------------------------------------------------

  Widget _buildPortraitLayout(MusicPlaybackService service, MediaItem track, MediaServerClient? client) {
    final playing = _tab == _NowPlayingTab.playing;
    Widget upper = Column(
      children: [
        _buildTopBar(track, service.playContext),
        // Atlas: on Lyrics and Up Next the song shrinks to a small header (Apple Music style).
        if (!playing) _buildCompactHeader(track, client),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: playing ? 24 : 8, vertical: 8),
            child: _buildArtworkOrLyrics(service, track, client),
          ),
        ),
        if (playing)
          Padding(padding: const EdgeInsets.fromLTRB(28, 12, 28, 0), child: _buildTrackInfo(track, centered: true)),
      ],
    );
    // Touch only — desktop keeps mouse drags for text selection and the
    // lyrics pane. A drag starting on the lyrics scrollable still scrolls
    // (the descendant recognizer wins the arena).
    if (!PlatformDetector.isDesktopOS()) {
      upper = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: _onDismissDragStart,
        onVerticalDragUpdate: _onDismissDragUpdate,
        onVerticalDragEnd: _onDismissDragEnd,
        onVerticalDragCancel: _onDismissDragCancel,
        child: upper,
      );
    }
    return Column(
      children: [
        Expanded(child: upper),
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 0), child: _buildSeekBar(track)),
        _buildTransportRow(service),
        const SizedBox(height: 4),
        _buildUtilityRow(showQueueButton: true),
        const SizedBox(height: 14),
      ],
    );
  }

  /// The song as one line with its cover, above the lyrics or the queue.
  Widget _buildCompactHeader(MediaItem track, MediaServerClient? client) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final artist = track.trackArtistTitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: OptimizedMediaImage(
              client: client,
              imagePath: track.thumbPath,
              imageType: ImageType.square,
              width: 56,
              height: 56,
              fallbackIcon: Symbols.music_note_rounded,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                GestureDetector(
                  onTap: () => unawaited(_openAlbum(track)),
                  child: Text(
                    track.title ?? '',
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: textTheme.titleMedium?.copyWith(fontWeight: .w700, color: tk.text),
                  ),
                ),
                if (artist != null && artist.isNotEmpty)
                  ArtistLinks(
                    credit: ArtistCredit.parse(artist, title: track.title),
                    accent: true,
                    onTap: (name) => unawaited(_openArtistNamed(track, name)),
                    style: textTheme.bodyMedium?.copyWith(color: tk.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _LoveButton(track: track),
        ],
      ),
    );
  }

  Widget _buildWideLayout(MusicPlaybackService service, MediaItem track, MediaServerClient? client) {
    return Column(
      children: [
        _buildTopBar(track, service.playContext),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Row(
              crossAxisAlignment: .stretch,
              children: [
                Expanded(flex: 10, child: _buildArtworkOrLyrics(service, track, client)),
                const SizedBox(width: 48),
                // Atlas: no track list beside the art; just the song, big, and the controls.
                // Up Next is a button away (the queue sheet).
                Expanded(
                  flex: 10,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        mainAxisSize: .min,
                        crossAxisAlignment: .stretch,
                        children: [
                          _buildTrackInfo(track, centered: true, large: true),
                          const SizedBox(height: 20),
                          _buildSeekBar(track),
                          const SizedBox(height: 8),
                          _buildWideControlBand(service),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTvLayout(MusicPlaybackService service, MediaItem track, MediaServerClient? client) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final artist = track.trackArtistTitle;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
      child: Row(
        children: [
          Expanded(flex: 4, child: _buildArtworkOrLyrics(service, track, client, tvArt: true)),
          const SizedBox(width: 48),
          Expanded(
            flex: 5,
            child: Column(
              mainAxisAlignment: .center,
              crossAxisAlignment: .stretch,
              children: [
                Row(
                  children: [
                    const Spacer(),
                    _buildOverflowButton(track, focusable: true),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  track.title ?? '',
                  maxLines: 2,
                  overflow: .ellipsis,
                  style: textTheme.headlineMedium?.copyWith(fontWeight: .w600, color: tk.text),
                ),
                if (artist != null && artist.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: textTheme.bodyLarge?.copyWith(color: tk.textMuted),
                  ),
                ],
                const SizedBox(height: 28),
                _buildSeekBar(track),
                const SizedBox(height: 8),
                _buildTransportRow(service),
                _buildUtilityRow(showQueueButton: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // Pieces
  // -------------------------------------------------------------------

  /// [playContext] is passed in (not selected) because this builds
  /// inside the layout-phase LayoutBuilder, where `context.select` on the
  /// screen's element asserts; the screen already watches the service.
  Widget _buildTopBar(MediaItem track, MusicPlayContext? playContext) {
    final tk = tokens(context);
    // macOS pins the traffic lights at y=21 (16pt buttons → center 29, see
    // WindowUtilsPlugin.customButtonPositions); a fixed 58px row centers the
    // close button on that line regardless of the platform visual density
    // shrinking the IconButton box.
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, isMacOS ? 0 : 4, 8, 0),
      child: SizedBox(
        height: isMacOS ? 58 : null,
        child: Row(
          children: [
            // Inset past the macOS traffic lights — this screen is a fullscreen
            // route, so the close button would otherwise sit underneath them.
            if (PlatformDetector.isDesktopOS())
              DesktopAppBarHelper.buildAdjustedLeading(
                FocusableButton(
                  onPressed: _pop,
                  child: IconButton(
                    icon: AppIcon(Symbols.keyboard_arrow_down_rounded, fill: 1, color: tk.text),
                    tooltip: t.common.close,
                    onPressed: _pop,
                  ),
                ),
                context: context,
              )!
            else
              const SizedBox(width: 44),
            // Atlas: a grabber, like a sheet you pull down (no "Playing from …" line).
            Expanded(
              child: Center(
                child: Semantics(
                  button: true,
                  label: t.common.close,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _pop,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      child: Container(
                        width: 40,
                        height: 5,
                        decoration: BoxDecoration(
                          color: tk.text.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _buildOverflowButton(track),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// Wide-layout control band: the transport row stays exactly centered
  /// (equal-width flanks), with lyrics + a desktop volume slider as a
  /// right-aligned cluster that scales down instead of overflowing when the
  /// pane is narrow.
  Widget _buildWideControlBand(MusicPlaybackService service) {
    final tk = tokens(context);
    final colorScheme = Theme.of(context).colorScheme;
    final cluster = Row(
      mainAxisSize: .min,
      children: [
        FocusableButton(
          onPressed: _toggleLyrics,
          child: IconButton(
            icon: AppIcon(
              Symbols.lyrics_rounded,
              fill: 1,
              size: 22,
              color: _tab == _NowPlayingTab.lyrics ? colorScheme.primary : tk.textMuted,
            ),
            tooltip: t.music.lyrics,
            onPressed: _toggleLyrics,
          ),
        ),
        const SizedBox(width: 4),
        FocusableButton(
          onPressed: _toggleQueue,
          child: IconButton(
            icon: AppIcon(
              Symbols.queue_music_rounded,
              fill: 1,
              size: 22,
              color: _tab == _NowPlayingTab.queue ? colorScheme.primary : tk.textMuted,
            ),
            tooltip: t.music.queue,
            onPressed: _toggleQueue,
          ),
        ),
        if (PlatformDetector.isDesktop(context)) ...[const SizedBox(width: 4), _buildVolumeCluster(service)],
      ],
    );

    return Row(
      children: [
        const Expanded(child: SizedBox()),
        _buildTransportRow(service),
        Expanded(
          child: Align(
            alignment: .centerRight,
            child: FittedBox(fit: BoxFit.scaleDown, child: cluster),
          ),
        ),
      ],
    );
  }

  /// Desktop volume control (0–100), persisted by the service across
  /// sessions. Mono styling matches the seek bar: text-colored active track
  /// on outline.
  Widget _buildVolumeCluster(MusicPlaybackService service) {
    return ValueListenableBuilder<double>(
      valueListenable: service.volumeListenable,
      builder: (context, volume, _) {
        final tk = tokens(context);
        final icon = volume <= 0
            ? Symbols.volume_off_rounded
            : volume < 50
            ? Symbols.volume_down_rounded
            : Symbols.volume_up_rounded;
        return Row(
          mainAxisSize: .min,
          children: [
            AppIcon(icon, fill: 1, size: 20, color: tk.textMuted),
            SizedBox(
              width: 140,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: tk.text,
                  inactiveTrackColor: tk.outline,
                  thumbColor: tk.text,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: FocusableSlider(
                  value: volume.clamp(0.0, 100.0),
                  max: 100,
                  onChanged: (value) => unawaited(service.setVolume(value, persist: false)),
                  onChangeEnd: (value) => unawaited(service.setVolume(value)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// ⋮ — the current track's standard context menu plus the Sleep timer
  /// entry. On TV ([focusable]) it joins the d-pad chain above the seek bar.
  Widget _buildOverflowButton(MediaItem track, {bool focusable = false}) {
    final tk = tokens(context);
    void showMenu() => contextMenuKey.currentState?.showContextMenu(context);

    return MediaContextMenu(
      key: contextMenuKey,
      item: track,
      extraEntries: [
        MediaMenuExtraEntry(icon: Symbols.bedtime_rounded, label: t.music.sleepTimer, onSelected: _showSleepTimerSheet),
        // Atlas: hide it for good (the player skips to the next song).
        MediaMenuExtraEntry(
          icon: Symbols.visibility_off_rounded,
          label: MusicStrings.hideSong,
          onSelected: () => unawaited(
            MusicBans.instance.add(
              MusicBan(
                kind: MusicBanKind.song,
                title: track.title ?? '',
                artist: track.trackArtistTitle ?? track.albumArtistTitle ?? '',
                id: track.id,
              ),
            ),
          ),
        ),
        if ((track.albumArtistTitle ?? track.trackArtistTitle) case final artist? when artist.isNotEmpty)
          MediaMenuExtraEntry(
            icon: Symbols.person_off_rounded,
            label: MusicStrings.hideArtist(artist),
            onSelected: () => unawaited(
              MusicBans.instance.add(MusicBan(kind: MusicBanKind.artist, title: artist, id: track.grandparentId)),
            ),
          ),
      ],
      child: FocusableButton(
        focusNode: focusable ? _overflowFocusNode : null,
        onPressed: showMenu,
        onNavigateDown: focusable ? _seekFocusNode.requestFocus : null,
        onNavigateUp: focusable ? () {} : null,
        onNavigateLeft: focusable ? () {} : null,
        onNavigateRight: focusable ? () {} : null,
        onBack: focusable ? _pop : null,
        useBackgroundFocus: focusable,
        child: Tooltip(
          message: MaterialLocalizations.of(context).showMenuTooltip,
          child: _Pressable(
            onTap: showMenu,
            child: _Frosted(
              size: 36,
              child: AppIcon(Symbols.more_horiz_rounded, fill: 1, size: 22, color: tk.text),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackInfo(MediaItem track, {required bool centered, bool large = false}) {
    final tk = tokens(context);
    final textTheme = Theme.of(context).textTheme;
    final accent = Theme.of(context).colorScheme.primary;
    final artist = track.trackArtistTitle;
    final album = track.albumTitle;

    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          track.title ?? '',
          maxLines: 1,
          overflow: .ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: (large ? textTheme.headlineMedium : textTheme.headlineSmall)?.copyWith(
            fontWeight: .w800,
            letterSpacing: -0.4,
            color: tk.text,
          ),
        ),
        // The album, then everyone on the song, each a link in the accent color.
        if (album != null && album.isNotEmpty)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => unawaited(_openAlbum(track)),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  album,
                  maxLines: 1,
                  overflow: .ellipsis,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: (large ? textTheme.titleMedium : textTheme.bodyLarge)?.copyWith(
                    color: accent,
                    fontWeight: .w700,
                  ),
                ),
              ),
            ),
          ),
        if (artist != null && artist.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ArtistLinks(
              credit: ArtistCredit.parse(artist, title: track.title),
              accent: true,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              onTap: (name) => unawaited(_openArtistNamed(track, name)),
              style: (large ? textTheme.titleLarge : textTheme.titleMedium)?.copyWith(fontWeight: .w600),
            ),
          ),
      ],
    );
  }

  Widget _buildArtworkOrLyrics(
      MusicPlaybackService service,
      MediaItem track,
      MediaServerClient? client, {
        bool tvArt = false,
      }) {
    // Atlas: art, lyrics and Up Next trade places with a soft cross-fade that drifts and
    // settles (the old switch was a quick plain fade).
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 240),
      switchInCurve: const Cubic(0.05, 0.7, 0.1, 1.0),
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.center,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.965, end: 1).animate(animation),
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.025), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
      ),
      child: _tab == _NowPlayingTab.queue && !tvArt
          ? const KeyedSubtree(
        key: ValueKey('now_playing_queue'),
        child: Material(type: MaterialType.transparency, child: _UpNextPanel()),
      )
          : _showLyrics
          ? KeyedSubtree(
        key: const ValueKey('now_playing_lyrics'),
        // Lines melt into the header and the controls instead of being sliced off.
        child: EdgeFade(
          top: 40,
          bottom: 64,
          child: LyricsView(
            lyricsFuture: _lyricsFutureFor(track),
            focusNode: _lyricsPaneFocusNode,
            onExit: _focusTransport,
            // Atlas: long-press lines to share them as a card.
            onShareLines: PlatformDetector.isTV()
                ? null
                : (lines) => unawaited(
              shareLyrics(
                context,
                track: track,
                client: context.tryGetMediaClientWithFallback(serverIdOrNull(track.serverId)),
                lines: lines,
              ),
            ),
          ),
        ),
      )
          : KeyedSubtree(
        key: const ValueKey('now_playing_art'),
        child: _Artwork(track: track, client: client, tvSized: tvArt),
      ),
    );
  }

  Widget _buildSeekBar(MediaItem track) {
    return _NowPlayingSeekBar(
      trackKey: track.globalKey,
      focusNode: _seekFocusNode,
      onNavigateUp: PlatformDetector.isTV() ? _overflowFocusNode.requestFocus : null,
      onNavigateDown: _focusTransport,
      onBack: _pop,
    );
  }

  /// One transport icon with the shared text-fill focus pill.
  Widget _transportIcon(
      FocusableActionBuildState state, {
        required IconData icon,
        required VoidCallback onPressed,
        bool active = true,
        String? tooltip,
        double size = 26,
      }) {
    final tk = tokens(context);
    return AnimatedContainer(
      duration: state.animationDuration,
      decoration: FocusTheme.textFillFocusDecoration(
        context,
        isFocused: state.showFocus,
        borderRadius: MonoTokens.radiusFull,
      ),
      child: Tooltip(
        message: tooltip ?? '',
        child: _Pressable(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: AppIcon(icon, fill: 1, size: size, color: active ? tk.text : tk.text.withValues(alpha: 0.45)),
          ),
        ),
      ),
    );
  }

  /// Lyrics / Up Next: a quiet glyph, in a frosted chip when that view is open.
  Widget _utilityIcon(
      FocusableActionBuildState state, {
        required IconData icon,
        required bool active,
        required String tooltip,
        required VoidCallback onPressed,
      }) {
    final tk = tokens(context);
    return AnimatedContainer(
      duration: state.animationDuration,
      decoration: FocusTheme.textFillFocusDecoration(
        context,
        isFocused: state.showFocus,
        borderRadius: MonoTokens.radiusFull,
      ),
      child: Tooltip(
        message: tooltip,
        child: _Pressable(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? tk.text.withValues(alpha: 0.9) : Colors.transparent,
            ),
            child: Center(
              child: AppIcon(
                icon,
                fill: 1,
                size: 22,
                color: active ? tk.bg : tk.text.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransportRow(MusicPlaybackService service) {
    // Atlas: shuffle and repeat live with the queue now (Up Next), Apple Music style.
    final transport = FocusableActionBar(
      spacing: 28,
      onNavigateUp: _seekFocusNode.requestFocus,
      onNavigateDown: () => _utilityBarKey.currentState?.requestFocusOnFirst(),
      onBack: _pop,
      actions: [
        FocusableAction(
          debugLabel: 'np_previous',
          onPressed: () => unawaited(service.previous()),
          builder: (context, state) => _transportIcon(
            state,
            icon: Symbols.skip_previous_rounded,
            tooltip: t.music.previousTrack,
            onPressed: () => unawaited(service.previous()),
            size: 42,
          ),
        ),
        FocusableAction(
          debugLabel: 'np_play_pause',
          focusNode: _playPauseFocusNode,
          autofocus: PlatformDetector.isTV(),
          onPressed: () => unawaited(service.togglePlayPause()),
          builder: (context, state) =>
              _PlayPauseButton(state: state, onPressed: () => unawaited(service.togglePlayPause())),
        ),
        FocusableAction(
          debugLabel: 'np_next',
          onPressed: () => unawaited(service.next()),
          builder: (context, state) => _transportIcon(
            state,
            icon: Symbols.skip_next_rounded,
            tooltip: t.music.nextTrack,
            onPressed: () => unawaited(service.next()),
            size: 42,
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        // Cars must retain the enlarged touch targets. Other form factors keep
        // scaling the row down rather than overflowing narrow layouts.
        child: PlatformDetector.isAutomotive() ? transport : FittedBox(fit: BoxFit.scaleDown, child: transport),
      ),
    );
  }

  Widget _buildUtilityRow({required bool showQueueButton}) {
    return Center(
      child: FocusableActionBar(
        key: _utilityBarKey,
        spacing: 64,
        onNavigateUp: _focusTransport,
        // Bottom of the chain — trap DOWN so focus can't escape the screen.
        // ignore: no-empty-block
        onNavigateDown: () {},
        onBack: _pop,
        actions: [
          FocusableAction(
            debugLabel: 'np_lyrics',
            onPressed: _toggleLyrics,
            builder: (context, state) => _utilityIcon(
              state,
              icon: Symbols.lyrics_rounded,
              active: _showLyrics,
              tooltip: t.music.lyrics,
              onPressed: _toggleLyrics,
            ),
          ),
          if (showQueueButton)
            FocusableAction(
              debugLabel: 'np_queue',
              onPressed: _toggleQueue,
              builder: (context, state) => _utilityIcon(
                state,
                icon: Symbols.queue_music_rounded,
                active: _tab == _NowPlayingTab.queue,
                tooltip: t.music.queue,
                onPressed: _toggleQueue,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------

/// Square artwork with the M3E pause shape-morph: large-radius while
/// playing, ~28 when paused.
class _Artwork extends StatelessWidget {
  final MediaItem track;
  final MediaServerClient? client;

  /// TV sizes the art off the screen height instead of hugging width.
  final bool tvSized;

  const _Artwork({required this.track, required this.client, required this.tvSized});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final isPlaying = context.select<MusicPlaybackService, bool>((s) => s.isPlaying);

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = tvSized
            ? math.min(constraints.maxWidth, constraints.maxHeight * 0.62)
            : math.min(constraints.maxWidth * 0.85, constraints.maxHeight);
        if (side <= 0 || !side.isFinite) return const SizedBox.shrink();
        // Atlas: Apple Music style: the art sits big with a deep shadow while playing and
        // settles back a little when paused.
        final shown = isPlaying ? side : side * 0.86;
        return Center(
          child: AnimatedContainer(
            duration: MonoMotion.shape(context),
            curve: MonoMotion.emphasized,
            width: shown,
            height: shown,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(isPlaying ? tk.radiusLg : 28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isPlaying ? 0.45 : 0.25),
                  blurRadius: isPlaying ? 48 : 24,
                  offset: Offset(0, isPlaying ? 24 : 10),
                ),
              ],
            ),
            // Atlas: the next cover fades in over the last (with a slight settle) instead of
            // swapping.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween<double>(begin: 1.04, end: 1).animate(animation), child: child),
              ),
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              child: OptimizedMediaImage(
                key: ValueKey(track.globalKey),
                client: client,
                imagePath: track.thumbPath,
                imageType: ImageType.square,
                width: side,
                height: side,
                fallbackIcon: Symbols.music_note_rounded,
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------

/// Blurred album art at low opacity under a bg scrim. Skipped entirely on
/// the reduced performance tier (plain background).
class _Background extends StatelessWidget {
  final MediaItem track;
  final MediaServerClient? client;
  final bool heavyScrim;

  const _Background({super.key, required this.track, required this.client, required this.heavyScrim});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    // A small copy of the cover (warmed ahead of time): blurred this hard, more pixels add
    // nothing, and it's ready the moment the song changes.
    final art = DevicePerformance.isReduced
        ? null
        : MusicArtCache.provider(context, track, MusicArtCache.backdropSize, client: client);
    if (art == null) {
      return ColoredBox(color: tk.bg);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: tk.bg),
        // Atlas: the art's colors wash the whole screen (the blurred cover, stronger than before),
        // fading into the page toward the controls.
        // Atlas: the cover blown up and blurred twice over (one turned, so the colors pool
        // unevenly like Apple Music's), then a soft shade toward the controls.
        Opacity(
          opacity: heavyScrim ? 0.45 : 0.9,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90, tileMode: TileMode.mirror),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Transform.scale(
                  scale: 1.6,
                  child: Image(image: art, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true),
                ),
                Opacity(
                  opacity: 0.55,
                  child: Transform.rotate(
                    angle: math.pi,
                    child: Transform.scale(
                      scale: 2.2,
                      alignment: Alignment.bottomLeft,
                      child: Image(image: art, fit: BoxFit.cover, gaplessPlayback: true, excludeFromSemantics: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.55, 1],
              colors: [tk.bg.withValues(alpha: 0.1), tk.bg.withValues(alpha: 0.28), tk.bg.withValues(alpha: 0.62)],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Play / pause morph button
// ---------------------------------------------------------------------

/// 72px inverse-surface button: circle while paused, rounded square while
/// playing (M3E shape morph). Focus reads through the action bar's dimming
/// plus a small scale.
class _PlayPauseButton extends StatelessWidget {
  final FocusableActionBuildState state;
  final VoidCallback onPressed;

  const _PlayPauseButton({required this.state, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final isPlaying = context.select<MusicPlaybackService, bool>((s) => s.isPlaying);
    final isLoading = context.select<MusicPlaybackService, bool>((s) => s.status == MusicPlaybackStatus.loading);

    // Atlas: just the glyph, big, like Apple Music (no Material slab). It swaps with a quick
    // scale and fade; on TV, focus shows as the usual soft pill behind it.
    return AnimatedContainer(
      duration: state.animationDuration,
      decoration: FocusTheme.textFillFocusDecoration(context, isFocused: state.showFocus, borderRadius: MonoTokens.radiusFull),
      child: _Pressable(
        onTap: onPressed,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Center(
            child: isLoading
                ? SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3, color: tk.text))
                : AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: AppIcon(
                isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                key: ValueKey(isPlaying),
                fill: 1,
                size: 64,
                color: tk.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Atlas: a tap target that dips in scale while pressed instead of a Material ink splash.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.86 : 1,
          duration: Duration(milliseconds: _down ? 90 : 220),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: AnimatedOpacity(
            opacity: _down ? 0.7 : 1,
            duration: const Duration(milliseconds: 120),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Atlas: a small frosted circle (blur over whatever's behind, a touch of white).
class _Frosted extends StatelessWidget {
  const _Frosted({required this.child, required this.size});

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: size,
          height: size,
          color: MusicGlass.tint(context, strength: 1.3),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Atlas: Up Next (queue tab) and the love button
// ---------------------------------------------------------------------

/// The song's heart: loves it on the server (Jellyfin favorite), filled in the accent color
/// when it is. Remembers the change itself, since the track it was handed is a snapshot.
class _LoveButton extends StatefulWidget {
  const _LoveButton({required this.track});

  final MediaItem track;

  @override
  State<_LoveButton> createState() => _LoveButtonState();
}

class _LoveButtonState extends State<_LoveButton> {
  static final Map<String, bool> _changed = {};
  bool _busy = false;

  bool get _loved => _changed[widget.track.globalKey] ?? widget.track.isFavorite ?? false;

  Future<void> _toggle() async {
    if (_busy) return;
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(widget.track.serverId));
    if (client == null) return;
    final want = !_loved;
    unawaited(want ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick());
    setState(() {
      _busy = true;
      _changed[widget.track.globalKey] = want;
    });
    try {
      await client.setFavorite(widget.track, want);
    } catch (_) {
      _changed[widget.track.globalKey] = !want;
      if (mounted) showErrorSnackBar(context, MusicStrings.loadFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final loved = _loved;
    return Tooltip(
      message: loved ? MusicStrings.unlove : MusicStrings.love,
      child: _Pressable(
        onTap: () => unawaited(_toggle()),
        child: _Frosted(
          size: 40,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
            child: AppIcon(
              Symbols.favorite_rounded,
              key: ValueKey(loved),
              fill: loved ? 1 : 0,
              size: 22,
              color: loved ? Theme.of(context).colorScheme.primary : tk.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// The queue tab, Apple Music style: Shuffle / Repeat / AutoPlay / Mixing as a row of frosted
/// toggles, then Up Next (with Clear) and the list, starting at the top.
class _UpNextPanel extends StatelessWidget {
  const _UpNextPanel();

  @override
  Widget build(BuildContext context) {
    final service = context.watch<MusicPlaybackService>();
    final settings = SettingsService.instance;
    return Column(
      crossAxisAlignment: .stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: ListenableBuilder(
            listenable: Listenable.merge([
              settings.listenable(SettingsService.musicAutoplay),
              settings.listenable(SettingsService.musicMixing),
            ]),
            builder: (context, _) {
              final autoplay = settings.read(SettingsService.musicAutoplay);
              final mixing = settings.read(SettingsService.musicMixing);
              return Row(
                children: [
                  _QueueToggle(
                    icon: Symbols.shuffle_rounded,
                    tooltip: t.common.shuffle,
                    active: service.shuffled,
                    onTap: service.toggleShuffle,
                  ),
                  _QueueToggle(
                    icon: repeatModeIcon(service.repeatMode),
                    tooltip: repeatModeLabel(service.repeatMode),
                    active: service.repeatMode != MusicRepeatMode.off,
                    onTap: () => service.setRepeatMode(nextRepeatMode(service.repeatMode)),
                  ),
                  // Like Apple: AutoPlay can't run under Repeat (the queue never ends), so it
                  // reads as off then, and turning it on turns Repeat off.
                  _QueueToggle(
                    icon: Symbols.all_inclusive_rounded,
                    tooltip: MusicStrings.autoplay,
                    active: autoplay && service.repeatMode == MusicRepeatMode.off,
                    onTap: () async {
                      final repeating = service.repeatMode != MusicRepeatMode.off;
                      final turnOn = !autoplay || repeating;
                      if (repeating && turnOn) service.setRepeatMode(MusicRepeatMode.off);
                      await settings.write(SettingsService.musicAutoplay, turnOn);
                      service.autoplayChanged();
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          !turnOn
                              ? MusicStrings.autoplayOff
                              : repeating
                              ? MusicStrings.autoplayNeedsRepeatOff
                              : MusicStrings.autoplayOn,
                        );
                      }
                    },
                  ),
                  // Coming with AudioMuse's transitions; the switch is kept so it's ready.
                  _QueueToggle(
                    icon: Symbols.instant_mix_rounded,
                    tooltip: MusicStrings.mixing,
                    active: mixing,
                    onTap: () async {
                      await settings.write(SettingsService.musicMixing, !mixing);
                      if (context.mounted) showAppSnackBar(context, MusicStrings.mixingSoon);
                    },
                  ),
                ],
              );
            },
          ),
        ),
        // History above (scroll up for it), then Up Next with Clear, then AutoPlay.
        const Expanded(child: QueueList(showCurrent: false)),
      ],
    );
  }
}

/// One of the Up Next toggles: a frosted pill, filled when on.
class _QueueToggle extends StatelessWidget {
  const _QueueToggle({required this.icon, required this.tooltip, required this.active, required this.onTap});

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Tooltip(
          message: tooltip,
          child: _Pressable(
            onTap: () {
              unawaited(HapticFeedback.selectionClick());
              onTap();
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  height: 40,
                  alignment: Alignment.center,
                  color: active ? tk.text.withValues(alpha: 0.9) : MusicGlass.tint(context, strength: 1.3),
                  child: AppIcon(icon, fill: 1, size: 20, color: active ? tk.bg : tk.text),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Seek bar
// ---------------------------------------------------------------------

/// Thin mono slider driven by the position stream — an isolated widget so
/// per-second ticks never rebuild the screen. The thumb only appears while
/// dragging. As a d-pad region, LEFT/RIGHT seek ±10s with the video
/// timeline's stepped key-repeat acceleration; focus renders as a
/// text-based background pill behind the bar.
class _NowPlayingSeekBar extends StatefulWidget {
  final String trackKey;
  final FocusNode focusNode;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback onBack;

  const _NowPlayingSeekBar({
    required this.trackKey,
    required this.focusNode,
    required this.onNavigateUp,
    required this.onNavigateDown,
    required this.onBack,
  });

  @override
  State<_NowPlayingSeekBar> createState() => _NowPlayingSeekBarState();
}

class _NowPlayingSeekBarState extends State<_NowPlayingSeekBar> {
  static const int _baseStepMs = 10000;

  double? _dragValueMs;
  bool _focused = false;

  int _seekRepeatCount = 0;
  LogicalKeyboardKey? _seekDirection;
  late final DebouncedSeekAccumulator _keySeek;

  @override
  void initState() {
    super.initState();
    _keySeek = DebouncedSeekAccumulator(
      currentPosition: () => context.read<MusicPlaybackService>().position,
      duration: () => context.read<MusicPlaybackService>().duration ?? Duration.zero,
      seek: (target) {
        final service = context.read<MusicPlaybackService>();
        if (service.currentTrack?.globalKey == widget.trackKey) {
          unawaited(service.seek(target));
        }
      },
      // The scrub bar cancels the pin itself, but OS media controls, a headset
      // and the lock screen all seek straight through the service, and those
      // have to retire it too (#1819).
      playheadJumps: context.read<MusicPlaybackService>().playheadJumpStream,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void didUpdateWidget(covariant _NowPlayingSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackKey == widget.trackKey) return;
    _keySeek.cancel();
    _dragValueMs = null;
    _resetSeekState();
  }

  @override
  void dispose() {
    _keySeek.dispose();
    super.dispose();
  }

  void _resetSeekState() {
    _seekRepeatCount = 0;
    _seekDirection = null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    if (event is KeyUpEvent && (key.isLeftKey || key.isRightKey)) {
      _keySeek.flush();
      _resetSeekState();
      return KeyEventResult.handled;
    }

    final backResult = handleBackKeyAction(event, widget.onBack);
    if (backResult != KeyEventResult.ignored) return backResult;

    if (!event.isActionable) return KeyEventResult.ignored;

    if (key.isUpKey) {
      if (widget.onNavigateUp == null) return KeyEventResult.handled; // trap
      widget.onNavigateUp!();
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      widget.onNavigateDown?.call();
      return KeyEventResult.handled;
    }

    if (key.isLeftKey || key.isRightKey) {
      final service = context.read<MusicPlaybackService>();
      final duration = service.duration;
      if (duration == null || duration.inMilliseconds <= 0) return KeyEventResult.handled;

      if (_seekDirection != key) {
        _seekDirection = key;
        _seekRepeatCount = 0;
      }
      if (event is KeyRepeatEvent) _seekRepeatCount++;
      final multiplier = event is KeyRepeatEvent ? steppedSeekMultiplier(_seekRepeatCount) : 1.0;
      final stepMs = (_baseStepMs * multiplier).round();

      final step = Duration(milliseconds: stepMs);
      _keySeek.seekBy(key.isRightKey ? step : -step);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final service = context.read<MusicPlaybackService>();
    final showFocus = _focused && InputModeTracker.isKeyboardMode(context);

    final bar = StreamBuilder<Duration>(
      key: ValueKey(widget.trackKey),
      stream: service.positionStream,
      builder: (context, snapshot) {
        final duration = service.duration ?? Duration.zero;
        final durationMs = duration.inMilliseconds.toDouble();
        final hasDuration = durationMs > 0;
        final rawPositionMs =
            _dragValueMs ??
                _keySeek.pendingPosition?.inMilliseconds.toDouble() ??
                (snapshot.data ?? service.position).inMilliseconds.toDouble();
        final positionMs = hasDuration ? rawPositionMs.clamp(0.0, durationMs) : 0.0;
        final dragging = _dragValueMs != null;

        return Column(
          mainAxisSize: .min,
          children: [
            SliderTheme(
              // Atlas: a soft capsule with no thumb that grows while you drag it (Apple Music),
              // instead of Material's slider.
              data: SliderTheme.of(context).copyWith(
                trackHeight: dragging ? 12 : 6,
                activeTrackColor: tk.text.withValues(alpha: dragging ? 0.95 : 0.8),
                inactiveTrackColor: tk.text.withValues(alpha: 0.18),
                thumbColor: Colors.transparent,
                trackGap: 0,
                thumbShape: SliderComponentShape.noThumb,
                overlayShape: SliderComponentShape.noOverlay,
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                max: hasDuration ? durationMs : 1,
                value: positionMs,
                onChangeStart: hasDuration
                    ? (value) {
                  _keySeek.cancel();
                  setState(() => _dragValueMs = value);
                }
                    : null,
                onChanged: hasDuration ? (value) => setState(() => _dragValueMs = value) : null,
                onChangeEnd: hasDuration
                    ? (value) {
                  if (service.currentTrack?.globalKey == widget.trackKey) {
                    unawaited(service.seek(Duration(milliseconds: value.round())));
                  }
                  setState(() => _dragValueMs = null);
                }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
              child: Row(
                children: [
                  Text(
                    formatDurationTimestamp(Duration(milliseconds: positionMs.round())),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tk.text.withValues(alpha: 0.55),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  // Time left, like Apple Music.
                  Text(
                    '-${formatDurationTimestamp(Duration(milliseconds: (durationMs - positionMs).clamp(0, durationMs).round()))}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tk.text.withValues(alpha: 0.55),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );

    return Focus(
      focusNode: widget.focusNode,
      descendantsAreFocusable: false,
      onKeyEvent: _handleKeyEvent,
      onFocusChange: (hasFocus) {
        if (!hasFocus) {
          _keySeek.flush();
          _resetSeekState();
        }
        setState(() => _focused = hasFocus);
      },
      child: AnimatedContainer(
        duration: FocusTheme.getAnimationDuration(context),
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: FocusTheme.textFillFocusDecoration(context, isFocused: showFocus, borderRadius: tk.radiusLg),
        child: bar,
      ),
    );
  }
}

/// Atlas: Now Playing with nothing to play: a calm card that says so, and the way back.
class _NothingPlaying extends StatelessWidget {
  const _NothingPlaying({required this.onBrowse});

  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final tk = tokens(context);
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.35),
                radius: 1.1,
                colors: [accent.withValues(alpha: 0.28), tk.bg],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: .min,
                  children: [
                    Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(32),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [accent, Color.lerp(accent, Colors.black, 0.5)!],
                        ),
                        boxShadow: [
                          BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 16)),
                        ],
                      ),
                      child: const Center(
                        child: AppIcon(Symbols.music_note_rounded, size: 88, color: Colors.white, fill: 1),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      MusicStrings.nothingPlaying,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: .w800, color: tk.text),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Text(
                        MusicStrings.nothingPlayingBody,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(color: tk.textMuted),
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      autofocus: true,
                      onPressed: onBrowse,
                      icon: const AppIcon(Symbols.library_music_rounded, fill: 1),
                      label: const Text(MusicStrings.browseMusic),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _NowPlayingTab { lyrics, playing, queue }
