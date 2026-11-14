import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../focus/focusable_text_field.dart';
import '../../services/atlas_gate/atlas_gate.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/atlas_backdrop.dart' show AtlasBanner;
import '../../widgets/dialog_action_button.dart';
import '../../widgets/expressive_button_group.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import '../atlas_access_screen.dart';

/// Everything a trusted device can do for other devices:
///   * approve a Quick Connect code (signs the other device in AND lets it past
///     the server's device gate in one step),
///   * create a time-limited guest pass,
///   * see and remove this person's devices,
///   * make a new recovery code.
class AuthorizeDeviceScreen extends StatefulWidget {
  /// Pre-filled Quick Connect code, e.g. from an `atlas://authorize` link.
  final String? initialCode;

  const AuthorizeDeviceScreen({super.key, this.initialCode});
  @override
  State<AuthorizeDeviceScreen> createState() => _AuthorizeDeviceScreenState();
}

class _Session {
  final JellyfinConnection conn;
  final String token;
  const _Session(this.conn, this.token);
}

class _AuthorizeDeviceScreenState extends State<AuthorizeDeviceScreen> {
  final _code = TextEditingController();
  final _guestName = TextEditingController();

  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _timer;

  // Found device waiting for a yes/no.
  String? _previewLabel;
  bool _previewSameNetwork = false;
  bool _previewViaGate = false;
  String? _previewCode;

  AtlasGateStatus? _status;
  List<Map<String, dynamic>> _devices = const [];
  int _guestHours = 48;
  String? _guestCode;
  int? _guestCodeHours;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    final initial = widget.initialCode;
    if (initial != null && initial.isNotEmpty) {
      _code.text = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_find());
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _guestName.dispose();
    super.dispose();
  }

  Future<_Session> _session() async {
    final activeId = context.read<ActiveProfileProvider>().activeId;
    final pcs = await context.read<ProfileConnectionRegistry>().listForProfile(activeId!);
    final conns = await context.read<ConnectionRegistry>().list();
    final pc = pcs.firstWhere((p) => conns.any((c) => c.id == p.connectionId && c is JellyfinConnection));
    final conn = conns.firstWhere((c) => c.id == pc.connectionId) as JellyfinConnection;
    final token = (pc.userToken?.isNotEmpty ?? false) ? pc.userToken! : conn.accessToken;
    return _Session(conn, token);
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _load() async {
    final status = await AtlasGate.status();
    if (!mounted) return;
    setState(() => _status = status);
    await _loadDevices();
  }

  Future<void> _loadDevices() async {
    try {
      final s = await _session();
      final r = await AtlasGate.devices(s.token);
      if (!mounted) return;
      final items = (r.json['items'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? const [];
      setState(() => _devices = r.ok ? items : const []);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ approve a device

  Future<void> _find() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
      _previewLabel = null;
      _previewCode = null;
    });
    try {
      final s = await _session();
      final r = await AtlasGate.enrollPreview(code, s.token);
      if (!mounted) return;
      if (r.ok && r.json['found'] == true) {
        if (r.json['ambiguous'] == true) {
          _say('Two devices are showing that code. Ask them to cancel and try again.', error: true);
        } else {
          setState(() {
            _previewLabel = (r.json['label'] as String?)?.trim().isNotEmpty == true
                ? r.json['label'] as String
                : 'Unknown device';
            _previewSameNetwork = r.json['sameNetwork'] == true;
            _previewViaGate = true;
            _previewCode = code;
          });
        }
      } else if (r.status == 401 && r.error == 'jellyfin session required') {
        _say("The Atlas server couldn't confirm your sign-in. Try again in a moment.", error: true);
      } else if (r.status == 403 && r.error == 'not approved') {
        _say("This device isn't allowed to add other devices.", error: true);
      } else {
        // Gate not answering for this code (older Atlas on the other device, or
        // gate not deployed): fall back to the plain Quick Connect approval.
        setState(() {
          _previewLabel = 'Device with code $code';
          _previewSameNetwork = false;
          _previewViaGate = false;
          _previewCode = code;
        });
      }
    } catch (e) {
      _say('Something went wrong: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final code = _previewCode;
    if (code == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final s = await _session();
      if (_previewViaGate) {
        final enrolled = await AtlasGate.enroll(code, s.token);
        if (!enrolled.ok) {
          final err = enrolled.error;
          if (err == 'device_cap') {
            _say('You have reached the device limit. Remove one below, then try again.', error: true);
          } else if (err == 'ambiguous') {
            _say('Two devices are showing that code. Ask them to cancel and try again.', error: true);
          } else if (enrolled.status == 503) {
            _say('Atlas+ is not adding devices right now.', error: true);
          } else {
            _say("That code expired. Ask the other device to show a new one.", error: true);
          }
          return;
        }
      }
      final base = s.conn.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final res = await http.post(
        Uri.parse('$base/QuickConnect/Authorize').replace(queryParameters: {'code': code}),
        headers: {
          'Authorization':
              'MediaBrowser Client="Atlas", Device="Atlas", DeviceId="${s.conn.deviceId}", Version="1.0", Token="${s.token}"',
          'X-Emby-Token': s.token,
        },
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        _say('Device approved. It should sign in within a few seconds.');
        setState(() {
          _previewLabel = null;
          _previewCode = null;
          _code.clear();
        });
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 2), () => unawaited(_loadDevices()));
      } else {
        _say('That code was rejected (${res.statusCode}). Check the code and try again.', error: true);
      }
    } catch (e) {
      _say('Something went wrong: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ guest pass

  Future<void> _createGuestPass() async {
    final name = _guestName.text.trim();
    if (name.isEmpty) {
      _say("Enter the guest's name first.", error: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _guestCode = null;
    });
    try {
      final s = await _session();
      final r = await AtlasGate.createGuestPass(name, _guestHours, s.token);
      if (!mounted) return;
      if (r.ok && r.json['code'] is String) {
        setState(() {
          _guestCode = r.json['code'] as String;
          _guestCodeHours = _guestHours;
        });
      } else if (r.error == 'too_many_invites') {
        _say('You already have the maximum number of unused guest passes.', error: true);
      } else if (r.status == 503) {
        _say('Atlas+ is not creating passes right now.', error: true);
      } else {
        _say("Couldn't create the pass (${r.status}).", error: true);
      }
    } catch (e) {
      _say('Something went wrong: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ devices / recovery

  Future<void> _revoke(Map<String, dynamic> device) async {
    final label = (device['label'] as String?) ?? 'this device';
    final ok = await showScopedDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $label?'),
        content: const Text('It will be signed out and will need to be approved again to come back.'),
        actions: [
          // Cancel first and focused: OK on a remote shouldn't remove a device.
          DialogActionButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), label: 'Cancel'),
          DialogActionButton(isPrimary: true, onPressed: () => Navigator.pop(ctx, true), label: 'Remove'),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final s = await _session();
      await AtlasGate.revokeDevice((device['id'] as num).toInt(), s.token);
      await _loadDevices();
    } catch (e) {
      _say('Something went wrong: $e', error: true);
    }
  }

  Future<void> _newRecoveryCode() async {
    final ok = await showScopedDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make a new recovery code?'),
        content: const Text('Your old recovery code will stop working.'),
        actions: [
          DialogActionButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), label: 'Cancel'),
          DialogActionButton(isPrimary: true, onPressed: () => Navigator.pop(ctx, true), label: 'Make new code'),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final s = await _session();
      final r = await AtlasGate.newRecoveryCode(s.token);
      final code = r.json['code'] as String?;
      if (!mounted) return;
      if (r.ok && code != null) {
        await showAtlasRecoveryDialog(context, code);
        await _load();
      } else {
        _say("Couldn't make a recovery code (${r.status}).", error: true);
      }
    } catch (e) {
      _say('Something went wrong: $e', error: true);
    }
  }

  String _ago(num? epochSeconds) {
    if (epochSeconds == null) return 'never';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochSeconds.toInt() * 1000));
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }

  // ------------------------------------------------------------------ build

  /// Non-interactive explanation row inside a group.
  Widget _info(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }

  TextStyle? _guestCodeStyle(ThemeData theme) =>
      theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 1);

  Widget _field(Widget field) => Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 12), child: field);

  InputDecoration _decoration(String label, IconData icon) =>
      InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 20), border: const OutlineInputBorder());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = PlatformDetector.isTV();
    final canInvite = _status?.canInvite ?? false;
    final preview = _previewCode != null;

    return SettingsPage(
      title: const Text('Devices & access'),
      children: [
        SettingsGroup(
          title: 'Add a device',
          children: [
            _info(
              'On the other device, choose Quick Connect (or scan its QR code), then enter the code it shows here.',
            ),
            _field(
              FocusableTextField(
                controller: _code,
                // TV: arriving here shouldn't throw the keyboard over the page.
                tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textInputAction: TextInputAction.search,
                decoration: _decoration('Quick Connect code', Icons.pin_rounded),
                onChanged: (_) {
                  if (_previewCode != null) setState(() => _previewCode = null);
                },
                onSubmitted: (_) => _busy ? null : _find(),
              ),
            ),
            if (!preview)
              FocusableListTile(
                leading: _busy
                    ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.search_rounded, color: scheme.primary),
                title: const Text('Find device'),
                onTap: _busy ? null : _find,
              )
            else ...[
              ListTile(
                leading: Icon(Icons.devices_rounded, color: scheme.primary),
                title: Text(_previewLabel ?? '', style: theme.textTheme.titleMedium),
                subtitle: Text(
                  !_previewViaGate
                      ? 'This device did not announce itself, so only its sign-in will be approved.'
                      : _previewSameNetwork
                      ? 'On the same network as you'
                      : 'Wants to join Atlas+',
                ),
              ),
              FocusableListTile(
                autofocus: true,
                leading: Icon(Icons.check_circle_rounded, color: scheme.primary),
                title: const Text('Approve'),
                onTap: _busy ? null : _approve,
              ),
              FocusableListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('Not me'),
                onTap: _busy ? null : () => setState(() => _previewCode = null),
              ),
            ],
          ],
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: tv ? kTvSettingsMaxWidth : double.infinity),
                child: AtlasBanner(text: _message!, isError: _messageIsError),
              ),
            ),
          ),
        if (canInvite)
          SettingsGroup(
            title: 'Guest pass',
            children: [
              _info('Give someone temporary access, like for a movie night. It ends on its own.'),
              _field(
                FocusableTextField(
                  controller: _guestName,
                  tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  decoration: _decoration("Guest's name", Icons.person_rounded),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: ExpressiveButtonGroup<int>(
                  segments: const [
                    ButtonSegment(value: 24, label: Text('24 hours')),
                    ButtonSegment(value: 48, label: Text('48 hours')),
                    ButtonSegment(value: 168, label: Text('7 days')),
                  ],
                  selected: _guestHours,
                  onChanged: (v) => setState(() => _guestHours = v),
                ),
              ),
              FocusableListTile(
                leading: Icon(Icons.confirmation_number_rounded, color: scheme.primary),
                title: const Text('Create pass'),
                onTap: _busy ? null : _createGuestPass,
              ),
              if (_guestCode != null) ...[
                ListTile(
                  // SelectableText grabs D-pad focus and traps it on TV.
                  title: tv
                      ? Text(_guestCode!, style: _guestCodeStyle(theme))
                      : SelectableText(_guestCode!, style: _guestCodeStyle(theme)),
                  subtitle: Text(
                    'They enter it under "I have a code" in Atlas within 24 hours. '
                    'Access then lasts $_guestCodeHours hours.',
                  ),
                ),
                if (!tv)
                  FocusableListTile(
                    leading: const Icon(Icons.copy_rounded),
                    title: const Text('Copy code'),
                    onTap: () => Clipboard.setData(ClipboardData(text: _guestCode!)),
                  ),
              ],
            ],
          ),
        SettingsGroup(
          title: 'My devices',
          children: [
            if (_devices.isEmpty) _info('No devices to show.'),
            // The whole row is the target (select = remove): a trailing icon
            // button inside a row is unreachable with a D-pad.
            for (final d in _devices)
              FocusableListTile(
                leading: Icon(d['current'] == true ? Icons.smartphone_rounded : Icons.devices_rounded),
                title: Text((d['label'] as String?)?.isNotEmpty == true ? d['label'] as String : 'Device'),
                subtitle: Text(d['current'] == true ? 'This device' : 'Last seen ${_ago(d['lastSeen'] as num?)}'),
                trailing: d['current'] == true ? null : Icon(Icons.delete_outline_rounded, color: scheme.error),
                onTap: d['current'] == true ? null : () => _revoke(d),
              ),
          ],
        ),
        if (_status?.name != null && _status?.role != 'guest')
          SettingsGroup(
            title: 'Recovery code',
            children: [
              _info('Lets you get back in after deleting the app or switching phones, without asking anyone.'),
              FocusableListTile(
                leading: Icon(Icons.shield_rounded, color: scheme.primary),
                title: const Text('Make a new recovery code'),
                onTap: _newRecoveryCode,
              ),
            ],
          ),
        const SizedBox(height: 32),
      ],
    );
  }
}
