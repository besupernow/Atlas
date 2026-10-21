/// Hosts that get the device key header. The key is never sent anywhere else.
const Set<String> kAtlasGateHosts = {'atlas.besupernow.com', 'requests.besupernow.com'};

/// Dependency-free holder for the device key so the low-level HTTP client can
/// attach it without importing any Flutter plugins.
class AtlasGateHeaders {
  AtlasGateHeaders._();

  static String? _key;

  static void setKey(String key) => _key = key;

  static String get key => _key ?? '';

  /// Header value for requests to Atlas hosts, null for everyone else.
  static String? forUri(Uri uri) {
    final k = _key;
    if (k == null || k.isEmpty || !kAtlasGateHosts.contains(uri.host)) return null;
    return k;
  }
}
