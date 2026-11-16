import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../services/jellyfin_client.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/setting_tile.dart';
import '../../../widgets/settings_page.dart';
import '../../../widgets/settings_section.dart';
import '../data/music_server.dart';
import '../discover/listenbrainz.dart';
import '../music_strings.dart';

/// Atlas: for admins, which ListenBrainz account goes with each Jellyfin user. Saved on the
/// server with the user, so everyone's devices pick it up without anyone signing in.
class ListenBrainzAccounts extends StatefulWidget {
  const ListenBrainzAccounts({super.key});

  @override
  State<ListenBrainzAccounts> createState() => _ListenBrainzAccountsState();
}

class _ListenBrainzAccountsState extends State<ListenBrainzAccounts> {
  JellyfinClient? _client;
  Future<List<AtlasMusicUser>>? _users;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_client != null) return;
    _client = MusicServer.jellyfin(context);
    _users = _client?.atlasMusicUsers();
  }

  void _reload() => setState(() => _users = _client?.atlasMusicUsers());

  Future<void> _edit(AtlasMusicUser user) async {
    final client = _client;
    if (client == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _UserNameDialog(client: client, user: user),
    );
    if (saved != true || !mounted) return;
    _reload();
    // Their own name may have changed.
    unawaited(ListenBrainzAccount.refresh(context, force: true));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: const Text(MusicStrings.listenBrainzAccounts),
      children: [
        FutureBuilder<List<AtlasMusicUser>>(
          future: _users,
          builder: (context, snapshot) {
            if (_users == null) return const _Note(MusicStrings.listenBrainzNoServer);
            if (snapshot.hasError) return const _Note(MusicStrings.listenBrainzServerOld);
            final users = snapshot.data;
            if (users == null) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return SettingsGroup(
              title: MusicStrings.listenBrainzAccountsHint,
              children: [
                for (final user in users)
                  SettingNavigationTile(
                    icon: Symbols.person_rounded,
                    title: user.name,
                    subtitle: user.listenBrainzUserName ?? MusicStrings.listenBrainzNotSet,
                    trailingIcon: Symbols.edit_rounded,
                    onTap: () => unawaited(_edit(user)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
  );
}

/// The dialog owns its text field's controller, so the controller lives exactly as long as the
/// dialog (including its closing animation). Pops true once saved.
class _UserNameDialog extends StatefulWidget {
  const _UserNameDialog({required this.client, required this.user});

  final JellyfinClient client;
  final AtlasMusicUser user;

  @override
  State<_UserNameDialog> createState() => _UserNameDialogState();
}

class _UserNameDialogState extends State<_UserNameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.user.listenBrainzUserName ?? '');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(String? name) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    if (name != null && name.isNotEmpty) {
      var exists = true;
      try {
        exists = await ListenBrainzAccount.exists(name);
      } catch (_) {
        // ListenBrainz unreachable or rate-limited: trust the name.
      }
      if (!mounted) return;
      if (!exists) {
        setState(() {
          _saving = false;
          _error = MusicStrings.userNotFound;
        });
        return;
      }
    }
    try {
      await widget.client.setAtlasListenBrainzUserName(widget.user.userId, name);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = MusicStrings.listenBrainzSaveFailed;
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    void submit() => unawaited(_save(_controller.text.trim()));
    return AlertDialog(
      icon: const AppIcon(Symbols.graphic_eq_rounded, size: 32),
      title: Text(widget.user.name),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          labelText: MusicStrings.usernameHint,
          errorText: _error,
          prefixIcon: const AppIcon(Symbols.person_rounded),
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        if (widget.user.listenBrainzUserName != null)
          TextButton(onPressed: _saving ? null : () => unawaited(_save(null)), child: const Text(MusicStrings.remove)),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text(MusicStrings.cancel)),
        FilledButton(
          onPressed: _saving ? null : submit,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text(MusicStrings.save),
        ),
      ],
    );
  }
}
