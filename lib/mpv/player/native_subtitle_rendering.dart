/// A backend that can stop drawing subtitles itself while keeping the track
/// selected, so the Flutter-side overlay (`AtlasSubtitleOverlay`) draws them
/// instead. Selection, the track list and timing stay with the backend.
abstract interface class NativeSubtitleRendering {
  Future<void> setNativeSubtitleRendering(bool enabled);
}
