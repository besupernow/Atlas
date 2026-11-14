import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../widgets/app_icon.dart';
import '../music_strings.dart';
import '../widgets/music_page.dart';
import 'listenbrainz.dart';

/// Ask for (or change, or remove) this profile's ListenBrainz username.
Future<void> showListenBrainzConnect(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => _ListenBrainzDialog(host: context),
);

/// The dialog owns its text field's controller, so the controller lives exactly as long as the
/// dialog (including its closing animation).
class _ListenBrainzDialog extends StatefulWidget {
  const _ListenBrainzDialog({required this.host});

  /// Where the account is saved from (the dialog's own context sits above the profile).
  final BuildContext host;

  @override
  State<_ListenBrainzDialog> createState() => _ListenBrainzDialogState();
}

class _ListenBrainzDialogState extends State<_ListenBrainzDialog> {
  late final String? _current = ListenBrainzAccount.username(widget.host);
  late final TextEditingController _controller = TextEditingController(text: _current ?? '');
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    bool ok;
    try {
      ok = await ListenBrainzAccount.exists(name);
    } catch (_) {
      ok = true; // Offline or rate-limited: trust the name, it'll load once ListenBrainz answers.
    }
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _checking = false;
        _error = MusicStrings.userNotFound;
      });
      return;
    }
    if (widget.host.mounted) await ListenBrainzAccount.setUsername(widget.host, name);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _disconnect() async {
    if (widget.host.mounted) await ListenBrainzAccount.setUsername(widget.host, null);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const AppIcon(Symbols.graphic_eq_rounded, size: 32),
      title: const Text(MusicStrings.listenBrainz),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(MusicStrings.connectBody),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_save()),
            decoration: InputDecoration(
              labelText: MusicStrings.usernameHint,
              errorText: _error,
              prefixIcon: const AppIcon(Symbols.person_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        if (_current != null)
          TextButton(onPressed: () => unawaited(_disconnect()), child: const Text(MusicStrings.disconnect)),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text(MusicStrings.cancel)),
        FilledButton(
          onPressed: _checking ? null : () => unawaited(_save()),
          child: _checking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text(MusicStrings.save),
        ),
      ],
    );
  }
}

/// The card on Home until someone connects ListenBrainz.
class ListenBrainzConnectCard extends StatelessWidget {
  const ListenBrainzConnectCard({super.key, this.onNavigateLeft});

  final VoidCallback? onNavigateLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    void connect() => unawaited(showListenBrainzConnect(context));
    return Padding(
      padding: MusicPage.padding(context).add(const EdgeInsets.only(top: 22)),
      child: FocusableWrapper(
        borderRadius: 24,
        onSelect: connect,
        onNavigateLeft: onNavigateLeft,
        child: Material(
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: connect,
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, Color.lerp(accent, const Color(0xFF3B1E8F), 0.6)!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.all(22),
              child: Row(
                children: [
                  const AppIcon(Symbols.auto_awesome_rounded, size: 40, color: Colors.white, fill: 1.0),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          MusicStrings.connectTitle,
                          style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          MusicStrings.connectBody,
                          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: connect,
                          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                          child: const Text(MusicStrings.connect),
                        ),
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
}
