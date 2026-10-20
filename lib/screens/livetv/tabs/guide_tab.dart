import 'dart:async';
import '../../../media/ids.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../focus/dpad_navigator.dart';
import '../../../focus/dpad_select_long_press_controller.dart';
import '../../../focus/focus_theme.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../focus/key_event_utils.dart';
import '../../../i18n/app_locale_utils.dart';
import '../../../i18n/strings.g.dart';
import '../../../mixins/mounted_set_state_mixin.dart';
import '../../../models/livetv_channel.dart';
import '../../../models/livetv_program.dart';
import '../../../models/media_grab_operation.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../media/media_server_client.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/app_logger.dart';
import '../live_tv_actions_mixin.dart';
import '../live_tv_refresh_mixin.dart';
import '../live_tv_server_iteration.dart';
import '../../../utils/formatters.dart';
import '../../../utils/live_tv_grouping.dart';
import '../../../utils/live_tv_matching.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/tone_mapped_logo_image.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/app_menu.dart';
import '../../../widgets/clickable_cursor.dart';
import '../../../widgets/optimized_media_image.dart';
import '../livetv_styles.dart';

class GuideTab extends StatefulWidget {
  final List<LiveTvChannel> channels;
  final bool Function(LiveTvChannel channel)? isFavoriteChannel;
  final void Function(LiveTvChannel)? onToggleFavorite;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onBack;

  /// Overrides what selecting a channel does (default: open full screen).
  final void Function(LiveTvChannel channel)? onChannelTap;

  /// Remote "Menu/Options" key pressed on the channel column or time bar.
  final VoidCallback? onMenuKey;

  /// A channel row took D-pad focus (arrow keys moved onto it).
  final void Function(LiveTvChannel channel)? onChannelFocused;

  /// When set, the guide inserts a header row whenever this label changes
  /// (channels must already be ordered by it).
  final String Function(LiveTvChannel channel)? groupLabelOf;

  /// The group header currently at the top of the guide changed (scroll spy).
  final void Function(String group)? onVisibleGroupChanged;

  /// Dense layout for TVs / short landscape screens: smaller rows, and the
  /// day/time label lives in the top-left corner instead of its own bar.
  final bool compact;

  /// Channel to land on when the guide first shows (the remembered one).
  final LiveTvChannel? initialChannel;

  /// Called whenever the guide data (re)loads, keyed by liveTvChannelScopeKey.
  final void Function(Map<String, List<LiveTvProgram>> programs)? onProgramsLoaded;

  const GuideTab({
    super.key,
    required this.channels,
    this.isFavoriteChannel,
    this.onToggleFavorite,
    this.onNavigateUp,
    this.onBack,
    this.onChannelTap,
    this.onMenuKey,
    this.onChannelFocused,
    this.groupLabelOf,
    this.onVisibleGroupChanged,
    this.compact = false,
    this.initialChannel,
    this.onProgramsLoaded,
  });

  @override
  State<GuideTab> createState() => GuideTabState();
}

@visibleForTesting
({String channelScopeKey, ({String kind, String value})? programId, int? beginsAt, int? endsAt}) guideAiringIdentity(
    LiveTvChannel channel,
    LiveTvProgram program,
    ) {
  ({String kind, String value})? programId;
  if (program.ratingKey case final ratingKey? when ratingKey.isNotEmpty) {
    programId = (kind: 'ratingKey', value: ratingKey);
  } else if (program.guid case final guid? when guid.isNotEmpty) {
    programId = (kind: 'guid', value: guid);
  } else if (program.key case final key? when key.isNotEmpty) {
    programId = (kind: 'key', value: key);
  }

  // Keep the slot even with an ID so repeated airings cannot inherit each
  // other's hold; with no ID, channel scope plus timing is the fallback.
  return (
  channelScopeKey: liveTvChannelScopeKey(channel),
  programId: programId,
  beginsAt: program.beginsAt,
  endsAt: program.endsAt,
  );
}

enum _GuideZone { timeNav, grid }

typedef _GuideFocusSnapshot = ({
bool hasFocus,
_GuideZone zone,
int timeNavIndex,
int channelIndex,
int gridColumn,
LiveTvProgram? program,
});

sealed class _GuideRow {
  const _GuideRow();
}

final class _GuideSourceHeaderRow extends _GuideRow {
  final String label;

  /// True for a sub-group header, drawn inset under its parent group.
  final bool inset;

  /// Channels under this header (shown as a muted count), when known.
  final int? count;

  /// Compact layout: sub-group shown inline after the group ("Group › Sub").
  final String? sub;

  const _GuideSourceHeaderRow({required this.label, this.inset = false, this.count, this.sub});
}

final class _GuideChannelRow extends _GuideRow {
  final LiveTvChannel channel;
  final int channelIndex;

  const _GuideChannelRow({required this.channel, required this.channelIndex});
}

class GuideTabState extends State<GuideTab>
    with LiveTvActionsMixin<GuideTab>, MountedSetStateMixin, WidgetsBindingObserver, LiveTvRefreshMixin<GuideTab> {
  @override
  Future<void> tuneChannel(LiveTvChannel channel) {
    final onTap = widget.onChannelTap;
    if (onTap != null) {
      onTap(channel);
      return Future<void>.value();
    }
    return super.tuneChannel(channel);
  }

  static const _slotWidth = 180.0;
  double get _channelColumnWidth => widget.compact ? 76.0 : 132.0;
  double get _rowHeight => widget.compact ? 50.0 : 64.0;
  double get _sourceHeaderRowHeight => widget.compact ? 30.0 : 44.0;
  double get _subHeaderRowHeight => widget.compact ? 22.0 : 32.0;
  double get _timeHeaderHeight => widget.compact ? 28.0 : 40.0;

  /// Slim bar above the time header holding the day status + "Now" pill.
  double get _statusBarHeight => widget.compact ? 34.0 : 0.0;
  static const _minutesPerSlot = 30;

  /// Minimum time away (backgrounded or on another section) before the
  /// viewport is realigned to the live line on return.
  static const _realignAfterAway = Duration(minutes: 30);

  List<LiveTvProgram> _programs = [];
  Map<String, List<LiveTvProgram>> _programsByChannelScope = const {};
  Set<String> _scheduledRecordingKeys = const {};

  /// Recording keys the user just scheduled/unscheduled from this guide.
  /// Local actions stay authoritative until the next full grid load returns
  /// fresh subscription attributes: the grab refresh below races the server
  /// materializing (or tearing down) grab operations, and the rendered
  /// programs keep their stale `subscriptionID` attributes until refetched.
  Map<String, bool> _recordingOverrides = const {};
  bool _isLoading = true;

  /// Whether a load has completed at least once for this tab. Until the
  /// first successful load the guide shows a full-screen spinner; in-session
  /// window reloads keep the existing grid mounted and only overlay a
  /// lightweight loading indicator. Never reset on channel-list changes:
  /// `didUpdateWidget` re-indexes the loaded programs and fires no fetch, and
  /// a reset would restore the unmount (and D-pad focus loss) this flag fixes.
  bool _hasLoadedOnce = false;
  int _programLoadGeneration = 0;

  late DateTime _gridStart;
  late DateTime _gridEnd;

  final ScrollController _headerHorizontalController = ScrollController();
  final ScrollController _gridHorizontalController = ScrollController();
  final ScrollController _channelVerticalController = ScrollController();
  final ScrollController _gridVerticalController = ScrollController();
  bool _syncingScroll = false;

  final _selectLongPressController = DpadSelectLongPressController();
  final _dayPickerKey = GlobalKey();

  // Stale-window catch-up state (#1297). The grid window is only auto
  // re-anchored when it was live-anchored and has drifted fully into the
  // past — deliberately picked day/time windows are never yanked.
  DateTime? _hiddenSince;
  bool _nowWasInWindow = true;
  bool _extendingWindow = false;
  static const _maxDaysAhead = 7;

  // Focus state
  final FocusNode _guideFocusNode = FocusNode(debugLabel: 'guide_tab');
  _GuideZone _focusZone = _GuideZone.timeNav;
  int _timeNavIndex = 1; // 0=left arrow, 1=day picker, 2=right arrow
  int _gridChannelIndex = 0;
  bool _initialChannelApplied = false;
  bool _userNavigated = false;
  int _gridColumn = 0; // 0=channel, 1=program
  bool _hasFocus = false;
  final ValueNotifier<_GuideFocusSnapshot> _focusSnapshot = ValueNotifier((
  hasFocus: false,
  zone: _GuideZone.timeNav,
  timeNavIndex: 1,
  channelIndex: 0,
  gridColumn: 0,
  program: null,
  ));
  LiveTvProgram? _focusedProgram;
  bool _pendingFocus = false;

  @override
  List<LiveTvChannel> get liveTvChannels => widget.channels;

  // Jump requested while programs were still loading (guide search from
  // another tab lands on a freshly built guide) — replayed by _loadPrograms.
  LiveTvChannel? _pendingJumpChannel;
  LiveTvProgram? _pendingJumpProgram;

  /// Focus into the guide content (called from tab bar navigation or initial load).
  void focusContent() {
    if (!InputModeTracker.isKeyboardMode(context)) return;
    // If still loading programs, defer until the Focus widget is in the tree.
    if (_isLoading) {
      _pendingFocus = true;
      return;
    }
    _pendingFocus = false;
    _guideFocusNode.requestFocus();
    _updateFocus(() {
      if (widget.channels.isNotEmpty) {
        _focusZone = _GuideZone.grid;
        _gridColumn = 0;
        _gridChannelIndex = _firstVisibleChannelIndex();
        _focusedProgram = null;
      } else {
        _focusZone = _GuideZone.timeNav;
        _timeNavIndex = 1;
      }
    });
  }

  /// Jump the guide to [channel] (from guide search): scroll to its row and
  /// land d-pad focus on the channel cell in keyboard mode.
  void jumpToChannel(LiveTvChannel channel) {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = null;
      return;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return;

    // Focus state renders through _focusSnapshot listeners; _updateFocus
    // publishes it (a bare setState would leave the cells unchanged).
    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = 0;
      _focusedProgram = null;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToChannel(index);
    });
  }

  /// Jump the guide to [program] on [channel] (from guide search), shifting
  /// the time window first when the airing isn't visible in the current one.
  Future<void> jumpToProgram(LiveTvChannel channel, LiveTvProgram program) async {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = program;
      return;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return;

    final begin = program.startTime;
    final end = program.endTime ?? begin;
    final intersectsWindow = begin != null && end != null && begin.isBefore(_gridEnd) && end.isAfter(_gridStart);
    if (begin != null && !intersectsWindow) {
      // Same window mechanics as the day/time-slot picker: anchor a fresh
      // 6-hour window one slot before the program and reload.
      var start = DateTime(begin.year, begin.month, begin.day, begin.hour, begin.minute >= 30 ? 30 : 0);
      start = start.subtract(const Duration(minutes: 30));
      setState(() {
        _gridStart = start;
        _gridEnd = start.add(const Duration(hours: 6));
        _nowWasInWindow = _nowInWindow(DateTime.now());
      });
      await _loadPrograms();
      if (!mounted) return;
    }

    // Re-resolve against the loaded list — the search sheet's program objects
    // come from its own fetch and never match _programs by identity.
    final target = _getProgramsForChannel(
      widget.channels[index],
    ).where((p) => p.beginsAt == program.beginsAt).firstOrNull;

    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = target != null ? 1 : 0;
      _focusedProgram = target;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToChannel(index);
      if (target != null) _scrollToProgramTime(target);
    });
  }

  int? _channelIndexFor(LiveTvChannel channel) {
    final scopeKey = liveTvChannelScopeKey(channel);
    for (var i = 0; i < widget.channels.length; i++) {
      if (liveTvChannelScopeKey(widget.channels[i]) == scopeKey) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initTimeRange();
    _loadPrograms();
    _applyInitialChannel();

    _gridHorizontalController.addListener(_syncGridToHeader);
    _headerHorizontalController.addListener(_syncHeaderToGrid);
    _gridHorizontalController.addListener(_maybeExtendWindow);
    _gridVerticalController.addListener(_onVerticalScrollSpy);
  }

  // Not the gated data-refresh timer the other tabs run: the tick is a
  // per-minute UI ticker that advances the time indicator and re-anchors a
  // live-anchored window that drifted fully into the past.
  @override
  Duration get refreshInterval => const Duration(minutes: 1);

  @override
  void onRefreshTick() {
    _checkWindowDrift();
    // ignore: no-empty-block - setState triggers rebuild to update time indicator
    setStateIfMounted(() {});
  }

  // Pause has to stamp _hiddenSince on a tab switch, a section hide, and an
  // app background alike so _catchUpIfStale can measure the absence.
  @override
  void onRefreshPaused() {
    _hiddenSince ??= DateTime.now();
  }

  @override
  void onRefreshResumed(LiveTvRefreshResumeReason reason) {
    unawaited(_refreshScheduledRecordingKeys());
    // Post-frame: resume fires during tab transitions/build and the catch-up
    // may setState (reload or scroll).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _catchUpIfStale();
    });
  }

  /// Select (and scroll to) the remembered channel once the list is known.
  void _applyInitialChannel() {
    if (_initialChannelApplied) return;
    final target = widget.initialChannel;
    if (target == null || widget.channels.isEmpty) return;
    _initialChannelApplied = true;
    final key = liveTvChannelScopeKey(target);
    final index = widget.channels.indexWhere((c) => liveTvChannelScopeKey(c) == key);
    if (index < 0) return;
    void apply() {
      if (!mounted || _userNavigated || index >= widget.channels.length) return;
      _updateFocus(() => _gridChannelIndex = index);
      _scrollToChannel(index);
    }

    // The grid may not be laid out yet (guide data still loading): retry.
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    Future<void>.delayed(const Duration(milliseconds: 500), apply);
    Future<void>.delayed(const Duration(milliseconds: 1500), apply);
  }

  @override
  void didUpdateWidget(GuideTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyInitialChannel();
    if (!identical(oldWidget.channels, widget.channels)) {
      _programsByChannelScope = _indexProgramsByChannel(_programs, widget.channels);
    }
    if (widget.channels.isNotEmpty && _gridChannelIndex >= widget.channels.length) {
      _gridChannelIndex = widget.channels.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publishFocusSnapshot();
      });
    }
  }

  @override
  void dispose() {
    _programLoadGeneration++;
    _selectLongPressController.dispose();
    _guideFocusNode.dispose();
    _gridVerticalController.dispose();
    _gridVerticalController.removeListener(_onVerticalScrollSpy);
    _gridHorizontalController.removeListener(_maybeExtendWindow);
    _gridHorizontalController.removeListener(_syncGridToHeader);
    _headerHorizontalController.removeListener(_syncHeaderToGrid);
    _headerHorizontalController.dispose();
    _gridHorizontalController.dispose();
    _channelVerticalController.dispose();
    _focusSnapshot.dispose();
    super.dispose();
  }

  void _handleGuideFocusChange(bool hasFocus) {
    if (_hasFocus == hasFocus) return;
    if (!hasFocus) _resetSelectLongPressState();
    _hasFocus = hasFocus;
    _publishFocusSnapshot();
  }

  void _updateFocus(VoidCallback update) {
    update();
    _publishFocusSnapshot();
  }

  void _publishFocusSnapshot() {
    _focusSnapshot.value = (
    hasFocus: _hasFocus,
    zone: _focusZone,
    timeNavIndex: _timeNavIndex,
    channelIndex: _gridChannelIndex,
    gridColumn: _gridColumn,
    program: _focusedProgram,
    );
  }

  void _resetSelectLongPressState() => _selectLongPressController.reset();

  void _syncGridToHeader() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_headerHorizontalController.hasClients) {
      _headerHorizontalController.jumpTo(_gridHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _syncHeaderToGrid() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_gridHorizontalController.hasClients) {
      _gridHorizontalController.jumpTo(_headerHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _initTimeRange() {
    final now = DateTime.now();
    _gridStart = DateTime(now.year, now.month, now.day, now.hour);
    if (now.minute >= 30) {
      _gridStart = _gridStart.add(const Duration(minutes: 30));
    }
    _gridStart = _gridStart.subtract(const Duration(hours: 1));
    _gridEnd = _gridStart.add(const Duration(hours: 6));
    _nowWasInWindow = true;
  }

  void _shiftTimeRange(int hours) {
    setState(() {
      _gridStart = _gridStart.add(Duration(hours: hours));
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    _loadPrograms();
  }

  void _jumpToNow() {
    _initTimeRange();
    _loadPrograms();
  }

  bool _nowInWindow(DateTime now) => !now.isBefore(_gridStart) && now.isBefore(_gridEnd);

  /// Timer path: re-anchor only when a live-anchored window drifted fully past.
  void _checkWindowDrift() {
    if (!isRefreshSubtreeVisible || _isLoading) return;
    if (_nowWasInWindow && !_nowInWindow(DateTime.now())) _jumpToNow();
  }

  /// Active path (app resume / guide became visible): drift-jump, else
  /// realign the viewport to the live line after a meaningful absence (#1297).
  void _catchUpIfStale() {
    if (!isRefreshSubtreeVisible) return; // still hidden — keep _hiddenSince
    final hiddenSince = _hiddenSince;
    _hiddenSince = null; // evaluated while visible — consume it
    if (_isLoading) return; // in-flight load already ends in _scrollToNow()
    final now = DateTime.now();
    if (_nowWasInWindow && !_nowInWindow(now)) {
      _jumpToNow();
    } else if (_nowInWindow(now) && hiddenSince != null && now.difference(hiddenSince) >= _realignAfterAway) {
      _scrollToNow();
    }
  }

  bool _isCurrentProgramLoad(int generation) => mounted && generation == _programLoadGeneration;

  Future<void> _loadPrograms() async {
    if (!mounted) return;
    final loadGeneration = ++_programLoadGeneration;
    final requestGridStart = _gridStart;
    final requestGridEnd = _gridEnd;
    final startEpoch = requestGridStart.millisecondsSinceEpoch ~/ 1000;
    final endEpoch = requestGridEnd.millisecondsSinceEpoch ~/ 1000;
    final from = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);
    final to = DateTime.fromMillisecondsSinceEpoch(endEpoch * 1000, isUtc: true);
    setState(() => _isLoading = true);

    try {
      final allPrograms = <LiveTvProgram>[];
      final scheduledRecordingKeys = <String>{};
      final multiServer = context.read<MultiServerProvider>();

      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        isCurrent: () => _isCurrentProgramLoad(loadGeneration),
        body: (client, serverInfo) async {
          final programs = await client.liveTv.fetchSchedule(from: from, to: to);
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          allPrograms.addAll(programs);
          await _addScheduledRecordingKeysForServer(
            client: client,
            serverId: ServerId(serverInfo.serverId),
            keys: scheduledRecordingKeys,
            isCurrent: () => _isCurrentProgramLoad(loadGeneration),
          );
        },
        onError: (client, serverInfo, error, stackTrace) {
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          appLogger.e('Failed to load programs from server ${serverInfo.serverId}', error: error);
        },
      );

      if (!_isCurrentProgramLoad(loadGeneration)) return;
      final shouldFocus = _pendingFocus;
      final programsByChannelScope = _indexProgramsByChannel(allPrograms, widget.channels);
      final pendingJumpChannel = _pendingJumpChannel;
      final pendingJumpProgram = _pendingJumpProgram;
      _pendingJumpChannel = null;
      _pendingJumpProgram = null;

      setState(() {
        _programs = allPrograms;
        _programsByChannelScope = programsByChannelScope;
        widget.onProgramsLoaded?.call(programsByChannelScope);
        _scheduledRecordingKeys = scheduledRecordingKeys;
        _recordingOverrides = const {};
        _isLoading = false;
        _hasLoadedOnce = true;
        // Focus tracking compares by identity, so a reload orphans the
        // focused program — re-resolve it against the fresh list.
        if (_focusZone == _GuideZone.grid && _gridColumn == 1 && _focusedProgram != null) {
          final focused = _focusedProgram;
          if (!_programs.any((p) => identical(p, focused))) {
            _focusedProgram = _findCurrentProgram(_gridChannelIndex);
          }
        }
      });
      _publishFocusSnapshot();

      if (pendingJumpChannel != null) {
        // A stashed search jump wins over the default live-line anchoring and
        // over any focus request queued during the load.
        _pendingFocus = false;
        if (pendingJumpProgram != null) {
          unawaited(jumpToProgram(pendingJumpChannel, pendingJumpProgram));
        } else {
          jumpToChannel(pendingJumpChannel);
        }
        return;
      }

      _scrollToNow(loadGeneration: loadGeneration);

      if (shouldFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrentProgramLoad(loadGeneration)) focusContent();
        });
      }
    } catch (e) {
      if (!_isCurrentProgramLoad(loadGeneration)) return;
      appLogger.e('Failed to load guide programs', error: e);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshScheduledRecordingKeys() async {
    if (!mounted) return;
    final multiServer = context.read<MultiServerProvider>();
    final scheduledRecordingKeys = <String>{};

    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      body: (client, serverInfo) => _addScheduledRecordingKeysForServer(
        client: client,
        serverId: ServerId(serverInfo.serverId),
        keys: scheduledRecordingKeys,
      ),
    );

    if (!mounted) return;
    setState(() => _scheduledRecordingKeys = scheduledRecordingKeys);
  }

  Future<void> _addScheduledRecordingKeysForServer({
    required MediaServerClient client,
    required ServerId serverId,
    required Set<String> keys,
    bool Function()? isCurrent,
  }) async {
    final dvr = client.liveTvDvr;
    if (dvr == null) return;
    try {
      final grabs = await dvr.fetchScheduledRecordings();
      if (isCurrent?.call() == false) return;
      for (final grab in grabs) {
        _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load scheduled recordings for $serverId', error: e);
    }

    try {
      final rules = await dvr.fetchRecordingRules(includeGrabs: true, includeStorage: false);
      if (isCurrent?.call() == false) return;
      for (final rule in rules) {
        for (final grab in rule.grabOperations) {
          _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
        }
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load active recording grabs for $serverId', error: e);
    }
  }

  void _addRecordingKeysForGrab(MediaGrabOperation grab, {required ServerId serverId, required Set<String> keys}) {
    if (!_isActiveScheduledGrab(grab)) return;
    final program = grab.program;
    if (program == null) return;
    keys.addAll(_recordingKeysForProgram(program, fallbackServerId: serverId));
  }

  bool _isActiveScheduledGrab(MediaGrabOperation grab) {
    final status = grab.status?.trim().toLowerCase();
    return status == null || status.isEmpty || status == 'scheduled' || status == 'grabbing' || status == 'recording';
  }

  bool _isRecordingScheduled(LiveTvProgram program) {
    final keys = _recordingKeysForProgram(program);
    for (final key in keys) {
      final override = _recordingOverrides[key];
      if (override != null) return override;
    }
    // The grid response tags subscribed airings itself (subscriptionID /
    // grandparentSubscriptionID) — the signal the official client renders
    // its record badges from. Grab matching below stays as the secondary
    // signal for airings the server did not tag.
    if (program.recordingRuleKey != null) return true;
    return keys.any(_scheduledRecordingKeys.contains);
  }

  void _handleRecordingStateChanged(LiveTvProgram program, bool isScheduled) {
    final keys = _recordingKeysForProgram(program);
    if (keys.isNotEmpty) {
      setState(() {
        _recordingOverrides = {..._recordingOverrides, for (final key in keys) key: isScheduled};
      });
    }
    unawaited(_refreshScheduledRecordingKeys());
  }

  Set<String> _recordingKeysForProgram(LiveTvProgram program, {String? fallbackServerId}) {
    final serverId = liveTvNonEmpty(program.serverId) ?? liveTvNonEmpty(fallbackServerId);
    if (serverId == null) return const <String>{};

    final keys = <String>{};
    void addMediaId(String? value) {
      final normalized = liveTvNonEmpty(value);
      if (normalized != null) keys.add(_recordingKey(ServerId(serverId), 'media', normalized));
    }

    addMediaId(program.ratingKey);
    addMediaId(program.guid);
    addMediaId(program.key);

    final channelIdentifier = liveTvNonEmpty(program.channelIdentifier);
    final beginsAt = program.beginsAt;
    if (channelIdentifier != null && beginsAt != null) {
      keys.add(_recordingKey(ServerId(serverId), 'slot', '$channelIdentifier|$beginsAt|${program.endsAt ?? ''}'));
    }

    return keys;
  }

  String _recordingKey(ServerId serverId, String type, String value) => '$serverId\u0000$type\u0000$value';

  List<_GuideRow> get _guideRows {
    final labelOf = widget.groupLabelOf;
    final groups = labelOf != null ? const <LiveTvChannelGroup>[] : groupLiveTvChannelsBySource(widget.channels);
    if (groups.length <= 1) {
      if (labelOf != null) {
        final rows = <_GuideRow>[];
        String? last;
        final groupCounts = <String, int>{};
        final subCounts = <String, int>{};
        for (final c in widget.channels) {
          final l = labelOf(c);
          groupCounts.update(l.split(' · ').first, (v) => v + 1, ifAbsent: () => 1);
          subCounts.update(l, (v) => v + 1, ifAbsent: () => 1);
        }
        for (var i = 0; i < widget.channels.length; i++) {
          final label = labelOf(widget.channels[i]);
          if (label != last) {
            // "Group · Sub": a group header when the group changes, then an
            // inset sub-group header.
            final parts = label.split(' · ');
            final group = parts.first;
            final sub = parts.length > 1 ? parts.sublist(1).join(' · ') : null;
            final lastGroup = last?.split(' · ').first;
            if (widget.compact) {
              // One compact line: "Group › Sub".
              rows.add(_GuideSourceHeaderRow(label: group, sub: sub, count: subCounts[label]));
            } else {
              if (group != lastGroup) rows.add(_GuideSourceHeaderRow(label: group, count: groupCounts[group]));
              if (sub != null) rows.add(_GuideSourceHeaderRow(label: sub, inset: true, count: subCounts[label]));
            }
            last = label;
          }
          rows.add(_GuideChannelRow(channel: widget.channels[i], channelIndex: i));
        }
        return rows;
      }
      return [
        for (var i = 0; i < widget.channels.length; i++) _GuideChannelRow(channel: widget.channels[i], channelIndex: i),
      ];
    }

    final channelIndexes = <LiveTvChannel, int>{};
    for (var i = 0; i < widget.channels.length; i++) {
      channelIndexes[widget.channels[i]] = i;
    }

    return [
      for (final group in groups) ...[
        _GuideSourceHeaderRow(label: group.label),
        for (final channel in group.channels)
          _GuideChannelRow(channel: channel, channelIndex: channelIndexes[channel] ?? 0),
      ],
    ];
  }

  /// Flat [GuideTab.channels] indexes in displayed row order. Differs from
  /// ascending index order when multiple source groups exist: the flat list is
  /// number-sorted across sources, while rows are grouped by source.
  List<int> get _displayOrderChannelIndexes => [
    for (final row in _guideRows)
      if (row is _GuideChannelRow) row.channelIndex,
  ];

  double _guideRowHeight(_GuideRow row) {
    return switch (row) {
      _GuideSourceHeaderRow(:final inset) => inset ? _subHeaderRowHeight : _sourceHeaderRowHeight,
      _GuideChannelRow() => _rowHeight,
    };
  }

  double _guideContentHeight(List<_GuideRow> rows) {
    var height = 0.0;
    for (final row in rows) {
      height += _guideRowHeight(row);
    }
    return height;
  }

  double _rowTopForChannelIndex(int channelIndex) {
    var top = 0.0;
    for (final row in _guideRows) {
      if (row is _GuideChannelRow && row.channelIndex == channelIndex) return top;
      top += _guideRowHeight(row);
    }
    return channelIndex * _rowHeight;
  }

  String? _spyGroup;

  /// Group whose header is at (or just above) the top of the viewport.
  String? _groupAtTop() {
    if (!_gridVerticalController.hasClients) return null;
    final offset = _gridVerticalController.offset;
    var top = 0.0;
    String? current;
    for (final row in _guideRows) {
      if (row is _GuideSourceHeaderRow && !row.inset) {
        if (top > offset + _rowHeight * 0.6 && current != null) break;
        current = row.label;
      }
      top += _guideRowHeight(row);
    }
    return current;
  }

  void _onVerticalScrollSpy() {
    final g = _groupAtTop();
    if (g == null || g == _spyGroup) return;
    _spyGroup = g;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisibleGroupChanged?.call(g);
    });
  }

  /// Scrolls so [group]'s header is at the top of the guide.
  void scrollToGroup(String group) {
    if (!_gridVerticalController.hasClients) return;
    var top = 0.0;
    for (final row in _guideRows) {
      if (row is _GuideSourceHeaderRow && !row.inset && row.label == group) {
        final max = _gridVerticalController.position.maxScrollExtent;
        _spyGroup = group;
        unawaited(
          _gridVerticalController.animateTo(
            top.clamp(0.0, max),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          ),
        );
        return;
      }
      top += _guideRowHeight(row);
    }
  }

  /// First channel row at/under the top of the viewport.
  int _firstVisibleChannelIndex() {
    if (!_gridVerticalController.hasClients) return 0;
    final offset = _gridVerticalController.offset;
    var top = 0.0;
    for (final row in _guideRows) {
      if (row is _GuideChannelRow && top + _rowHeight / 2 >= offset) return row.channelIndex;
      top += _guideRowHeight(row);
    }
    return 0;
  }

  /// Scrolling near the right edge grows the window by 6h (up to 7 days ahead)
  /// by fetching just the new chunk, so the viewport never jumps.
  void _maybeExtendWindow() {
    if (_extendingWindow || _isLoading || !_gridHorizontalController.hasClients) return;
    final pos = _gridHorizontalController.position;
    if (pos.maxScrollExtent - pos.pixels > _slotWidth * 3) return;
    unawaited(_extendWindow());
  }

  Future<void> _extendWindow() async {
    final cap = DateTime.now().add(const Duration(days: _maxDaysAhead));
    if (!_gridEnd.isBefore(cap) || !mounted) return;
    _extendingWindow = true;
    final generation = _programLoadGeneration;
    final oldEnd = _gridEnd;
    var newEnd = oldEnd.add(const Duration(hours: 6));
    if (newEnd.isAfter(cap)) newEnd = cap;
    try {
      final added = <LiveTvProgram>[];
      final multiServer = context.read<MultiServerProvider>();
      bool current() => mounted && generation == _programLoadGeneration;
      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        isCurrent: current,
        body: (client, serverInfo) async {
          final programs = await client.liveTv.fetchSchedule(
            from: oldEnd.toUtc(),
            to: newEnd.toUtc(),
          );
          if (current()) added.addAll(programs);
        },
        onError: (client, serverInfo, error, stackTrace) {
          appLogger.w('Failed to extend guide window for ${serverInfo.serverId}', error: error);
        },
      );
      if (!current()) return;
      String sig(LiveTvProgram p) => '${p.channelIdentifier}|${p.beginsAt}|${p.key}';
      final seen = {for (final p in _programs) sig(p)};
      final fresh = [
        for (final p in added)
          if (seen.add(sig(p))) p,
      ];
      setState(() {
        _gridEnd = newEnd;
        _programs = [..._programs, ...fresh];
        _programsByChannelScope = _indexProgramsByChannel(_programs, widget.channels);
        widget.onProgramsLoaded?.call(_programsByChannelScope);
      });
    } finally {
      _extendingWindow = false;
    }
  }

  /// Time at the left edge of the viewport, rounded down to a 30 min mark.
  DateTime _viewTime() {
    final offset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
    final minutes = (offset / _slotWidth * _minutesPerSlot).floor();
    final rounded = (minutes ~/ _minutesPerSlot) * _minutesPerSlot;
    return _gridStart.add(Duration(minutes: rounded));
  }

  /// True when the live line is out of view (or the window left "now" behind).
  bool _nowOutOfView() {
    final now = DateTime.now();
    if (!_nowInWindow(now)) return true;
    if (!_gridHorizontalController.hasClients) return false;
    final x = now.difference(_gridStart).inMinutes / _minutesPerSlot * _slotWidth;
    final pos = _gridHorizontalController.position;
    return x < pos.pixels || x > pos.pixels + pos.viewportDimension;
  }

  void _recenterOnNow() {
    final now = DateTime.now();
    if (!_nowInWindow(now) || !_gridHorizontalController.hasClients) {
      _jumpToNow();
      return;
    }
    final x = now.difference(_gridStart).inMinutes / _minutesPerSlot * _slotWidth;
    final pos = _gridHorizontalController.position;
    unawaited(
      _gridHorizontalController.animateTo(
        (x - MediaQuery.sizeOf(context).width / 3).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _scrollToNow({int? loadGeneration}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (loadGeneration != null && !_isCurrentProgramLoad(loadGeneration))) return;
      final now = DateTime.now();
      final minutesSinceStart = now.difference(_gridStart).inMinutes;
      final offset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
      if (_gridHorizontalController.hasClients) {
        _gridHorizontalController.jumpTo(
          (offset - MediaQuery.sizeOf(context).width / 3).clamp(0, _gridHorizontalController.position.maxScrollExtent),
        );
      }
    });
  }

  Map<String, List<LiveTvProgram>> _indexProgramsByChannel(List<LiveTvProgram> programs, List<LiveTvChannel> channels) {
    final programsByIdentifier = <String, List<LiveTvProgram>>{};
    for (final program in programs) {
      final identifier = program.channelIdentifier?.trim();
      if (identifier == null || identifier.isEmpty) continue;
      (programsByIdentifier[identifier] ??= []).add(program);
    }

    final indexed = <String, List<LiveTvProgram>>{};
    for (final channel in channels) {
      final candidates = <LiveTvProgram>{};
      candidates.addAll(programsByIdentifier[channel.key] ?? const []);
      final identifier = channel.identifier;
      if (identifier != null && identifier != channel.key) {
        candidates.addAll(programsByIdentifier[identifier] ?? const []);
      }
      final matching = candidates.where((program) => liveTvProgramMatchesChannel(program, channel)).toList()
        ..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      indexed[liveTvChannelScopeKey(channel)] = matching;
    }
    return indexed;
  }

  List<LiveTvProgram> _getProgramsForChannel(LiveTvChannel channel) {
    return _programsByChannelScope[liveTvChannelScopeKey(channel)] ?? const [];
  }

  double _totalGridWidth() {
    final totalMinutes = _gridEnd.difference(_gridStart).inMinutes;
    return (totalMinutes / _minutesPerSlot) * _slotWidth;
  }

  void _activateProgram(LiveTvChannel channel, LiveTvProgram program) {
    if (PlatformDetector.isTV() && program.isCurrentlyAiring) {
      tuneChannel(channel);
      return;
    }

    _showProgramDetails(channel, program);
  }

  ({LiveTvChannel channel, LiveTvProgram program})? _focusedProgramTarget() {
    if (_focusZone != _GuideZone.grid || _gridColumn != 1) return null;
    final program = _focusedProgram;
    if (program == null) return null;
    if (_gridChannelIndex < 0 || _gridChannelIndex >= widget.channels.length) return null;

    return (channel: widget.channels[_gridChannelIndex], program: program);
  }

  KeyEventResult _handleFocusedProgramSelectKey(KeyEvent event) {
    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    final ownerChannelIndex = _gridChannelIndex;
    final targetIdentity = guideAiringIdentity(target.channel, target.program);
    return _selectLongPressController.handleKeyEvent(
      event,
      isOwnerActive: () {
        if (!mounted || _focusZone != _GuideZone.grid || _gridColumn != 1 || _gridChannelIndex != ownerChannelIndex) {
          return false;
        }

        final activeTarget = _focusedProgramTarget();
        return activeTarget != null &&
            guideAiringIdentity(activeTarget.channel, activeTarget.program) == targetIdentity;
      },
      onShortPress: () => _activateProgram(target.channel, target.program),
      onLongPress: () {
        _selectLongPressController.reset();
        _showProgramDetails(target.channel, target.program);
      },
    );
  }

  LiveTvChannel? _focusedChannelTarget() {
    if (_focusZone != _GuideZone.grid || _gridColumn != 0) return null;
    if (_gridChannelIndex < 0 || _gridChannelIndex >= widget.channels.length) return null;
    return widget.channels[_gridChannelIndex];
  }

  /// TV SELECT on a channel cell: a short press tunes and a hold toggles the
  /// favorite, the same split as a tap and a long press on the cell.
  KeyEventResult _handleFocusedChannelSelectKey(KeyEvent event) {
    final onToggleFavorite = widget.onToggleFavorite;
    final channel = _focusedChannelTarget();
    if (onToggleFavorite == null || channel == null) return KeyEventResult.ignored;

    final ownerChannelIndex = _gridChannelIndex;
    return _selectLongPressController.handleKeyEvent(
      event,
      isOwnerActive: () => mounted && _focusedChannelTarget() != null && _gridChannelIndex == ownerChannelIndex,
      onShortPress: () => tuneChannel(channel),
      onLongPress: () {
        _selectLongPressController.reset();
        onToggleFavorite(channel);
      },
    );
  }

  /// The context-menu key (gamepad X, keyboard Menu) toggles the focused
  /// channel's favorite. Down only, so a held key cannot flip it back and forth.
  KeyEventResult _handleFocusedChannelContextMenuKey(KeyEvent event) {
    if (!event.logicalKey.isContextMenuKey) return KeyEventResult.ignored;
    final onToggleFavorite = widget.onToggleFavorite;
    final channel = _focusedChannelTarget();
    if (onToggleFavorite == null || channel == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) onToggleFavorite(channel);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleFocusedProgramContextMenuKey(KeyEvent event) {
    if (!event.logicalKey.isContextMenuKey || !event.isActionable) return KeyEventResult.ignored;
    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    _resetSelectLongPressState();
    _showProgramDetails(target.channel, target.program);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;

    if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) {
      if (event is KeyUpEvent && key.isSelectKey) {
        _resetSelectLongPressState();
      }
      return KeyEventResult.handled;
    }

    // Back key
    if (key.isBackKey) {
      if (BackKeyUpSuppressor.consumeIfSuppressed(event)) {
        return KeyEventResult.handled;
      }
      if (_focusZone == _GuideZone.grid && widget.compact) {
        // On a program card: Back first returns to this row's channel card;
        // from the channel card Back goes on to the sidebar.
        if (_gridColumn == 1) {
          if (event is KeyUpEvent) {
            _updateFocus(() {
              _gridColumn = 0;
              _focusedProgram = null;
            });
          }
          return KeyEventResult.handled;
        }
        return handleBackKeyAction(event, () => widget.onBack?.call());
      }
      if (_focusZone == _GuideZone.grid) {
        if (event is KeyUpEvent) {
          _updateFocus(() {
            _focusZone = _GuideZone.timeNav;
            _timeNavIndex = 1;
          });
        }
        return KeyEventResult.handled;
      }
      return handleBackKeyAction(event, () => widget.onBack?.call());
    }

    if (PlatformDetector.isTV()) {
      final selectResult = _handleFocusedProgramSelectKey(event);
      if (selectResult != KeyEventResult.ignored) return selectResult;
      final channelSelectResult = _handleFocusedChannelSelectKey(event);
      if (channelSelectResult != KeyEventResult.ignored) return channelSelectResult;
    }

    if (key.isContextMenuKey &&
        widget.onMenuKey != null &&
        (_focusZone == _GuideZone.timeNav || _gridColumn == 0)) {
      if (event is KeyDownEvent) widget.onMenuKey!();
      return KeyEventResult.handled;
    }

    final contextMenuResult = _handleFocusedProgramContextMenuKey(event);
    if (contextMenuResult != KeyEventResult.ignored) return contextMenuResult;
    final channelContextMenuResult = _handleFocusedChannelContextMenuKey(event);
    if (channelContextMenuResult != KeyEventResult.ignored) return channelContextMenuResult;

    if (!event.isActionable) return KeyEventResult.ignored;

    return _focusZone == _GuideZone.timeNav ? _handleTimeNavKey(key) : _handleGridKey(key);
  }

  KeyEventResult _handleTimeNavKey(LogicalKeyboardKey key) {
    if (key.isLeftKey) {
      if (_timeNavIndex == 2 && !widget.compact) {
        _updateFocus(() => _timeNavIndex = 1);
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_timeNavIndex == 1 && !widget.compact && _nowOutOfView()) _updateFocus(() => _timeNavIndex = 2);
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      if (widget.channels.isNotEmpty) {
        _updateFocus(() {
          _focusZone = _GuideZone.grid;
          _gridColumn = 0;
          _focusedProgram = null;
        });
        _scrollToChannel(_gridChannelIndex);
      }
      return KeyEventResult.handled;
    }
    if (key.isUpKey) {
      widget.onNavigateUp?.call();
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      switch (_timeNavIndex) {
        case 0:
          _shiftTimeRange(-2);
        case 1:
        // The menu takes focus; suppress the in-flight SELECT key-up so the
        // press that opened it cannot also activate the first menu item.
          SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
          _showDayPicker();
        case 2:
          _recenterOnNow();
          _updateFocus(() {
            if (widget.compact) _focusZone = _GuideZone.grid;
            _timeNavIndex = 1;
          });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleGridKey(LogicalKeyboardKey key) {
    if (key.isUpKey || key.isDownKey) {
      // Move through rows in displayed (source-grouped) order. Stepping the
      // flat channel index would interleave sources whose channel numbers
      // overlap and could dead-end before the last displayed row.
      _userNavigated = true;
      final order = _displayOrderChannelIndexes;
      final position = order.indexOf(_gridChannelIndex);
      if (key.isUpKey && position <= 0) {
        if (widget.compact && !_nowOutOfView()) {
          // Compact has no focusable time bar unless the "Now" pill is showing.
          widget.onNavigateUp?.call();
          return KeyEventResult.handled;
        }
        _updateFocus(() {
          _focusZone = _GuideZone.timeNav;
          _timeNavIndex = widget.compact ? 2 : 1;
        });
      } else if (key.isUpKey || (position != -1 && position < order.length - 1)) {
        _updateFocus(() {
          _gridChannelIndex = order[key.isUpKey ? position - 1 : position + 1];
          if (_gridColumn == 1) {
            // Keep the focused time rather than jumping back to what airs now,
            // which may be scrolled out of view (or outside a picked window).
            final anchor = _focusedProgram;
            _focusedProgram = anchor == null
                ? _findCurrentProgram(_gridChannelIndex)
                : _programNearTime(_gridChannelIndex, _programAnchorEpoch(anchor));
            // A row with nothing in this window has no program cell; land on
            // its channel cell instead of nowhere.
            if (_focusedProgram == null) _gridColumn = 0;
          }
        });
        _scrollToChannel(_gridChannelIndex);
        if (_gridColumn == 1) _scrollToProgramTime(_focusedProgram);
        if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
          widget.onChannelFocused?.call(widget.channels[_gridChannelIndex]);
        }
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_gridColumn == 0) {
        final program = _findCurrentProgram(_gridChannelIndex);
        if (program != null) {
          _updateFocus(() {
            _gridColumn = 1;
            _focusedProgram = program;
          });
          _scrollToProgramTime(program);
        }
      } else {
        // Already in program column — move to next program
        _navigateToAdjacentProgram(_gridChannelIndex, forward: true);
      }
      return KeyEventResult.handled;
    }
    if (key.isLeftKey) {
      if (_gridColumn == 1) {
        // Try moving to previous program; if at first program, go back to channel column
        if (!_navigateToAdjacentProgram(_gridChannelIndex, forward: false)) {
          _updateFocus(() {
            _gridColumn = 0;
            _focusedProgram = null;
          });
        }
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        final channel = widget.channels[_gridChannelIndex];
        if (_gridColumn == 0) {
          tuneChannel(channel);
        } else if (_focusedProgram != null) {
          _activateProgram(channel, _focusedProgram!);
        }
      }
      return KeyEventResult.handled;
    }
    // 'F' key toggles favorite on focused channel
    if (key == LogicalKeyboardKey.keyF && _gridColumn == 0) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        widget.onToggleFavorite?.call(widget.channels[_gridChannelIndex]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  LiveTvProgram? _findCurrentProgram(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return null;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Currently airing
    for (final p in programs) {
      if ((p.beginsAt ?? 0) <= now && (p.endsAt ?? 0) > now) return p;
    }
    // First future program
    for (final p in programs) {
      if ((p.endsAt ?? 0) > now) return p;
    }
    return programs.firstOrNull;
  }

  /// Epoch second a vertical move should stay at: the focused program's start,
  /// or the window start when it began before the window.
  int _programAnchorEpoch(LiveTvProgram program) {
    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final begin = program.beginsAt ?? gridStartEpoch;
    return begin < gridStartEpoch ? gridStartEpoch : begin;
  }

  /// The program on [channelIndex] airing at [epoch], else the one closest to
  /// it, or null when the channel has nothing in this window.
  LiveTvProgram? _programNearTime(int channelIndex, int epoch) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return null;
    LiveTvProgram? nearest;
    var nearestDistance = 0;
    for (final program in _getProgramsForChannel(widget.channels[channelIndex])) {
      final begin = program.beginsAt ?? 0;
      final end = program.endsAt ?? begin;
      if (begin <= epoch && end > epoch) return program;
      final distance = begin > epoch ? begin - epoch : epoch - end;
      if (nearest == null || distance < nearestDistance) {
        nearest = program;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// Navigate to the next or previous program on the same channel.
  /// Returns true if navigation succeeded, false if at the boundary.
  bool _navigateToAdjacentProgram(int channelIndex, {required bool forward}) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return false;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    if (programs.isEmpty || _focusedProgram == null) return false;

    final currentIndex = programs.indexWhere((p) => identical(p, _focusedProgram));
    if (currentIndex < 0) return false;

    final nextIndex = forward ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= programs.length) return false;

    final nextProgram = programs[nextIndex];
    _updateFocus(() => _focusedProgram = nextProgram);
    _scrollToProgramTime(nextProgram);
    return true;
  }

  void _scrollToChannel(int index) {
    if (!_gridVerticalController.hasClients) return;
    final targetTop = _rowTopForChannelIndex(index);
    final targetBottom = targetTop + _rowHeight;
    final viewportTop = _gridVerticalController.offset;
    final viewportBottom = viewportTop + _gridVerticalController.position.viewportDimension;

    double? newOffset;
    if (targetTop < viewportTop) {
      newOffset = targetTop;
    } else if (targetBottom > viewportBottom) {
      newOffset = targetBottom - _gridVerticalController.position.viewportDimension;
    }

    if (newOffset != null) {
      final clamped = newOffset.clamp(0.0, _gridVerticalController.position.maxScrollExtent);
      _gridVerticalController.animateTo(clamped, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      if (_channelVerticalController.hasClients) {
        _channelVerticalController.animateTo(
          clamped.clamp(0.0, _channelVerticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _scrollToProgramTime(LiveTvProgram? program) {
    if (program == null || !_gridHorizontalController.hasClients) return;

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;
    final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
    final startOffset = progStart - gridStartEpoch;
    final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;

    final viewportWidth = _gridHorizontalController.position.viewportDimension;
    final currentOffset = _gridHorizontalController.offset;

    if (left < currentOffset || left > currentOffset + viewportWidth - 100) {
      final maxScroll = _gridHorizontalController.position.maxScrollExtent;
      _gridHorizontalController.jumpTo((left - 50).clamp(0.0, maxScroll));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Full-screen spinner only before the first window has loaded. In-session
    // window reloads keep the grid mounted (so the day/time pickers and the
    // guide Focus stay alive for D-pad navigation) and show a lightweight
    // overlay instead — stale programs stay tappable while it settles.
    if (_isLoading && !_hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        Focus(
          focusNode: _guideFocusNode,
          onFocusChange: _handleGuideFocusChange,
          onKeyEvent: _handleKeyEvent,
          child: _buildGuideGrid(theme),
        ),
        if (_isLoading)
          const Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGuideGrid(ThemeData theme) {
    final rows = _guideRows;
    return Column(
      children: [
        if (!widget.compact) _buildTimeNavigation(theme),
        Expanded(
          child: ListenableBuilder(
            listenable: _gridHorizontalController,
            builder: (context, child) {
              return Stack(children: [child!, _buildCompactHeaderOverlay(theme), _buildNowIndicatorOverlay(theme)]);
            },
            child: Column(
              children: [
                if (widget.compact) _buildCompactStatusBar(theme),
                Row(
                  children: [
                    SizedBox(width: _channelColumnWidth, height: _timeHeaderHeight),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _headerHorizontalController,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: SizedBox(
                          width: _totalGridWidth(),
                          height: _timeHeaderHeight,
                          child: _buildTimeHeader(theme),
                        ),
                      ),
                    ),
                  ],
                ),

                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: _channelColumnWidth,
                        child: CustomScrollView(
                          controller: _channelVerticalController,
                          physics: const NeverScrollableScrollPhysics(),
                          slivers: [
                            SliverVariedExtentList.builder(
                              itemCount: rows.length,
                              itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                return switch (row) {
                                  _GuideSourceHeaderRow(:final label, :final inset) => _buildSourceHeaderCell(label, theme, inset: inset),
                                  _GuideChannelRow(:final channel, :final channelIndex) => _buildChannelCell(
                                    channel,
                                    theme,
                                    index: channelIndex,
                                  ),
                                };
                              },
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is ScrollUpdateNotification &&
                                notification.metrics.axis == Axis.vertical) {
                              if (_channelVerticalController.hasClients) {
                                _channelVerticalController.jumpTo(notification.metrics.pixels);
                              }
                            }
                            return false;
                          },
                          child: SingleChildScrollView(
                            controller: _gridHorizontalController,
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: SizedBox(
                              width: _totalGridWidth(),
                              child: Stack(children: [
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _SlotLinesPainter(
                                        slotWidth: _slotWidth,
                                        firstIsHour: _gridStart.minute == 0,
                                        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
                                      ),
                                    ),
                                  ),
                                ),
                                CustomScrollView(
                                  controller: _gridVerticalController,
                                  slivers: [
                                    SliverVariedExtentList.builder(
                                      itemCount: rows.length,
                                      itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                                      itemBuilder: (context, index) {
                                        final row = rows[index];
                                        return switch (row) {
                                          _GuideSourceHeaderRow(:final label, :final inset, :final count) => _buildSourceHeaderGridRow(
                                            label,
                                            theme,
                                            inset: inset,
                                            count: count,
                                          ),
                                          _GuideChannelRow(:final channel, :final channelIndex) => _buildProgramRow(
                                            channel,
                                            _getProgramsForChannel(channel),
                                            theme,
                                            channelIndex: channelIndex,
                                          ),
                                        };
                                      },
                                    ),
                                  ],
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNowIndicatorOverlay(ThemeData _) {
    final now = DateTime.now();
    if (now.isBefore(_gridStart) || now.isAfter(_gridEnd)) {
      return const SizedBox.shrink();
    }
    final minutesSinceStart = now.difference(_gridStart).inMinutes.toDouble();
    final nowOffset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
    final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
    final left = _channelColumnWidth + nowOffset - scrollOffset - 5;

    // Hide when scrolled behind the channel column
    if (left + 5 < _channelColumnWidth) return const SizedBox.shrink();

    final gridHeight = _statusBarHeight + _timeHeaderHeight + _guideContentHeight(_guideRows);

    return Positioned(
      left: left,
      top: 0,
      height: gridHeight,
      child: IgnorePointer(
        child: SizedBox(
          width: 10,
          child: Stack(
            alignment: .topCenter,
            children: [
              Positioned(
                top: _statusBarHeight + _timeHeaderHeight - 5,
                bottom: 0,
                child: Container(width: 1.5, color: const Color(0xFFFF4D4D).withValues(alpha: 0.9)),
              ),
              Positioned(
                top: _statusBarHeight + _timeHeaderHeight - 10,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(color: Color(0xFFFF4D4D), shape: BoxShape.circle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);

    if (target == today) return t.liveTv.today;
    // Calendar arithmetic: across a DST change a day is 23 or 25 hours.
    if (target == DateTime(today.year, today.month, today.day + 1)) return t.liveTv.tomorrow;

    return DateFormat('EEEE', LocaleSettings.currentLocale.intlLocaleName).format(target);
  }

  List<(String, int)> get _timeSlots => [
    (t.liveTv.midnight, 0),
    (t.liveTv.overnight, 2),
    (t.liveTv.morning, 6),
    (t.liveTv.daytime, 12),
    (t.liveTv.evening, 18),
    (t.liveTv.lateNight, 22),
  ];

  Rect? _menuAnchorRect() {
    final renderBox = _dayPickerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    return Rect.fromLTWH(buttonPos.dx, buttonPos.dy, buttonSize.width, buttonSize.height);
  }

  Future<void> _showDayPicker() async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final gridDay = DateTime(_gridStart.year, _gridStart.month, _gridStart.day);

    final days = <DateTime>[];
    for (var i = 0; i < 8; i++) {
      days.add(DateTime(today.year, today.month, today.day + i));
    }

    final value = await showAppMenu<Object>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<Object>(value: 'now', label: t.liveTv.now),
        ...days.map((day) {
          final isSelected = day == gridDay;
          final label = _dayLabel(day);
          return AppMenuItem<Object>(value: day, label: label, selected: isSelected);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value is String && value == 'now') {
      _jumpToNow();
      _guideFocusNode.requestFocus();
    } else if (value is DateTime) {
      // Apply the picked day right away; the slot menu that follows only
      // refines it (dismissing it keeps this window).
      _applyDay(value);
      await _showTimeSlotPicker(value);
    }
  }

  /// Re-anchors the 6h window onto [day] keeping the current window's
  /// time-of-day. Picking 'Now' instead re-anchors live via [_jumpToNow].
  /// #1297: a deliberately picked day is never yanked back by the drift
  /// checker — [_nowWasInWindow] stays false when now is outside it.
  void _applyDay(DateTime day) {
    final hour = _gridStart.hour;
    final minute = _gridStart.minute;
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, hour, minute);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    unawaited(_loadPrograms());
  }

  Future<void> _showTimeSlotPicker(DateTime day) async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final label = _dayLabel(day).toUpperCase();

    final value = await showAppMenu<int>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<int>(
          value: -1,
          icon: Symbols.chevron_left_rounded,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: .bold)),
        ),
        const AppMenuDivider<int>(),
        ..._timeSlots.map((slot) {
          return AppMenuItem<int>(value: slot.$2, label: slot.$1);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value == -1) {
      await _showDayPicker();
      return;
    }
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, value);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    unawaited(_loadPrograms());
    _guideFocusNode.requestFocus();
  }

  Widget _timeNavFocusWrap({required Widget child, required int index}) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) => focus.hasFocus && focus.zone == _GuideZone.timeNav && focus.timeNavIndex == index,
      builder: (context, isFocused) {
        if (!isFocused) return child;
        return Container(
          decoration: FocusTheme.textFillFocusDecoration(context, isFocused: true, borderRadius: MonoTokens.radiusFull),
          child: child,
        );
      },
    );
  }

  /// Slim bar above the time header: day status on the left (not
  /// interactive), "Now" pill on the right when the live line is off screen.
  Widget _buildCompactStatusBar(ThemeData theme) {
    return SizedBox(
      height: _statusBarHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 12, 4),
        child: Row(
          children: [
            ListenableBuilder(
              listenable: _gridHorizontalController,
              builder: (context, _) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _dayLabel(_viewTime()),
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: .w700, color: theme.hintColor),
                ),
              ),
            ),
            const Spacer(),
            _buildCompactNowPill(theme),
          ],
        ),
      ),
    );
  }

  /// Compact (TV) "Now" pill, floating at the right end of the time header.
  /// Idle: outlined with a red dot. Focused: solid accent fill, like the
  /// focused program card, with a soft glow.
  Widget _buildCompactNowPill(ThemeData theme) {
    return ListenableBuilder(
      listenable: _gridHorizontalController,
      builder: (context, _) {
        if (!_nowOutOfView()) return const SizedBox.shrink();
        final scheme = theme.colorScheme;
        return _GuideFocusSelector(
          valueListenable: _focusSnapshot,
          isSelected: (focus) => focus.hasFocus && focus.zone == _GuideZone.timeNav && focus.timeNavIndex == 2,
          builder: (context, focused) {
            return ClickableCursor(
              child: GestureDetector(
                onTap: _recenterOnNow,
                behavior: HitTestBehavior.opaque,
                child: AnimatedScale(
                  scale: focused ? 1.06 : 1.0,
                  duration: const Duration(milliseconds: 140),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: focused ? scheme.primary : scheme.surface.withValues(alpha: 0.92),
                      border: Border.all(
                        color: focused ? scheme.primary : scheme.error.withValues(alpha: 0.55),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: focused
                          ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 14)]
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: .min,
                      children: [
                        AppIcon(
                          Symbols.fiber_manual_record_rounded,
                          size: 8,
                          color: focused ? scheme.error : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          t.liveTv.now,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: .w700,
                            color: focused ? scheme.onPrimary : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Compact (TV) group headers, drawn as one overlay line each so they span
  /// the full width (never clipped to the narrow channel column).
  Widget _buildCompactHeaderOverlay(ThemeData theme) {
    if (!widget.compact) return const SizedBox.shrink();
    final scheme = theme.colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      top: _timeHeaderHeight + _statusBarHeight,
      bottom: 0,
      child: IgnorePointer(
        child: ClipRect(
          child: ListenableBuilder(
            listenable: _gridVerticalController,
            builder: (context, _) {
              final offset = _gridVerticalController.hasClients ? _gridVerticalController.offset : 0.0;
              var top = 0.0;
              final children = <Widget>[];
              for (final row in _guideRows) {
                final h = _guideRowHeight(row);
                if (row is _GuideSourceHeaderRow && top + h > offset && top < offset + 4000) {
                  children.add(
                    Positioned(
                      left: 0,
                      right: 0,
                      top: top - offset,
                      height: h,
                      child: Align(
                        alignment: .bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                          child: Text.rich(
                            TextSpan(
                              style: theme.textTheme.labelMedium,
                              children: [
                                TextSpan(
                                  text: row.label,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                if (row.sub != null) ...[
                                  TextSpan(
                                    text: '  ›  ',
                                    style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.4)),
                                  ),
                                  TextSpan(
                                    text: row.sub,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: scheme.onSurface.withValues(alpha: 0.75),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                top += h;
              }
              return Stack(children: children);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTimeNavigation(ThemeData theme) {
    final is24 = MediaQuery.alwaysUse24HourFormatOf(context);
    const sideWidth = 84.0;

    return ListenableBuilder(
      listenable: _gridHorizontalController,
      builder: (context, _) {
        final view = _viewTime();
        final showNow = _nowOutOfView();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const SizedBox(width: sideWidth),
              Expanded(
                child: Center(
                  child: _timeNavFocusWrap(
                    index: 1,
                    child: ClickableCursor(
                      child: GestureDetector(
                        key: _dayPickerKey,
                        onTap: _showDayPicker,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                          child: Row(
                            mainAxisSize: .min,
                            children: [
                              Text(_dayLabel(view), style: theme.textTheme.labelMedium?.copyWith(fontWeight: .w700)),
                              const SizedBox(width: 8),
                              Text(
                                formatClockTime(view, is24Hour: is24),
                                style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: sideWidth,
                child: Align(
                  alignment: .centerRight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: !showNow
                        ? const SizedBox.shrink(key: ValueKey('no-now'))
                        : KeyedSubtree(
                        key: const ValueKey('now'),
                        child: _timeNavFocusWrap(
                          index: 2,
                          child: ClickableCursor(
                            child: GestureDetector(
                              onTap: _recenterOnNow,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.error.withValues(alpha: 0.14),
                                  borderRadius: const BorderRadius.all(Radius.circular(MonoTokens.radiusFull)),
                                ),
                                child: Row(
                                  mainAxisSize: .min,
                                  children: [
                                    AppIcon(
                                      Symbols.fiber_manual_record_rounded,
                                      size: 10,
                                      color: theme.colorScheme.error,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      t.liveTv.now,
                                      style: theme.textTheme.labelMedium?.copyWith(fontWeight: .w700),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        )),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimeHeader(ThemeData theme) {
    final is24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final slots = <Widget>[];
    var current = _gridStart;

    while (current.isBefore(_gridEnd)) {
      final timeStr = formatClockTime(current, is24Hour: is24Hour);
      final isHour = current.minute == 0;
      slots.add(
        Container(
          width: _slotWidth,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: tokens(context).text.withValues(alpha: isHour ? 0.18 : 0.08), width: 1),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: .centerLeft,
              child: Text(
                timeStr,
                style: (widget.compact ? theme.textTheme.labelMedium : theme.textTheme.labelSmall)?.copyWith(
                  color: isHour ? tokens(context).text.withValues(alpha: 0.85) : tokens(context).textMuted,
                  fontWeight: isHour ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      );
      current = current.add(const Duration(minutes: _minutesPerSlot));
    }

    return Row(children: slots);
  }

  /// Channel-column side of a header row. Group: bold title with an accent
  /// dot; sub-group: indented soft pill with a branch icon.
  Widget _buildSourceHeaderCell(String label, ThemeData theme, {bool inset = false}) {
    if (widget.compact) return SizedBox(height: _sourceHeaderRowHeight);
    final scheme = theme.colorScheme;
    final c = widget.compact;
    if (!inset) {
      return Container(
        height: _sourceHeaderRowHeight,
        alignment: .bottomLeft,
        padding: EdgeInsets.fromLTRB(12, 0, 6, c ? 4 : 8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: .centerLeft,
          child: Row(
            mainAxisSize: .min,
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              ),
              Text(
                label,
                maxLines: 1,
                style: (c ? theme.textTheme.labelLarge : theme.textTheme.titleSmall)?.copyWith(
                  fontWeight: .w700,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      height: _subHeaderRowHeight,
      alignment: .centerLeft,
      padding: EdgeInsets.fromLTRB(c ? 14 : 20, 0, 6, c ? 2 : 4),
      child: Container(
        padding: EdgeInsets.fromLTRB(6, c ? 1 : 3, 10, c ? 1 : 3),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: .min,
          children: [
            AppIcon(
              Symbols.subdirectory_arrow_right_rounded,
              size: 14,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: .ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.75),
                  fontWeight: .w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Timeline side of a header row: channel count pinned left + soft rule.
  Widget _buildSourceHeaderGridRow(String label, ThemeData theme, {bool inset = false, int? count}) {
    if (widget.compact) return SizedBox(height: _sourceHeaderRowHeight);
    final scheme = theme.colorScheme;
    final countText = count == null ? null : (count == 1 ? '1 channel' : '$count channels');
    return Container(
      height: inset ? _subHeaderRowHeight : _sourceHeaderRowHeight,
      alignment: .bottomLeft,
      decoration: inset
          ? null
          : BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.07), width: 1)),
      ),
      child: countText == null
          ? null
          : ClipRect(
        child: ListenableBuilder(
          listenable: _gridHorizontalController,
          builder: (context, child) {
            final off = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
            return Transform.translate(offset: Offset(off, 0), child: child);
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 0, widget.compact ? 4 : (inset ? 8 : 9)),
            child: Text(
              countText,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: inset ? 0.35 : 0.45),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelCell(LiveTvChannel channel, ThemeData theme, {required int index}) {
    final multiServer = context.read<MultiServerProvider>();
    final serverId = serverIdOrNull(channel.serverId);
    final client = serverId == null ? null : multiServer.getClientForServer(serverId);

    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
      focus.hasFocus && focus.zone == _GuideZone.grid && focus.gridColumn == 0 && focus.channelIndex == index,
      builder: (context, isFocused) {
        return _ChannelCell(
          rowHeight: _rowHeight,
          channelColumnWidth: _channelColumnWidth,
          channelThumb: channel.thumb,
          client: client,
          channel: channel,
          theme: theme,
          onTap: () => tuneChannel(channel),
          onLongPress: widget.onToggleFavorite != null ? () => widget.onToggleFavorite!(channel) : null,
          isFocused: isFocused,
          isFavorite: widget.isFavoriteChannel?.call(channel) ?? false,
          fallbackBuilder: () => _buildChannelNameFallback(channel, theme),
        );
      },
    );
  }

  Widget _buildChannelNameFallback(LiveTvChannel channel, ThemeData theme) {
    return Column(
      mainAxisAlignment: .center,
      children: [
        if (channel.number != null)
          Text(
            channel.number!,
            style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted),
            maxLines: 1,
          ),
        Text(
          channel.displayName,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: .w500),
          maxLines: 1,
          overflow: .ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildProgramRow(
      LiveTvChannel channel,
      List<LiveTvProgram> programs,
      ThemeData theme, {
        required int channelIndex,
      }) {
    if (programs.isEmpty) {
      final tk = tokens(context);
      return SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
          child: Material(
            color: Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Center(
              child: Text(t.liveTv.noPrograms, style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted)),
            ),
          ),
        ),
      );
    }

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;

    return SizedBox(
      height: _rowHeight,
      child: ListenableBuilder(
        listenable: _gridHorizontalController,
        builder: (context, _) {
          final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
          // Keep one slot of overscan so the next D-pad target exists before the horizontal jump.
          final visibleStart = scrollOffset > _slotWidth ? scrollOffset - _slotWidth : 0.0;
          final visibleEnd = scrollOffset + MediaQuery.sizeOf(context).width + _slotWidth;
          final blocks = <Widget>[];

          for (final program in programs) {
            final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
            final progEnd = (program.endsAt ?? gridEndEpoch).clamp(gridStartEpoch, gridEndEpoch);
            if (progEnd <= progStart) continue;

            final startOffset = progStart - gridStartEpoch;
            final duration = progEnd - progStart;
            final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;
            final width = (duration / (_minutesPerSlot * 60)) * _slotWidth;
            final clampedWidth = width.clamp(6.0, double.infinity);
            if (left + clampedWidth < visibleStart || left > visibleEnd) continue;

            blocks.add(
              Positioned(
                key: ObjectKey(program),
                left: left,
                width: clampedWidth,
                top: 0,
                bottom: 0,
                child: _buildProgramBlock(
                  channel,
                  program,
                  theme,
                  channelIndex: channelIndex,
                  tileLeft: left,
                  tileWidth: clampedWidth,
                  scrollOffset: scrollOffset,
                ),
              ),
            );
          }

          return Stack(children: blocks);
        },
      ),
    );
  }

  Widget _buildProgramBlock(
      LiveTvChannel channel,
      LiveTvProgram program,
      ThemeData theme, {
        required int channelIndex,
        required double tileLeft,
        required double tileWidth,
        required double scrollOffset,
      }) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
      focus.hasFocus &&
          focus.zone == _GuideZone.grid &&
          focus.gridColumn == 1 &&
          focus.channelIndex == channelIndex &&
          identical(focus.program, program),
      builder: (context, isFocused) {
        final tk = tokens(context);
        final isCurrentlyAiring = program.isCurrentlyAiring;
        final isPast = program.endsAt != null && program.endsAt! < DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final isRecordingScheduled = _isRecordingScheduled(program);

        final Color fillColor;
        final Color titleColor;
        final Color subtitleColor;
        if (isFocused) {
          // Inverted focus card: primary == text in the mono theme, so the cursor
          // reads as a solid inverted cell (white card, dark text in dark mode).
          fillColor = theme.colorScheme.primary;
          titleColor = theme.colorScheme.onPrimary;
          subtitleColor = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
        } else if (isPast) {
          fillColor = Color.alphaBlend(tk.surface.withValues(alpha: 0.35), tk.bg);
          titleColor = tk.text.withValues(alpha: 0.45);
          subtitleColor = tk.text.withValues(alpha: 0.28);
        } else if (isCurrentlyAiring) {
          fillColor = Color.alphaBlend(theme.colorScheme.primary.withValues(alpha: 0.10), tk.surface);
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        } else {
          fillColor = tk.surface;
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        }
        final radius = BorderRadius.circular(isFocused ? 12 : 10);
        double? progress;
        if (isCurrentlyAiring && !isFocused && program.beginsAt != null && program.endsAt != null) {
          final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final span = program.endsAt! - program.beginsAt!;
          if (span > 0) progress = ((nowSec - program.beginsAt!) / span).clamp(0.0, 1.0);
        }

        return Padding(
          padding: const EdgeInsets.only(right: 4, bottom: 4),
          child: Material(
            color: fillColor,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: radius),
            child: InkWell(
              borderRadius: radius,
              mouseCursor: SystemMouseCursors.click,
              canRequestFocus: false,
              onTap: () => _activateProgram(channel, program),
              onLongPress: () => _showProgramDetails(channel, program),
              onSecondaryTap: () => _showProgramDetails(channel, program),
              child: Stack(children: [
                Padding(
                  padding: .fromLTRB(
                    (widget.compact ? 12 : 10) + (scrollOffset - tileLeft).clamp(0.0, (tileWidth - tk.groupGap - 32).clamp(0.0, double.infinity)),
                    widget.compact ? 3 : 6,
                    8,
                    widget.compact ? 3 : 6,
                  ),
                  child: Column(
                    crossAxisAlignment: .start,
                    mainAxisAlignment: .center,
                    children: [
                      Row(
                        children: [
                          if (isRecordingScheduled) ...[
                            _RecordingDot(color: Colors.red, tooltip: t.liveTv.recordingScheduled),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              program.grandparentTitle ?? program.title,
                              style: (widget.compact ? theme.textTheme.labelLarge : theme.textTheme.bodyMedium)?.copyWith(
                                fontSize: widget.compact ? 13 : null,
                                fontWeight: .w600,
                                color: titleColor,
                              ),
                              maxLines: 1,
                              overflow: .ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (program.grandparentTitle != null && !widget.compact)
                        Text(
                          '${program.parentIndex != null && program.index != null ? 'S${program.parentIndex}E${program.index} · ' : ''}${program.title}',
                          style: theme.textTheme.labelSmall?.copyWith(color: subtitleColor),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                      if (program.startTime != null)
                        Text(
                          '${formatClockTime(program.startTime!, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))} · ${formatDurationTextual(program.durationMinutes * 60_000)}',
                          style: theme.textTheme.labelSmall?.copyWith(color: subtitleColor),
                          maxLines: 1,
                          overflow: .ellipsis,
                        ),
                    ],
                  ),
                ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 3,
                    child: Align(
                      alignment: .centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress,
                        child: ColoredBox(color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }

  void _showProgramDetails(LiveTvChannel channel, LiveTvProgram program) {
    showProgramDetails(
      program: program,
      channel: channel,
      posterThumb: program.thumb,
      posterServerId: channel.serverId,
      onRecordingStateChanged: (isScheduled) => _handleRecordingStateChanged(program, isScheduled),
    );
  }
}

class _GuideFocusSelector extends StatefulWidget {
  const _GuideFocusSelector({required this.valueListenable, required this.isSelected, required this.builder});

  final ValueListenable<_GuideFocusSnapshot> valueListenable;
  final bool Function(_GuideFocusSnapshot focus) isSelected;
  final Widget Function(BuildContext context, bool isSelected) builder;

  @override
  State<_GuideFocusSelector> createState() => _GuideFocusSelectorState();
}

class _GuideFocusSelectorState extends State<_GuideFocusSelector> {
  late bool _isSelected;

  @override
  void initState() {
    super.initState();
    _isSelected = widget.isSelected(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(_GuideFocusSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_handleValueChanged);
      widget.valueListenable.addListener(_handleValueChanged);
    }
    _isSelected = widget.isSelected(widget.valueListenable.value);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  void _handleValueChanged() {
    final isSelected = widget.isSelected(widget.valueListenable.value);
    if (isSelected == _isSelected) return;
    setState(() => _isSelected = isSelected);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _isSelected);
}

class _RecordingDot extends StatelessWidget {
  final Color color;
  final String tooltip;

  const _RecordingDot({required this.color, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _ChannelCell extends StatefulWidget {
  final double rowHeight;
  final double channelColumnWidth;
  final String? channelThumb;
  final MediaServerClient? client;
  final LiveTvChannel channel;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isFocused;
  final bool isFavorite;
  final Widget Function() fallbackBuilder;

  const _ChannelCell({
    required this.rowHeight,
    required this.channelColumnWidth,
    required this.channelThumb,
    required this.client,
    required this.channel,
    required this.theme,
    required this.onTap,
    this.onLongPress,
    required this.isFocused,
    this.isFavorite = false,
    required this.fallbackBuilder,
  });

  @override
  State<_ChannelCell> createState() => _ChannelCellState();
}

class _ChannelCellState extends State<_ChannelCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final tk = tokens(context);
    final showAction = _hovered || widget.isFocused;
    final radius = BorderRadius.circular(widget.isFocused ? 12 : 10);
    // Inverted focus card, matching the program-block cursor.
    final contentColor = widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTap: widget.onLongPress,
        child: SizedBox(
          height: widget.rowHeight,
          child: Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Material(
              color: widget.isFocused ? theme.colorScheme.primary : tk.surface,
              shape: RoundedRectangleBorder(borderRadius: radius),
              child: InkWell(
                borderRadius: radius,
                canRequestFocus: false,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Stack(
                    alignment: .center,
                    children: [
                      AnimatedOpacity(
                        opacity: showAction ? 0.3 : 1.0,
                        duration: FocusTheme.getAnimationDuration(context),
                        child: widget.channelThumb != null && widget.client != null
                            ? OptimizedMediaImage.thumb(
                          client: widget.client!,
                          imagePath: widget.channelThumb,
                          width: widget.channelColumnWidth - 16,
                          height: widget.rowHeight - 16,
                          fit: BoxFit.contain,
                          logoToneTarget: logoToneTargetFor(
                            surface: widget.isFocused ? theme.colorScheme.primary : tk.surface,
                            foreground: widget.isFocused
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                          ),
                        )
                            : widget.fallbackBuilder(),
                      ),
                      if (showAction) AppIcon(Symbols.play_arrow_rounded, size: 32, color: contentColor),
                      if (widget.channel.number != null && widget.channelThumb != null && widget.client != null)
                        Positioned(
                          left: 0,
                          bottom: 3,
                          child: Text(
                            widget.channel.number!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: contentColor.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      if (widget.isFavorite)
                        Positioned(
                          top: 2,
                          right: 0,
                          child: AppIcon(
                            Symbols.star_rounded,
                            size: 14,
                            color: widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Soft vertical rules at every 30 minute slot boundary of the guide grid.
class _SlotLinesPainter extends CustomPainter {
  final double slotWidth;
  final bool firstIsHour;
  final Color color;

  const _SlotLinesPainter({required this.slotWidth, required this.firstIsHour, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final hourPaint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final halfPaint = Paint()
      ..color = color.withValues(alpha: color.a * 0.5)
      ..strokeWidth = 1;
    var i = 0;
    for (var x = 0.0; x < size.width; x += slotWidth, i++) {
      final isHour = (i.isEven) == firstIsHour;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), isHour ? hourPaint : halfPaint);
    }
  }

  @override
  bool shouldRepaint(_SlotLinesPainter old) => old.slotWidth != slotWidth || old.color != color || old.firstIsHour != firstIsHour;
}
