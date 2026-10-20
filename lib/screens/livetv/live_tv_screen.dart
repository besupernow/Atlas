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
  Timer? _hoverTimer;

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

  /// Hard-coded channel groups by channel-number range (edit freely). Channels
  /// are placed by the number Dispatcharr gives them; anything outside every
  /// range lands in "Other", last. Group/sub-group order is the order here.
  static const List<_AtlasGroup> kAtlasGroups = [
    _AtlasGroup('Atlas Original TV', 1, 60, [
      _AtlasGroup('News', 1, 10),
      _AtlasGroup('Movies', 11, 20),
      _AtlasGroup('Entertainment', 21, 30),
      _AtlasGroup('Kids', 31, 40),
      _AtlasGroup('Lifestyle', 41, 50),
      _AtlasGroup('Music', 51, 60),
    ]),
    _AtlasGroup('Sports', 61, 80, [
      _AtlasGroup('Live Sports', 61, 70),
      _AtlasGroup('Sports Talk', 71, 80),
    ]),
  ];
  static const String _kNoGroup = 'Other';

  /// Group currently at the top of the guide (highlighted chip). Chips jump
  /// the guide to a group; they never filter it.
  String? _selectedGroup;
  final List<FocusNode> _groupFocus = [];

  double? _numberOf(LiveTvChannel c) => double.tryParse((c.number ?? '').trim());

  /// (group index, sub index) for a channel; (-1, -1) when outside all ranges.
  (int, int) _slotOf(LiveTvChannel c) {
    final n = _numberOf(c);
    if (n == null) return (-1, -1);
    for (var gi = 0; gi < kAtlasGroups.length; gi++) {
      final g = kAtlasGroups[gi];
      if (n >= g.start && n < g.end + 1) {
        for (var si = 0; si < g.subs.length; si++) {
          final sub = g.subs[si];
          if (n >= sub.start && n < sub.end + 1) return (gi, si);
        }
        return (gi, -1);
      }
    }
    return (-1, -1);
  }

  String _groupOf(LiveTvChannel c) {
    final gi = _slotOf(c).$1;
    return gi < 0 ? _kNoGroup : kAtlasGroups[gi].name;
  }

  String? _subOf(LiveTvChannel c) {
    final (gi, si) = _slotOf(c);
    return gi < 0 || si < 0 ? null : kAtlasGroups[gi].subs[si].name;
  }

  /// Header text shown above each run of channels in the guide.
  String _headerFor(LiveTvChannel c) {
    final g = _groupOf(c);
    final sub = _subOf(c);
    return sub == null ? g : '$g · $sub';
  }

  List<LiveTvChannel> get _favoritesScoped => filterLiveTvChannelsForFavorites(
    channels: _channels,
    favoritesOnly: _showFavoritesOnly,
    favoritesLoaded: _favoritesLoaded,
    favorites: _favoriteChannels,
    sourceForChannel: _sourceForChannel,
  );

  /// Top-level groups present in the guide, in hard-coded order.
  List<String> get _groups {
    final present = <String>{for (final c in _favoritesScoped) _groupOf(c)};
    return [
      for (final g in kAtlasGroups)
        if (present.contains(g.name)) g.name,
      if (present.contains(_kNoGroup)) _kNoGroup,
    ];
  }

  /// All channels (favorites-scoped), ordered by group, sub-group, number.
  List<LiveTvChannel> get _filteredChannels {
    final list = _favoritesScoped;
    int key(LiveTvChannel c) {
      final (gi, si) = _slotOf(c);
      return (gi < 0 ? 999 : gi) * 1000 + (si < 0 ? 999 : si);
    }

    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final r = key(a.$2).compareTo(key(b.$2));
      if (r != 0) return r;
      final na = _numberOf(a.$2), nb = _numberOf(b.$2);
      if (na != null && nb != null && na != nb) return na.compareTo(nb);
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Dense layout for TVs and short landscape windows.
  bool get _compactLayout => PlatformDetector.isTV() || MediaQuery.sizeOf(context).height < 560;

  void _focusGroupRow() {
    final i = _selectedGroup == null ? 0 : _groups.indexOf(_selectedGroup!);
    if (i >= 0 && i < _groupFocus.length && _groupFocus[i].context != null) {
      _groupFocus[i].requestFocus();
    } else {
      _focusFilterRow();
    }
  }

  /// Where Up from the guide goes.
  void _upFromGuide() => _groups.isEmpty ? _focusFilterRow() : _focusGroupRow();

  void _jumpToGroup(String g) {
    setState(() => _selectedGroup = g);
    _guideTabKey.currentState?.scrollToGroup(g);
  }

  void _onVisibleGroupChanged(String g) {
    if (!mounted || _selectedGroup == g) return;
    setState(() => _selectedGroup = g);
    final i = _groups.indexOf(g);
    if (i >= 0 && i < _groupFocus.length) {
      final ctx = _groupFocus[i].context;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 200));
      }
    }
  }

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
    for (final n in _groupFocus) {
      n.dispose();
    }
    _resumeTimer?.cancel();
    _hoverTimer?.cancel();
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
      final groupedChannels = allChannels;

      appLogger.d('Live TV: loaded ${groupedChannels.length} channels');

      setState(() {
        _channels = groupedChannels;
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

  /// TV: just moving onto a channel previews it, after a short pause so
  /// scrolling through the list does not start a stream per row.
  void _onGuideChannelFocused(LiveTvChannel channel) {
    if (!PlatformDetector.isTV()) return;
    _hoverTimer?.cancel();
    final current = _previewChannel;
    if (current != null && liveTvChannelScopeKey(current) == liveTvChannelScopeKey(channel)) return;
    _hoverTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || !_tabVisible) return;
      _rememberChannel(channel);
      setState(() => _previewChannel = channel);
    });
  }

  /// Enlarges the SAME stream (no second player). A different channel is
  /// tuned into the mini player first, then expanded.
  Future<void> _openFullscreen([LiveTvChannel? channel]) async {
    if (!mounted) return;
    _hoverTimer?.cancel();
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
        toolbarHeight: _compactLayout ? 40 : null,
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
        onNavigateUp: _upFromGuide,
        onVisibleGroupChanged: _onVisibleGroupChanged,
        compact: true,
        groupLabelOf: _groups.isEmpty ? null : _headerFor,
        onBack: _goSidebar,
        onMenuKey: _toggleFavoritesFilter,
        onChannelTap: _onGuideChannelTap,
        onChannelFocused: _onGuideChannelFocused,
        initialChannel: _previewChannel,
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

    final compact = _compactLayout;
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

    // TV / short-landscape info column: channel + time on one line, title,
    // description, then the chip toolbar.
    final scheme = theme.colorScheme;
    final compactInfo = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (ch?.number != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(ch!.number!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            Flexible(
              child: Text(
                ch?.displayName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.hintColor, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            if (current != null) ...[
              Text('   ·   ', style: TextStyle(color: theme.hintColor, fontSize: 12)),
              Text(
                '${clock(current.beginsAt)} – ${clock(current.endsAt)}',
                style: TextStyle(color: theme.hintColor, fontSize: 12),
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text(
          programTitle ?? (ch?.displayName ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        if (episode != null && episode.isNotEmpty && episode != programTitle)
          Text(
            episode,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: theme.hintColor, fontSize: 12),
          ),
        if (summary != null && summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.hintColor, fontSize: 12, height: 1.25),
            ),
          ),
        const SizedBox(height: 10),
        _buildFilterRow(),
      ],
    );

    final hero = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 16, compact ? 6 : 8, wide ? 20 : 16, compact ? 8 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: compact ? 200 : (wide ? 240 : 168), child: preview),
          SizedBox(width: compact ? 18 : (wide ? 20 : 12)),
          Expanded(
            child: compact ? compactInfo : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  [if (ch?.number != null) ch!.number!, ch?.displayName ?? ''].join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: compact ? 2 : 4),
                Text(
                  programTitle ?? (ch?.displayName ?? ''),
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: (wide ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (!compact && episode != null && episode.isNotEmpty && episode != programTitle)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(episode, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                if (!compact && current != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${clock(current.beginsAt)} – ${clock(current.endsAt)}',
                      style: TextStyle(color: theme.hintColor, fontSize: 12),
                    ),
                  ),
                if (!compact && summary != null && summary.isNotEmpty)
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
        if (!compact) ...[_buildFilterRow(), _buildGroupRow()],
        Expanded(child: _buildTabContent(LiveTvTab.guide, guideChannels)),
      ],
    );
  }

  /// Group chips: tapping one jumps the guide to that group; the highlighted
  /// chip follows whichever group is at the top of the guide as you scroll.
  Widget _buildGroupRow({VoidCallback? leftTarget, VoidCallback? rightTarget, bool small = false}) {
    final groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    return _chipRow(
      labels: groups,
      selected: _selectedGroup ?? groups.first,
      nodes: _groupFocus,
      onSelect: (g) {
        if (g != null) _jumpToGroup(g);
      },
      onUp: _focusFilterRow,
      onDown: _focusCurrentTab,
      onLeftEdge: leftTarget,
      onRightEdge: rightTarget,
      small: small,
    );
  }

  Widget _chipRow({
    required List<String?> labels,
    required String? selected,
    required List<FocusNode> nodes,
    required void Function(String?) onSelect,
    required VoidCallback onUp,
    required VoidCallback onDown,
    VoidCallback? onLeftEdge,
    VoidCallback? onRight,
    VoidCallback? onRightEdge,
    bool vertical = false,
    bool small = false,
  }) {
    while (nodes.length < labels.length) {
      nodes.add(FocusNode(debugLabel: 'live_chip_${nodes.length}'));
    }
    final scheme = Theme.of(context).colorScheme;
    final list = ListView.separated(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      padding: vertical
          ? const EdgeInsets.fromLTRB(0, 0, 0, 8)
          : (small ? const EdgeInsets.fromLTRB(0, 0, 8, 0) : const EdgeInsets.fromLTRB(16, 0, 16, 8)),
      itemCount: labels.length,
      separatorBuilder: (_, _) => vertical ? const SizedBox(height: 6) : const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final g = labels[i];
        final isSel = selected == g;
        return Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            void step(int to) {
              nodes[to].requestFocus();
              Scrollable.ensureVisible(nodes[to].context!, alignment: 0.5);
            }

            final isPrev = vertical ? key == LogicalKeyboardKey.arrowUp : key.isLeftKey;
            final isNext = vertical ? key == LogicalKeyboardKey.arrowDown : key == LogicalKeyboardKey.arrowRight;
            if (isPrev) {
              if (i > 0) {
                step(i - 1);
              } else {
                (vertical ? onUp : (onLeftEdge ?? _goSidebar))();
              }
              return KeyEventResult.handled;
            }
            if (isNext) {
              if (i < labels.length - 1) {
                step(i + 1);
              } else if (!vertical) {
                onRightEdge?.call();
              }
              return KeyEventResult.handled;
            }
            // Cross axis: horizontal rows go up/down, vertical lists left/right.
            if (!vertical && key == LogicalKeyboardKey.arrowDown) {
              onDown();
              return KeyEventResult.handled;
            }
            if (!vertical && key == LogicalKeyboardKey.arrowUp) {
              onUp();
              return KeyEventResult.handled;
            }
            if (vertical && key.isLeftKey) {
              (onLeftEdge ?? _goSidebar)();
              return KeyEventResult.handled;
            }
            if (vertical && key == LogicalKeyboardKey.arrowRight) {
              (onRight ?? onDown)();
              return KeyEventResult.handled;
            }
            if (key.isBackKey) {
              _goSidebar();
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
                  color: isSel
                      ? scheme.primary.withValues(alpha: 0.22)
                      : scheme.surfaceContainerHighest.withValues(alpha: small ? 0.3 : 0.45),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: focused ? scheme.primary : Colors.transparent, width: 2),
                ),
                child: InkWell(
                  focusNode: nodes[i],
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onSelect(g),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: small ? 14 : 16, vertical: vertical ? 10 : (small ? 5 : 8)),
                    child: Text(
                      g ?? 'All',
                      style: TextStyle(
                        fontSize: small ? 12 : null,
                        fontWeight: FontWeight.w600,
                        color: isSel ? scheme.primary : null,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
    return vertical ? list : SizedBox(height: small ? 38 : 48, child: list);
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
      VoidCallback? onRight,
      VoidCallback? onLeft,
      bool dense = false,
      bool iconOnly = false,
    }) {
      final scheme = Theme.of(context).colorScheme;
      return Focus(
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowDown) {
            if (_groups.isEmpty || _compactLayout) {
              _focusCurrentTab();
            } else {
              _focusGroupRow();
            }
            return KeyEventResult.handled;
          }
          if (onRight != null && key == LogicalKeyboardKey.arrowRight) {
            onRight();
            return KeyEventResult.handled;
          }
          if (leftToSidebar && key.isLeftKey) {
            _goSidebar();
            return KeyEventResult.handled;
          }
          if (onLeft != null && key.isLeftKey) {
            onLeft();
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
                  padding: iconOnly
                      ? const EdgeInsets.all(8)
                      : EdgeInsets.symmetric(horizontal: dense ? 12 : 16, vertical: dense ? 8 : 10),
                  child: Row(
                    mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                    children: [
                      Icon(icon, size: 20, color: selected ? scheme.primary : null),
                      if (!iconOnly) const SizedBox(width: 8),
                      if (!iconOnly)
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: selected ? scheme.primary : null,
                            ),
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

    final compact = _compactLayout;
    if (compact) {
      // Lives inside the hero, under the now-playing text: chips on the left,
      // icon-only Search / Favorites on the right.
      return Row(
        children: [
          Expanded(
            child: _buildGroupRow(
              small: true,
              rightTarget: () => _searchPillFocus.requestFocus(),
            ),
          ),
          const SizedBox(width: 4),
          pill(
            node: _searchPillFocus,
            icon: Symbols.search_rounded,
            label: t.liveTv.searchGuide,
            onTap: _showGuideSearch,
            iconOnly: true,
            onLeft: _groups.isEmpty ? _goSidebar : _focusGroupRow,
            onRight: () => _favoritesPillFocus.requestFocus(),
          ),
          const SizedBox(width: 8),
          pill(
            node: _favoritesPillFocus,
            icon: _showFavoritesOnly ? Symbols.star_rounded : Symbols.star_outline_rounded,
            label: t.liveTv.favorites,
            onTap: _toggleFavoritesFilter,
            selected: _showFavoritesOnly,
            iconOnly: true,
            onLeft: () => _searchPillFocus.requestFocus(),
          ),
        ],
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

/// A channel-number range used to bucket channels into groups / sub-groups.
class _AtlasGroup {
  final String name;
  final int start;
  final int end;
  final List<_AtlasGroup> subs;
  const _AtlasGroup(this.name, this.start, this.end, [this.subs = const []]);
}
