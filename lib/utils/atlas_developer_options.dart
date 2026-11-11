import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../media/ids.dart';
import '../providers/multi_server_provider.dart';
import '../services/base_shared_preferences_service.dart';
import '../services/settings_service.dart';

/// Atlas: debug settings and menus (debug logging, logs, the performance overlay, mpv config,
/// player backend, the adaptive-streaming switch) are for server admins only, and stay hidden
/// until an admin turns on Developer options in Settings > Advanced.
abstract final class AtlasDeveloperOptions {
  /// The switch itself, shown to admins only.
  static const pref = BoolPref('atlas_developer_options');

  /// Whether this user is an admin on any connected server.
  static bool isAdmin(BuildContext context) {
    final MultiServerProvider provider;
    try {
      provider = Provider.of<MultiServerProvider>(context, listen: false);
    } on ProviderNotFoundException {
      return false;
    }
    final manager = provider.serverManager;
    return manager.serverIds.any((id) => manager.isOwnerOrAdmin(ServerId(id)));
  }

  /// Whether debug settings and menus show: an admin with Developer options on.
  static bool visible(BuildContext context) => isAdmin(context) && SettingsService.instance.read(pref);
}
