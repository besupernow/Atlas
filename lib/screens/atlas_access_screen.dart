import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../focus/key_event_utils.dart';
import '../services/atlas_gate/atlas_gate.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
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
  final _nameFocus = FocusNode(debugLabel: 'AtlasAccess:Name');
  final _phoneFocus = FocusNode(debugLabel: 'AtlasAccess:Phone');
  final _codeFocus = FocusNode(debugLabel: 'AtlasAccess:Code');
  final _submitFocus = FocusNode(debugLabel: 'AtlasAccess:Submit');

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _code.dispose();
    _nameFocus.dispose();
    _phoneFocus.dispose();
    _codeFocus.dispose();
    _submitFocus.dispose();
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
    final tv = PlatformDetector.isTV();
    final onSubmit = _busy ? null : (isRequest ? _submitRequest : _submitCode);
    void cancel() => _close(AtlasAccessResult.cancelled);
    final muted = scheme.onSurface.withValues(alpha: 0.66);
    final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    const buttonText = TextStyle(fontWeight: FontWeight.w700, fontSize: 15);
    return Focus(
      canRequestFocus: false,
      // Remote / gamepad back closes the form like the Back button.
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event, result: AtlasAccessResult.cancelled),
      child: Scaffold(
        body: AtlasBackdrop(
          child: SafeArea(
            child: Stack(
              children: [
                const Positioned(left: 32, top: 24, child: AtlasWordmark(height: 28)),
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 80, 20, 32),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: tv ? 520 : 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            isRequest ? 'Request access' : 'Enter your code',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontSize: tv ? 34 : 30,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.6,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            isRequest
                                ? "Add your name and number. Someone on Atlas+ will approve you, and this screen moves on by itself."
                                : 'Use an invite code, a guest pass, or your recovery code.',
                            style: theme.textTheme.bodyLarge?.copyWith(color: muted, height: 1.4),
                          ),
                          const SizedBox(height: 28),
                          if (isRequest) _requestForm() else _codeForm(),
                          if (_error != null) ...[const SizedBox(height: 16), AtlasBanner(text: _error!)],
                          const SizedBox(height: 24),
                          FocusableButton(
                            focusNode: _submitFocus,
                            useBackgroundFocus: true,
                            onPressed: onSubmit,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: scheme.onSurface,
                                foregroundColor: scheme.surface,
                                padding: const EdgeInsets.symmetric(vertical: 18),
                                shape: buttonShape,
                                textStyle: buttonText,
                              ),
                              onPressed: onSubmit,
                              child: _busy
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.surface),
                                    )
                                  : Text(isRequest ? 'Send request' : 'Continue'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          FocusableButton(
                            useBackgroundFocus: true,
                            onPressed: cancel,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
                                foregroundColor: scheme.onSurface,
                                padding: const EdgeInsets.symmetric(vertical: 18),
                                shape: buttonShape,
                                textStyle: buttonText,
                              ),
                              onPressed: cancel,
                              child: const Text('Back'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon, {String? hint}) {
    final scheme = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c, width: w),
    );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: scheme.onSurface.withValues(alpha: 0.06),
      border: border(scheme.onSurface.withValues(alpha: 0.18)),
      enabledBorder: border(scheme.onSurface.withValues(alpha: 0.18)),
      focusedBorder: border(scheme.onSurface, 2),
    );
  }

  Widget _requestForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          FocusableTextFormField(
            controller: _name,
            focusNode: _nameFocus,
            autofocus: true,
            // TV: land on the field without throwing the keyboard over the
            // form; OK opens it.
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.name],
            decoration: _decoration('Your name', Icons.person_rounded),
            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null,
            onFieldSubmitted: (_) => _phoneFocus.requestFocus(),
            onNavigateDown: _phoneFocus.requestFocus,
          ),
          const SizedBox(height: 12),
          FocusableTextFormField(
            controller: _phone,
            focusNode: _phoneFocus,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: _decoration('Phone number', Icons.phone_rounded),
            validator: (v) => RegExp(r'\d').allMatches(v ?? '').length >= 7 ? null : 'Enter a valid phone number',
            onFieldSubmitted: (_) => _busy ? null : _submitRequest(),
            onNavigateUp: _nameFocus.requestFocus,
            onNavigateDown: _submitFocus.requestFocus,
          ),
        ],
      ),
    );
  }

  Widget _codeForm() {
    return FocusableTextField(
      controller: _code,
      focusNode: _codeFocus,
      autofocus: true,
      tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      decoration: _decoration('Code', Icons.vpn_key_rounded, hint: 'XXXX-XXXX-XXXX'),
      onSubmitted: (_) => _busy ? null : _submitCode(),
      onNavigateDown: _submitFocus.requestFocus,
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
  return showScopedDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final scheme = theme.colorScheme;
      return Dialog(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: AtlasGlassCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Save your recovery code',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
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
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: scheme.onSurface.withValues(alpha: 0.18)),
                  ),
                  // SelectableText grabs D-pad focus and traps it on TV.
                  child: Builder(
                    builder: (_) {
                      final style = theme.textTheme.titleLarge?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      );
                      return PlatformDetector.isTV()
                          ? Text(code, textAlign: TextAlign.center, style: style)
                          : SelectableText(code, textAlign: TextAlign.center, style: style);
                    },
                  ),
                ),
                const SizedBox(height: 20),
                FocusableButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onSurface,
                      foregroundColor: scheme.surface,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text("I've saved it"),
                  ),
                ),
                // Copying is pointless on a TV: no clipboard to paste from.
                if (!PlatformDetector.isTV()) ...[
                  const SizedBox(height: 8),
                  FocusableButton(
                    onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.onSurface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy code'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
