/// Atlas: keys for the music services search talks to.
///
/// TIDAL: register an app at https://developer.tidal.com (free), then paste its Client ID and
/// Client Secret below, or build with `--dart-define=TIDAL_CLIENT_ID=…` and
/// `--dart-define=TIDAL_CLIENT_SECRET=…`. The app signs in as the app itself (client
/// credentials), never as anyone, so nothing it sees is tied to a person. Without them, search
/// runs on Deezer, Last.fm and MusicBrainz as before.
///
/// Last.fm: paste your API key between the quotes below, or leave it empty and build with
/// `--dart-define=LASTFM_API_KEY=yourkey`. Without one, search still works off Deezer and
/// MusicBrainz, just with less to go on for popularity.
abstract final class MusicKeys {
  static const _pastedLastFmKey = '';
  static const _pastedTidalClientId = '';
  static const _pastedTidalClientSecret = '';

  static const tidalClientId = String.fromEnvironment('TIDAL_CLIENT_ID', defaultValue: _pastedTidalClientId);
  static const tidalClientSecret = String.fromEnvironment('TIDAL_CLIENT_SECRET', defaultValue: _pastedTidalClientSecret);

  static const lastFm = String.fromEnvironment('LASTFM_API_KEY', defaultValue: _pastedLastFmKey);

  /// Who MusicBrainz should contact about our traffic (they ask every app to say).
  static const musicBrainzUserAgent = 'Atlas/1.0 ( https://github.com/besupernow/Atlas )';
}
