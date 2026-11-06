import 'dart:convert';

import 'package:web/web.dart' as web;

export 'loading_handoff_stub.dart' show LoadingHandoff;
import 'loading_handoff_stub.dart' show LoadingHandoff;

LoadingHandoff? readLoadingHandoff() {
  try {
    final store = web.window.sessionStorage;
    final shown = store.getItem('atlas_splash_shown') == '1';
    final raw = store.getItem('atlas_art');
    final t0 = int.tryParse(store.getItem('atlas_art_t0') ?? '');
    var urls = const <String>[];
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is List) urls = decoded.whereType<String>().toList();
    }
    if (!shown && urls.isEmpty) return null;
    return LoadingHandoff(urls: urls, startMs: t0, entranceDone: shown);
  } catch (_) {
    return null;
  }
}

void signalLoadingArtReady() {
  try {
    web.window.dispatchEvent(web.Event('atlas-loading-ready'));
  } catch (_) {}
}
