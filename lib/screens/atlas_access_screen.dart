import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/atlas_gate/atlas_gate.dart';
import '../widgets/atlas_backdrop.dart';

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
    final scheme = theme.colorScheme;
    return Scaffold(
      body: AtlasBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: AtlasGlassCard(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          isRequest ? Icons.waving_hand_rounded : Icons.vpn_key_rounded,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        isRequest ? 'Request access' : 'Enter your code',
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isRequest
                            ? "Tell us who you are and we'll let you know once you're approved."
                            : 'Enter an invite or guest code, or your personal recovery code.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.70),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (isRequest) _requestForm() else _codeForm(),
                      if (_error != null) ...[const SizedBox(height: 16), AtlasBanner(text: _error!)],
                      const SizedBox(height: 22),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        onPressed: _busy ? null : (isRequest ? _submitRequest : _submitCode),
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(isRequest ? 'Send request' : 'Continue'),
                      ),
                      const SizedBox(height: 4),
                      TextButton(onPressed: () => _close(AtlasAccessResult.cancelled), child: const Text('Back')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon, {String? hint}) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: scheme.surface.withValues(alpha: 0.45),
      border: border(scheme.onSurface.withValues(alpha: 0.14)),
      enabledBorder: border(scheme.onSurface.withValues(alpha: 0.14)),
      focusedBorder: border(scheme.primary, 1.6),
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
            decoration: _decoration('Your name', Icons.person_rounded),
            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            decoration: _decoration('Phone number', Icons.phone_rounded),
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
      decoration: _decoration('Code', Icons.vpn_key_rounded, hint: 'XXXX-XXXX-XXXX'),
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
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final scheme = theme.colorScheme;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: AtlasGlassCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.shield_rounded, color: scheme.primary),
                ),
                const SizedBox(height: 18),
                Text(
                  'Save your recovery code',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
                ),
                const SizedBox(height: 8),
                Text(
                  'If you ever delete Atlas or get a new phone, this code gets you back in without asking anyone. '
                      'Keep it in your password manager.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.70),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: scheme.primary.withValues(alpha: 0.40)),
                  ),
                  child: SelectableText(
                    code,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  autofocus: true,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text("I've saved it"),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
