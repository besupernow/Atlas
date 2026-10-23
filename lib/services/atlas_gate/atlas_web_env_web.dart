import 'package:web/web.dart' as web;

/// `<img>` and `<video>` can't send `X-Atlas-Key`, so on web the device key
/// also rides along as a same-origin cookie the gate reads as a fallback.
void atlasWebSetKeyCookie(String key) {
  web.document.cookie = 'atlas_key=$key; Path=/; Max-Age=31536000; Secure; SameSite=Strict';
}

/// Ask the browser not to evict this origin's storage (device key, profiles,
/// settings). Best effort: browsers may ignore or silently deny it.
void atlasWebRequestPersistentStorage() {
  try {
    web.window.navigator.storage.persist();
  } catch (_) {}
}
