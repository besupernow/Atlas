import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/device_performance.dart';

/// Shared look for the Atlas+ access flow: a dark gradient with two soft
/// colour glows behind the content. Pure decoration, no interaction.
class AtlasBackdrop extends StatelessWidget {
  final Widget child;

  const AtlasBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), base),
                base,
                Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.08), base),
              ],
            ),
          ),
        ),
        Positioned(top: -160, left: -120, child: _glow(scheme.primary.withValues(alpha: 0.22), 460)),
        Positioned(bottom: -200, right: -140, child: _glow(scheme.tertiary.withValues(alpha: 0.16), 520)),
        child,
      ],
    );
  }

  Widget _glow(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}

/// Frosted card used by the access flow. Falls back to a plain translucent
/// surface on the reduced effects tier (web, weak TVs) because blur is the
/// expensive part.
class AtlasGlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;

  const AtlasGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(28),
    this.radius = 28,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blur = !DevicePerformance.isReduced;
    final fill = (tint ?? scheme.surfaceContainerHigh).withValues(alpha: blur ? 0.55 : 0.82);
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.08)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 40, offset: const Offset(0, 18))],
      ),
      child: child,
    );
    if (!blur) return card;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: card),
    );
  }
}

/// Inline message box with readable contrast (replaces bare red text).
class AtlasBanner extends StatelessWidget {
  final String text;
  final bool isError;
  final VoidCallback? onAction;
  final String actionLabel;

  const AtlasBanner({
    super.key,
    required this.text,
    this.isError = true,
    this.onAction,
    this.actionLabel = 'Try again',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = isError ? scheme.error : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface, height: 1.35)),
                if (onAction != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: onAction,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Text(
                          actionLabel,
                          style: theme.textTheme.labelLarge?.copyWith(color: accent, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
