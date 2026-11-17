import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../utils/platform_detector.dart';
import '../discover/discover_models.dart';
import '../discover/discover_widgets.dart';
import 'art_backdrop.dart';
import 'music_page.dart';

/// Atlas: the top of a release page (an album, EP or single, on the server or not): the cover,
/// what it is and when ("SINGLE · 2025"), the title, everyone credited as accent-colored links,
/// a details line, and the actions. On phones the cover runs edge to edge and melts into the
/// page with the text over its lower part; on wide screens it sits beside the text.
class ReleaseHero extends StatelessWidget {
  const ReleaseHero({
    super.key,
    required this.art,
    required this.eyebrow,
    required this.title,
    required this.credit,
    required this.actions,
    this.iconActions = const [],
    this.details,
    this.badge,
    this.onArtist,
  });

  /// The cover, filling whatever box it's given.
  final Widget art;

  /// "ALBUM · 2025".
  final String eyebrow;
  final String title;
  final ArtistCredit credit;

  /// The big buttons (Play, Shuffle / Preview, Request): side by side, sharing the width.
  final List<Widget> actions;

  /// Small round buttons after them (Love, More).
  final List<Widget> iconActions;

  /// "12 songs · 41 min", genres, a label.
  final String? details;

  /// Laid over the cover's corner (whether we have it).
  final Widget? badge;

  /// Replaces opening an artist by name.
  final ValueChanged<String>? onArtist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 700;
    final isTV = PlatformDetector.isTV();
    final align = wide ? CrossAxisAlignment.start : CrossAxisAlignment.center;
    final textAlign = wide ? TextAlign.start : TextAlign.center;

    final text = Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          eyebrow.toUpperCase(),
          textAlign: textAlign,
          style: theme.textTheme.labelMedium?.copyWith(
            letterSpacing: 1.6,
            fontWeight: FontWeight.w800,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: (wide || isTV ? theme.textTheme.displaySmall : theme.textTheme.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -1,
            height: 1.05,
          ),
        ),
        if (!credit.isEmpty) ...[
          const SizedBox(height: 6),
          ArtistLinks(
            credit: credit,
            accent: true,
            maxLines: 2,
            textAlign: textAlign,
            onTap: onArtist,
            style: theme.textTheme.titleMedium,
          ),
        ],
        if (details case final details? when details.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            details,
            textAlign: textAlign,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        if (wide)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [...actions, ...iconActions],
          )
        else
          Row(
            children: [
              for (final (index, action) in actions.indexed) ...[
                if (index > 0) const SizedBox(width: 10),
                Expanded(child: action),
              ],
              for (final action in iconActions) ...[const SizedBox(width: 8), action],
            ],
          ),
      ],
    );

    if (wide) {
      final cover = 280.0;
      return Padding(
        padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 80, bottom: 16)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Stack(
              children: [
                Container(
                  width: cover,
                  height: cover,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(20)),
                  child: art,
                ),
                if (badge case final badge?) Positioned(top: 12, right: 12, child: badge),
              ],
            ),
            const SizedBox(width: 36),
            Expanded(child: text),
          ],
        ),
      );
    }

    // The cover edge to edge; the text overlaps its faded lower part. The art is laid out
    // taller than the space it takes, so there's no gap between the two.
    final height = size.width;
    const overlap = 96.0;
    return Column(
      children: [
        SizedBox(
          height: height - overlap,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: height,
            maxHeight: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FadingArt(image: art, height: height, fadeFrom: 0.42),
                if (badge case final badge?)
                  Positioned(top: MediaQuery.paddingOf(context).top + 52, right: 16, child: badge),
              ],
            ),
          ),
        ),
        Padding(padding: MusicPage.padding(context).add(const EdgeInsets.only(bottom: 12)), child: text),
      ],
    );
  }
}

/// The big rounded buttons on a release page.
abstract final class ReleaseButtons {
  static ButtonStyle get primary => FilledButton.styleFrom(
    minimumSize: const Size(120, 46),
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
  );

  /// Frosted, not a second solid accent button: the accent stays on the main action.
  static ButtonStyle secondary(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return primary.copyWith(
      backgroundColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: 0.12)),
      foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
      overlayColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: 0.08)),
    );
  }
}

/// Atlas: the back button on music's detail pages: a chevron in a small frosted circle over the
/// art, instead of Material's bare arrow.
class FrostedBackButton extends StatelessWidget {
  const FrostedBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Tooltip(
        message: MaterialLocalizations.of(context).backButtonTooltip,
        child: GestureDetector(
          onTap: () => Navigator.maybePop(context),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                width: 38,
                height: 38,
                color: Colors.black.withValues(alpha: 0.22),
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
