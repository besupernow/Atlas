import '../player.dart';

/// Non-web builds never reach this; the factory only calls it when kIsWeb.
Player createWebPlayer({bool audioOnly = false}) =>
    throw UnsupportedError('The web player is only available in web builds');
