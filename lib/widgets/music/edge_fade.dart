import 'package:flutter/material.dart';

/// Atlas: lets scrolling content (lyrics, the queue) melt into the edges instead of being
/// cut off by a hard line where the header or the controls begin.
class EdgeFade extends StatelessWidget {
  const EdgeFade({super.key, this.top = 28, this.bottom = 44, required this.child});

  /// How tall the fade is at each edge, in logical pixels (0 for none).
  final double top;
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (top <= 0 && bottom <= 0) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final height = bounds.height <= 0 ? 1.0 : bounds.height;
        final topStop = (top / height).clamp(0.0, 0.45);
        final bottomStop = (1 - bottom / height).clamp(0.55, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Eased (not linear) so the fade has no visible start line either.
          colors: const [
            Color(0x00000000),
            Color(0x66000000),
            Color(0xFF000000),
            Color(0xFF000000),
            Color(0x66000000),
            Color(0x00000000),
          ],
          stops: [0, topStop * 0.45, topStop, bottomStop, bottomStop + (1 - bottomStop) * 0.55, 1],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
