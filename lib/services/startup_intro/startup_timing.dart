import 'dart:async';

import 'package:flutter/foundation.dart';

import 'intro_handoff_stub.dart' if (dart.library.js_interop) 'intro_handoff_web.dart';

/// Startup pacing:
///
/// 1. The intro clip always plays out before the app moves past the loading
///    screen (native: [StartupIntroOverlay]; web: web/index.html).
/// 2. After that the loading screen stays up for at least
///    [minLoadingVisible], so the artwork wordmark is actually seen and the
///    launch feels deliberate instead of flickering straight to home.
class StartupTiming {
  StartupTiming._();

  static const minLoadingVisible = Duration(seconds: 3);

  /// Never let a stuck intro (or a page that never reports) block startup.
  static const _introCap = Duration(seconds: 25);

  static DateTime _appStart = DateTime.now();
  static final Completer<void> _introDone = Completer<void>();
  static DateTime? _introEndedAt;

  static void markAppStart() => _appStart = DateTime.now();

  /// Native: the intro overlay is gone (finished, skipped, or nothing to
  /// play).
  static void markIntroDone() {
    if (_introDone.isCompleted) return;
    _introEndedAt = DateTime.now();
    _introDone.complete();
  }

  static Future<void> beforeLeavingLoading() async {
    final DateTime visibleSince;
    if (kIsWeb) {
      visibleSince = await _waitForWebIntro();
    } else {
      await _introDone.future.timeout(_introCap, onTimeout: () {});
      visibleSince = _introEndedAt ?? _appStart;
    }
    final remaining = visibleSince.add(minLoadingVisible).difference(DateTime.now());
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  }

  static Future<DateTime> _waitForWebIntro() async {
    final deadline = DateTime.now().add(_introCap);
    while (true) {
      final ms = readWebIntroEndMs();
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      if (DateTime.now().isAfter(deadline)) return DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
}
