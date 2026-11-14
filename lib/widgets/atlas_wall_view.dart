import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_wrapper.dart';
import '../services/atlas_gate/atlas_gate.dart';
import '../utils/platform_detector.dart';
import 'atlas_backdrop.dart';
import 'loading_indicator_box.dart';

/// What a device the gate hasn't approved sees instead of the sign-in form.
/// Laid out like a streaming app's "sign in on your TV" page: logo, a short
/// heading, two plain steps, a big code, and a QR code on the side.
///
/// TV: fixed 960x540 canvas scaled to fit, so it looks the same on every set.
/// Wide screens: the same two columns in normal flow.
/// Narrow screens and phones: one column, no QR.
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

  String get _deviceWord {
    if (isTv) return 'TV';
    if (PlatformDetector.isDesktopOS()) return 'computer';
    return 'device';
  }

  String get _statusText => pending
      ? "Request sent. This screen updates on its own once it's approved."
      : "This screen updates on its own once you're approved.";

  @override
  Widget build(BuildContext context) {
    if (isTv) return AtlasBackdrop(child: _tvLayout(context));
    final mobile = PlatformDetector.isMobile(context);
    return AtlasBackdrop(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = !mobile && box.maxWidth >= 860;
          final pad = box.maxWidth >= 600 ? 40.0 : 20.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, pad * 0.8, pad, pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AtlasWordmark(height: 30),
                SizedBox(height: wide ? 72 : 36),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 920 : 480),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(child: _content(context, size: _Size.wide)),
                              const SizedBox(width: 64),
                              _qr(context, size: 220),
                            ],
                          )
                        : _content(context, size: _Size.narrow),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- TV

  static const Size _tvCanvas = Size(960, 540);

  Widget _tvLayout(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.noScaling),
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: _tvCanvas,
            // Margins wider than the 5% overscan safe area: some sets crop.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(64, 36, 64, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AtlasWordmark(height: 26),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            // Shrinks the column if a notice makes it too
                            // tall, instead of running off the screen.
                            builder: (context, c) => FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: c.maxWidth,
                                child: _content(context, size: _Size.tv),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                        _qr(context, size: 200),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- shared

  Widget _content(BuildContext context, {required _Size size}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.66);
    final tv = size == _Size.tv;
    final narrow = size == _Size.narrow;
    final retryFirst = error != null && onRetry != null;

    final titleSize = switch (size) {
      _Size.tv => 34.0,
      _Size.wide => 40.0,
      _Size.narrow => 30.0,
    };
    final bodySize = tv ? 17.0 : 16.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sign in to Atlas+',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontSize: titleSize,
            fontWeight: FontWeight.w700,
            height: 1.1,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          "Atlas+ is invite only. Approve this $_deviceWord from a phone or computer that's already signed in.",
          style: theme.textTheme.bodyLarge?.copyWith(fontSize: bodySize, color: muted, height: 1.4),
        ),
        if (notice != null) ...[const SizedBox(height: 16), AtlasBanner(text: notice!, isError: false)],
        if (error != null) ...[const SizedBox(height: 16), AtlasBanner(text: error!, onAction: tv ? null : onRetry)],
        SizedBox(height: tv ? 26 : 32),
        _step(theme, 1, 'On your signed-in device, open Atlas and go to Settings > Devices & access.', bodySize),
        const SizedBox(height: 12),
        _step(theme, 2, 'Enter this code:', bodySize),
        const SizedBox(height: 10),
        Padding(padding: const EdgeInsets.only(left: 30), child: _code(theme, size)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Text(
            _statusText,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: tv ? 14 : null, color: muted),
          ),
        ),
        SizedBox(height: tv ? 28 : 40),
        Text(
          'No signed-in device?',
          style: theme.textTheme.bodyMedium?.copyWith(fontSize: tv ? 15 : null, color: muted),
        ),
        const SizedBox(height: 12),
        if (tv)
          // Plain row: left/right moves between the buttons, and nothing else
          // on the page takes focus, so the remote can't get lost.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (retryFirst) ...[
                _TvButton(label: 'Try again', autofocus: true, onPressed: onRetry),
                const SizedBox(width: 12),
              ],
              _TvButton(
                label: lockdown ? 'Not taking requests' : 'Request access',
                autofocus: !retryFirst && !lockdown,
                onPressed: lockdown ? null : onRequestAccess,
              ),
              const SizedBox(width: 12),
              _TvButton(label: 'Enter invite code', autofocus: !retryFirst && lockdown, onPressed: onHaveCode),
            ],
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              _button(
                context,
                label: lockdown ? 'Not taking requests right now' : 'Request access',
                primary: true,
                autofocus: !lockdown,
                onPressed: lockdown ? null : onRequestAccess,
                expand: narrow,
              ),
              _button(context, label: 'Enter invite code', autofocus: lockdown, onPressed: onHaveCode, expand: narrow),
              if (onBack != null) _button(context, label: 'Back', onPressed: onBack, expand: narrow),
            ],
          ),
      ],
    );
  }

  Widget _step(ThemeData theme, int n, String text, double fontSize) {
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Text(
            '$n.',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(fontSize: fontSize, height: 1.4, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  /// The code as big plain text, split 3 + 3 so it's easy to read out.
  Widget _code(ThemeData theme, _Size size) {
    final value = code;
    final fontSize = switch (size) {
      _Size.tv => 46.0,
      _Size.wide => 48.0,
      _Size.narrow => 40.0,
    };
    if (value == null) {
      return SizedBox(
        height: fontSize * 1.2,
        child: const Align(alignment: Alignment.centerLeft, child: LoadingIndicatorBox(size: 24)),
      );
    }
    final shown = value.length == 6 ? '${value.substring(0, 3)} ${value.substring(3)}' : value;
    return Text(
      shown,
      style: theme.textTheme.displaySmall?.copyWith(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: fontSize * 0.14,
        height: 1.15,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _qr(BuildContext context, {required double size}) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.66);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
          child: code == null
              ? SizedBox.square(
                  dimension: size,
                  child: const Center(child: LoadingIndicatorBox(size: 26)),
                )
              : QrImageView(
                  data: '$kAtlasGateBase/join?code=$code',
                  size: size,
                  padding: EdgeInsets.zero,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: size + 24,
          child: Text(
            'Or scan with your phone camera',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: isTv ? 14 : null, color: muted),
          ),
        ),
      ],
    );
  }

  Widget _button(
    BuildContext context, {
    required String label,
    required VoidCallback? onPressed,
    bool primary = false,
    bool autofocus = false,
    bool expand = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: primary ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.12),
        foregroundColor: primary ? scheme.surface : scheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
    final focusable = FocusableButton(
      autofocus: autofocus,
      useBackgroundFocus: true,
      onPressed: onPressed,
      child: button,
    );
    return expand ? SizedBox(width: double.infinity, child: focusable) : focusable;
  }
}

enum _Size { tv, wide, narrow }

/// TV button. Unfocused: light text on a translucent grey fill. Focused:
/// solid white with dark text and a small lift, the usual TV "this one".
class _TvButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool autofocus;

  const _TvButton({required this.label, required this.onPressed, this.autofocus = false});

  @override
  State<_TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<_TvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = widget.onPressed != null;
    final bg = _focused ? scheme.onSurface : scheme.onSurface.withValues(alpha: enabled ? 0.14 : 0.06);
    final fg = _focused ? scheme.surface : scheme.onSurface.withValues(alpha: enabled ? 0.92 : 0.4);
    return FocusableWrapper(
      autofocus: widget.autofocus && enabled,
      canRequestFocus: enabled,
      // Draws its own focus state.
      delegateFocusBorder: true,
      useFocusGlow: false,
      disableScale: true,
      // The TV canvas never scrolls; don't let showOnScreen nudge it.
      autoScroll: false,
      descendantsAreFocusable: false,
      semanticLabel: widget.label,
      onFocusChange: (f) => setState(() => _focused = f),
      onSelect: widget.onPressed,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _focused ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 15),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
            child: Text(
              widget.label,
              style: theme.textTheme.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w700, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
