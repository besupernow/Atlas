import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Android-only. Talks to AtlasBlockStore.kt (Google Block Store), which keeps
/// the device key across uninstall / reinstall. Every call is best-effort and
/// never throws: no Play services (Fire TV) just means "nothing stored".
class AtlasBlockStore {
  AtlasBlockStore._();

  static const MethodChannel _channel = MethodChannel('atlas/blockstore');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<String?> read(String key) async {
    if (!_supported) return null;
    try {
      // Timeout so a device with a broken/missing Play services never stalls startup.
      return await _channel
          .invokeMethod<String>('get', {'key': key})
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  static Future<bool> write(String key, String value) async {
    if (!_supported) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('put', {'key': key, 'value': value})
          .timeout(const Duration(seconds: 6));
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}
