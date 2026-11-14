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
/// runs into the [ArtBackdrop] behind it.
class FadingArt extends StatelessWidget {
  const FadingArt({super.key, required this.image, required this.height, this.fadeFrom = 0.5});

  final Widget image;
  final double height;

  /// Where (0..1 down the art) the fade starts.
  final double fadeFrom;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0, fadeFrom, 1],
        colors: const [Colors.white, Colors.white, Colors.transparent],
      ).createShader(rect),
      child: SizedBox(height: height, width: double.infinity, child: image),
    );
  }
}
