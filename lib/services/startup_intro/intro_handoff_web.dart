import 'package:web/web.dart' as web;

/// When web/index.html finished (or skipped) its intro clip, in ms since
/// epoch; null while it's still playing.
int? readWebIntroEndMs() {
  try {
    return int.tryParse(web.window.sessionStorage.getItem('atlas_intro_end') ?? '');
  } catch (_) {
    // Storage blocked: don't hold the app hostage to it.
    return DateTime.now().millisecondsSinceEpoch;
  }
}
