/// What the web splash (web/index.html) already showed, so the Flutter
/// loading screen can pick up where it left off. Native has no web splash.
class LoadingHandoff {
  /// Artwork URLs the splash used, in order.
  final List<String> urls;

  /// When the splash started scrolling (ms since epoch), to keep the same
  /// position.
  final int? startMs;

  /// The splash already played the wordmark's entrance animation.
  final bool entranceDone;

  const LoadingHandoff({required this.urls, this.startMs, this.entranceDone = false});
}

LoadingHandoff? readLoadingHandoff() => null;

/// Tells the web splash it can fade out now (the Flutter copy has its art).
void signalLoadingArtReady() {}
