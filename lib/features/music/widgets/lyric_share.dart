import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:share_plus/share_plus.dart';

import '../../../media/media_item.dart';
import '../../../media/media_server_client.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/media_image_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/optimized_media_image.dart';
import '../music_strings.dart';

/// Atlas: share a few lines of a song like Apple Music: a card with the lyrics over the song's
/// art, the title and artist under them, sent as a picture (iMessage, RCS and the rest show it
/// inline) with the lines as text alongside for anywhere pictures don't go.
Future<void> shareLyrics(
  BuildContext context, {
  required MediaItem track,
  required MediaServerClient? client,
  required List<String> lines,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LyricShareSheet(track: track, client: client, lines: lines),
  );
}

class _LyricShareSheet extends StatefulWidget {
  const _LyricShareSheet({required this.track, required this.client, required this.lines});

  final MediaItem track;
  final MediaServerClient? client;
  final List<String> lines;

  @override
  State<_LyricShareSheet> createState() => _LyricShareSheetState();
}

class _LyricShareSheetState extends State<_LyricShareSheet> {
  final _card = GlobalKey();
  final _shareButton = GlobalKey();
  bool _sharing = false;

  String get _artist => widget.track.trackArtistTitle ?? widget.track.albumArtistTitle ?? '';

  String get _text {
    final title = widget.track.title ?? '';
    final quote = widget.lines.join('\n');
    return '“$quote”\n— $title${_artist.isEmpty ? '' : ' by $_artist'}';
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final origin = _originRect();
    try {
      final boundary = _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      final image = await boundary?.toImage(pixelRatio: 3);
      final bytes = await image?.toByteData(format: ui.ImageByteFormat.png);
      final files = [
        if (bytes != null)
          XFile.fromData(bytes.buffer.asUint8List(), mimeType: 'image/png', name: 'lyrics.png'),
      ];
      await SharePlus.instance.share(
        ShareParams(text: _text, files: files.isEmpty ? null : files, sharePositionOrigin: origin),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      appLogger.w('Sharing lyrics failed', error: error);
      // The picture didn't work out: the words alone still go.
      try {
        await SharePlus.instance.share(ShareParams(text: _text, sharePositionOrigin: origin));
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Where the share popover points on iPad and Mac.
  Rect? _originRect() {
    final box = _shareButton.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = (MediaQuery.sizeOf(context).width - 48).clamp(240.0, 380.0);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _card,
              child: _LyricCard(track: widget.track, client: widget.client, lines: widget.lines, width: width),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: width,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const AppIcon(Symbols.close_rounded),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      key: _shareButton,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
                      onPressed: _sharing ? null : () => unawaited(_share()),
                      icon: _sharing
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary),
                            )
                          : const AppIcon(Symbols.ios_share_rounded),
                      label: const Text(MusicStrings.share),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture that gets sent: 4:5, the art blurred behind, the lines big and bold.
class _LyricCard extends StatelessWidget {
  const _LyricCard({required this.track, required this.client, required this.lines, required this.width});

  final MediaItem track;
  final MediaServerClient? client;
  final List<String> lines;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width * 1.25;
    final count = lines.join(' ').length;
    final size = count > 160 ? 20.0 : (count > 90 ? 24.0 : 29.0);
    Widget art({double? side}) => OptimizedMediaImage(
      client: client,
      imagePath: track.thumbPath,
      imageType: ImageType.square,
      width: side,
      height: side,
      fit: BoxFit.cover,
      fallbackIcon: Symbols.music_note_rounded,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF15151A)),
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.decal),
              child: Transform.scale(scale: 1.6, child: art()),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x33000000), Color(0x80000000)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        lines.join('\n'),
                        maxLines: 9,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size,
                          height: 1.18,
                          letterSpacing: -0.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      ClipRRect(borderRadius: BorderRadius.circular(8), child: art(side: 44)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            Text(
                              track.trackArtistTitle ?? track.albumArtistTitle ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
