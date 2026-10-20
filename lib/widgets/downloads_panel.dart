import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/download_models.dart';
import '../providers/download_provider.dart';
import '../providers/multi_server_provider.dart';
import '../screens/downloads/downloads_screen.dart';
import '../utils/global_key_utils.dart';

const int _kMaxRows = 3;

bool _isCurrent(DownloadStatus s) =>
    s == DownloadStatus.downloading ||
        s == DownloadStatus.queued ||
        s == DownloadStatus.paused ||
        s == DownloadStatus.failed;

/// Opens the compact "current downloads" popup (max 3 rows) from the Home
/// app bar. Its footer button opens the full Downloads screen.
Future<void> showDownloadsPanel(BuildContext context) {
  final downloads = context.read<DownloadProvider>();
  final multi = context.read<MultiServerProvider>();
  final rootContext = context;

  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return Dialog(
        alignment: Alignment.topRight,
        insetPadding: const EdgeInsets.fromLTRB(16, 72, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListenableBuilder(
            listenable: downloads,
            builder: (context, _) {
              final theme = Theme.of(context);
              final current = downloads.downloads.values.where((d) => _isCurrent(d.status)).toList();
              final shown = current.take(_kMaxRows).toList();
              final extra = current.length - shown.length;

              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Downloads', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    if (current.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text('No active downloads', style: TextStyle(color: theme.hintColor)),
                      )
                    else
                      for (final d in shown) _DownloadRow(progress: d, downloads: downloads, multi: multi),
                    if (extra > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Text(
                          '$extra more current download${extra == 1 ? '' : 's'}',
                          style: TextStyle(color: theme.hintColor),
                        ),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        autofocus: true,
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          Navigator.of(rootContext).push(
                            MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                          );
                        },
                        child: const Text('All Downloads'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

class _DownloadRow extends StatelessWidget {
  final DownloadProgress progress;
  final DownloadProvider downloads;
  final MultiServerProvider multi;

  const _DownloadRow({required this.progress, required this.downloads, required this.multi});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = progress.globalKey;
    final title = downloads.getMetadata(key)?.title ?? 'Download';
    final failed = progress.status == DownloadStatus.failed;

    final String status = switch (progress.status) {
      DownloadStatus.failed => progress.errorMessage?.trim().isNotEmpty == true
          ? progress.errorMessage!.trim()
          : 'Download failed',
      DownloadStatus.queued => 'Queued',
      DownloadStatus.paused => 'Paused · ${progress.progress}%',
      _ => '${progress.progress}%',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (!failed)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 5,
                      value: progress.status == DownloadStatus.queued ? null : progress.progressPercent,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failed ? theme.colorScheme.error : theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
          if (failed)
            IconButton(
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                final parsed = parseGlobalKey(key);
                final client = parsed == null ? null : multi.getClientForServer(parsed.serverId);
                if (client != null) downloads.retryDownload(key, client);
              },
            ),
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => downloads.cancelDownload(key),
          ),
        ],
      ),
    );
  }
}
