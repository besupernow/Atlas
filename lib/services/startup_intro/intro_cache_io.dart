import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

/// Clips bigger than this are refused (a startup clip should be a few MB).
const int _maxBytes = 60 * 1024 * 1024;

final Set<String> _inFlight = {};

Future<Directory> _dir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'startup_intro'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String?> introCachedPath(String id) async {
  try {
    final f = File(p.join((await _dir()).path, '$id.mp4'));
    if (await f.exists() && await f.length() > 0) return f.path;
  } catch (_) {}
  return null;
}

Future<void> introDownload(String id, String url) async {
  if (!_inFlight.add(id)) return;
  final client = http.Client();
  File? tmp;
  try {
    final dir = await _dir();
    tmp = File(p.join(dir.path, '$id.part'));
    final res = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      appLogger.d('Startup intro: download of $id failed (HTTP ${res.statusCode})');
      return;
    }
    final sink = tmp.openWrite();
    var total = 0;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        total += chunk.length;
        if (total > _maxBytes) throw const FileSystemException('Startup intro clip too large');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    await tmp.rename(p.join(dir.path, '$id.mp4'));
    tmp = null;
    appLogger.i('Startup intro: cached $id (${(total / 1024 / 1024).toStringAsFixed(1)} MB)');
  } catch (e) {
    appLogger.d('Startup intro: download of $id failed: $e');
  } finally {
    client.close();
    _inFlight.remove(id);
    try {
      if (tmp != null && await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}

Future<void> introPrune(Set<String> keepIds) async {
  try {
    await for (final entity in (await _dir()).list()) {
      if (entity is! File) continue;
      final name = p.basenameWithoutExtension(entity.path);
      if (!keepIds.contains(name) && !_inFlight.contains(name)) await entity.delete();
    }
  } catch (_) {}
}
