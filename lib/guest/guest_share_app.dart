import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../mpv/mpv.dart';
import '../services/atlas_share/atlas_share_api.dart';
import '../services/fullscreen_state_manager.dart';
import 'guest_web_stub.dart' if (dart.library.js_interop) 'guest_web_web.dart';

/// Guest mode: someone opened a public share link
/// (`https://atlas.besupernow.com/web/?share=CODE`). No account, no device
/// approval, no app shell: just the shared title and a player. Leaving it in
/// any way lands on the normal app start (sign-in or the device gate).
class GuestShareApp extends StatelessWidget {
  const GuestShareApp({super.key, required this.code});

  final String code;

  static const _accent = Color(0xFF4A6BF6);
  static const _bg = Color(0xFF0E0F12);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: _accent, brightness: Brightness.dark, surface: _bg);
    return MaterialApp(
      title: 'Atlas+',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, scaffoldBackgroundColor: _bg, useMaterial3: true),
      home: _GuestHome(code: code),
    );
  }
}

class _GuestHome extends StatefulWidget {
  const _GuestHome({required this.code});

  final String code;

  @override
  State<_GuestHome> createState() => _GuestHomeState();
}

class _GuestHomeState extends State<_GuestHome> {
  AtlasShareSession? _session;
  String? _error;

  @override
  void initState() {
    super.initState();
    _redeem();
  }

  Future<void> _redeem() async {
    // A reload in the same tab reuses the session instead of spending the link again.
    final stored = guestStoredSession(widget.code);
    if (stored != null) {
      try {
        final session = AtlasShareSession(jsonDecode(stored) as Map<String, dynamic>);
        if (session.expiresAt.isAfter(DateTime.now())) {
          setState(() => _session = session);
          return;
        }
      } catch (_) {}
      guestStoreSession(widget.code, null);
    }
    try {
      final session = await AtlasShareApi.redeem(widget.code);
      guestStoreSession(widget.code, jsonEncode(session.json));
      if (mounted) setState(() => _session = session);
    } on AtlasShareException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reach Atlas+. Check your connection and try again.");
    }
  }

  Future<void> _watch() async {
    final session = _session!;
    final finished = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _GuestPlayerScreen(session: session)),
    );
    // Any exit from the media ends guest mode.
    if (finished != null || mounted) await _leave();
  }

  Future<void> _leave() async {
    final session = _session;
    if (session != null) await AtlasShareApi.end(session.id);
    guestStoreSession(widget.code, null);
    guestLeaveToApp();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (_error != null) return _GuestMessage(message: _error!, onContinue: _leave);
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _GuestLanding(session: session, onWatch: _watch, onSignIn: _leave);
  }
}

class _GuestMessage extends StatelessWidget {
  const _GuestMessage({required this.message, required this.onContinue});

  final String message;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Symbols.link_off_rounded, size: 48, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                const SizedBox(height: 24),
                FilledButton(onPressed: onContinue, child: const Text('Go to Atlas+')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GuestLanding extends StatelessWidget {
  const _GuestLanding({required this.session, required this.onWatch, required this.onSignIn});

  final AtlasShareSession session;
  final VoidCallback onWatch;
  final VoidCallback onSignIn;

  String _expiresText() {
    final left = session.expiresAt.difference(DateTime.now());
    final when = left.inHours >= 48
        ? '${left.inDays} days'
        : left.inHours >= 1
        ? '${left.inHours} hr${left.inHours == 1 ? '' : 's'}'
        : '${left.inMinutes.clamp(1, 59)} min';
    return 'Available for $when${session.singleUse ? ' · this link works once' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = session.item;
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 800;
    final meta = [
      if (item.isEpisode && item.seriesName != null) item.seriesName!,
      if (item.isEpisode && item.season != null && item.episode != null) 'S${item.season} E${item.episode}',
      if (item.year != null) '${item.year}',
      if (item.rating != null) item.rating!,
      if (item.runtime != null && item.runtime!.inMinutes > 0)
        item.runtime!.inHours > 0
            ? '${item.runtime!.inHours}h ${item.runtime!.inMinutes % 60}m'
            : '${item.runtime!.inMinutes}m',
    ].join('  ·  ');

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (item.backdropUrl != null)
            Image.network(item.backdropUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: wide ? Alignment.centerLeft : Alignment.bottomCenter,
                end: wide ? Alignment.centerRight : Alignment.topCenter,
                colors: [
                  theme.scaffoldBackgroundColor,
                  theme.scaffoldBackgroundColor.withValues(alpha: 0.85),
                  theme.scaffoldBackgroundColor.withValues(alpha: 0.1),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: wide ? Alignment.centerLeft : Alignment.bottomCenter,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(wide ? 64 : 24, 24, 24, wide ? 24 : 40),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.sharedBy == null
                            ? 'Shared with you on Atlas+'
                            : '${session.sharedBy} shared this with you',
                        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                      const SizedBox(height: 12),
                      if (item.logoUrl != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: wide ? 140 : 100, maxWidth: 420),
                          child: Image.network(
                            item.logoUrl!,
                            alignment: Alignment.centerLeft,
                            errorBuilder: (_, _, _) => _Title(text: item.title),
                          ),
                        )
                      else
                        _Title(text: item.title),
                      if (item.isEpisode) ...[
                        const SizedBox(height: 8),
                        Text(item.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      ],
                      const SizedBox(height: 10),
                      if (meta.isNotEmpty)
                        Text(meta, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                      if (item.overview != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          item.overview!,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.85), height: 1.4),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        autofocus: true,
                        onPressed: onWatch,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          textStyle: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                        label: const Text('Watch now'),
                      ),
                      const SizedBox(height: 14),
                      Text(_expiresText(), style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60)),
                      const SizedBox(height: 4),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                        onPressed: onSignIn,
                        child: const Text('Have Atlas+? Sign in instead'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, height: 1.05),
  );
}

/// A small, self-contained player for guests: play/pause, seek, fullscreen,
/// close. Pops when the guest closes it or the title ends.
class _GuestPlayerScreen extends StatefulWidget {
  const _GuestPlayerScreen({required this.session});

  final AtlasShareSession session;

  @override
  State<_GuestPlayerScreen> createState() => _GuestPlayerScreenState();
}

class _GuestPlayerScreenState extends State<_GuestPlayerScreen> {
  late final Player _player = Player();
  final List<StreamSubscription<Object?>> _subs = [];
  bool _playing = false;
  bool _buffering = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  double? _dragValue;
  String? _error;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.streams.playing.listen((v) => setState(() => _playing = v)))
      ..add(_player.streams.buffering.listen((v) => setState(() => _buffering = v)))
      ..add(_player.streams.position.listen((v) => setState(() => _position = v)))
      ..add(_player.streams.duration.listen((v) => setState(() => _duration = v)))
      ..add(_player.streams.completed.listen((done) {
        if (done) _close();
      }))
      ..add(_player.streams.error.listen((e) => setState(() => _error = 'Playback stopped. The link may have expired.')));
    unawaited(_player.open(Media(widget.session.streamUrl)));
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _poke() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    unawaited(FullscreenStateManager().exitFullscreenIfActive());
    if (mounted) Navigator.of(context).pop(true);
  }

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    _poke();
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      unawaited(_player.playOrPause());
    } else if (k == LogicalKeyboardKey.arrowRight) {
      unawaited(_player.seek(_position + const Duration(seconds: 10)));
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      unawaited(_player.seek(_position - const Duration(seconds: 10)));
    } else if (k == LogicalKeyboardKey.keyF) {
      unawaited(FullscreenStateManager().toggleFullscreen());
    } else if (k == LogicalKeyboardKey.escape) {
      unawaited(_close());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.session.item;
    final max = _duration.inMilliseconds.toDouble();
    final value = (_dragValue ?? _position.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 0.0 : max);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(FullscreenStateManager().exitFullscreenIfActive());
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _poke(),
            cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _poke();
                unawaited(_player.playOrPause());
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(player: _player),
                  if (_buffering && _error == null) const Center(child: CircularProgressIndicator()),
                  if (_error != null)
                    Center(
                      child: Text(_error!, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                    ),
                  AnimatedOpacity(
                    opacity: _controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xAA000000), Colors.transparent, Colors.transparent, Color(0xCC000000)],
                            stops: [0, 0.2, 0.7, 1],
                          ),
                        ),
                        child: SafeArea(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                                child: Row(
                                  children: [
                                    IconButton(
                                      tooltip: 'Close',
                                      onPressed: _close,
                                      icon: const Icon(Symbols.close_rounded, color: Colors.white),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        item.isEpisode && item.seriesName != null
                                            ? '${item.seriesName} · ${item.title}'
                                            : item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Row(
                                  children: [
                                    IconButton(
                                      tooltip: _playing ? 'Pause' : 'Play',
                                      onPressed: () => _player.playOrPause(),
                                      icon: Icon(
                                        _playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                                        fill: 1,
                                        size: 32,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Text(_fmt(_position), style: theme.textTheme.bodySmall),
                                    Expanded(
                                      child: Slider(
                                        value: value,
                                        max: max <= 0 ? 1 : max,
                                        onChanged: max <= 0 ? null : (v) => setState(() => _dragValue = v),
                                        onChangeEnd: (v) {
                                          _dragValue = null;
                                          unawaited(_player.seek(Duration(milliseconds: v.round())));
                                          _scheduleHide();
                                        },
                                      ),
                                    ),
                                    Text(_fmt(_duration), style: theme.textTheme.bodySmall),
                                    IconButton(
                                      tooltip: 'Fullscreen',
                                      onPressed: () => FullscreenStateManager().toggleFullscreen(),
                                      icon: const Icon(Symbols.fullscreen_rounded, color: Colors.white),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
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
}
