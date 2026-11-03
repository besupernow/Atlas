import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_wrapper.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../services/jellyfin_client.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/dialog_action_button.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/focused_scroll_scaffold.dart';
import '../widgets/loading_indicator_box.dart';

/// Jellyfin web's "Identify": search the metadata providers for the right
/// title and re-match the item to it. Movies and series only.
///
/// Pops `true` when the item was re-identified.
class IdentifyScreen extends StatefulWidget {
  const IdentifyScreen({super.key, required this.client, required this.item});

  final JellyfinClient client;
  final MediaItem item;

  static bool supports(MediaItem item) => item.kind == MediaKind.movie || item.kind == MediaKind.show;

  @override
  State<IdentifyScreen> createState() => _IdentifyScreenState();
}

class _IdentifyScreenState extends State<IdentifyScreen> {
  final _name = TextEditingController();
  final _year = TextEditingController();
  final _imdb = TextEditingController();
  final _tmdb = TextEditingController();
  final _tvdb = TextEditingController();

  String? _path;
  bool _searching = false;
  bool _applying = false;
  List<Map<String, dynamic>>? _results;

  String get _searchType => widget.item.kind == MediaKind.movie ? 'Movie' : 'Series';

  @override
  void initState() {
    super.initState();
    _name.text = widget.item.title ?? '';
    if (widget.item.year != null) _year.text = '${widget.item.year}';
    _prefill();
  }

  /// Path and current provider IDs, so a re-match starts from what's there.
  Future<void> _prefill() async {
    try {
      final raw = await widget.client.fetchEditableMetadataItem(widget.item.id);
      if (!mounted || raw == null) return;
      final ids = raw['ProviderIds'];
      setState(() {
        _path = raw['Path'] as String?;
        if (ids is Map) {
          _imdb.text = ids['Imdb']?.toString() ?? '';
          _tmdb.text = ids['Tmdb']?.toString() ?? '';
          _tvdb.text = ids['Tvdb']?.toString() ?? '';
        }
      });
    } catch (e) {
      appLogger.w('Identify: could not load current IDs', error: e);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _year, _imdb, _tmdb, _tvdb]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results = null;
    });
    try {
      final results = await widget.client.remoteSearch(
        widget.item.id,
        searchType: _searchType,
        name: _name.text,
        year: int.tryParse(_year.text.trim()),
        providerIds: {
          if (_imdb.text.trim().isNotEmpty) 'Imdb': _imdb.text.trim(),
          if (_tmdb.text.trim().isNotEmpty) 'Tmdb': _tmdb.text.trim(),
          if (_tvdb.text.trim().isNotEmpty) 'Tvdb': _tvdb.text.trim(),
        },
      );
      if (mounted) setState(() => _results = results);
    } catch (e, st) {
      appLogger.e('Identify search failed', error: e, stackTrace: st);
      if (mounted) showErrorSnackBar(context, "Search failed. Check the server can reach its metadata providers.");
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _apply(Map<String, dynamic> result) async {
    final replaceImages = await showScopedDialog<bool>(
      context: context,
      builder: (dialogContext) => _ConfirmApplyDialog(name: _resultTitle(result)),
    );
    if (replaceImages == null || !mounted) return;
    setState(() => _applying = true);
    try {
      final ok = await widget.client.applyRemoteSearchResult(widget.item.id, result, replaceAllImages: replaceImages);
      if (!mounted) return;
      if (ok) {
        showSuccessSnackBar(context, 'Identified as ${_resultTitle(result)}. Metadata is updating.');
        Navigator.of(context).pop(true);
        return;
      }
      showErrorSnackBar(context, "Couldn't apply that match.");
    } catch (e, st) {
      appLogger.e('Identify apply failed', error: e, stackTrace: st);
      if (mounted) showErrorSnackBar(context, "Couldn't apply that match.");
    }
    if (mounted) setState(() => _applying = false);
  }

  static String _resultTitle(Map<String, dynamic> r) {
    final name = r['Name'] as String? ?? 'Unknown';
    final year = r['ProductionYear'];
    return year == null ? name : '$name ($year)';
  }

  Widget _field(TextEditingController c, String label, {bool number = false, bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        autofocus: autofocus,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _searching ? null : _search(),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    final isMovie = widget.item.kind == MediaKind.movie;
    return PopScope(
      canPop: !_applying,
      child: FocusedScrollScaffold(
        title: const Text('Identify'),
        slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Enter one or more search criteria. Remove criteria to get more results.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (_path != null) ...[
                        const SizedBox(height: 12),
                        Text('Path', style: theme.textTheme.labelLarge),
                        SelectableText(_path!, style: theme.textTheme.bodySmall),
                      ],
                      const SizedBox(height: 16),
                      _field(_name, 'Name', autofocus: true),
                      _field(_year, 'Year', number: true),
                      _field(_imdb, 'IMDb ID'),
                      _field(_tmdb, isMovie ? 'TMDB movie ID' : 'TMDB series ID', number: true),
                      if (!isMovie) _field(_tvdb, 'TVDB ID', number: true),
                      const SizedBox(height: 4),
                      Align(
                        child: FocusableButton(
                          onPressed: _searching || _applying ? null : _search,
                          child: FilledButton.icon(
                            onPressed: _searching || _applying ? null : _search,
                            icon: const AppIcon(Symbols.search_rounded, fill: 1),
                            label: Text(_searching ? 'Searching…' : 'Search'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_searching || _applying)
            LoadingIndicatorBox.sliver
          else if (results != null && results.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No matches found.'))),
            )
          else if (results != null)
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.52,
                  ),
                  delegate: SliverChildBuilderDelegate(
                        (context, index) => _ResultCard(result: results[index], onSelect: () => _apply(results[index])),
                    childCount: results.length,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.onSelect});

  final Map<String, dynamic> result;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = result['ImageUrl'] as String?;
    final year = result['ProductionYear'];
    final provider = result['SearchProviderName'] as String?;
    return FocusableWrapper(
      onSelect: onSelect,
      semanticLabel: result['Name'] as String? ?? 'Result',
      delegateFocusBorder: false,
      child: GestureDetector(
        onTap: onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHigh,
                  child: image == null || image.isEmpty
                      ? const Center(child: AppIcon(Symbols.image_not_supported_rounded, fill: 1))
                      : Image.network(
                    image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                    const Center(child: AppIcon(Symbols.image_not_supported_rounded, fill: 1)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              result['Name'] as String? ?? 'Unknown',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              [if (year != null) '$year', if (provider != null && provider.isNotEmpty) provider].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirms the match. Pops with whether to replace the existing artwork,
/// or null when cancelled.
class _ConfirmApplyDialog extends StatefulWidget {
  const _ConfirmApplyDialog({required this.name});

  final String name;

  @override
  State<_ConfirmApplyDialog> createState() => _ConfirmApplyDialogState();
}

class _ConfirmApplyDialogState extends State<_ConfirmApplyDialog> {
  bool _replaceImages = true;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Use this match?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Re-identify as ${widget.name} and download its metadata.'),
            const SizedBox(height: 12),
            FocusableListTile(
              leading: AppIcon(
                _replaceImages ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded,
                fill: 1,
                color: _replaceImages ? scheme.primary : scheme.onSurfaceVariant,
              ),
              title: const Text('Replace existing images'),
              onTap: () => setState(() => _replaceImages = !_replaceImages),
            ),
          ],
        ),
      ),
      actions: [
        DialogActionButton(onPressed: () => Navigator.of(context).pop(), label: 'Cancel'),
        DialogActionButton(
          onPressed: () => Navigator.of(context).pop(_replaceImages),
          label: 'Identify',
          isPrimary: true,
          autofocus: true,
        ),
      ],
    );
  }
}
