import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool webIsFullscreen() => web.document.fullscreenElement != null;

Future<void> webSetFullscreen(bool value) async {
  try {
    if (value) {
      await web.document.documentElement?.requestFullscreen().toDart;
    } else if (web.document.fullscreenElement != null) {
      await web.document.exitFullscreen().toDart;
    }
  } catch (_) {
    // Browsers refuse fullscreen without a user gesture; nothing to do.
  }
}

void webListenFullscreen(void Function(bool isFullscreen) onChange) {
  web.document.addEventListener('fullscreenchange', ((web.Event _) => onChange(webIsFullscreen())).toJS);
}
