import 'dart:async';
import '../../media/ids.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../focus/dpad_navigator.dart';
import '../../navigation/main_screen_scope.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../focus/focusable_action_bar.dart';
import '../../i18n/strings.g.dart';
import '../../media/live_tv_support.dart';
import '../../media/media_server_client.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_dvr.dart';
import '../../models/livetv_program.dart';
import '../../mixins/refreshable.dart';
import '../../mixins/tab_navigation_mixin.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../utils/live_tv_player_navigation.dart';
import 'live_tv_preview.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/settings_builder.dart';
import '../../utils/app_logger.dart';
import '../../utils/error_message_utils.dart';
import '../../utils/desktop_window_padding.dart';
import '../../utils/live_tv_matching.dart';
import '../../utils/platform_detector.dart';
import '../../utils/serial_future_queue.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../../widgets/overlay_sheet.dart';
import '../libraries/state_messages.dart';
import 'guide_search_sheet.dart';
import 'live_tv_server_iteration.dart';
import 'reorder_favorites_sheet.dart';
import 'tabs/guide_tab.dart';
import 'tabs/recordings_tab.dart';
import 'tabs/whats_on_tab.dart';

typedef _FavoriteScope = ({String source, String storeKey, FavoriteChannelPersistenceMode mode});

enum LiveTvTab { guide, whatsOn, recordings }

class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key});

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen>
    with TickerProviderStateMixin, TabNavigationMixin
    implements FocusableTab, ManualRefreshable, TabVisibilityAware {
  final _guideTabFocusNode = FocusNode(debugLabel: 'tab_chip_guide');
  final _whatsOnTabFocusNode = FocusNode(debugLabel: 'tab_chip_whats_on');
  final _recordingsTabFocusNode = FocusNode(debugLabel: 'tab_chip_recordings');
  final _guideTabKey = GlobalKey<GuideTabState>();
  final _whatsOnTabKey = GlobalKey<WhatsOnTabState>();
  final _recordingsTabKey = GlobalKey<RecordingsTabState>();

  /// Focus target for the "Show all channels" action shown when the favorites
  /// filter empties the guide; lets D-pad users reach the action from the tab bar.
  final _guideEmptyStateActionFocusNode = FocusNode(debugLabel: 'guide_empty_state_action');

  /// Visible tabs in the current session. What's On is included only when a
  /// Live TV server is Plex (the only backend with Live TV hubs), Recordings
  /// only when at least one Live TV server has `liveTvDvr` capability.
  List<LiveTvTab> _visibleTabs = [LiveTvTab.guide];

  /// Whether any connected DVR supports Plex-style rule re-evaluation;
  /// gates the recordings tab's bolt action.
  bool _canProcessRules = false;

  // Atlas guide layout
  static const _lastChannelPref = 'atlas_last_live_channel';
  final _previewKey = GlobalKey<LiveTvPreviewState>();
  final _searchPillFocus = FocusNode(debugLabel: 'live_search_pill');
  final _favoritesPillFocus = FocusNode(debugLabel: 'live_favorites_pill');
  LiveTvChannel? _previewChannel;
  Map<String, List<LiveTvProgram>> _guidePrograms = const {};
  bool _hasRecordings = false;
  bool _tabVisible = true;
  Timer? _resumeTimer;

  // App bar action bar
  final _actionBarKey = GlobalKey<FocusableActionBarState>();

  List<LiveTvChannel> _channels = [];
  bool _isLoading = true;
  String? _error;

  // Favorites
  bool _showFavoritesOnly = false;
  Set<String> _favoriteKeys = {};
  List<FavoriteChannel> _favoriteChannels = [];

  /// Favorite source URI, store key and persistence mode per Live TV server/DVR.
  /// The source is built from machineIdentifier + EPG provider identifier.
  final Map<String, _FavoriteScope> _favoriteScopeByLiveServer = {};
  final Map<String, String> _liveServerKeyByChannel = {};

  /// Store key per favorite source. A superset of the scope sources: it also
  /// collects sources of fetched and toggled favorites that belong to other
  /// servers sharing an account-scoped store.
  final Map<String, String> _favoriteStoreBySource = {};
  Future<void>? _channelsLoadFuture;
  int _favoritesLoadGeneration = 0;
  Future<void>? _favoritesLoadFuture;
  final SerialFutureQueue _favoritesMutationQueue = SerialFutureQueue();

  /// True while [_favoriteChannels] holds an authoritative set. A refresh keeps the previous set live until the new
  /// one commits, so the favorites filter never widens mid-load.
  bool _favoritesLoaded = false;
  bool _favoritesWritable = false;

  List<LiveTvChannel> get _filteredChannels => filterLiveTvChannelsForFavorites(
    channels: _channels,
    favoritesOnly: _showFavoritesOnly,
    favoritesLoaded: _favoritesLoaded,
    favorites: _favoriteChannels,
    sourceForChannel: _sourceForChannel,
  );

  /// True when the favorites filter removed every loaded channel, so the guide
  /// tab shows an explanatory empty state instead of a bare timeline.
  bool get _guideShowsFavoritesEmptyState => _channels.isNotEmpty && _filteredChannels.isEmpty;

  String _liveServerScopeKey(LiveTvServerInfo serverInfo) => '${serverInfo.serverId}\u0000${serverInfo.dvrKey}';

  _FavoriteScope? _favoriteScopeForChannel(LiveTvChannel channel) {
    final liveServerKey = _liveServerKeyByChannel[liveTvChannelScopeKey(channel)];
    return liveServerKey == null ? null : _favoriteScopeByLiveServer[liveServerKey];
  }

  String _sourceForChannel(LiveTvChannel channel) {
    return channel.favoriteSource ?? _favoriteScopeForChannel(channel)?.source ?? '';
  }

  String _favoriteKeyForChannel(LiveTvChannel channel) => favoriteChannelKey(_sourceForChannel(channel), channel.key);

  bool _isFavoriteChannel(LiveTvChannel channel) => _favoriteKeys.contains(_favoriteKeyForChannel(channel));

  void _refreshFavoriteKeys() {
    _favoriteKeys = _favoriteChannels.map((f) => f.stableKey).toSet();
  }

  @override
  List<FocusNode> get tabChipFocusNodes => [for (final tab in _visibleTabs) _focusNodeForTab(tab)];

  FocusNode _focusNodeForTab(LiveTvTab tab) => switch (tab) {
    LiveTvTab.guide => _guideTabFocusNode,
    LiveTvTab.whatsOn => _whatsOnTabFocusNode,
    LiveTvTab.recordings => _recordingsTabFocusNode,
  };

  @override
  void initState() {
    super.initState();
    suppressAutoFocus = true;
    _showFavoritesOnly = context.settingsRead(SettingsService.liveTvDefaultFavorites);
    unawaited(_restoreFavoritesFilter());
    final initialTabs = _tabStateFor(context.read<MultiServerProvider>());
    _visibleTabs = initialTabs.tabs;
    _canProcessRules = initialTabs.canProcessRules;
    _hasRecordings = initialTabs.hasRecordings;
    initTabNavigation();
    _loadChannels();
  }

  @override
  void dispose() {
    _guideTabFocusNode.dispose();
    _whatsOnTabFocusNode.dispose();
    _recordingsTabFocusNode.dispose();
    _guideEmptyStateActionFocusNode.dispose();
    _searchPillFocus.dispose();
    _favoritesPillFocus.dispose();
    _resumeTimer?.cancel();
    disposeTabNavigation();
    super.dispose();
  }

  @override
  void onTabChanged() {
    if (!tabController.indexIsChanging) {
      super.onTabChanged();
      // Pause/resume timers based on active tab
      if (tabController.index >= _visibleTabs.length) return;
      switch (_visibleTabs[tabController.index]) {
        case LiveTvTab.guide:
          _whatsOnTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.pauseRefresh();
          _guideTabKey.currentState?.resumeRefresh();
        case LiveTvTab.whatsOn:
          _guideTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.pauseRefresh();
          _whatsOnTabKey.currentState?.resumeRefresh();
        case LiveTvTab.recordings:
          _guideTabKey.currentState?.pauseRefresh();
          _whatsOnTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.resumeRefresh();
      }
    }
  }

  LiveTvTab? get _currentTab {
    if (tabController.index < 0 || tabController.index >= _visibleTabs.length) return null;
    return _visibleTabs[tabController.index];
  }

  @override
  void manualRefresh() => unawaited(_onRefresh());

  /// Tab-aware refresh handler bound to the AppBar refresh button.
  /// - Guide / What's On: server-side `reloadGuide` per DVR-capable client +
  ///   client-side channel re-fetch.
  /// - Recordings: re-fetches scheduled recordings + rules.
  Future<void> _onRefresh() async {
    if (_currentTab == LiveTvTab.recordings) {
      await _recordingsTabKey.currentState?.reload();
      return;
    }
    await _broadcastToDvrs(
      actionLabel: 'Reload guide',
      successMessage: t.liveTv.guideReloadRequested,
      failureMessage: t.liveTv.guideReloadFailed,
      action: (dvr, serverInfo) => dvr.reloadGuide(serverInfo.dvrKey),
    );
    await _loadChannels();
  }

  /// Runs [action] on every DVR-capable Live TV server in parallel, then
  /// reports the outcome: [successMessage] once every DVR accepted the
  /// request, otherwise an error naming the failure — `dvrAdminRequired`
  /// when every failure was a 403 (admin only), else [failureMessage].
  /// Per-DVR failures never abort the broadcast; they are logged under
  /// [actionLabel] and the remaining DVRs still run, since callers re-fetch
  /// their own client-side state regardless. Returns `true` once at least
  /// one DVR was reached and this widget is still mounted.
  Future<bool> _broadcastToDvrs({
    required String actionLabel,
    required String successMessage,
    required String failureMessage,
    required Future<void> Function(LiveTvDvrSupport dvr, LiveTvServerInfo serverInfo) action,
  }) async {
    final multiServer = context.read<MultiServerProvider>();
    var failed = 0;
    var adminBlocked = 0;
    Future<void> runSafely(LiveTvDvrSupport dvr, LiveTvServerInfo serverInfo) async {
      try {
        await action(dvr, serverInfo);
      } catch (e, stackTrace) {
        failed++;
        if (e is MediaServerHttpException && e.statusCode == 403) adminBlocked++;
        appLogger.w('$actionLabel failed for DVR ${serverInfo.dvrKey}', error: e, stackTrace: stackTrace);
      }
    }

    final futures = <Future<void>>[];
    for (final serverInfo in multiServer.liveTvServers) {
      final dvr = multiServer.getClientForServer(ServerId(serverInfo.serverId))?.liveTvDvr;
      if (dvr == null) continue;
      futures.add(runSafely(dvr, serverInfo));
    }
    if (futures.isEmpty) return false;
    await Future.wait(futures);
    if (!mounted) return false;
    if (failed == 0) {
      showSnackBar(context, successMessage);
    } else {
      final message = adminBlocked == failed ? t.liveTv.dvrAdminRequired : failureMessage;
      showSnackBar(context, message, type: SnackBarType.error);
    }
    return true;
  }

  Future<void> _processRecordingRules() async {
    final reached = await _broadcastToDvrs(
      actionLabel: 'processRecordingRules',
      successMessage: t.liveTv.rulesProcessRequested,
      failureMessage: t.liveTv.rulesProcessFailed,
      action: (dvr, _) => dvr.processRecordingRules(),
    );
    if (!reached) return;
    await _recordingsTabKey.currentState?.reload();
  }

  ({List<LiveTvTab> tabs, bool canProcessRules, bool hasRecordings}) _tabStateFor(MultiServerProvider multiServer) {
    var hasPlexServer = false;
    var hasDvr = false;
    var canProcessRules = false;
    for (final s in multiServer.liveTvServers) {
      final serverId = ServerId(s.serverId);
      // What's On lists Plex's Live TV hubs; Jellyfin and Emby have none, so
      // the tab would only ever be empty for them.
      hasPlexServer = hasPlexServer || multiServer.getPlexClientForServer(serverId) != null;
      final dvr = multiServer.getClientForServer(serverId)?.liveTvDvr;
      if (dvr == null) continue;
      hasDvr = true;
      canProcessRules = canProcessRules || dvr.supportsRuleProcessing;
    }
    return (
    // Atlas: the guide is the only tab; Recordings opens from a button.
    tabs: [LiveTvTab.guide],
    canProcessRules: canProcessRules,
    hasRecordings: hasDvr,
    );
  }

  /// Recompute visible tabs from the current MultiServerProvider state.
  /// Re-inits the tab controller when the visible set changes (matches the
  /// libraries-screen pattern at libraries_screen.dart:365).
  void _refreshVisibleTabs(MultiServerProvider multiServer) {
    final (tabs: newTabs, :canProcessRules, :hasRecordings) = _tabStateFor(multiServer);
    if (canProcessRules != _canProcessRules || hasRecordings != _hasRecordings) {
      setState(() {
        _canProcessRules = canProcessRules;
        _hasRecordings = hasRecordings;
      });
    }
    if (listEquals(_visibleTabs, newTabs)) return;
    final currentTab = tabController.index < _visibleTabs.length ? _visibleTabs[tabController.index] : null;
    disposeTabNavigation();
    _visibleTabs = newTabs;
    initTabNavigation();
    if (currentTab != null) {
      final newIndex = newTabs.indexOf(currentTab);
      if (newIndex >= 0) tabController.index = newIndex;
    }
  }

  /// Extracts enabled channel keys from DVR mappings, returning null if no DVR has mapping data.
  Set<String>? _extractEnabledChannelKeys(List<LiveTvDvr> dvrs) {
    final enabledKeys = <String>{};
    bool hasMappings = false;
    for (final dvr in dvrs) {
      if (dvr.channelMappings.isEmpty) continue;
      hasMappings = true;
      for (final m in dvr.channelMappings) {
        if (m.enabled == true && m.channelKey != null) {
          enabledKeys.add(m.channelKey!);
        }
      }
    }
    return hasMappings ? enabledKeys : null;
  }

  Set<String>? _extractEnabledChannelKeysForServerInfo(LiveTvServerInfo serverInfo) {
    final matching = serverInfo.dvrs.where((dvr) => dvr.key == serverInfo.dvrKey).toList();
    return _extractEnabledChannelKeys(matching.isNotEmpty ? matching : serverInfo.dvrs);
  }

  String? _sourceTitleForServerInfo(LiveTvServerInfo serverInfo) {
    for (final dvr in serverInfo.dvrs) {
      if (dvr.key == serverInfo.dvrKey) {
        return liveTvNonEmpty(dvr.lineupTitle) ?? liveTvNonEmpty(dvr.lineupURL) ?? liveTvNonEmpty(dvr.lineup);
      }
    }
    return liveTvNonEmpty(serverInfo.lineup);
  }

  Future<void> _loadChannels() {
    final inFlight = _channelsLoadFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> load;
    load = _loadChannelsOnce().whenComplete(() {
      if (identical(_channelsLoadFuture, load)) _channelsLoadFuture = null;
    });
    _channelsLoadFuture = load;
    return load;
  }

  Future<void> _loadChannelsOnce() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final multiServer = context.read<MultiServerProvider>();
      final liveTvServers = multiServer.liveTvServers;

      if (liveTvServers.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = t.liveTv.noDvr;
        });
        return;
      }

      final allChannels = <LiveTvChannel>[];
      final seenChannels = <String>{};
      final favoriteScopeByLiveServer = <String, _FavoriteScope>{};
      final liveServerKeyByChannel = <String, String>{};
      final favoriteStoreBySource = <String, String>{};

      appLogger.d(
        'Live TV DVRs: ${liveTvServers.map((s) => '${s.serverId}/${s.dvrKey} lineup=${s.lineup}').join(', ')}',
      );

      // Build a set of enabled channel keys per Live TV DVR from cached DVR data.
      final enabledKeysByLiveServer = <String, Set<String>>{};
      for (final serverInfo in liveTvServers) {
        final enabledKeys = _extractEnabledChannelKeysForServerInfo(serverInfo);
        if (enabledKeys != null) {
          enabledKeysByLiveServer[_liveServerScopeKey(serverInfo)] = enabledKeys;
        }
      }

      var serversTried = 0;
      var serversFailed = 0;
      Object? firstFailure;

      // One liveTvServers entry per DVR: visit them all; channels dedupe below.
      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        dedupeByServerId: false,
        body: (genericClient, serverInfo) async {
          serversTried++;
          final liveTv = genericClient.liveTv;
          final source = await liveTv.buildFavoriteChannelSource(lineup: serverInfo.lineup);
          final sourceTitle = _sourceTitleForServerInfo(serverInfo);
          final storeKey = liveTv.favoriteStoreKey;
          final liveServerKey = _liveServerScopeKey(serverInfo);
          favoriteScopeByLiveServer[liveServerKey] = (
          source: source,
          storeKey: storeKey,
          mode: liveTv.favoritePersistenceMode,
          );
          favoriteStoreBySource[source] = storeKey;

          final channels = await genericClient.liveTv.fetchChannels(lineup: serverInfo.lineup);
          // Plex's DVR exposes a separate enabled-channel mapping; Jellyfin
          // already filters to subscribed channels server-side.
          final enabledKeys = enabledKeysByLiveServer[liveServerKey];
          appLogger.d(
            'Channels from ${serverInfo.dvrKey}: ${channels.length} channels (${enabledKeys?.length ?? 'all'} enabled)',
          );
          for (final channel in channels) {
            if (enabledKeys != null && !enabledKeys.contains(channel.key)) continue;
            final scopedChannel = channel.copyWith(
              liveDvrKey: serverInfo.dvrKey,
              liveTvSourceTitle: sourceTitle,
              favoriteSource: source,
              favoriteStoreKey: storeKey,
            );
            final dedupKey = liveTvChannelScopeKey(scopedChannel);
            if (seenChannels.add(dedupKey)) {
              liveServerKeyByChannel[dedupKey] = liveServerKey;
              allChannels.add(scopedChannel);
            }
          }
        },
        onError: (client, serverInfo, error, stackTrace) {
          serversFailed++;
          firstFailure ??= error;
          appLogger.e('Failed to load channels from server ${serverInfo.serverId}', error: error);
        },
      );

      final failure = firstFailure;
      if (failure != null && serversFailed == serversTried) {
        if (!mounted) return;
        // Every server failed, so there is nothing to replace the loaded
        // channels with: keep them and report the failure, or show the error
        // state when there were none (not an empty "no channels" guide).
        final message = localizedLoadErrorText(failure, context: t.liveTv.title);
        final keepChannels = _channels.isNotEmpty;
        setState(() {
          _isLoading = false;
          if (!keepChannels) _error = message;
        });
        if (keepChannels) showErrorSnackBar(context, message);
        return;
      }

      allChannels.sort((a, b) {
        final aNum = double.tryParse(a.number ?? '') ?? 999999;
        final bNum = double.tryParse(b.number ?? '') ?? 999999;
        return aNum.compareTo(bNum);
      });

      if (!mounted) return;

      appLogger.d('Live TV: loaded ${allChannels.length} channels');

      setState(() {
        _channels = allChannels;
        _favoriteScopeByLiveServer
          ..clear()
          ..addAll(favoriteScopeByLiveServer);
        _liveServerKeyByChannel
          ..clear()
          ..addAll(liveServerKeyByChannel);
        _favoriteStoreBySource
          ..clear()
          ..addAll(favoriteStoreBySource);
        _isLoading = false;
      });

      _refreshVisibleTabs(multiServer);

      // Load favorites by backend store: Plex is cloud/account-scoped, Jellyfin per server.
      final favoritesLoad = _loadFavorites(multiServer);
      _favoritesLoadFuture = favoritesLoad;
      unawaited(
        favoritesLoad.whenComplete(() {
          if (identical(_favoritesLoadFuture, favoritesLoad)) {
            _favoritesLoadFuture = null;
          }
        }),
      );
      unawaited(favoritesLoad.catchError((Object _) {}).whenComplete(_ensurePreviewChannel));

      if (allChannels.isNotEmpty && PlatformDetector.shouldUseSideNavigation(context)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusCurrentTab();
        });
      }
    } catch (e, stackTrace) {
      final message = localizedLoadErrorMessage(e, stackTrace, context: t.liveTv.title);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = message;
        });
      }
    }
  }

  Future<void> _loadFavorites(MultiServerProvider multiServer) async {
    final loadGeneration = ++_favoritesLoadGeneration;
    _favoritesWritable = false;
    final previousStoreBySource = Map<String, String>.of(_favoriteStoreBySource);
    final scopeByLiveServer = Map<String, _FavoriteScope>.of(_favoriteScopeByLiveServer);
    final storeBySource = Map<String, String>.of(_favoriteStoreBySource);
    final merged = <FavoriteChannel>[];
    final successfulStores = <String>{};
    final failedStores = <String>{};
    final seenFavorites = <String>{};

    // One liveTvServers entry per DVR: register every favorite scope, but
    // fetch each favorite store only once.
    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      dedupeByServerId: false,
      body: (client, serverInfo) async {
        final liveTv = client.liveTv;
        final storeKey = liveTv.favoriteStoreKey;
        final liveServerKey = _liveServerScopeKey(serverInfo);

        final source = await liveTv.buildFavoriteChannelSource(lineup: serverInfo.lineup);
        scopeByLiveServer[liveServerKey] = (source: source, storeKey: storeKey, mode: liveTv.favoritePersistenceMode);
        storeBySource[source] = storeKey;
        if (successfulStores.contains(storeKey)) return;

        final serverFavorites = await liveTv.fetchFavoriteChannels();
        successfulStores.add(storeKey);
        failedStores.remove(storeKey);
        for (final favorite in serverFavorites) {
          storeBySource[favorite.source] = storeKey;
          if (seenFavorites.add(favorite.stableKey)) merged.add(favorite);
        }
      },
      onError: (client, serverInfo, error, stackTrace) {
        final storeKey = client.liveTv.favoriteStoreKey;
        if (!successfulStores.contains(storeKey)) failedStores.add(storeKey);
        appLogger.e('Failed to load favorite channels for $storeKey', error: error, stackTrace: stackTrace);
      },
    );

    // A failed store keeps its last committed in-memory slice. Healthy stores
    // still refresh, but mutations stay disabled until every store has loaded
    // so a later persist cannot replace the failed store with an empty list.
    for (final favorite in _favoriteChannels) {
      final storeKey = previousStoreBySource[favorite.source];
      if (storeKey != null && failedStores.contains(storeKey) && seenFavorites.add(favorite.stableKey)) {
        merged.add(favorite);
      }
    }

    if (!mounted || loadGeneration != _favoritesLoadGeneration) return;
    setState(() {
      _favoriteScopeByLiveServer
        ..clear()
        ..addAll(scopeByLiveServer);
      _favoriteStoreBySource
        ..clear()
        ..addAll(storeBySource);
      _favoriteChannels = merged;
      _refreshFavoriteKeys();
      _favoritesLoaded = failedStores.isEmpty || successfulStores.isNotEmpty || merged.isNotEmpty;
      _favoritesWritable = failedStores.isEmpty;
    });
    appLogger.d(
      'Live TV: loaded ${merged.length} favorite channels'
          '${failedStores.isEmpty ? '' : ' (${failedStores.length} store(s) deferred)'}',
    );
  }

  // ---- Atlas guide: preview channel, full screen, visibility ----

  /// Remembered channel → first favorite → first channel by number.
  Future<void> _ensurePreviewChannel() async {
    if (!mounted || _previewChannel != null || _channels.isEmpty) return;
    LiveTvChannel? pick;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_lastChannelPref);
      if (saved != null) {
        pick = _channels.where((c) => liveTvChannelScopeKey(c) == saved).firstOrNull;
      }
    } catch (_) {}
    if (pick == null && _favoritesLoaded) {
      final favs = filterLiveTvChannelsForFavorites(
        channels: _channels,
        favoritesOnly: true,
        favoritesLoaded: true,
        favorites: _favoriteChannels,
        sourceForChannel: _sourceForChannel,
      );
      pick = favs.firstOrNull;
    }
    pick ??= _channels.first; // already sorted by channel number
    if (!mounted || _previewChannel != null) return;
    setState(() => _previewChannel = pick);
  }

  void _rememberChannel(LiveTvChannel channel) {
    SharedPreferences.getInstance().then((p) => p.setString(_lastChannelPref, liveTvChannelScopeKey(channel))).catchError((_) => false);
  }

  /// Guide tap/select. TV: straight to full screen. Touch: load in the mini player.
  void _onGuideChannelTap(LiveTvChannel channel) {
    if (PlatformDetector.isTV()) {
      unawaited(_openFullscreen(channel));
      return;
    }
    _rememberChannel(channel);
    setState(() => _previewChannel = channel);
  }

  /// Enlarges the SAME stream (no second player). A different channel is
  /// tuned into the mini player first, then expanded.
  Future<void> _openFullscreen([LiveTvChannel? channel]) async {
    if (!mounted) return;
    if (channel != null) {
      _rememberChannel(channel);
      final cur = _previewChannel;
      if (cur == null || liveTvChannelScopeKey(cur) != liveTvChannelScopeKey(channel)) {
        setState(() => _previewChannel = channel);
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!mounted) return;
    await _previewKey.currentState?.openFullscreen();
  }

  @override
  void onTabShown() {
    _tabVisible = true;
    if (_resumeTimer?.isActive ?? false) return; // still in full screen
    _previewKey.currentState?.resume();
  }

  @override
  void onTabHidden() {
    _tabVisible = false;
    unawaited(_previewKey.currentState?.suspend());
  }

  void _focusFilterRow() {
    if (_searchPillFocus.context != null) _searchPillFocus.requestFocus();
  }

  void _openRecordings() {
    unawaited(_previewKey.currentState?.suspend());
    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(t.liveTv.recordings),
            actions: [
              if (_canProcessRules)
                IconButton(
                  icon: const Icon(Symbols.bolt_rounded),
                  tooltip: t.liveTv.processRecordingRules,
                  onPressed: _processRecordingRules,
                ),
              IconButton(
                icon: const Icon(Symbols.refresh_rounded),
                tooltip: t.common.refresh,
                onPressed: () => unawaited(_recordingsTabKey.currentState?.reload()),
              ),
            ],
          ),
          body: RecordingsTab(
            key: _recordingsTabKey,
            onNavigateUp: () {},
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    )
        .whenComplete(() {
      if (mounted && _tabVisible) _previewKey.currentState?.resume();
    });
  }

  static const _kFavFilterPref = 'atlas_live_tv_favorites_filter';

  /// The last Favorites on/off choice wins over the settings default.
  Future<void> _restoreFavoritesFilter() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_kFavFilterPref);
      if (saved != null && mounted && saved != _showFavoritesOnly) {
        setState(() => _showFavoritesOnly = saved);
      }
    } catch (_) {}
  }

  void _toggleFavoritesFilter() {
    setState(() {
      _showFavoritesOnly = !_showFavoritesOnly;
    });
    final value = _showFavoritesOnly;
    unawaited(
      SharedPreferences.getInstance().then((p) => p.setBool(_kFavFilterPref, value)).catchError((Object _) => false),
    );
  }

  void _goSidebar() {
    if (mounted) MainScreenFocusScope.focusSidebarOf(context);
  }

  /// Clears the favorites filter from the guide's empty state. When the action
  /// button owned the focus (TV/D-pad), hand focus to the guide content that
  /// replaces it so focus is not dropped.
  void _showAllChannelsFromEmptyState() {
    final hadFocus = _guideEmptyStateActionFocusNode.hasFocus;
    _toggleFavoritesFilter();
    if (!hadFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusCurrentTab();
    });
  }

  void _toggleFavorite(LiveTvChannel channel) {
    _enqueueFavoriteMutation(() {
      final source = _sourceForChannel(channel);
      final favoriteKey = favoriteChannelKey(source, channel.key);
      final storeKey = channel.favoriteStoreKey ?? _favoriteScopeForChannel(channel)?.storeKey;
      if (storeKey != null) _favoriteStoreBySource[source] = storeKey;

      setState(() {
        if (_favoriteKeys.contains(favoriteKey)) {
          _favoriteChannels = _favoriteChannels.where((f) => f.id != channel.key || f.source != source).toList();
        } else {
          _favoriteChannels = [..._favoriteChannels, FavoriteChannel.fromLiveTvChannel(channel, source)];
        }
        _refreshFavoriteKeys();
      });
    });
  }

  void _enqueueFavoriteMutation(VoidCallback mutation) {
    final pendingLoad = _favoritesLoadFuture;
    unawaited(
      _favoritesMutationQueue
          .run(() async {
        if (pendingLoad != null) await pendingLoad;
        if (!mounted) return;
        if (!_favoritesWritable) {
          showErrorSnackBar(context, t.liveTv.favoritesLoadFailed);
          return;
        }
        mutation();
        await _persistFavorites();
      })
          .catchError((Object error, StackTrace stackTrace) {
        appLogger.e('Failed to mutate favorite channels', error: error, stackTrace: stackTrace);
        if (mounted) {
          showErrorSnackBar(context, t.liveTv.favoritesUpdateFailed);
        }
      }),
    );
  }

  void _showGuideSearch() {
    OverlaySheetController.showAdaptive(
      context,
      isScrollControlled: true,
      builder: (sheetContext) => GuideSearchSheet(
        channels: _channels,
        onChannelSelected: _jumpToGuideChannel,
        onProgramSelected: (channel, program) => _jumpToGuideChannel(channel, program: program),
      ),
    );
  }

  void _jumpToGuideChannel(LiveTvChannel channel, {LiveTvProgram? program}) {
    // The guide only shows favorite rows while the filter is on — drop it so
    // the target channel's row exists to land on.
    if (_showFavoritesOnly && !_isFavoriteChannel(channel)) {
      setState(() => _showFavoritesOnly = false);
    }
    // Search opens from any tab, but results live in the guide grid. A tab
    // switch builds GuideTab fresh (no keep-alive); its jump methods stash
    // the request until the initial program load completes.
    final guideIndex = _visibleTabs.indexOf(LiveTvTab.guide);
    if (guideIndex >= 0 && tabController.index != guideIndex) {
      setState(() => tabController.index = guideIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final guide = _guideTabKey.currentState;
      if (guide == null) return;
      if (program != null) {
        unawaited(guide.jumpToProgram(channel, program));
      } else {
        guide.jumpToChannel(channel);
      }
    });
  }

  void _showReorderFavorites() {
    final channelMap = {for (final c in _channels) _favoriteKeyForChannel(c): c};

    OverlaySheetController.showAdaptive(
      context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => ReorderFavoritesSheet(
        favorites: List.from(_favoriteChannels),
        channelMap: channelMap,
        onReorder: (reordered) {
          _enqueueFavoriteMutation(() {
            setState(() {
              _favoriteChannels = reordered;
              _refreshFavoriteKeys();
            });
          });
        },
        onRemove: (removed) {
          _enqueueFavoriteMutation(() {
            setState(() {
              _favoriteChannels = _favoriteChannels.where((f) => f.stableKey != removed.stableKey).toList();
              _refreshFavoriteKeys();
            });
          });
        },
      ),
    );
  }

  Future<void> _persistFavorites() async {
    final multiServer = context.read<MultiServerProvider>();
    final byStore = <String, List<FavoriteChannel>>{};
    for (final favorite in _favoriteChannels) {
      final storeKey = _favoriteStoreBySource[favorite.source];
      if (storeKey == null) continue;
      byStore.putIfAbsent(storeKey, () => []).add(favorite);
    }
    final writtenStores = <String>{};
    final writes = <Future<void>>[];
    for (final serverInfo in multiServer.liveTvServers) {
      final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
      if (client == null) continue;
      final scope = _favoriteScopeByLiveServer[_liveServerScopeKey(serverInfo)];
      if (scope == null || !writtenStores.add(scope.storeKey)) continue;
      final storeChannels = byStore[scope.storeKey] ?? const <FavoriteChannel>[];
      final channels = switch (scope.mode) {
        FavoriteChannelPersistenceMode.sharedFullList => storeChannels,
        FavoriteChannelPersistenceMode.serverSlice =>
            storeChannels.where((favorite) => favorite.source == scope.source).toList(),
      };
      writes.add(client.liveTv.setFavoriteChannels(channels));
    }
    await Future.wait(writes);
  }

  void _focusCurrentTab() {
    if (tabController.index < _visibleTabs.length) {
      switch (_visibleTabs[tabController.index]) {
        case LiveTvTab.guide:
          final guideState = _guideTabKey.currentState;
          if (guideState != null) {
            guideState.focusContent();
          } else if (_guideShowsFavoritesEmptyState && _guideEmptyStateActionFocusNode.context != null) {
            _guideEmptyStateActionFocusNode.requestFocus();
          }
        case LiveTvTab.whatsOn:
          _whatsOnTabKey.currentState?.focusFirstHub();
        case LiveTvTab.recordings:
          _recordingsTabKey.currentState?.focusContent();
      }
    }
    setState(() {
      suppressAutoFocus = false;
    });
  }

  @override
  void focusActiveTabIfReady() => _focusCurrentTab();

  String _getTabLabel(LiveTvTab tab) {
    return switch (tab) {
      LiveTvTab.guide => t.liveTv.guide,
      LiveTvTab.whatsOn => t.liveTv.whatsOn,
      LiveTvTab.recordings => t.liveTv.recordings,
    };
  }

  List<Widget> _buildTabChipItems() {
    return [
      for (int i = 0; i < _visibleTabs.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        buildTabChip(
          _getTabLabel(_visibleTabs[i]),
          i,
          onSelectWhenActive: _focusCurrentTab,
          onNavigateDown: _focusCurrentTab,
          onNavigateToActions: () => _actionBarKey.currentState?.requestFocusOnFirst(),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final useSideNav = PlatformDetector.shouldUseSideNavigation(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.liveTv.title),
        actions: DesktopAppBarHelper.buildAdjustedActions([
          if (_hasRecordings)
            FocusableActionBar(
              key: _actionBarKey,
              onNavigateLeft: _focusFilterRow,
              onNavigateDown: _focusCurrentTab,
              actions: [
                FocusableAction(
                  icon: Symbols.fiber_dvr_rounded,
                  tooltip: t.liveTv.recordings,
                  onPressed: _openRecordings,
                ),
              ],
            ),
        ]),
      ),
      body: _buildLiveTvBody(useSideNav),
    );
  }

  Widget _buildTabContent(LiveTvTab tab, List<LiveTvChannel> guideChannels) {
    return switch (tab) {
      LiveTvTab.guide =>
      guideChannels.isEmpty && _channels.isNotEmpty
          ? LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: EmptyStateWidget(
                icon: Symbols.star_outline_rounded,
                message: t.liveTv.noFavoriteChannels,
                subtitle: t.liveTv.noFavoriteChannelsHint,
                actionLabel: t.liveTv.showAllChannels,
                actionIcon: Symbols.list_rounded,
                actionFocusNode: _guideEmptyStateActionFocusNode,
                onAction: _showAllChannelsFromEmptyState,
                onActionNavigateUp: _focusFilterRow,
                onActionBack: _goSidebar,
              ),
            ),
          ),
        ),
      )
          : GuideTab(
        key: _guideTabKey,
        channels: guideChannels,
        isFavoriteChannel: _isFavoriteChannel,
        onToggleFavorite: _toggleFavorite,
        onNavigateUp: _focusFilterRow,
        onBack: _goSidebar,
        onMenuKey: _toggleFavoritesFilter,
        onChannelTap: _onGuideChannelTap,
        onProgramsLoaded: (programs) {
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _guidePrograms = programs);
          });
        },
      ),
      LiveTvTab.whatsOn => WhatsOnTab(
        key: _whatsOnTabKey,
        channels: _channels,
        onNavigateUp: focusTabBar,
        onBack: onTabBarBack,
      ),
      LiveTvTab.recordings => RecordingsTab(key: _recordingsTabKey, onNavigateUp: focusTabBar, onBack: onTabBarBack),
    };
  }

  Widget _buildLiveTvBody(bool useSideNav) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorStateWidget(
        message: _error!,
        icon: Symbols.error_rounded,
        onRetry: _loadChannels,
        actionAutofocus: true,
        actionUseBackgroundFocus: true,
      );
    }
    if (_channels.isEmpty && !_visibleTabs.contains(LiveTvTab.recordings)) {
      return Center(child: Text(t.liveTv.noChannels));
    }

    final guideChannels = _filteredChannels;
    final isTv = PlatformDetector.isTV();
    final preview = LiveTvPreview(
      key: _previewKey,
      channel: _previewChannel,
      onFullscreen: _openFullscreen,
      showFullscreenButton: !isTv,
    );

    final wide = isTv || MediaQuery.sizeOf(context).width > 800;
    final ch = _previewChannel;
    final theme = Theme.of(context);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    LiveTvProgram? current;
    if (ch != null) {
      for (final pr in _guidePrograms[liveTvChannelScopeKey(ch)] ?? const <LiveTvProgram>[]) {
        if ((pr.beginsAt ?? 0) <= now && now < (pr.endsAt ?? 0)) {
          current = pr;
          break;
        }
      }
    }
    String clock(int? epoch) => epoch == null
        ? ''
        : MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(epoch * 1000)),
    );
    final episode = current == null
        ? null
        : [
      if (current.parentIndex != null && current.index != null) 'S${current.parentIndex} E${current.index}',
      if (current.grandparentTitle != null) current.title,
    ].join(' · ');
    final programTitle = current == null ? null : (current.grandparentTitle ?? current.title);
    final summary = current?.summary?.trim();

    final hero = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 16, 8, wide ? 20 : 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: wide ? 240 : 168, child: preview),
          SizedBox(width: wide ? 20 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  [if (ch?.number != null) ch!.number!, ch?.displayName ?? ''].join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  programTitle ?? (ch?.displayName ?? ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: (wide ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (episode != null && episode.isNotEmpty && episode != programTitle)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(episode, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                if (current != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${clock(current.beginsAt)} – ${clock(current.endsAt)}',
                      style: TextStyle(color: theme.hintColor, fontSize: 12),
                    ),
                  ),
                if (summary != null && summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      summary,
                      maxLines: wide ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.hintColor, fontSize: wide ? 14 : 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        hero,
        _buildFilterRow(),
        Expanded(child: _buildTabContent(LiveTvTab.guide, guideChannels)),
      ],
    );
  }

  /// Search pill + Favorites filter pill under the mini player.
  Widget _buildFilterRow() {
    Widget pill({
      required FocusNode node,
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool selected = false,
      bool expand = false,
      bool leftToSidebar = false,
    }) {
      final scheme = Theme.of(context).colorScheme;
      return Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowDown) {
            _focusCurrentTab();
            return KeyEventResult.handled;
          }
          if (leftToSidebar && key.isLeftKey) {
            _goSidebar();
            return KeyEventResult.handled;
          }
          if (key.isContextMenuKey) {
            _toggleFavoritesFilter();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.22)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: focused ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: InkWell(
                focusNode: node,
                borderRadius: BorderRadius.circular(999),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Icon(icon, size: 20, color: selected ? scheme.primary : null),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: selected ? scheme.primary : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: pill(
              node: _searchPillFocus,
              icon: Symbols.search_rounded,
              label: t.liveTv.searchGuide,
              onTap: _showGuideSearch,
              expand: true,
              leftToSidebar: true,
            ),
          ),
          const SizedBox(width: 10),
          pill(
            node: _favoritesPillFocus,
            icon: _showFavoritesOnly ? Symbols.star_rounded : Symbols.star_outline_rounded,
            label: t.liveTv.favorites,
            onTap: _toggleFavoritesFilter,
            selected: _showFavoritesOnly,
          ),
          if (_showFavoritesOnly && _favoriteChannels.length > 1) ...[
            const SizedBox(width: 6),
            IconButton(
              tooltip: t.liveTv.reorderFavorites,
              icon: const Icon(Symbols.swap_vert_rounded),
              onPressed: _showReorderFavorites,
            ),
          ],
        ],
      ),
    );
  }
}
