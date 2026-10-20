import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../media/media_item.dart';
import '../mixins/refreshable.dart';
import '../providers/multi_server_provider.dart';
import '../services/jellyfin_client.dart';
import '../utils/app_logger.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/platform_detector.dart';
import '../widgets/focusable_media_card.dart';

/// Jellyfin collections carrying this tag show up as categories.
const String kAtlasCategoryTag = 'atlas-category';

/// Curated "Categories" tab (Tubi style). Categories are Jellyfin collections
/// tagged [kAtlasCategoryTag]; add/remove/rename them in Jellyfin.
///
/// TV / desktop: scrollable category list on the left, media grid on the right.
/// Mobile: category list; tapping a row opens that collection's page.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> with ManualRefreshable, FullRefreshable, FocusableTab {
  List<MediaItem> _categories = const [];
  bool _loading = true;
  String? _error;

  MediaItem? _selected;
  List<MediaItem> _items = const [];
  bool _itemsLoading = false;

  final Map<String, FocusNode> _nodes = {};

  bool _pendingFocus = false;

  JellyfinClient? _client() {
    final multi = context.read<MultiServerProvider>();
    for (final id in multi.onlineServerIds) {
      final c = multi.getClientForServer(ServerId(id));
      if (c is JellyfinClient) return c;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  void manualRefresh() => unawaited(_load());

  @override
  void fullRefresh() => unawaited(_load());

  @override
  void primeRefresh() {
    if (_categories.isEmpty) unawaited(_load());
  }

  @override
  void focusActiveTabIfReady() {
    _pendingFocus = true;
    _tryFocusFirst();
  }

  void _tryFocusFirst() {
    if (!_pendingFocus || !mounted) return;
    if (_categories.isEmpty) return; // _load() calls this again once loaded
    final node = _nodes[_categories.first.id];
    if (node == null || node.context == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryFocusFirst());
      return;
    }
    _pendingFocus = false;
    node.requestFocus();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryFocusFirst());
    try {
      final client = _client();
      if (client == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Not connected';
        });
        return;
      }
      final cats = await client.fetchTaggedCollections(kAtlasCategoryTag);
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _loading = false;
      });
      if (PlatformDetector.shouldUseSideNavigation(context) && cats.isNotEmpty) {
        final keep = cats.where((c) => c.id == _selected?.id).firstOrNull;
        unawaited(_select(keep ?? cats.first));
      }
    } catch (e, st) {
      appLogger.w('Categories load failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load categories';
      });
    }
  }

  Future<void> _select(MediaItem category) async {
    setState(() {
      _selected = category;
      _itemsLoading = true;
    });
    try {
      final client = _client();
      if (client == null) return;
      final page = await client.fetchChildrenPage(category.id, start: 0, size: 200);
      if (!mounted || _selected?.id != category.id) return;
      setState(() {
        _items = page.items;
        _itemsLoading = false;
      });
    } catch (e, st) {
      appLogger.w('Category items failed', error: e, stackTrace: st);
      if (!mounted || _selected?.id != category.id) return;
      setState(() {
        _items = const [];
        _itemsLoading = false;
      });
    }
  }

  void _onCategoryTap(MediaItem category) {
    if (PlatformDetector.shouldUseSideNavigation(context)) {
      unawaited(_select(category));
    } else {
      // Mobile: open the collection's own page.
      unawaited(navigateToMediaItem(context, category));
    }
  }

  Widget _buildCategoryList({required bool wide}) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_categories.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No categories yet', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(12, wide ? 4 : 8, 12, 16),
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final c = _categories[i];
        final node = _nodes.putIfAbsent(c.id, () => FocusNode(debugLabel: 'category_${c.id}'));
        return _CategoryTile(
          title: c.title ?? '',
          focusNode: node,
          selected: wide && _selected?.id == c.id,
          showChevron: !wide,
          // On TV/desktop the grid follows focus, so moving down the list
          // previews each category without pressing select.
          onFocused: wide ? () => _select(c) : null,
          onTap: () => _onCategoryTap(c),
        );
      },
    );
  }

  Widget _buildGrid() {
    final theme = Theme.of(context);
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Text(
            selected?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (selected != null && !_itemsLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              _items.length == 1 ? '1 title' : '${_items.length} titles',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            ),
          ),
        Expanded(
          child: _itemsLoading
              ? const Center(child: CircularProgressIndicator())
              : (selected == null || _items.isEmpty)
              ? const Center(child: Text('Nothing here yet'))
              : GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              childAspectRatio: 0.52,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) => FocusableMediaCard(item: _items[i]),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = PlatformDetector.shouldUseSideNavigation(context);
    final theme = Theme.of(context);

    if (!wide) {
      return Scaffold(
        appBar: AppBar(title: const Text('Categories'), backgroundColor: theme.scaffoldBackgroundColor),
        body: RefreshIndicator(onRefresh: _load, child: _buildCategoryList(wide: false)),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                    child: Text(
                      'Categories',
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(child: _buildCategoryList(wide: true)),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: theme.dividerColor.withValues(alpha: 0.2)),
            Expanded(child: _buildGrid()),
          ],
        ),
      ),
    );
  }
}

class _CategoryPill extends StatefulWidget {
  final String title;
  final FocusNode focusNode;
  final bool selected;
  final bool showChevron;
  final VoidCallback onTap;
  final VoidCallback? onFocused;

  const _CategoryPill({
    required this.title,
    required this.focusNode,
    required this.selected,
    required this.showChevron,
    required this.onTap,
    this.onFocused,
  });

  @override
  State<_CategoryPill> createState() => _CategoryPillState();
}

class _CategoryPillState extends State<_CategoryPill> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.selected || _focused;
    final bg = _focused
        ? scheme.primary.withValues(alpha: 0.28)
        : widget.selected
        ? scheme.primary.withValues(alpha: 0.16)
        : scheme.onSurface.withValues(alpha: 0.05);
    final fg = active ? scheme.primary : scheme.onSurface.withValues(alpha: 0.85);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _focused ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          focusNode: widget.focusNode,
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          onFocusChange: (focused) {
            setState(() => _focused = focused);
            if (focused) widget.onFocused?.call();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: active ? FontWeight.w700 : FontWeight.w600, color: fg),
                  ),
                ),
                if (widget.showChevron) Icon(Icons.chevron_right_rounded, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded, focus-aware category row.
class _CategoryTile extends StatefulWidget {
  final String title;
  final FocusNode focusNode;
  final bool selected;
  final bool showChevron;
  final VoidCallback onTap;
  final VoidCallback? onFocused;

  const _CategoryTile({
    required this.title,
    required this.focusNode,
    required this.selected,
    required this.showChevron,
    required this.onTap,
    this.onFocused,
  });

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.selected || _focused;
    final bg = _focused
        ? scheme.primary.withValues(alpha: 0.22)
        : widget.selected
        ? scheme.primary.withValues(alpha: 0.12)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.35);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _focused ? scheme.primary : Colors.transparent, width: 1.5),
      ),
      child: InkWell(
        focusNode: widget.focusNode,
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onTap,
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocused?.call();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? scheme.primary : null,
                  ),
                ),
              ),
              if (widget.showChevron) const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
