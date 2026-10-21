import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../services/atlas_gate/atlas_gate.dart';
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $label?'),
        content: const Text('It will be signed out and will need to be approved again to come back.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make a new recovery code?'),
        content: const Text('Your old recovery code will stop working.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Make new code')),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canInvite = _status?.canInvite ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices & access')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _sectionTitle('Add a device'),
              const Text('On the other device, choose Quick Connect, then enter the code it shows here.'),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quick Connect code', border: OutlineInputBorder()),
                onChanged: (_) {
                  if (_previewCode != null) setState(() => _previewCode = null);
                },
                onSubmitted: (_) => _busy ? null : _find(),
              ),
              const SizedBox(height: 12),
              if (_previewCode == null)
                FilledButton(onPressed: _busy ? null : _find, child: const Text('Find device'))
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_previewLabel ?? '', style: Theme.of(context).textTheme.titleMedium),
                        if (_previewSameNetwork)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Icon(Icons.wifi_rounded, size: 16, color: scheme.primary),
                                const SizedBox(width: 6),
                                const Text('On the same network as you'),
                              ],
                            ),
                          ),
                        if (!_previewViaGate)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text('This device did not announce itself, so only its sign-in will be approved.'),
                          ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                autofocus: true,
                                onPressed: _busy ? null : _approve,
                                child: const Text('Approve'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _busy ? null : () => setState(() => _previewCode = null),
                              child: const Text('Not me'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!, style: TextStyle(color: _messageIsError ? scheme.error : scheme.primary)),
                ),
              if (canInvite) ...[
                _sectionTitle('Guest pass'),
                const Text('Give someone temporary access, like for a movie night. It ends on its own.'),
                const SizedBox(height: 12),
                TextField(
                  controller: _guestName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: "Guest's name", border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 24, label: Text('24 hours')),
                    ButtonSegment(value: 48, label: Text('48 hours')),
                    ButtonSegment(value: 168, label: Text('7 days')),
                  ],
                  selected: {_guestHours},
                  onSelectionChanged: (v) => setState(() => _guestHours = v.first),
                ),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _busy ? null : _createGuestPass, child: const Text('Create pass')),
                if (_guestCode != null)
                  Card(
                    margin: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            _guestCode!,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'They enter it under "Have a code?" in Atlas within 24 hours. '
                                'Access then lasts $_guestCodeHours hours.',
                          ),
                          TextButton.icon(
                            onPressed: () => Clipboard.setData(ClipboardData(text: _guestCode!)),
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('Copy code'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              _sectionTitle('My devices'),
              if (_devices.isEmpty) const Text('No devices to show.'),
              for (final d in _devices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_rounded),
                  title: Text((d['label'] as String?)?.isNotEmpty == true ? d['label'] as String : 'Device'),
                  subtitle: Text(d['current'] == true ? 'This device' : 'Last seen ${_ago(d['lastSeen'] as num?)}'),
                  trailing: d['current'] == true
                      ? null
                      : IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _revoke(d),
                  ),
                ),
              if (_status?.name != null && _status?.role != 'guest') ...[
                _sectionTitle('Recovery code'),
                const Text(
                  'Lets you get back in after deleting the app or switching phones, without asking anyone.',
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _newRecoveryCode, child: const Text('Make a new recovery code')),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
  );
}
