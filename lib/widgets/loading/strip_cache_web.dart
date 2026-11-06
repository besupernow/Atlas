import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// The strip the web splash (web/index.html) is showing right now, as a
/// data URL it left in sessionStorage. The splash keeps the cache and
/// prepares the next one itself.
Future<Uint8List?> readCachedStrip() async {
  try {
    final url = web.window.sessionStorage.getItem('atlas_strip_now');
    if (url == null) return null;
    final comma = url.indexOf(',');
    if (!url.startsWith('data:') || comma < 0) return null;
    return base64Decode(url.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

Future<void> writeCachedStrip(Uint8List bytes) async {}

const bool kRefreshesOwnStrip = false;
