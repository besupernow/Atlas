import 'package:flutter/widgets.dart';

import '../../../services/jellyfin_client.dart';
import '../../../utils/provider_extensions.dart';
import 'music_catalog.dart';

/// Atlas: the Jellyfin server music mode talks to for its own settings (the Atlas server's
/// /Atlas/Music endpoints): the server behind the first music library, or the active server.
abstract final class MusicServer {
  static JellyfinClient? jellyfin(BuildContext context) {
    for (final source in MusicCatalog.of(context).sources) {
      if (source.client case final JellyfinClient client) return client;
    }
    if (context.tryGetMediaClientWithFallback(null) case final JellyfinClient client) return client;
    return null;
  }

  /// Whether the signed-in user can change other people's music settings.
  static bool isAdmin(BuildContext context) => jellyfin(context)?.connection.isAdministrator ?? false;
}
