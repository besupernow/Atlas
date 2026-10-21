/// `atlas://authorize?code=123456`: opens the "Devices & access" screen with a
/// Quick Connect code already filled in. The QR code on a waiting TV points at
/// the gate's join page, which hands the phone over to this link.
///
/// Opening the link only pre-fills the code. The approver still has to see the
/// device's name and tap Approve.
class AtlasAuthorizeLink {
  const AtlasAuthorizeLink(this.code);

  static const scheme = 'atlas';
  static const host = 'authorize';

  final String code;

  static AtlasAuthorizeLink? tryParse(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != scheme || uri.host != host) return null;
    final code = (uri.queryParameters['code'] ?? '').replaceAll(RegExp(r'\D'), '');
    if (code.length < 4 || code.length > 8) return null;
    return AtlasAuthorizeLink(code);
  }
}
