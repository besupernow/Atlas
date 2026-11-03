import 'package:web/web.dart' as web;

/// Leave guest mode for the normal app start (sign-in or the device gate).
/// `replace` keeps the share link out of the back history.
void guestLeaveToApp() {
  final base = Uri.base;
  web.window.location.replace('${base.origin}${base.path}');
}

/// A redeemed session survives a page refresh in this tab, so a single-use
/// link doesn't lock the guest out on reload.
String? guestStoredSession(String code) {
  try {
    return web.window.sessionStorage.getItem('atlas_share_$code');
  } catch (_) {
    return null;
  }
}

void guestStoreSession(String code, String? json) {
  try {
    if (json == null) {
      web.window.sessionStorage.removeItem('atlas_share_$code');
    } else {
      web.window.sessionStorage.setItem('atlas_share_$code', json);
    }
  } catch (_) {}
}
