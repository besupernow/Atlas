import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../focus/focusable_button.dart';
import '../services/atlas_gate/atlas_gate.dart';
import 'loading_indicator_box.dart';

/// The "closed private server" page an unapproved device sees instead of the
/// sign-in form. It shows a Quick Connect code straight away (plus a QR code on
/// TV) so an approved device can let this one in with a single tap, and offers
/// request access / invite code underneath.
///
/// TV: edge-to-edge split, steps on the left and a tinted QR pane on the right.
/// Phones and desktops: one centered column, no QR (the phone is the approver).
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
    return LayoutBuilder(
      builder: (context, box) {
        final showQr = isTv && code != null && box.maxWidth >= 700;
        final content = _content(context, wide: box.maxWidth >= 700);

        if (!showQr) {
          return _scroll(
            box,
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(padding: const EdgeInsets.all(24), child: content),
              ),
            ),
          );
        }

        final paneWidth = (box.maxWidth * 0.36).clamp(300.0, 420.0);
        return Row(
          children: [
            Expanded(
              child: _scroll(
                box,
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: Padding(padding: const EdgeInsets.fromLTRB(56, 24, 40, 24), child: content),
                  ),
                ),
              ),
            ),
            SizedBox(width: paneWidth, child: _qrPane(context)),
          ],
        );
      },
    );
  }

  /// Scrolls from the top when the content is taller than the screen, and
  /// centers it when it is shorter.
  Widget _scroll(BoxConstraints box, Widget child) {
    return SingleChildScrollView(
      child: ConstrainedBox(constraints: BoxConstraints(minHeight: box.maxHeight), child: child),
    );
  }

  Widget _content(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.68);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              'ATLAS+',
              style: theme.textTheme.labelLarge?.copyWith(
                letterSpacing: 3,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Atlas+ is a closed private server',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: wide ? 30 : 26,
            fontWeight: FontWeight.w800,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "Let this device in from one you've already signed in on.",
          style: theme.textTheme.bodyLarge?.copyWith(color: muted),
        ),
        const SizedBox(height: 26),
        _stepRow(
          theme,
          1,
          'Open Atlas on an approved device',
          subtitle: isTv ? 'Settings > Devices & access, or scan the QR code.' : 'Settings > Devices & access',
        ),
        const SizedBox(height: 22),
        _stepRow(
          theme,
          2,
          'Enter this code and tap Approve',
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _codeTiles(theme),
              const SizedBox(height: 14),
              _statusPill(theme),
            ],
          ),
        ),
        if (notice != null) ...[
          const SizedBox(height: 14),
          Text(notice!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
        const SizedBox(height: 26),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.45)),
        const SizedBox(height: 16),
        Text('No approved device?', style: theme.textTheme.labelLarge?.copyWith(color: muted)),
        const SizedBox(height: 10),
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
                onPressed: lockdown ? null : onRequestAccess,
                child: Text(lockdown ? 'Not taking requests right now' : 'Request access'),
              ),
            ),
            FocusableButton(
              useBackgroundFocus: true,
              onPressed: onHaveCode,
              child: TextButton(onPressed: onHaveCode, child: const Text('Have a code?')),
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
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.16), shape: BoxShape.circle),
          child: Text(
            '$n',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.primary),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
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
      return const SizedBox(height: 62, child: Align(alignment: Alignment.centerLeft, child: LoadingIndicatorBox(size: 26)));
    }
    final tiles = <Widget>[];
    for (var i = 0; i < value.length; i++) {
      if (value.length == 6 && i == 3) tiles.add(const SizedBox(width: 12));
      tiles.add(
        Container(
          width: 48,
          height: 62,
          alignment: Alignment.center,
          margin: EdgeInsets.only(right: i == value.length - 1 ? 0 : 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
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
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                child: QrImageView(
                  data: '$kAtlasGateBase/join?code=$code',
                  size: 190,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Scan with your phone',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Opens Atlas so you can approve this TV.',
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
