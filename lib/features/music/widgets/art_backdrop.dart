import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Atlas: the background of music's detail pages (artist, album, single): the artwork blown up
/// and blurred so its colors wash the whole page, under the page's content. The sharp artwork
/// itself goes at the top of the content in a [FadingArt], which melts into this.
class ArtBackdrop extends StatelessWidget {
  const ArtBackdrop({super.key, required this.image, required this.child});

  /// The artwork, filling whatever box it's given (BoxFit.cover). Null for a plain page.
  final Widget? image;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final art = image;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: surface),
        if (art != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90, tileMode: TileMode.decal),
            child: Opacity(opacity: 0.9, child: Transform.scale(scale: 1.8, child: art)),
          ),
        // Keeps text readable and lets the color settle toward the bottom.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.5, 1],
              colors: [surface.withValues(alpha: 0.1), surface.withValues(alpha: 0.35), surface.withValues(alpha: 0.65)],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The sharp artwork at the top of a detail page, fading to clear at its bottom edge so it
/// runs into the [ArtBackdrop] behind it. The art is zoomed in a touch so the part that fades
/// is still picture (not an edge), and the fade eases out instead of stopping on a line.
class FadingArt extends StatelessWidget {
  const FadingArt({super.key, required this.image, required this.height, this.fadeFrom = 0.5, this.zoom = 1.1});

  final Widget image;
  final double height;

  /// Where (0..1 down the art) the fade starts.
  final double fadeFrom;

  /// How far the art is scaled up (from its top, so faces and titles stay put).
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final start = fadeFrom.clamp(0.0, 0.95);
    final span = 1 - start;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        // An ease-out curve in five steps: no visible edge where the picture ends.
        // Fully clear a little before the bottom: when the page scrolls to a fraction of a pixel
        // the mask's last row can land on the art's edge and show as a line.
        stops: [0, start, start + span * 0.28, start + span * 0.5, start + span * 0.72, start + span * 0.92, 1],
        colors: [
          Colors.white,
          Colors.white,
          Colors.white.withValues(alpha: 0.82),
          Colors.white.withValues(alpha: 0.5),
          Colors.white.withValues(alpha: 0.18),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(rect),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: ClipRect(
          child: Transform.scale(scale: zoom, alignment: Alignment.topCenter, child: image),
        ),
      ),
    );
  }
}
