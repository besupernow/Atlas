import 'package:web/web.dart' as web;

final web.HTMLVideoElement _probe = web.HTMLVideoElement();

bool _can(String mime) => _probe.canPlayType(mime).isNotEmpty;

/// A DeviceProfile built from what this browser can actually decode, so the
/// server direct-plays only what will play and transcodes (HLS) the rest.
Map<String, Object?>? buildWebDeviceProfile({
  int? maxStreamingBitrate,
  required bool burnSubtitles,
  required bool audioProfile,
}) {
  final h264 = _can('video/mp4; codecs="avc1.640029"');
  final hevc = _can('video/mp4; codecs="hvc1.1.6.L153.B0"') || _can('video/mp4; codecs="hev1.1.6.L153.B0"');
  final av1 = _can('video/mp4; codecs="av01.0.15M.10"');
  final vp9 = _can('video/webm; codecs="vp9"');
  final vp8 = _can('video/webm; codecs="vp8"');

  final aac = _can('audio/mp4; codecs="mp4a.40.2"');
  final mp3 = _can('audio/mpeg');
  final ac3 = _can('audio/mp4; codecs="ac-3"');
  final eac3 = _can('audio/mp4; codecs="ec-3"');
  final opus = _can('audio/webm; codecs="opus"');
  final flac = _can('audio/flac') || _can('audio/mp4; codecs="flac"');
  final vorbis = _can('audio/ogg; codecs="vorbis"');

  final mp4Video = [if (h264) 'h264', if (hevc) ...['hevc', 'h265'], if (av1) 'av1'];
  final mp4Audio = [if (aac) 'aac', if (mp3) 'mp3', if (ac3) 'ac3', if (eac3) 'eac3', if (opus) 'opus', if (flac) 'flac'];
  final webmVideo = [if (vp8) 'vp8', if (vp9) 'vp9', if (av1) 'av1'];
  final webmAudio = [if (opus) 'opus', if (vorbis) 'vorbis'];
  final mkv = _can('video/x-matroska');

  final hlsVideo = [if (h264) 'h264', if (hevc) 'hevc', if (av1) 'av1'];
  final hlsAudio = [if (aac) 'aac', if (mp3) 'mp3', if (opus) 'opus', if (flac) 'flac', if (ac3) 'ac3', if (eac3) 'eac3'];

  return <String, Object?>{
    'Name': 'Atlas Web',
    'MaxStreamingBitrate': ?maxStreamingBitrate,
    'CodecProfiles': const <Map<String, Object?>>[],
    'DirectPlayProfiles': <Map<String, Object?>>[
      if (mp4Video.isNotEmpty)
        {
          'Type': 'Video',
          'Container': 'mp4,m4v,mov',
          'VideoCodec': mp4Video.join(','),
          'AudioCodec': mp4Audio.join(','),
        },
      if (webmVideo.isNotEmpty)
        {
          'Type': 'Video',
          'Container': 'webm',
          'VideoCodec': webmVideo.join(','),
          'AudioCodec': webmAudio.join(','),
        },
      if (mkv && (mp4Video.isNotEmpty || webmVideo.isNotEmpty))
        {
          'Type': 'Video',
          'Container': 'mkv',
          'VideoCodec': {...mp4Video, ...webmVideo}.join(','),
          'AudioCodec': {...mp4Audio, ...webmAudio}.join(','),
        },
      if (audioProfile)
        {
          'Type': 'Audio',
          'Container': [if (mp3) 'mp3', if (flac) 'flac', if (aac) ...['aac', 'm4a'], if (opus) 'webma'].join(','),
        },
    ],
    'TranscodingProfiles': <Map<String, Object?>>[
      {
        'Type': 'Video',
        'Container': 'mp4',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'VideoCodec': hlsVideo.isEmpty ? 'h264' : hlsVideo.join(','),
        'AudioCodec': hlsAudio.isEmpty ? 'aac' : hlsAudio.join(','),
        'MaxAudioChannels': '6',
      },
      // Live TV sources only negotiate MPEG-TS HLS (see the mpv profile).
      {
        'Type': 'Video',
        'Container': 'ts',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'VideoCodec': 'h264',
        'AudioCodec': 'aac,mp3',
        'MaxAudioChannels': '6',
      },
      if (audioProfile)
        const {
          'Type': 'Audio',
          'Container': 'mp3',
          'AudioCodec': 'mp3',
          'Protocol': 'http',
          'Context': 'Streaming',
          'MaxAudioChannels': '2',
        },
    ],
    // Browsers draw WebVTT cues only. Text subtitles come as external files
    // the server converts; anything without a matching entry (PGS etc.) is
    // burned into a transcode by the server.
    'SubtitleProfiles': <Map<String, Object?>>[
      if (!burnSubtitles)
        for (final format in const ['vtt', 'srt', 'ass', 'ssa']) {'Format': format, 'Method': 'External'},
    ],
  };
}
