import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../profiles/active_profile_provider.dart';
import '../../../providers/libraries_provider.dart';
import '../../../providers/seerr_account_provider.dart';

/// Atlas: what music mode's pages are built from: the music libraries, whether Allseerr is
/// connected, and whose profile it is. Music mode is built at startup (behind the video side),
/// usually before the libraries have loaded or Allseerr has signed in, so a page that loads once
/// in initState comes up empty. Pages watch this instead and load (again) when it changes.
///
/// Call from build or didChangeDependencies; it subscribes [context] to those changes.
String watchMusicSources(BuildContext context) {
  final libraries = context.select<LibrariesProvider, String>(
    (p) => [for (final library in p.musicLibraries) '${library.serverId}/${library.id}'].join(','),
  );
  final seerr = context.select<SeerrAccountProvider?, bool>((s) => s?.catalogClient != null);
  final profile = context.select<ActiveProfileProvider?, String?>((p) => p?.activeId);
  return '$libraries|$seerr|$profile';
}
