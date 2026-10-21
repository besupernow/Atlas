
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/atlas_gate/atlas_gate.dart';

enum AtlasAccessMode { request, code }

/// The two small forms behind the "closed private server" page:
///   * request access (name + phone number), or
///   * enter an invite / guest / recovery code.
///
/// Pops with [AtlasAccessResult.approved] when the device is now in,
/// [AtlasAccessResult.requested] when a request is waiting for approval, or
/// [AtlasAccessResult.cancelled].
class AtlasAccessScreen extends StatefulWidget {
  final AtlasAccessMode mode;

  const AtlasAccessScreen({super.key, required this.mode});

  @override
  State<AtlasAccessScreen> createState() => _AtlasAccessScreenState();
}

class _AtlasAccessScreenState extends State<AtlasAccessScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _close(AtlasAccessResult result) {
    if (mounted) Navigator.of(context).pop(result);
  }

  static const _noConnection = "Couldn't reach the server. Check your connection and try again.";

  Future<void> _submitRequest() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await AtlasGate.requestAccess(name: _name.text.trim(), phone: _phone.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.failedToReach) {
      setState(() => _error = _noConnection);
    } else if (r.ok && r.state == 'approved') {
      _close(AtlasAccessResult.approved);
    } else if (r.ok) {
      _close(AtlasAccessResult.requested);
    } else if (r.status == 429) {
      setState(() => _error = 'Too many requests today. Please try again tomorrow.');
    } else if (r.status == 403) {
      setState(() => _error = "Access can't be requested from this device.");
    } else if (r.status == 503) {
      setState(() => _error = 'Atlas+ is not taking new requests right now.');
    } else if (r.status == 422) {
      setState(() => _error = 'Enter your name and a valid phone number.');
    } else {
      setState(() => _error = 'Something went wrong (${r.status}). Please try again.');
    }
  }

  Future<void> _submitCode() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await AtlasGate.redeem(code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      _close(AtlasAccessResult.approved);
    } else if (r.failedToReach) {
      setState(() => _error = _noConnection);
    } else if (r.status == 429) {
      setState(() => _error = 'Too many attempts. Please try again tomorrow.');
    } else if (r.status == 409) {
      setState(() => _error = 'That account already has the maximum number of devices.');
    } else {
      setState(() => _error = "That code didn't work.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRequest = widget.mode == AtlasAccessMode.request;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isRequest ? 'Request access' : 'Enter your code',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isRequest
                        ? "Tell us who you are and we'll let you know once you're approved."
                        : 'Enter an invite or guest code, or your personal recovery code.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  if (isRequest) _requestForm() else _codeForm(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    autofocus: false,
                    onPressed: _busy ? null : (isRequest ? _submitRequest : _submitCode),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(isRequest ? 'Send request' : 'Continue'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _close(AtlasAccessResult.cancelled),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _requestForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          TextFormField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Phone number', border: OutlineInputBorder()),
            validator: (v) => RegExp(r'\d').allMatches(v ?? '').length >= 7 ? null : 'Enter a valid phone number',
            onFieldSubmitted: (_) => _busy ? null : _submitRequest(),
          ),
        ],
      ),
    );
  }

  Widget _codeForm() {
    return TextField(
      controller: _code,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(labelText: 'Code', hintText: 'XXXX-XXXX-XXXX', border: OutlineInputBorder()),
      onSubmitted: (_) => _busy ? null : _submitCode(),
    );
  }
}

/// One-time prompt after the first successful sign-in on a new person: creates
/// a personal recovery code and shows it so a deleted app or a new phone can be
/// re-enrolled without asking anyone.
Future<void> promptAtlasRecoveryIfNeeded(BuildContext context, String jellyfinToken) async {
  const prefKey = 'atlas_recovery_prompted';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefKey) == true) return;
    final status = await AtlasGate.status();
    // Needs a real person on the gate (not a bypass via the tailnet) and a role that lasts.
    if (!status.approved || status.name == null || status.hasRecovery || status.role == 'guest') return;
    final res = await AtlasGate.newRecoveryCode(jellyfinToken);
    final code = res.json['code'] as String?;
    if (!res.ok || code == null) return;
    await prefs.setBool(prefKey, true);
    if (!context.mounted) return;
    await showAtlasRecoveryDialog(context, code);
  } catch (_) {
    // Never block the app over this.
  }
}

Future<void> showAtlasRecoveryDialog(BuildContext context, String code) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Save your recovery code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'If you ever delete Atlas or get a new phone, this code gets you back in without asking anyone. '
                'Keep it in your password manager.',
          ),
          const SizedBox(height: 16),
          SelectableText(code, style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          child: const Text('Copy'),
        ),
        FilledButton(autofocus: true, onPressed: () => Navigator.of(ctx).pop(), child: const Text("I've saved it")),
      ],
    ),
  );
}
