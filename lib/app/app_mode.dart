import 'package:flutter/foundation.dart';

import '../services/base_shared_preferences_service.dart';
import '../services/settings_service.dart';

/// Atlas: which half of the app is showing. Video is everything Atlas did before music mode;
/// music is the separate music experience.
enum AppMode { video, music }

/// The current [AppMode], saved per device and restored on launch.
///
/// Switching modes only changes which shell is on screen. Both shells stay alive underneath, so
/// each comes back exactly where it was left, and music keeps playing across a switch.
class AppModeController extends ChangeNotifier {
  AppModeController._(this._settings) : _mode = _settings.read(pref);

  static const pref = EnumPref<AppMode>('atlas_app_mode', values: AppMode.values, defaultValue: AppMode.video);

  static AppModeController? _instance;

  /// One controller per app run; the saved mode is read the first time.
  static AppModeController get instance => _instance ??= AppModeController._(SettingsService.instance);

  final SettingsService _settings;
  AppMode _mode;

  AppMode get mode => _mode;
  bool get isMusic => _mode == AppMode.music;

  void setMode(AppMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    _settings.write(pref, mode);
  }

  void toggle() => setMode(isMusic ? AppMode.video : AppMode.music);

  @visibleForTesting
  static void resetForTesting() => _instance = null;
}
