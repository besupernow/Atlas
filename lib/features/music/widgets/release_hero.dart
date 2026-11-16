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
  final List<Widget> actions;

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
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
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

    final height = size.width;
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FadingArt(image: art, height: height, fadeFrom: 0.42),
              if (badge case final badge?) Positioned(top: MediaQuery.paddingOf(context).top + 52, right: 16, child: badge),
            ],
          ),
        ),
        // The text rides up over the faded part of the cover.
        Transform.translate(
          offset: const Offset(0, -84),
          child: Padding(padding: MusicPage.padding(context), child: text),
        ),
      ],
    );
  }
}

/// The big rounded buttons on a release page.
abstract final class ReleaseButtons {
  static ButtonStyle get primary => FilledButton.styleFrom(
    minimumSize: const Size(140, 50),
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
  );

  static ButtonStyle get secondary => FilledButton.styleFrom(
    minimumSize: const Size(140, 50),
    shape: const StadiumBorder(),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
  );
}
