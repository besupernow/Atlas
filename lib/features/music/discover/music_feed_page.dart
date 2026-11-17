import 'dart:async';

import 'package:flutter/material.dart';

import '../data/music_sources.dart';
import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import 'allseerr_music.dart';
import 'deezer.dart';
import 'discover_feed.dart';
import 'discover_models.dart';
import 'discover_widgets.dart';
import 'listenbrainz.dart';
import '../../../services/music/music_bans.dart';

/// One row of a feed page and how to load it. Rows load side by side and appear as they
/// arrive; a row that fails or comes back empty is left out.
class MusicFeedSpec {
  const MusicFeedSpec({required this.id, required this.load, this.onItemTap});

  final String id;
  final Future<MusicFeedRow?> Function(MusicDiscovery discovery) load;
  final ValueChanged<MusicFeedItem>? onItemTap;
}

/// Atlas: a music page made of a hero banner and rows (Home and New).
class MusicFeedPage extends StatefulWidget {
  const MusicFeedPage({
    super.key,
    required this.title,
    required this.specs,
    this.hero,
    this.heroLoader,
    required this.heroEyebrow,
    this.actions = const [],
    this.header,
    this.emptyMessage = MusicStrings.nothingYet,
  });

  final String title;
  final List<MusicFeedSpec> specs;

  /// Picks the banner's items once rows have loaded (by row id).
  final List<MusicFeedItem> Function(Map<String, MusicFeedRow> rows)? hero;

  /// Or loads the banner's items on their own.
  final Future<List<MusicFeedItem>> Function(MusicDiscovery discovery)? heroLoader;
  final String heroEyebrow;
  final List<Widget> actions;

  /// Shown under the banner (the ListenBrainz card, say).
  final Widget Function(BuildContext context)? header;
  final String emptyMessage;

  @override
  State<MusicFeedPage> createState() => _MusicFeedPageState();
}

/// What a feed page last showed, kept for the session so coming back to it (or the app
/// rebuilding it) shows the rows at once instead of filling in again.
class _FeedCache {
  _FeedCache(this.rows, this.hero, this.sources, this.at);

  final Map<String, MusicFeedRow> rows;
  final List<MusicFeedItem> hero;
  final String? sources;
  final DateTime at;
}

class _MusicFeedPageState extends State<MusicFeedPage> {
  static final Map<String, _FeedCache> _cache = {};

  final Map<String, MusicFeedRow> _rows = {};
  final Set<String> _pending = {};
  List<MusicFeedItem> _loadedHero = const [];
  int _generation = 0;
  String? _sources;
  Timer? _sourcesSettle;

  /// For a moment after a load starts, a row still loading holds back the rows below it. After
  /// that, slow rows don't keep the rest of the page waiting.
  bool _holdInOrder = false;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    ListenBrainzAccount.changes.addListener(_reload);
    MusicBans.instance.addListener(_bansChanged);
    if (_cache[widget.title] case final cached?) {
      _rows.addAll(cached.rows);
      _loadedHero = cached.hero;
    }
  }

  /// Loads the first time the libraries (and Allseerr) are there, and again whenever they
  /// change, so the page never sits empty waiting for a pull to refresh. At startup those
  /// arrive one after another, so changes settle for a moment and load once; what's on screen
  /// stays until the new rows replace it.
  /// Called from build (where watching providers is allowed).
  void _watchSources() {
    final sources = watchMusicSources(context);
    if (sources == _sources) return;
    final first = _sources == null;
    _sources = sources;
    final cached = _cache[widget.title];
    // Just shown from the cache with the same sources: nothing to do yet.
    if (first &&
        cached != null &&
        cached.sources == sources &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 10)) {
      return;
    }
    _sourcesSettle?.cancel();
    _sourcesSettle = Timer(Duration(milliseconds: first && _rows.isEmpty ? 0 : 450), () {
      if (!mounted) return;
      unawaited(_load(refreshCaches: !first));
      // The ListenBrainz name lives on the server; a change reloads through [_reload].
      unawaited(ListenBrainzAccount.refresh(context, force: !first));
    });
  }

  @override
  void dispose() {
    _sourcesSettle?.cancel();
    _holdTimer?.cancel();
    ListenBrainzAccount.changes.removeListener(_reload);
    MusicBans.instance.removeListener(_bansChanged);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  /// Something was hidden or unhidden: the rows filter themselves, they just need drawing.
  void _bansChanged() {
    if (mounted) setState(() {});
  }

  /// Load every row. Rows already showing stay until their new version arrives (or the row
  /// comes back empty), so nothing blinks out and back in.
  Future<void> _load({bool refreshCaches = false}) async {
    if (refreshCaches) {
      MusicDiscovery.invalidate();
      Deezer.clearCache();
    }
    final generation = ++_generation;
    final discovery = MusicDiscovery.of(context);
    final heroLoader = widget.heroLoader;
    if (heroLoader != null) {
      unawaited(
        quietly(heroLoader(discovery), const <MusicFeedItem>[], 'banner').then((items) {
          if (mounted && generation == _generation && items.isNotEmpty) setState(() => _loadedHero = items);
        }),
      );
    }
    setState(() {
      _pending
        ..clear()
        ..addAll(widget.specs.map((spec) => spec.id));
      // Only an empty page fills in order; one already showing rows just updates them.
      _holdInOrder = _rows.isEmpty;
    });
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _holdInOrder = false);
    });
    await Future.wait([
      for (final spec in widget.specs)
        () async {
          MusicFeedRow? row;
          try {
            row = await spec.load(discovery);
          } catch (_) {
            row = null;
          }
          if (!mounted || generation != _generation) return;
          setState(() {
            _pending.remove(spec.id);
            if (row == null || row.isEmpty) {
              _rows.remove(spec.id);
            } else {
              _rows[spec.id] = row;
            }
          });
        }(),
    ]);
    if (mounted && generation == _generation) {
      _cache[widget.title] = _FeedCache(Map.of(_rows), _loadedHero, _sources, DateTime.now());
    }
  }

  void _openSeeAll(MusicFeedRow row, ValueChanged<MusicFeedItem>? onItemTap) {
    final load = row.seeAll;
    if (load == null) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MusicFeedGridPage(title: row.title, load: load, onItemTap: onItemTap),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _watchSources();
    final focus = MusicShellFocus.maybeOf(context);
    final hero = [for (final item in widget.hero?.call(_rows) ?? _loadedHero) if (!item.isHidden) item];
    final loading = _pending.isNotEmpty;
    // Rows show in page order: one still loading holds back the ones below it (unless they're
    // already on screen), so nothing pops in above what you're looking at.
    final ordered = <(MusicFeedSpec, MusicFeedRow)>[];
    for (final spec in widget.specs) {
      final row = _rows[spec.id];
      if (row != null) {
        ordered.add((spec, row));
      } else if (_pending.contains(spec.id) && _holdInOrder) {
        break;
      }
    }
    return MusicPage(
      title: widget.title,
      actions: widget.actions,
      onRefresh: () => _load(refreshCaches: true),
      children: [
        if (hero.isNotEmpty)
          MusicHeroCarousel(items: hero, eyebrow: widget.heroEyebrow, onNavigateToSidebar: focus?.focusRail),
        if (widget.header case final header?) header(context),
        for (final (spec, row) in ordered)
          if (row.custom case final custom?)
            KeyedSubtree(key: ValueKey(row.id), child: custom(context, focus?.focusRail))
          else
            MusicFeedShelf(
              key: ValueKey(row.id),
              title: row.title,
              subtitle: row.subtitle,
              items: row.items,
              large: row.large,
              onItemTap: spec.onItemTap,
              onNavigateToSidebar: focus?.focusRail,
              onSeeAll: row.seeAll == null ? null : () => _openSeeAll(row, spec.onItemTap),
              kicker: row.kicker,
              ranked: row.ranked,
            ),
        if (loading && ordered.length < 2)
          const MusicPagePlaceholder()
        else if (!loading && ordered.isEmpty)
          MusicPagePlaceholder(message: widget.emptyMessage),
      ],
    );
  }
}

/// Atlas: a row's full list ("see all"), as a grid.
class MusicFeedGridPage extends StatefulWidget {
  const MusicFeedGridPage({super.key, required this.title, required this.load, this.onItemTap});

  final String title;
  final Future<List<MusicFeedItem>> Function() load;
  final ValueChanged<MusicFeedItem>? onItemTap;

  @override
  State<MusicFeedGridPage> createState() => _MusicFeedGridPageState();
}

class _MusicFeedGridPageState extends State<MusicFeedGridPage> {
  List<MusicFeedItem>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.load().then(
        (items) {
          if (mounted) setState(() => _items = items);
        },
        onError: (Object _) {
          if (mounted) setState(() => _failed = true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final size = MusicFeedShelf.cardSize(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: items == null
          ? MusicPagePlaceholder(message: _failed ? MusicStrings.loadFailed : null)
          : items.isEmpty
          ? const MusicPagePlaceholder(message: MusicStrings.nothingYet)
          : GridView.builder(
              padding: MusicPage.padding(
                context,
              ).add(EdgeInsets.only(top: 12, bottom: 24 + MusicPage.bottomRoom(context))),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: size + 16,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                childAspectRatio: size / (size + 62),
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => LayoutBuilder(
                builder: (context, constraints) => MusicFeedCard(
                  item: items[index],
                  size: constraints.maxWidth,
                  onTap: widget.onItemTap,
                ),
              ),
            ),
    );
  }
}
