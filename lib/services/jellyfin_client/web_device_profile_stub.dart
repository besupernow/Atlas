/// Non-web builds keep the built-in mpv profile.
Map<String, Object?>? buildWebDeviceProfile({
  int? maxStreamingBitrate,
  required bool burnSubtitles,
  required bool audioProfile,
}) => null;
