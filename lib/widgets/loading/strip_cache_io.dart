import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _file() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'loading_strip.png'));
}

/// The strip saved at the end of the last launch.
Future<Uint8List?> readCachedStrip() async {
  try {
    final f = await _file();
    if (await f.exists()) return await f.readAsBytes();
  } catch (_) {}
  return null;
}

/// Saves the strip for the next launch. Written to a temp file and renamed,
/// so a launch never reads half a file.
Future<void> writeCachedStrip(Uint8List bytes) async {
  try {
    final f = await _file();
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  } catch (_) {}
}

const bool kRefreshesOwnStrip = true;
