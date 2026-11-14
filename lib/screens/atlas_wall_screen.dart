import 'dart:async';

import 'package:flutter/material.dart';

import '../database/tvos_database_recovery_store.dart';
import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../main.dart' show SetupScreen;
import '../media/media_browser_dialect.dart';
import '../services/atlas_gate/atlas_gate.dart';
import '../services/jellyfin_endpoint_discovery.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import '../utils/navigation_transitions.dart';
import '../utils/platform_detector.dart';
import '../widgets/atlas_wall_view.dart';
import 'atlas_access_screen.dart';
import 'settings/add_jellyfin_screen.dart';
import 'settings/async_form_state_mixin.dart';
import 'settings/quick_connect_flow_mixin.dart';

/// Replaces the whole stack with the wall. Used by SetupScreen and as a
/// defensive redirect from anywhere that finds out the device isn't in.
void openAtlasWall(BuildContext context, AtlasGateStatus status) {
  unawaited(
    Navigator.of(
      context,
      rootNavigator: true,
    ).pushAndRemoveUntil(fadeRoute(AtlasWallScreen(initialStatus: status)), (_) => false),
  );
}

/// Atlas+ is a closed server. A device the gate hasn't approved lands here,
/// before any login form exists: a Quick Connect code (QR on TV) that an
/// approved device can approve, plus request access / invite code.
///
/// When the device gets in, the stack is handed back to [SetupScreen], which
/// routes on to home (Quick Connect also signed in) or the login screen
/// (approved through a request or code).
class AtlasWallScreen extends StatefulWidget {
  final AtlasGateStatus? initialStatus;

  const AtlasWallScreen({super.key, this.initialStatus});

  @override
  State<AtlasWallScreen> createState() => _AtlasWallScreenState();
}

class _AtlasWallScreenState extends State<AtlasWallScreen> with AsyncFormStateMixin, QuickConnectFlowMixin {
  static const _dialect = MediaBrowserDialect.jellyfin;

  late AtlasGateStatus _status;
  bool _requestSent = false;
  bool _leaving = false;
  bool _loopRunning = false;
  Timer? _poll;
  Timer? _qcGrace;

  JellyfinServerInfo? _serverInfo;
  JellyfinEndpointRaceResult? _endpoint;
  bool _quickConnectEnabled = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus ?? const AtlasGateStatus(state: 'unknown');
    _requestSent = _status.state == 'pending';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _qcGrace?.cancel();
    endQuickConnectFlow();
    super.dispose();
  }

  Future<void> _start() async {
    final s = await AtlasGate.status();
    if (!mounted) return;
    if (s.approved) {
      _continue();
      return;
    }
    if (s.reachable) setState(() => _status = s);
    _startPoll();
    await _probe();
    if (mounted && _serverInfo != null) unawaited(_quickConnectLoop());
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) async {
      final s = await AtlasGate.status();
      if (!mounted || _leaving || !s.reachable) return;
      if (s.approved) {
        // Approved through Quick Connect: that flow is about to finish the
        // sign-in, give it a moment so the user lands on home, not the login.
        if (quickConnectCode != null) {
          _qcGrace ??= Timer(const Duration(seconds: 10), _continue);
        } else {
          _continue();
        }
        return;
      }
      if (s.state != _status.state || s.lockdown != _status.lockdown) {
        setState(() {
          _status = s;
          if (s.state == 'denied' || s.state == 'banned') _requestSent = false;
          if (s.state == 'pending') _requestSent = true;
        });
      }
    });
  }

  /// Device is in. Hand the whole stack back to the startup router.
  void _continue() {
    if (_leaving || !mounted) return;
    _leaving = true;
    _poll?.cancel();
    _qcGrace?.cancel();
    endQuickConnectFlow();
    unawaited(
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        fadeRoute(const SetupScreen(databaseRecoveryOutcome: TvosDatabaseRecoveryOutcome.notApplicable)),
        (_) => false,
      ),
    );
  }

  Future<void> _probe() async {
    final input = JellyfinEndpointDiscovery.buildUserInputCandidates(
      JellyfinEndpointDiscovery.parseUserEnteredUrls(kAtlasServerUrl),
      dialect: _dialect,
    );
    await runAsync<void>(
      () async {
        final auth = await buildJellyfinAuthService(_dialect);
        final endpoint = await auth.raceEndpoints(
          input.probeBaseUrls,
          baseUrlsToPersist: input.explicitBaseUrls,
          baseUrlValidationGroups: input.validationBaseUrlGroups,
        );
        final serverDialect = endpoint.serverInfo.dialect ?? _dialect;
        final qcEnabled = serverDialect.supportsQuickConnect
            ? await auth.isQuickConnectEnabled(endpoint.activeBaseUrl)
            : false;
        if (!mounted) return;
        setState(() {
          _endpoint = endpoint;
          _serverInfo = endpoint.serverInfo;
          _quickConnectEnabled = qcEnabled;
        });
      },
      errorMapper: (e) =>
          e is MediaServerUrlException ? e.display ?? e.message : t.addServer.couldNotReachServer(error: e.toString()),
    );
  }

  /// Keeps a live Quick Connect code on the wall, fetching a fresh one when it
  /// expires.
  Future<void> _quickConnectLoop() async {
    if (_loopRunning) return;
    _loopRunning = true;
    try {
      while (mounted && !_leaving && _serverInfo != null && _quickConnectEnabled) {
        await _runQuickConnect();
        if (!mounted || _leaving) break;
        await Future<void>.delayed(Duration(seconds: errorText != null ? 8 : 1));
      }
    } finally {
      _loopRunning = false;
    }
  }

  Future<void> _runQuickConnect() async {
    final info = _serverInfo;
    final endpoint = _endpoint;
    if (info == null || endpoint == null) return;
    final attemptId = beginQuickConnectAttempt();
    await runAsync<void>(
      () async {
        final auth = await buildJellyfinAuthService(_dialect);
        final storage = await StorageService.getInstance();
        final deviceId = await storage.getOrCreateClientIdentifier();

        final initiation = await auth.initiateQuickConnect(baseUrl: endpoint.activeBaseUrl, deviceId: deviceId);
        if (!isCurrentQuickConnectAttempt(attemptId)) return;
        // Tell the gate which code this device is showing, so approving it on a
        // trusted device also lets this device through.
        await AtlasGate.registerEnrollment(initiation.code);
        if (!isCurrentQuickConnectAttempt(attemptId)) return;
        showQuickConnectCode(initiation.code);
        setBusy(false);

        final connection = await auth.authenticateByQuickConnect(
          baseUrl: endpoint.activeBaseUrl,
          baseUrls: endpoint.baseUrls,
          secret: initiation.secret,
          deviceId: deviceId,
          serverInfo: info,
          shouldCancel: () => quickConnectAborted(attemptId),
        );

        if (!isCurrentQuickConnectAttempt(attemptId)) return;
        if (connection == null) {
          hideQuickConnectCode();
          if (!quickConnectCancelled) setErrorText(t.auth.quickConnectExpired);
          return;
        }
        final error = await persistJellyfinSignIn(context, connection);
        if (!mounted) return;
        if (error != null) {
          setErrorText(error);
          return;
        }
        _continue();
      },
      errorMapper: (e) {
        if (e is MediaServerAuthException) return e.display ?? e.message;
        appLogger.e('Atlas wall Quick Connect failed', error: e);
        return t.addServer.quickConnectFailed(error: e.toString());
      },
      shouldApplyState: () => isCurrentQuickConnectAttempt(attemptId),
    );
    if (isCurrentQuickConnectAttempt(attemptId) && errorText != null && quickConnectCode != null) {
      hideQuickConnectCode();
    }
  }

  Future<void> _openAccessScreen(AtlasAccessMode mode) async {
    final result = await Navigator.of(
      context,
    ).push<AtlasAccessResult>(MaterialPageRoute(builder: (_) => AtlasAccessScreen(mode: mode)));
    if (!mounted) return;
    if (result == AtlasAccessResult.approved) {
      _continue();
    } else if (result == AtlasAccessResult.requested) {
      setState(() {
        _requestSent = true;
        _status = const AtlasGateStatus(state: 'pending');
      });
    }
  }

  Future<void> _retry() async {
    setErrorText(null);
    if (_serverInfo == null) await _probe();
    if (mounted && _serverInfo != null) unawaited(_quickConnectLoop());
  }

  String? get _notice {
    switch (_status.state) {
      case 'denied':
        return "Your last request wasn't approved.";
      case 'banned':
        return "Access can't be requested from this device.";
      case 'expired':
        return 'Your guest pass has ended.';
      case 'revoked':
        return 'This device was removed from Atlas+. Approve it from another device, or use your recovery code.';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The wall is the root route, so Back (remote, gesture) leaves the app
    // instead of doing nothing.
    return PopScope(
      canPop: true,
      child: Scaffold(
        body: SafeArea(
          child: AtlasWallView(
            code: quickConnectCode,
            isTv: PlatformDetector.isTV(),
            pending: _requestSent,
            lockdown: _status.lockdown,
            notice: _notice,
            error: quickConnectCode == null ? errorText : null,
            onRequestAccess: () => _openAccessScreen(AtlasAccessMode.request),
            onHaveCode: () => _openAccessScreen(AtlasAccessMode.code),
            onRetry: _serverInfo == null || errorText != null ? () => unawaited(_retry()) : null,
          ),
        ),
      ),
    );
  }
}
