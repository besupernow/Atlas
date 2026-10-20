import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile_connection_registry.dart';

class AuthorizeDeviceScreen extends StatefulWidget {
  const AuthorizeDeviceScreen({super.key});
  @override
  State<AuthorizeDeviceScreen> createState() => _AuthorizeDeviceScreenState();
}

class _AuthorizeDeviceScreenState extends State<AuthorizeDeviceScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;
  Timer? _timer;


@override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _authorize() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() { _busy = true; _message = null; });
    try {
      final activeId = context.read<ActiveProfileProvider>().activeId;
      final pcs = await context.read<ProfileConnectionRegistry>().listForProfile(activeId!);
      final conns = await context.read<ConnectionRegistry>().list();
      final pc = pcs.firstWhere((p) => conns.any((c) => c.id == p.connectionId && c is JellyfinConnection));
      final conn = conns.firstWhere((c) => c.id == pc.connectionId) as JellyfinConnection;

      final base = conn.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final res = await http.post(
        Uri.parse('$base/QuickConnect/Authorize').replace(queryParameters: {'code': code}),
        headers: {
          'Authorization': 'MediaBrowser Client="Atlas", Device="Atlas", DeviceId="atlas", Version="1.0", Token="${pc.userToken}"',
          'X-Emby-Token': pc.userToken ?? '',
        },
      );
      if (!mounted) return;
      setState(() => _message = res.statusCode == 200
          ? 'Device approved. It should sign in within a few seconds.'
          : 'That code was rejected (${res.statusCode}). Check the code and try again.');
      if (res.statusCode == 200){
        _timer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            Navigator.pop(context);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Authorize a device')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('On the other device, choose Quick Connect, then enter the code it shows here.'),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quick Connect code'),
              onSubmitted: (_) => _busy ? null : _authorize(),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _authorize, child: const Text('Authorize')),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_message!)),
          ],
        ),
      ),
    );
  }
}
