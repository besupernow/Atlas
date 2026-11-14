import 'dart:async';

import 'package:flutter/material.dart';

import '../music_strings.dart';
import '../shell/music_shell_focus.dart';
import '../widgets/music_page.dart';
import 'discover_feed.dart';
import 'discover_models.dart';
import 'discover_widgets.dart';
import 'listenbrainz.dart';

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
    required this.hero,
    required this.heroEyebrow,
    this.actions = const [],
    this.header,
    this.emptyMessage = MusicStrings.nothingYet,
  });

  final String title;
  final List<MusicFeedSpec> specs;

  /// Picks the banner's items once rows have loaded (by row id).
  final List<MusicFeedItem> Function(Map<String, MusicFeedRow> rows) hero;
  final String heroEyebrow;
  final List<Widget> actions;

  /// Shown under the banner (the ListenBrainz card, say).
  final Widget Function(BuildContext context)? header;
  final String emptyMessage;

  @override
  State<MusicFeedPage> createState() => _MusicFeedPageState();
}

class _MusicFeedPageState extends State<MusicFeedPage> {
  final Map<String, MusicFeedRow> _rows = {};
  final Set<String> _pending = {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ListenBrainzAccount.changes.addListener(_reload);
    unawaited(_load());
  }

  @override
  void dispose() {
    ListenBrainzAccount.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load({bool fresh = false}) async {
    if (fresh) MusicDiscovery.invalidate();
    final generation = ++_generation;
    final discovery = MusicDiscovery.of(context);
    setState(() {
      _pending
        ..clear()
        ..addAll(widget.specs.map((spec) => spec.id));
      if (fresh) _rows.clear();
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
    final focus = MusicShellFocus.maybeOf(context);
    final hero = widget.hero(_rows);
    final loading = _pending.isNotEmpty;
    final ordered = [
      for (final spec in widget.specs)
        if (_rows[spec.id] case final row?) (spec, row),
    ];
    return MusicPage(
      title: widget.title,
      actions: widget.actions,
      onRefresh: () => _load(fresh: true),
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
