import 'dart:typed_data';

/// Web: the strip the web splash is showing right now (it keeps its own
/// cache in localStorage). Native: the strip saved at the end of the last
/// launch.
Future<Uint8List?> readCachedStrip() async => null;

/// Saves an encoded strip for the next launch (native only; the web splash
/// manages its own).
Future<void> writeCachedStrip(Uint8List bytes) async {}

/// Whether this platform refreshes the strip itself for next time.
const bool kRefreshesOwnStrip = false;
