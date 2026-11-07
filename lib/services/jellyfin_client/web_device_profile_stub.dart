/// Non-web builds keep the built-in mpv profile.
Map<String, Object?>? buildWebDeviceProfile({
  int? maxStreamingBitrate,
  required bool burnSubtitles,
  required bool audioProfile,
}) => null;

/// What the browser can take in an Atlas adaptive (HLS) stream. Null off the web.
({List<String> video, List<String> audio, int? downlinkBps})? atlasWebAdaptiveCaps() => null;
