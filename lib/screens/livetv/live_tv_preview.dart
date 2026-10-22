import 'dart:async';
import 'package:plezy/utils/app_platform.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../media/ids.dart';
import '../../media/live_tv_support.dart';
import '../../models/livetv_channel.dart';
import '../../models/transcode_quality_preset.dart';
import '../../mpv/mpv.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/playback_coordinator.dart';
import '../../utils/app_logger.dart';
import '../../utils/live_tv_player_navigation.dart';

/// Master switch for the inline mini player. If it misbehaves on a device,
/// set this to false: the hero shows the channel card with a Play button
/// that opens full screen instead.
const bool kLiveTvInlinePreview = true;

/// Same stream quality as full screen, so enlarging never re-tunes or skips.
const TranscodeQualityPreset kLiveTvPreviewQuality = TranscodeQualityPreset.original;

/// Full screen brings up the original-quality stream and swaps to it. The two
/// encodes are independent, so the swap can step back a moment; set this to
/// false to keep the light stream in full screen instead (no swap at all).
const bool kLiveTvUpgradeOnFullscreen = true;

/// Android, iOS and macOS draw mpv/ExoPlayer video on a full-window native
/// plane that cannot be placed in a small rectangle, so the mini player (and
/// its full-screen view) use a Flutter-texture player there. Windows and Linux
/// can position the native plane, so they keep the mpv player.
bool get _useTexturePlayer => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// The Video widget paints a black cover until it hears a playback-restart.
/// Our Video mounts AFTER open() finished (restart already fired), so reveal
/// it right away instead of waiting for an event that never comes.
final ValueNotifier<bool> _kAlwaysRevealed = ValueNotifier<bool>(true);

/// The mini player at the top of the Live TV guide.
///
/// Tunes [channel] into its own small player. Changing [channel] retunes.
/// Call [LiveTvPreviewState.suspend] before opening the full-screen player and
/// [LiveTvPreviewState.resume] when coming back; only one live stream should
/// be open at a time.
class LiveTvPreview extends StatefulWidget {
  final LiveTvChannel? channel;
  final VoidCallback onFullscreen;
  final bool showFullscreenButton;

  const LiveTvPreview({super.key, required this.channel, required this.onFullscreen, this.showFullscreenButton = true});

  @override
  State<LiveTvPreview> createState() => LiveTvPreviewState();
}

class LiveTvPreviewState extends State<LiveTvPreview> with WidgetsBindingObserver {
  Player? _player;
  vp.VideoPlayerController? _vc;
  LiveTvPlaybackSession? _session;
  int _generation = 0;
  bool _loading = false;
  bool _disposed = false;
  bool _fullscreen = false;
  int _videoEpoch = 0;

  /// Current player (null while tuning/suspended). Full screen listens to this
  /// so it shows the SAME stream instead of opening a second player.
  final ValueNotifier<Object?> playerNotifier = ValueNotifier<Object?>(null);
  bool _suspended = false;
  bool _tickerEnabled = true;
  bool _muted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.channel != null) _tune();
  }

  /// Hidden tabs (IndexedStack) and covered routes lose their tickers. That is
  /// a reliable "not on screen" signal even when the tab callbacks fire before
  /// this widget exists, so stop the stream (and its audio) when it flips off.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.of(context);
    if (enabled == _tickerEnabled) return;
    _tickerEnabled = enabled;
    if (_fullscreen) return; // our own full-screen route covers us on purpose
    if (!enabled) {
      unawaited(suspend());
    } else {
      resume();
    }
  }

  @override
  void didUpdateWidget(LiveTvPreview old) {
    super.didUpdateWidget(old);
    final a = old.channel == null ? null : liveTvChannelScopeKey(old.channel!);
    final b = widget.channel == null ? null : liveTvChannelScopeKey(widget.channel!);
    if (a != b && !_suspended) _tune();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(suspend());
    } else if (state == AppLifecycleState.resumed) {
      resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _generation++;
    unawaited(_teardown().whenComplete(playerNotifier.dispose));
    super.dispose();
  }

  /// Forces the native video plane to re-measure (after full screen closes).
  void refreshVideoRect() {
    if (mounted) setState(() => _videoEpoch++);
  }

  /// Enlarges the existing stream. No retune, no second player.
  Future<void> openFullscreen() async {
    if (!mounted) return;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    // Only one Video widget may drive the native surface at a time.
    setState(() => _fullscreen = true);
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 150),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, __, ___) => _LiveFullscreen(state: this),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    if (mounted) setState(() {
      _fullscreen = false;
      _videoEpoch++;
    });
  }

  void toggleMute() => _toggleMute();
  bool get muted => _muted;
  LiveTvChannel? get currentChannel => widget.channel;

  /// Stop and release the stream (tab hidden, full screen opened, app paused).
  Future<void> suspend() async {
    _suspended = true;
    _generation++;
    await _teardown();
    if (mounted) setState(() => _loading = false);
  }

  /// Start again after [suspend].
  void resume() {
    if (!_suspended || _player != null || _vc != null || !_tickerEnabled) return;
    _suspended = false;
    if (widget.channel != null && mounted) _tune();
  }

  Future<void> _teardown() async {
    final player = _player;
    final vc = _vc;
    final session = _session;
    _player = null;
    _vc = null;
    _session = null;
    if (!_disposed) playerNotifier.value = null;
    try {
      await vc?.dispose();
    } catch (_) {}
    try {
      await player?.stop();
    } catch (_) {}
    try {
      await player?.dispose();
    } catch (e) {
      appLogger.d('Live preview player dispose failed', error: e);
    }
    try {
      await session?.discard();
    } catch (_) {}
  }

  Future<void> _tune() async {
    final channel = widget.channel;
    if (channel == null || !kLiveTvInlinePreview) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_useTexturePlayer) {
      // The current picture stays up until the new channel is playing.
      unawaited(_tuneTexture(channel, generation));
      return;
    }
    // Release the previous channel in the background: its server calls (stop
    // transcode, close tuner) no longer sit in front of the new tune. The
    // fields are detached synchronously inside _teardown, so nothing races.
    unawaited(_teardown());
    if (!mounted || generation != _generation) return;

    try {
      final multi = context.read<MultiServerProvider>();
      final info = liveTvServerInfoForChannel(multi, channel);
      final client = info == null ? null : multi.getClientForServer(ServerId(info.serverId));
      if (info == null || client == null) throw StateError('Live TV server unavailable');

      final session = await client.liveTv.startPlayback(
        channel.key,
        dvrKey: info.dvrKey,
        quality: kLiveTvPreviewQuality,
      );
      if (session == null) throw StateError('Channel could not be started');
      if (!mounted || generation != _generation) {
        unawaited(session.discard());
        return;
      }
      _session = session;

      var url = await session.streamUrlAt();
      if (url == null) throw StateError('No stream URL');
      url = _fasterHlsStart(url);
      if (!mounted || generation != _generation) return;

      await PlaybackCoordinator.instance.claimVideo();
      if (!mounted || generation != _generation) return;

      final player = Player();
      _player = player;
      if (Platform.isAndroid) await player.setLogLevel('warn');
      await player.setVolume(_muted ? 0 : 100);
      // Faster start for a live preview: shorter probing, no initial cache wait.
      for (final o in const {
        'cache-pause-initial': 'no',
        'cache-pause': 'no',
        'demuxer-lavf-analyzeduration': '1',
        'demuxer-lavf-probesize': '500000',
        'force-seekable': 'no',
      }.entries) {
        try {
          await player.setProperty(o.key, o.value);
        } catch (_) {}
      }
      await player.open(Media(url), isLive: true);
      if (!mounted || generation != _generation) return;
      appLogger.i('Live preview playing: ${channel.displayName}');
      playerNotifier.value = player;
      setState(() => _loading = false);
      // The native surface can hold its first frame until its size changes
      // (full screen "fixes" it). Re-attach the video once it is running so
      // the small view starts rendering live frames too.
      for (final ms in const [350, 1200]) {
        Future<void>.delayed(Duration(milliseconds: ms), () {
          if (!kIsWeb && mounted && generation == _generation && identical(_player, player) && !_fullscreen) {
            setState(() => _videoEpoch++);
          }
        });
      }
    } catch (e, st) {
      appLogger.w('Live preview failed', error: e, stackTrace: st);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Preview unavailable';
      });
    }
  }

  Future<void> _release(vp.VideoPlayerController? vc, LiveTvPlaybackSession? session) async {
    try {
      await vc?.dispose();
    } catch (_) {}
    try {
      await session?.discard();
    } catch (_) {}
  }

  /// Texture-player tune. Everything lives in locals until the new stream is
  /// really playing, then it replaces the old one in a single swap: no black
  /// gap, and a superseded/failed attempt cleans up after itself.
  Future<void> _tuneTexture(
      LiveTvChannel channel,
      int generation, {
        TranscodeQualityPreset quality = kLiveTvPreviewQuality,
        bool quiet = false,
      }) async {
    LiveTvPlaybackSession? session;
    vp.VideoPlayerController? vc;
    var committed = false;
    bool stale() => !mounted || generation != _generation;
    try {
      final multi = context.read<MultiServerProvider>();
      final info = liveTvServerInfoForChannel(multi, channel);
      final client = info == null ? null : multi.getClientForServer(ServerId(info.serverId));
      if (info == null || client == null) throw StateError('Live TV server unavailable');

      session = await client.liveTv.startPlayback(channel.key, dvrKey: info.dvrKey, quality: quality);
      if (session == null) throw StateError('Channel could not be started');
      if (stale()) return;

      var url = await session.streamUrlAt();
      if (url == null) throw StateError('No stream URL');
      url = _fasterHlsStart(url);
      if (stale()) return;

      await PlaybackCoordinator.instance.claimVideo();
      if (stale()) return;

      // AVPlayer (iOS/macOS) rejects a live HLS playlist that has no segments
      // yet (CoreMedia -12884); a fresh transcode needs a moment. Retry.
      appLogger.i('Live preview stream: ${Uri.parse(url).path}');
      Object? lastError;
      for (var attempt = 0; attempt < 4 && vc == null; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 1200 * attempt));
          if (stale()) return;
        }
        final candidate = vp.VideoPlayerController.networkUrl(
          Uri.parse(url),
          videoPlayerOptions: vp.VideoPlayerOptions(mixWithOthers: true),
        );
        try {
          await candidate.initialize();
          vc = candidate;
        } catch (e) {
          lastError = e;
          appLogger.d('Live preview attempt ${attempt + 1} failed', error: e);
          try {
            await candidate.dispose();
          } catch (_) {}
        }
      }
      final ready = vc;
      if (ready == null) throw lastError ?? StateError('Preview could not start');
      if (stale()) return;

      await ready.setVolume(0); // silent until it replaces the old picture
      await ready.setLooping(false);
      // A fresh HLS session starts a few segments behind live. Move it to just
      // before the live edge so it lines up with what was already on screen.
      try {
        final total = ready.value.duration;
        if (total > const Duration(seconds: 4)) {
          await ready.seekTo(total - const Duration(milliseconds: 1200));
        }
      } catch (_) {}
      await ready.play();
      if (stale()) return;

      final oldVc = _vc;
      final oldSession = _session;
      unawaited(oldVc?.setVolume(0));
      _vc = ready;
      _session = session;
      committed = true;
      await ready.setVolume(_muted ? 0 : 1);
      appLogger.i('Live preview playing (texture): ${channel.displayName}');
      playerNotifier.value = ready;
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
      unawaited(_release(oldVc, oldSession));
    } catch (e, st) {
      appLogger.w('Live preview failed (${quality.name})', error: e, stackTrace: st);
      if (stale()) return;
      // A background quality swap that fails just keeps the current picture.
      if (quiet && _vc != null) return;
      unawaited(_teardown());
      setState(() {
        _loading = false;
        _error = 'Preview unavailable';
      });
    } finally {
      if (!committed) unawaited(_release(vc, session));
    }
  }

  /// Jellyfin cuts live HLS into 6 s segments by default and the player waits
  /// for several before it moves, which is most of the "frozen first frame".
  /// Ask for short segments so playback gets going in a couple of seconds.
  static String _fasterHlsStart(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.path.toLowerCase().endsWith('.m3u8')) return url;
    final query = Map<String, String>.from(uri.queryParameters);
    query['SegmentLength'] = '2';
    query.putIfAbsent('MinSegments', () => '1');
    return uri.replace(queryParameters: query).toString();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    unawaited(_player?.setVolume(_muted ? 0 : 100));
    unawaited(_vc?.setVolume(_muted ? 0 : 1));
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final theme = Theme.of(context);
    final player = _player;
    final vc = _vc;
    final hasVideo = vc != null || (player != null && !_loading);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!hasVideo) const ColoredBox(color: Colors.black),
            if (hasVideo && vc != null) _TextureVideo(controller: vc, cover: true),
            // mpv draws on a native surface BEHIND Flutter, so cut a hole
            // through whatever is painted under it.
            if (hasVideo && player != null && !_fullscreen)
              const Positioned.fill(child: CustomPaint(painter: _HolePainter())),
            if (hasVideo && player != null && !_fullscreen)
              Video(key: ValueKey('v$_videoEpoch'), player: player, hasFirstFrame: _kAlwaysRevealed),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (!_loading && player == null && vc == null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      channel?.displayName ?? 'Select a channel',
                      style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
                      ),
                    if (channel != null && (!kLiveTvInlinePreview || _error != null))
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: FilledButton.icon(
                          onPressed: widget.onFullscreen,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Watch'),
                        ),
                      ),
                  ],
                ),
              ),
            // Bottom gradient + channel label.
            if (channel != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 18, 8, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xCC000000)],
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [if (channel.number != null) channel.number!, channel.displayName].join('  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: _muted ? 'Unmute' : 'Mute',
                        icon: Icon(_muted ? Symbols.volume_off_rounded : Symbols.volume_up_rounded, color: Colors.white),
                        onPressed: (player == null && vc == null) ? null : _toggleMute,
                      ),
                      if (widget.showFullscreenButton)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Full screen',
                          icon: const Icon(Symbols.fullscreen_rounded, color: Colors.white),
                          onPressed: widget.onFullscreen,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Clears whatever opaque pixels were painted under the video area so the
/// native video surface behind Flutter shows through.
class _HolePainter extends CustomPainter {
  const _HolePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Full-screen view of the SAME stream the mini player is running.
class _LiveFullscreen extends StatefulWidget {
  final LiveTvPreviewState state;
  const _LiveFullscreen({required this.state});

  @override
  State<_LiveFullscreen> createState() => _LiveFullscreenState();
}

class _LiveFullscreenState extends State<_LiveFullscreen> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _bump();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _bump() {
    _hideTimer?.cancel();
    if (!_showControls) setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final ch = st.currentChannel;
    return Scaffold(
      backgroundColor: _useTexturePlayer ? Colors.black : Colors.transparent,
      body: PopScope(
        canPop: true,
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) _bump();
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _bump,
            child: ValueListenableBuilder<Object?>(
              valueListenable: st.playerNotifier,
              builder: (context, player, _) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (player == null)
                      const ColoredBox(color: Colors.black, child: Center(child: CircularProgressIndicator()))
                    else if (player is vp.VideoPlayerController)
                      _TextureVideo(controller: player, cover: false)
                    else if (player is Player)
                        Video(key: ValueKey(player), player: player, hasFirstFrame: _kAlwaysRevealed),
                    AnimatedOpacity(
                      opacity: _showControls ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_showControls,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            padding: EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 8, 8, 24),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0xB3000000), Colors.transparent],
                              ),
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  autofocus: true,
                                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                                  onPressed: () => Navigator.of(context).maybePop(),
                                ),
                                Expanded(
                                  child: Text(
                                    [if (ch?.number != null) ch!.number!, ch?.displayName ?? ''].join('  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 18),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    st.muted ? Symbols.volume_off_rounded : Symbols.volume_up_rounded,
                                    color: Colors.white,
                                  ),
                                  onPressed: () {
                                    st.toggleMute();
                                    setState(() {});
                                    _bump();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Flutter-texture video, sized like a normal widget (cover = fill and crop,
/// otherwise letterbox).
class _TextureVideo extends StatelessWidget {
  final vp.VideoPlayerController controller;
  final bool cover;
  const _TextureVideo({required this.controller, required this.cover});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<vp.VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        if (!v.isInitialized || v.size.isEmpty) return const ColoredBox(color: Colors.black);
        final video = SizedBox(width: v.size.width, height: v.size.height, child: vp.VideoPlayer(controller));
        return ColoredBox(
          color: Colors.black,
          child: ClipRect(
            child: FittedBox(fit: cover ? BoxFit.cover : BoxFit.contain, child: video),
          ),
        );
      },
    );
  }
}
