/// [mediaSegment] selects the endpoint family: Jellyfin serves the identical
/// static-stream contract under `/Videos/{id}/stream` and `/Audio/{id}/stream`
/// — music track playback passes `'Audio'`.
String buildJellyfinDirectStreamUrl({
  required String baseUrl,
  required String accessToken,
  required String tokenQueryParam,
  required String deviceId,
  required String itemId,
  String mediaSegment = 'Videos',
  String? container,
  String? mediaSourceId,
  String? playSessionId,
  String? liveStreamId,
  int? audioStreamIndex,
  bool containerExtension = false,
}) {
  final params = <String, String>{
    'Static': 'true',
    tokenQueryParam: accessToken,
    'DeviceId': deviceId,
    'Container': ?container,
    'MediaSourceId': ?mediaSourceId,
    'PlaySessionId': ?playSessionId,
    'LiveStreamId': ?liveStreamId,
    'AudioStreamIndex': ?audioStreamIndex?.toString(),
  };
  final encodedItem = Uri.encodeComponent(itemId);
  // `stream.{container}` is the canonical direct-play shape Jellyfin's own
  // clients hand external players: the extension is the only hint a player
  // gets about the payload (a bare `stream` path gives it nothing to sniff
  // for, which is fatal for disc images like ISO). Restricted to callers that
  // opt in via [containerExtension]; the extension is sanitized to a plain
  // alphanumeric suffix so a malformed Container can't inject path segments.
  final extension = containerExtension ? _safeContainerExtension(container) : null;
  final streamPath = extension == null ? 'stream' : 'stream.$extension';
  return '$baseUrl/$mediaSegment/$encodedItem/$streamPath?${_encodeQuery(params)}';
}

String? _safeContainerExtension(String? container) {
  final value = container?.trim();
  if (value == null || value.isEmpty) return null;
  // Lowercased to match jellyfin-web's `stream.{container}` construction.
  return RegExp(r'^[A-Za-z0-9]+$').hasMatch(value) ? value.toLowerCase() : null;
}

String buildJellyfinTrickplayTileUrl({
  required String baseUrl,
  required String accessToken,
  required String tokenQueryParam,
  required String deviceId,
  required String itemId,
  required int width,
  required int sheetIndex,
  String? mediaSourceId,
}) {
  final params = <String, String>{tokenQueryParam: accessToken, 'DeviceId': deviceId, 'MediaSourceId': ?mediaSourceId};
  final encodedItem = Uri.encodeComponent(itemId);
  return '$baseUrl/Videos/$encodedItem/Trickplay/$width/$sheetIndex.jpg?${_encodeQuery(params)}';
}

String _encodeQuery(Map<String, String> params) =>
    params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');

/// Atlas adaptive (ABR) master playlist: `/Videos/{id}/master.m3u8` with
/// `AtlasAbr=true`, which the Atlas server answers with a whole quality ladder.
///
/// What this asks for decides the top level. Stream copy is allowed for video
/// and audio, and no bitrate or size cap is sent, so a file the client can play
/// as-is comes back as the original (remuxed, not re-encoded) with transcoded
/// levels below it. The server adds those levels and their caps itself.
///
/// Subtitles are left out of the stream (no `SubtitleStreamIndex`): text
/// tracks travel as sidecar files, so switching them needs no new stream.
String buildJellyfinAtlasAdaptiveUrl({
  required String baseUrl,
  required String accessToken,
  required String tokenQueryParam,
  required String deviceId,
  required String itemId,
  required String mediaSourceId,
  required String playSessionId,
  required List<String> videoCodecs,
  required List<String> audioCodecs,
  required int maxAudioChannels,
  int? audioStreamIndex,
  int? startBitrate,
  int? startTicks,
  int? pinnedBitrate,
  int? pinnedHeight,
}) {
  final params = <String, String>{
    tokenQueryParam: accessToken,
    'DeviceId': deviceId,
    'MediaSourceId': mediaSourceId,
    'PlaySessionId': playSessionId,
    'VideoCodec': videoCodecs.join(','),
    'AudioCodec': audioCodecs.join(','),
    'AllowVideoStreamCopy': 'true',
    'AllowAudioStreamCopy': 'true',
    'SegmentContainer': 'mp4',
    'MinSegments': '1',
    'BreakOnNonKeyFrames': 'false',
    'RequireAvc': 'false',
    'EnableAudioVbrEncoding': 'true',
    'TranscodingMaxAudioChannels': '$maxAudioChannels',
    'AudioStreamIndex': ?audioStreamIndex?.toString(),
    'AtlasAbr': 'true',
    'AtlasStartBitrate': ?(startBitrate != null && startBitrate > 0 ? '$startBitrate' : null),
    // Where playback will begin, so the server can start transcoding that segment
    // while the player is still fetching playlists.
    'AtlasStartTicks': ?(startTicks != null && startTicks > 0 ? '$startTicks' : null),
    // A quality picked by hand: the server answers with just that one level.
    'AtlasMaxBitrate': ?(pinnedBitrate != null && pinnedHeight != null && pinnedBitrate > 0 ? '$pinnedBitrate' : null),
    'AtlasMaxHeight': ?(pinnedBitrate != null && pinnedHeight != null && pinnedHeight > 0 ? '$pinnedHeight' : null),
  };
  final encodedItem = Uri.encodeComponent(itemId);
  return '$baseUrl/Videos/$encodedItem/master.m3u8?${_encodeQuery(params)}';
}
