import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../services/jellyfin_client.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import 'app_icon.dart';
import 'dialog_action_button.dart';
import 'focusable_list_tile.dart';

enum _RefreshMode {
  scan(
    'Scan for new and updated files',
    'Picks up changed files and local artwork. Leaves existing metadata alone.',
    metadataMode: 'Default',
    imageMode: 'Default',
    replaceMetadata: false,
  ),
  missing(
    'Search for missing metadata',
    'Asks the metadata providers to fill in anything that is empty.',
    metadataMode: 'FullRefresh',
    imageMode: 'FullRefresh',
    replaceMetadata: false,
  ),
  replace(
    'Replace all metadata',
    'Downloads everything again from the providers. Overwrites manual edits on unlocked items.',
    metadataMode: 'FullRefresh',
    imageMode: 'FullRefresh',
    replaceMetadata: true,
  );

  const _RefreshMode(
      this.title,
      this.subtitle, {
        required this.metadataMode,
        required this.imageMode,
        required this.replaceMetadata,
      });

  final String title;
  final String subtitle;
  final String metadataMode;
  final String imageMode;
  final bool replaceMetadata;
}

/// Jellyfin web's "Refresh metadata" dialog. Returns true when a refresh was
/// queued on the server.
Future<bool> showMetadataRefreshDialog(BuildContext context, {required JellyfinClient client, required MediaItem item}) async {
  final queued = await showScopedDialog<bool>(
    context: context,
    builder: (_) => _MetadataRefreshDialog(client: client, item: item),
  );
  return queued == true;
}

class _MetadataRefreshDialog extends StatefulWidget {
  const _MetadataRefreshDialog({required this.client, required this.item});

  final JellyfinClient client;
  final MediaItem item;

  @override
  State<_MetadataRefreshDialog> createState() => _MetadataRefreshDialogState();
}

class _MetadataRefreshDialogState extends State<_MetadataRefreshDialog> {
  _RefreshMode _mode = _RefreshMode.missing;
  bool _replaceImages = false;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await widget.client.refreshItemMetadata(
        widget.item.id,
        metadataMode: _mode.metadataMode,
        imageMode: _mode.imageMode,
        replaceAllMetadata: _mode.replaceMetadata,
        replaceAllImages: _mode != _RefreshMode.scan && _replaceImages,
      );
    } catch (e, st) {
      appLogger.e('Metadata refresh failed', error: e, stackTrace: st);
    }
    if (!mounted) return;
    if (ok) {
      final scope = widget.item.kind == MediaKind.show || widget.item.kind == MediaKind.season
          ? 'and all its episodes '
          : '';
      showSuccessSnackBar(context, 'Refreshing ${widget.item.title ?? 'item'} ${scope}in the background.');
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
      showErrorSnackBar(context, "Couldn't start the refresh.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Refresh metadata'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final mode in _RefreshMode.values)
                FocusableListTile(
                  autofocus: mode == _mode,
                  leading: AppIcon(
                    mode == _mode ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
                    fill: 1,
                    color: mode == _mode ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: Text(mode.title),
                  subtitle: Text(mode.subtitle),
                  onTap: _busy ? null : () => setState(() => _mode = mode),
                ),
              if (_mode != _RefreshMode.scan) ...[
                const Divider(height: 24),
                FocusableListTile(
                  leading: AppIcon(
                    _replaceImages ? Symbols.check_box_rounded : Symbols.check_box_outline_blank_rounded,
                    fill: 1,
                    color: _replaceImages ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: const Text('Replace existing images'),
                  subtitle: const Text('Swaps the current artwork for the providers\' picks.'),
                  onTap: _busy ? null : () => setState(() => _replaceImages = !_replaceImages),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        DialogActionButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), label: 'Cancel'),
        DialogActionButton(onPressed: _busy ? null : _submit, label: _busy ? 'Starting…' : 'Refresh', isPrimary: true),
      ],
    );
  }
}
