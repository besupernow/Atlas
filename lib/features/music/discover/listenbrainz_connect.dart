import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../widgets/app_icon.dart';
import '../music_strings.dart';
import '../widgets/music_page.dart';
import 'listenbrainz.dart';

/// Ask for (or change, or remove) this profile's ListenBrainz username.
Future<void> showListenBrainzConnect(BuildContext context) async {
  final current = ListenBrainzAccount.username(context);
  final controller = TextEditingController(text: current ?? '');
  String? error;
  var checking = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        Future<void> save() async {
          final name = controller.text.trim();
          if (name.isEmpty) return;
          setDialogState(() {
            checking = true;
            error = null;
          });
          bool ok;
          try {
            ok = await ListenBrainzAccount.exists(name);
          } catch (_) {
            ok = true; // Offline or rate-limited: trust the name, it'll show up once it loads.
          }
          if (!dialogContext.mounted) return;
          if (!ok) {
            setDialogState(() {
              checking = false;
              error = MusicStrings.userNotFound;
            });
            return;
          }
          if (context.mounted) await ListenBrainzAccount.setUsername(context, name);
          if (dialogContext.mounted) Navigator.of(dialogContext).pop();
        }

        return AlertDialog(
          icon: const AppIcon(Symbols.graphic_eq_rounded, size: 32),
          title: const Text(MusicStrings.listenBrainz),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(MusicStrings.connectBody),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(save()),
                decoration: InputDecoration(
                  labelText: MusicStrings.usernameHint,
                  errorText: error,
                  prefixIcon: const AppIcon(Symbols.person_rounded),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            if (current != null)
              TextButton(
                onPressed: () async {
                  await ListenBrainzAccount.setUsername(context, null);
                  if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                },
                child: const Text(MusicStrings.disconnect),
              ),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text(MusicStrings.cancel)),
            FilledButton(
              onPressed: checking ? null : () => unawaited(save()),
              child: checking
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text(MusicStrings.save),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
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
