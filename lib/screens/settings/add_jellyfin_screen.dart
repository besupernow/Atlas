import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../services/atlas_gate/atlas_gate.dart';
import '../atlas_wall_screen.dart';
import '../../widgets/atlas_backdrop.dart';

import '../../connection/connection.dart';

import '../../connection/connection_registry.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/card_focus_scope.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_browser_dialect.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../services/jellyfin_auth_header.dart';
import '../../services/jellyfin_auth_service.dart';
import '../../services/jellyfin_endpoint_discovery.dart';
import '../../services/jellyfin_lan_discovery_service.dart';
import '../../services/storage_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/quick_connect_code_panel.dart';
import '../profile/profile_switch_screen.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';
import 'quick_connect_flow_mixin.dart';

@visibleForTesting
Future<String> resolveJellyfinClientVersion({Future<PackageInfo> Function()? packageInfoLoader}) async {
  const fallbackVersion = '1.0';
  try {
    final packageInfo = await (packageInfoLoader == null ? PackageInfo.fromPlatform() : packageInfoLoader());
    final version = packageInfo.version.trim();
    if (version.isNotEmpty) return version;
    appLogger.w('Package version is empty; using Jellyfin client version $fallbackVersion');
  } catch (error, stackTrace) {
    appLogger.w(
      'Failed to resolve package version; using Jellyfin client version $fallbackVersion',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return fallbackVersion;
}

const String kAtlasServerUrl = 'https://atlas.besupernow.com';

/// Auth service with this install's client/device identity. Shared by the
/// login form and the Atlas+ wall.
Future<JellyfinConnectionAuthService> buildJellyfinAuthService(MediaBrowserDialect dialect) async {
  final clientVersion = await resolveJellyfinClientVersion();
  final identity = await DeviceIdentityService.resolve();
  return JellyfinConnectionAuthService(
    clientName: jellyfinClientName(identity),
    clientVersion: clientVersion,
    deviceName: jellyfinDeviceName(identity),
    dialect: dialect,
  );
}

/// Shared persistence path for password and Quick Connect sign-ins:
/// atomically provision the optional first-run profile, connection, and
/// ownership row, then bind. Returns an error message, or null on success.
/// Does not navigate.
Future<String?> persistJellyfinSignIn(
    BuildContext context,
    JellyfinConnection connection, {
      Profile? targetProfile,
    }) async {
  final activeProvider = context.read<ActiveProfileProvider>();
  await activeProvider.initialize();
  if (!context.mounted) return null;
  var boundProfile = targetProfile ?? activeProvider.active;
  if (shouldPromptForJellyfinProfileSelection(
    targetProfile: targetProfile,
    activeProfile: activeProvider.active,
    hasProfiles: activeProvider.profiles.isNotEmpty,
  )) {
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
    if (!context.mounted) return null;
    boundProfile = activeProvider.active;
    if (boundProfile == null) return t.messages.noProfilesAvailable;
  }

  Profile? firstRunProfile;
  if (shouldCreateLocalJellyfinProfile(
    targetProfile: targetProfile,
    activeProfile: boundProfile,
    hasProfiles: activeProvider.profiles.isNotEmpty,
  )) {
    final now = DateTime.now();
    firstRunProfile = Profile.local(
      id: 'local-${const Uuid().v4()}',
      displayName: connection.userName.isNotEmpty ? connection.userName : connection.serverName,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );
    boundProfile = firstRunProfile;
  }

  final bindProfile = boundProfile;
  if (bindProfile == null) return t.messages.noProfilesAvailable;

  await persistAndBindConnection(
    context: context,
    connection: connection,
    bindToProfile: ProfileConnection(
      profileId: bindProfile.id,
      connectionId: connection.id,
      userToken: connection.accessToken,
      userIdentifier: connection.userId,
      tokenAcquiredAt: DateTime.now(),
    ),
    firstRunProfile: firstRunProfile,
  );

  if (!context.mounted) return null;
  if (bindProfile.id == activeProvider.activeId) {
    await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
  }
  return null;
}

@visibleForTesting
bool shouldCreateLocalJellyfinProfile({
  required Profile? targetProfile,
  required Profile? activeProfile,
  required bool hasProfiles,
}) {
  return targetProfile == null && activeProfile == null && !hasProfiles;
}

@visibleForTesting
bool shouldPromptForJellyfinProfileSelection({
  required Profile? targetProfile,
  required Profile? activeProfile,
  required bool hasProfiles,
}) {
  return targetProfile == null && activeProfile == null && hasProfiles;
}

/// Three-step form to add a Jellyfin or Emby server:
///   1. Probe URL candidates (`/System/Info/Public`).
///   2. Username + password (`/Users/AuthenticateByName`) or Quick Connect
///      when supported by the selected [dialect].
///   3. Persist via [ConnectionRegistry] and create a [ProfileConnection]
///      row binding the server to [targetProfile] (or the active profile,
///      if not provided). When the target *is* the active profile we also
///      register the client with the manager so libraries refresh
///      immediately; otherwise the binder picks it up on the next switch.
class AddJellyfinScreen extends StatefulWidget {
  /// When set, the new MediaBrowser connection is bound to this profile via a
  /// [ProfileConnection] row. When null, falls back to the currently active
  /// profile (typical for the global Connections screen entry point).
  final Profile? targetProfile;
  final MediaBrowserDialect dialect;
  final FutureOr<JellyfinConnectionAuthService> Function()? _authServiceFactory;
  final FutureOr<List<DiscoveredJellyfinServer>> Function()? _localDiscoveryFactory;

  const AddJellyfinScreen({
    super.key,
    this.targetProfile,
    this.dialect = MediaBrowserDialect.jellyfin,
    @visibleForTesting this._authServiceFactory,
    @visibleForTesting this._localDiscoveryFactory,
  });

  @override
  State<AddJellyfinScreen> createState() => _AddJellyfinScreenState();
}

class _AddJellyfinScreenState extends State<AddJellyfinScreen>
    with AsyncFormStateMixin, QuickConnectFlowMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'AddJellyfin:Url');
  final _findServerFocus = FocusNode(debugLabel: 'AddJellyfin:FindServer');
  final _changeServerFocus = FocusNode(debugLabel: 'AddJellyfin:ChangeServer');
  final _usernameFocus = FocusNode(debugLabel: 'AddJellyfin:Username');
  // Owned so the username field can advance focus on Enter; mobile keyboards
  // act on `textInputAction: next` automatically but TV remotes / hardware
  // keyboards need the explicit `onFieldSubmitted` handler below.
  final _passwordFocus = FocusNode(debugLabel: 'AddJellyfin:Password');
  final _signInFocus = FocusNode(debugLabel: 'AddJellyfin:SignIn');
  final _quickConnectFocus = FocusNode(debugLabel: 'AddJellyfin:QuickConnect');
  final _cancelQuickConnectFocus = FocusNode(debugLabel: 'AddJellyfin:CancelQuickConnect');
  final _discoveredServerFocusNodes = <String, FocusNode>{};
  final _formKey = GlobalKey<FormState>();

  JellyfinServerInfo? _serverInfo;
  JellyfinEndpointRaceResult? _serverEndpoint;
  List<DiscoveredJellyfinServer> _localServers = const [];
  bool _isDiscoveringLocalServers = true;
  bool _quickConnectEnabled = false;
  int _localDiscoveryAttemptId = 0;

  @override
  void initState() {
    super.initState();
    _isDiscoveringLocalServers = false;
    _urlController.text = kAtlasServerUrl;
    // The device gate is decided before this screen ever shows (SetupScreen
    // routes unapproved devices to AtlasWallScreen). This is only the login.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_probe());
    });
  }

  @override
  void dispose() {
    // Short-circuit any in-flight Quick Connect poll so it doesn't try to
    // setState after the widget is gone.
    endQuickConnectFlow();
    _urlFocus.dispose();
    _findServerFocus.dispose();
    _changeServerFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _signInFocus.dispose();
    _quickConnectFocus.dispose();
    _cancelQuickConnectFocus.dispose();
    for (final node in _discoveredServerFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _discoverLocalServers() async {
    final attemptId = ++_localDiscoveryAttemptId;
    try {
      List<Connection> existingConnections = const <Connection>[];
      try {
        existingConnections = await context.read<ConnectionRegistry>().list();
      } on ProviderNotFoundException {
        // No ConnectionRegistry in the tree (tests / isolated subtrees).
      }
      final existing = existingConnections
          .whereType<JellyfinConnection>()
          .where((c) => c.dialect == widget.dialect)
          .map(
            (c) => DiscoveredJellyfinServer(
          address: c.baseUrl,
          id: c.serverMachineId,
          name: c.serverName,
          dialect: c.dialect,
        ),
      );

      final factory = widget._localDiscoveryFactory;
      final lanServers = factory != null
          ? await factory()
          : await JellyfinLanDiscoveryService().discover(
        dialect: widget.dialect,
        responseWindow: const Duration(milliseconds: 1300),
      );
      if (!mounted || attemptId != _localDiscoveryAttemptId) return;

      // Deduplicate by machine ID
      final combined = [...existing, ...lanServers];
      final seen = <String>{};
      final servers = JellyfinLanDiscoveryService.sortDiscoveredServers(combined.where((s) => seen.add(s.id)));
      setState(() {
        _localServers = servers;
        _isDiscoveringLocalServers = false;
        _syncDiscoveredServerFocusNodes(servers);
      });
    } catch (e, st) {
      appLogger.w('Add ${widget.dialect.productName} local discovery failed', error: e, stackTrace: st);
      if (!mounted || attemptId != _localDiscoveryAttemptId) return;
      setState(() => _isDiscoveringLocalServers = false);
    }
  }

  void _syncDiscoveredServerFocusNodes(List<DiscoveredJellyfinServer> servers) {
    for (final server in servers) {
      _discoveredServerFocusNodes.putIfAbsent(
        server.id,
            () => FocusNode(debugLabel: 'AddJellyfin:Discovered:${server.id}'),
      );
    }
  }

  void _clearResolvedServer() {
    _serverEndpoint = null;
    _serverInfo = null;
    _quickConnectEnabled = false;
  }

  Future<void> _useDiscoveredServer(DiscoveredJellyfinServer server) async {
    if (busy) return;
    setState(() {
      _urlController.text = server.address;
      _clearResolvedServer();
    });
    await _probe();
  }
  Future<void> _probe() async {
    final input = JellyfinEndpointDiscovery.buildUserInputCandidates(_enteredUrls(), dialect: widget.dialect);
    if (input.probeBaseUrls.isEmpty) {
      setErrorText(t.addServer.enterMediaBrowserUrlError(product: widget.dialect.productName));
      return;
    }
    final autoStartQuickConnect = await runAsync<bool>(
          () async {
        final auth = await _buildAuthService();
        final endpoint = await auth.raceEndpoints(
          input.probeBaseUrls,
          baseUrlsToPersist: input.explicitBaseUrls,
          baseUrlValidationGroups: input.validationBaseUrlGroups,
        );
        final serverDialect = endpoint.serverInfo.dialect ?? widget.dialect;
        final qcEnabled = widget.dialect.supportsQuickConnect && serverDialect.supportsQuickConnect
            ? await auth.isQuickConnectEnabled(endpoint.activeBaseUrl)
            : false;
        if (!mounted) return false;
        setState(() {
          _serverEndpoint = endpoint;
          _serverInfo = endpoint.serverInfo;
          _quickConnectEnabled = qcEnabled;
          _urlController.text = endpoint.baseUrls.join('\n');
        });
        // On TV, typing a username/password with a remote is misery — auto-jump
        // to Quick Connect when the server supports it. Mirrors the
        // PlatformDetector.isTV() default in add_plex_account_screen.dart.
        final autoStart = qcEnabled && PlatformDetector.isTV();
        if (!autoStart) requestFocusAfterFrame(_usernameFocus);
        return autoStart;
      },
      errorMapper: (e) =>
      e is MediaServerUrlException ? e.display ?? e.message : t.addServer.couldNotReachServer(error: e.toString()),
    );
    // Sequenced after the probe's runAsync so busy stays set straight through
    // /QuickConnect/Initiate. Started from inside the probe body, the probe's
    // `finally` cleared busy mid-initiate, re-enabling the form — the focus
    // fallback from the removed tile/button then landed on the URL field and
    // auto-opened the TV keyboard over the Quick Connect panel.
    if (autoStartQuickConnect == true && mounted) await _startQuickConnect();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final info = _serverInfo;
    final endpoint = _serverEndpoint;
    if (info == null || endpoint == null) {
      await _probe();
      return;
    }
    // Defensive: the device got revoked (or the gate came back online) after
    // startup. Never show the wall from here, hand off to the wall screen.
    final gate = await AtlasGate.status();
    if (!mounted) return;
    if (gate.needsWall) {
      openAtlasWall(context, gate);
      return;
    }

    await runAsync<void>(
          () async {
        final auth = await _buildAuthService();
        final storage = await StorageService.getInstance();
        final deviceId = await storage.getOrCreateClientIdentifier();

        final connection = await auth.authenticateByName(
          baseUrl: endpoint.activeBaseUrl,
          baseUrls: endpoint.baseUrls,
          username: _usernameController.text,
          password: _passwordController.text,
          deviceId: deviceId,
          serverInfo: info,
        );

        if (!mounted) return;
        // Tells the OS / browser password manager the sign-in worked, so it
        // offers to save (or update) the username and password.
        TextInput.finishAutofillContext();
        await _persistAndExit(connection);
      },
      errorMapper: (e) {
        if (e is MediaServerAuthException) return e.display ?? e.message;
        appLogger.e('Add ${widget.dialect.productName} failed', error: e);
        return t.addServer.signInFailed(error: e.toString());
      },
    );
  }

  Future<void> _startQuickConnect() async {
    final info = _serverInfo;
    final endpoint = _serverEndpoint;
    if (info == null || endpoint == null) return;
    if (!widget.dialect.supportsQuickConnect || !(info.dialect ?? widget.dialect).supportsQuickConnect) return;
    final attemptId = beginQuickConnectAttempt();
    await runAsync<void>(
          () async {
        final auth = await _buildAuthService();
        final storage = await StorageService.getInstance();
        final deviceId = await storage.getOrCreateClientIdentifier();

        final initiation = await auth.initiateQuickConnect(baseUrl: endpoint.activeBaseUrl, deviceId: deviceId);
        if (!isCurrentQuickConnectAttempt(attemptId)) return;
        // Tell the gate which code this device is about to show, so approving
        // that code on a trusted device also lets this device through.
        await AtlasGate.registerEnrollment(initiation.code);
        if (!isCurrentQuickConnectAttempt(attemptId)) return;
        // Show the waiting panel without a spinner — opt-out of busy mid-flow
        // so the user-visible state matches "we're polling, nothing for you to do".
        showQuickConnectCode(initiation.code);
        requestFocusAfterFrame(_cancelQuickConnectFocus);
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
          // Either user cancelled or the secret expired before approval.
          // Cancellation is silent; expiry surfaces an error.
          hideQuickConnectCode();
          if (!quickConnectCancelled) setErrorText(t.auth.quickConnectExpired);
          return;
        }
        await _persistAndExit(connection);
      },
      errorMapper: (e) {
        if (e is MediaServerAuthException) return e.display ?? e.message;
        appLogger.e('Jellyfin Quick Connect failed', error: e);
        return t.addServer.quickConnectFailed(error: e.toString());
      },
      shouldApplyState: () => isCurrentQuickConnectAttempt(attemptId),
    );
    // Clear the QC panel after any error so the form re-shows.
    if (isCurrentQuickConnectAttempt(attemptId) && errorText != null && quickConnectCode != null) {
      hideQuickConnectCode();
    }
  }

  void _focusFirstDiscoveredServerOrFind() {
    if (_localServers.isEmpty) {
      _findServerFocus.requestFocus();
      return;
    }
    _discoveredServerFocusNodes[_localServers.first.id]?.requestFocus();
  }

  void _focusLastDiscoveredServerOrUrl() {
    if (_localServers.isEmpty) {
      _urlFocus.requestFocus();
      return;
    }
    _discoveredServerFocusNodes[_localServers.last.id]?.requestFocus();
  }

  List<String> _enteredUrls() => JellyfinEndpointDiscovery.parseUserEnteredUrls(_urlController.text);

  Future<void> _persistAndExit(JellyfinConnection connection) async {
    if (!mounted) return;
    final error = await persistJellyfinSignIn(context, connection, targetProfile: widget.targetProfile);
    if (!mounted) return;
    if (error != null) {
      setErrorText(error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<JellyfinConnectionAuthService> _buildAuthService() async {
    final authServiceFactory = widget._authServiceFactory;
    if (authServiceFactory != null) return await authServiceFactory();
    return buildJellyfinAuthService(widget.dialect);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: widget.targetProfile != null, // no back out of the login screen
      child: Scaffold(
        body: AtlasBackdrop(
          child: SafeArea(
            child: Stack(
              children: [
                const Positioned(left: 32, top: 24, child: AtlasWordmark(height: 28)),
                Positioned.fill(
                  child: widget.dialect.supportsQuickConnect && quickConnectCode != null
                      ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: QuickConnectCodePanel(
                        code: quickConnectCode!,
                        cancelFocusNode: _cancelQuickConnectFocus,
                        onCancel: cancelQuickConnect,
                        errorText: errorText,
                      ),
                    ),
                  )
                      : Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 80, 24, 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        // AutofillGroup ties username + password together so iOS /
                        // Android autofill and browser password managers treat them as
                        // one login form (on web Flutter emits a real <form>).
                        child: AutofillGroup(
                          child: Form(
                            key: _formKey,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _buildBodyChildren(theme),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyle _primaryButtonStyle(ThemeData theme) => FilledButton.styleFrom(
    backgroundColor: theme.colorScheme.onSurface,
    foregroundColor: theme.colorScheme.surface,
    padding: const EdgeInsets.symmetric(vertical: 18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
  );

  ButtonStyle _secondaryButtonStyle(ThemeData theme) => FilledButton.styleFrom(
    backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
    foregroundColor: theme.colorScheme.onSurface,
    padding: const EdgeInsets.symmetric(vertical: 18),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
  );

  List<Widget> _buildBodyChildren(ThemeData theme) {
    return [
      Text(
        'Sign in',
        style: theme.textTheme.headlineMedium?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          height: 1.1,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Use your Atlas+ username and password.',
        style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.66)),
      ),
      const SizedBox(height: 28),
      if (_serverInfo == null) ...[
        // Still reaching the server, or it failed (error shows below).
        if (busy)
          const Center(child: LoadingIndicatorBox())
        else
          FocusableButton(
            focusNode: _findServerFocus,
            useBackgroundFocus: true,
            autofocus: true,
            onPressed: _probe,
            child: FilledButton(style: _primaryButtonStyle(theme), onPressed: _probe, child: const Text('Retry')),
          ),
      ] else ...[
        FocusableTextFormField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.username],
          keyboardType: TextInputType.text,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: t.addServer.username,
            prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
          ),
          validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
        ),
        const SizedBox(height: 12),
        FocusableTextFormField(
          controller: _passwordController,
          focusNode: _passwordFocus,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          enabled: !busy,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: busy ? null : (_) => _signIn(),
          decoration: InputDecoration(
            labelText: t.addServer.password,
            prefixIcon: const AppIcon(Symbols.lock_rounded, fill: 1),
          ),
        ),
        const SizedBox(height: 16),
        FocusableButton(
          focusNode: _signInFocus,
          useBackgroundFocus: true,
          onPressed: busy ? null : _signIn,
          child: FilledButton(
            style: _primaryButtonStyle(theme),
            onPressed: busy ? null : _signIn,
            child: busy ? const LoadingIndicatorBox(size: 20) : Text(t.addServer.signIn),
          ),
        ),
        if (widget.dialect.supportsQuickConnect && _quickConnectEnabled) ...[
          const SizedBox(height: 12),
          FocusableButton(
            focusNode: _quickConnectFocus,
            useBackgroundFocus: true,
            onPressed: busy ? null : _startQuickConnect,
            child: FilledButton(
              style: _secondaryButtonStyle(theme),
              onPressed: busy ? null : _startQuickConnect,
              child: Text(t.auth.useQuickConnect),
            ),
          ),
        ],
      ],
      ...buildInlineError(theme),
    ];
  }

  Widget _buildServerCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(tokens(context).radiusMd),
      ),
      child: Row(
        children: [
          const AppIcon(Symbols.cloud_done_rounded, fill: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(_serverInfo!.serverName, style: theme.textTheme.titleSmall),
                Text(
                  '${widget.dialect.productName} ${_serverInfo!.version}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  List<Widget> _buildLocalDiscoverySection(ThemeData theme) {
    if (_isDiscoveringLocalServers) {
      return [
        const SizedBox(height: 16),
        Row(
          children: [
            const LoadingIndicatorBox(size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                t.addServer.searchingLocalMediaBrowserServers(product: widget.dialect.productName),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
            ),
          ],
        ),
      ];
    }

    if (_localServers.isEmpty) return const [];
    final tokensRef = tokens(context);
    return [
      const SizedBox(height: 16),
      Text(
        t.addServer.localMediaBrowserServers(product: widget.dialect.productName),
        style: theme.textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      for (final (i, server) in _localServers.indexed) ...[
        if (i > 0) SizedBox(height: tokensRef.groupGap),
        _DiscoveredJellyfinServerTile(
          server: server,
          borderRadius: groupItemRadii(context, i, _localServers.length),
          focusNode: _discoveredServerFocusNodes[server.id],
          onNavigateUp: () {
            final index = _localServers.indexOf(server);
            if (index <= 0) {
              _urlFocus.requestFocus();
              return;
            }
            _discoveredServerFocusNodes[_localServers[index - 1].id]?.requestFocus();
          },
          onNavigateDown: () {
            final index = _localServers.indexOf(server);
            if (index < 0 || index == _localServers.length - 1) {
              _findServerFocus.requestFocus();
              return;
            }
            _discoveredServerFocusNodes[_localServers[index + 1].id]?.requestFocus();
          },
          onTap: busy ? null : () => unawaited(_useDiscoveredServer(server)),
        ),
      ],
      const SizedBox(height: 8),
    ];
  }
}

class _DiscoveredJellyfinServerTile extends StatelessWidget {
  final DiscoveredJellyfinServer server;
  final BorderRadius borderRadius;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onTap;

  const _DiscoveredJellyfinServerTile({
    required this.server,
    required this.borderRadius,
    required this.focusNode,
    required this.onNavigateUp,
    required this.onNavigateDown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusableWrapper(
      focusNode: focusNode,
      disableScale: true,
      // Border drawn by CardFocusBorder so it paints over the opaque Material.
      delegateFocusBorder: true,
      descendantsAreFocusable: false,
      onSelect: onTap,
      onNavigateUp: onNavigateUp,
      onNavigateDown: onNavigateDown,
      child: CardFocusBorder(
        borderRadii: borderRadius,
        strokeAlign: BorderSide.strokeAlignInside,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: borderRadius,
          child: InkWell(
            onTap: onTap,
            borderRadius: borderRadius,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const AppIcon(Symbols.dns_rounded, fill: 1),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      mainAxisSize: .min,
                      children: [
                        Text(server.name, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          server.address,
                          maxLines: 1,
                          overflow: .ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
