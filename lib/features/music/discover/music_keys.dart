/// Atlas: keys for the music services search talks to.
///
/// Last.fm: paste your API key between the quotes below, or leave it empty and build with
/// `--dart-define=LASTFM_API_KEY=yourkey`. Without one, search still works off Deezer and
/// MusicBrainz, just with less to go on for popularity.
abstract final class MusicKeys {
  static const _pastedLastFmKey = '5e68889f695e159f3752f9a0853fb8a2';

  static const lastFm = String.fromEnvironment('LASTFM_API_KEY', defaultValue: _pastedLastFmKey);

  /// Who MusicBrainz should contact about our traffic (they ask every app to say).
  static const musicBrainzUserAgent = 'Atlas/1.0 ( https://github.com/besupernow/Atlas )';
}
