import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../focus/focusable_button.dart';
import '../services/atlas_gate/atlas_gate.dart';
import '../utils/platform_detector.dart';
import 'atlas_backdrop.dart';
import 'loading_indicator_box.dart';

/// The "closed private server" page an unapproved device sees instead of the
/// sign-in form. It shows a Quick Connect code straight away so an approved
/// device can let this one in with a single tap, and offers request access /
/// invite code underneath.
///
/// Everything except phones (and mobile browsers) also gets a QR code: scan it
/// with an approved phone and the code is filled in for you.
///
/// Wide screens: one frosted card, steps on the left and the QR on the right.
/// Narrow screens: a single column, no QR.
class AtlasWallView extends StatelessWidget {
  /// Quick Connect code to show, or null while one is being fetched.
  final String? code;
  final bool isTv;

  /// A request is already waiting for approval.
  final bool pending;
  final bool lockdown;
  final String? notice;
  final String? error;
  final VoidCallback onRequestAccess;
  final VoidCallback onHaveCode;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  const AtlasWallView({
    super.key,
    required this.code,
    required this.isTv,
    required this.pending,
    required this.lockdown,
    required this.onRequestAccess,
    required this.onHaveCode,
    this.notice,
    this.error,
    this.onRetry,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final mobile = PlatformDetector.isMobile(context);
    return AtlasBackdrop(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 860;
          final showQr = !mobile && code != null && wide;
          final pad = box.maxWidth >= 600 ? 32.0 : 20.0;

          final Widget body;
          if (showQr) {
            body = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: AtlasGlassCard(
                padding: EdgeInsets.zero,
                radius: 32,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(31),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        flex: 6,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(44, 40, 20, 40),
                          child: _content(context, wide: true),
                        ),
                      ),
                      Expanded(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                          child: _qrPane(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          } else {
            body = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: AtlasGlassCard(
                padding: EdgeInsets.all(box.maxWidth >= 600 ? 36 : 24),
                child: _content(context, wide: false),
              ),
            );
          }

          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Center(
                child: Padding(padding: EdgeInsets.all(pad), child: body),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.70);
    final qrVisible = !PlatformDetector.isMobile(context) && code != null && wide;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, size: 14, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'ATLAS+  PRIVATE',
                style: theme.textTheme.labelMedium?.copyWith(
                  letterSpacing: 2.2,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'This server is invite only',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: wide ? 34 : 27,
            fontWeight: FontWeight.w800,
            height: 1.1,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          "Let this device in from one you've already signed in on.",
          style: theme.textTheme.bodyLarge?.copyWith(color: muted, height: 1.4),
        ),
        if (notice != null) ...[const SizedBox(height: 18), AtlasBanner(text: notice!, isError: false)],
        if (error != null) ...[
          const SizedBox(height: 18),
          AtlasBanner(text: error!, onAction: onRetry),
        ],
        const SizedBox(height: 28),
        _stepRow(
          theme,
          1,
          'Open Atlas on an approved device',
          subtitle: qrVisible ? 'Scan the QR code, or go to Settings > Devices & access.' : 'Settings > Devices & access',
        ),
        const SizedBox(height: 22),
        _stepRow(
          theme,
          2,
          'Enter this code and tap Approve',
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_codeTiles(theme), const SizedBox(height: 16), _statusPill(theme)],
          ),
        ),
        const SizedBox(height: 28),
        Divider(height: 1, color: scheme.onSurface.withValues(alpha: 0.10)),
        const SizedBox(height: 18),
        Text('No approved device?', style: theme.textTheme.labelLarge?.copyWith(color: muted)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FocusableButton(
              autofocus: true,
              useBackgroundFocus: true,
              onPressed: lockdown ? null : onRequestAccess,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: lockdown ? null : onRequestAccess,
                child: Text(lockdown ? 'Not taking requests right now' : 'Request access'),
              ),
            ),
            FocusableButton(
              useBackgroundFocus: true,
              onPressed: onHaveCode,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.18)),
                ),
                onPressed: onHaveCode,
                child: const Text('I have a code'),
              ),
            ),
            if (onBack != null)
              FocusableButton(
                useBackgroundFocus: true,
                onPressed: onBack,
                child: TextButton(onPressed: onBack, child: const Text('Back')),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stepRow(ThemeData theme, int n, String title, {String? subtitle, Widget? trailing}) {
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [scheme.primary, scheme.primary.withValues(alpha: 0.65)]),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$n',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimary),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withValues(alpha: 0.68)),
                ),
              ],
              if (trailing != null) ...[const SizedBox(height: 14), trailing],
            ],
          ),
        ),
      ],
    );
  }

  /// One tile per digit, split into two groups of three.
  Widget _codeTiles(ThemeData theme) {
    final scheme = theme.colorScheme;
    final value = code;
    if (value == null) {
      return const SizedBox(
        height: 64,
        child: Align(alignment: Alignment.centerLeft, child: LoadingIndicatorBox(size: 26)),
      );
    }
    final tiles = <Widget>[];
    for (var i = 0; i < value.length; i++) {
      if (value.length == 6 && i == 3) tiles.add(const SizedBox(width: 14));
      tiles.add(
        Container(
          width: 48,
          height: 64,
          alignment: Alignment.center,
          margin: EdgeInsets.only(right: i == value.length - 1 ? 0 : 8),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.40)),
            boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.12), blurRadius: 14)],
          ),
          child: Text(
            value[i],
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(mainAxisSize: MainAxisSize.min, children: tiles),
    );
  }

  Widget _statusPill(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LoadingIndicatorBox(size: 14),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              pending ? "Request sent. You'll be let in once it's approved." : 'Waiting for approval',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _qrPane(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final what = isTv
        ? 'this TV'
        : PlatformDetector.isDesktopOS()
        ? 'this computer'
        : 'this browser';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [scheme.primary.withValues(alpha: 0.16), scheme.primary.withValues(alpha: 0.05)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.28), blurRadius: 36)],
                ),
                child: QrImageView(
                  data: '$kAtlasGateBase/join?code=$code',
                  size: 200,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.qr_code_scanner_rounded, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text('Scan with your phone', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Opens Atlas on your phone so you can approve $what.',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withValues(alpha: 0.68)),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
