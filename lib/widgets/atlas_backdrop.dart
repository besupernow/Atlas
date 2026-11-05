import 'package:flutter/material.dart';

/// Background for the Atlas+ access flow (wall, request access, invite code).
/// A flat dark page with a faint lift at the top, like the sign-in screens of
/// the big streaming apps. No glows, no glass.
class AtlasBackdrop extends StatelessWidget {
  final Widget child;

  const AtlasBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.05), base), base],
          stops: const [0, 0.6],
        ),
      ),
      child: child,
    );
  }
}

/// Atlas+ logo: the glyph plus the name.
class AtlasWordmark extends StatelessWidget {
  final double height;

  const AtlasWordmark({super.key, this.height = 32});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/brand/glyph-app.png', height: height, width: height, filterQuality: FilterQuality.medium),
        SizedBox(width: height * 0.3),
        Text(
          'Atlas+',
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: height * 0.72,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// Content block for the access flow. Kept for API compatibility: it used to
/// be a frosted card, now it's just padding so forms sit straight on the page.
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
  Widget build(BuildContext context) => Padding(padding: padding, child: child);
}

/// Inline message: an icon and a line of text, in the error colour or a
/// neutral one for notices.
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
    final accent = isError ? scheme.error : scheme.onSurface.withValues(alpha: 0.85);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(isError ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 18, color: accent),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: accent, height: 1.35)),
              if (onAction != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: GestureDetector(
                    onTap: onAction,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(
                        actionLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
