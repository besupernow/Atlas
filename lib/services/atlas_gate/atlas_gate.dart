import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../storage_service.dart';
import 'atlas_gate_headers.dart';

export 'atlas_gate_headers.dart' show kAtlasGateHosts;
import 'dart:async';
import 'atlas_block_store.dart';

/// Where the gate service answers. Same host as Jellyfin, behind NPM at
/// `/atlas-gate/`, so the app needs no extra configuration.
const String kAtlasGateBase = 'https://atlas.besupernow.com/atlas-gate';

/// This install's secret. Generated once, kept in the Keychain / Keystore.
///
/// iOS: the Keychain survives deleting and reinstalling the app (and moves to a
/// new phone through an encrypted backup), so a reinstall signs back in with no
/// approval. "Offload app" never touches it.
/// Android: the Keystore is wiped on uninstall, so a reinstall is a new device
/// and re-enrolls with Quick Connect from another device, or the recovery code.
class AtlasGateKey {
  AtlasGateKey._();

  static const String _storageKey = 'atlas_gate_device_key';
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Loads (or creates) the key. Never throws.
  static Future<void> init() async {
    if (AtlasGateHeaders.key.isNotEmpty) return;
    String? key;
    try {
      key = await _secure.read(key: _storageKey);
    } catch (e) {
      appLogger.w('Atlas gate: secure storage read failed, using fallback', error: e);
      try {
        await _secure.deleteAll();
      } catch (_) {}
    }
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    if (!_valid(key)) {
      final fallback = prefs?.getString(_storageKey);
      if (_valid(fallback)) key = fallback;
    }
    if (!_valid(key)) {
      // Android reinstall: Keystore and prefs are gone, Block Store is not.
      final restored = await AtlasBlockStore.read(_storageKey);
      if (_valid(restored)) key = restored;
    }
    if (!_valid(key)) {
      key = _generate();
      try {
        await _secure.write(key: _storageKey, value: key);
      } catch (e) {
        appLogger.w('Atlas gate: secure storage write failed, using fallback', error: e);
      }
    }
    try {
      // Mirror so a platform without a working keychain still keeps its key.
      if (prefs?.getString(_storageKey) != key) await prefs?.setString(_storageKey, key!);
    } catch (_) {}
    AtlasGateHeaders.setKey(key!);
    unawaited(AtlasBlockStore.write(_storageKey, key));
  }

  static bool _valid(String? k) => k != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(k);

  static String _generate() {
    final rng = Random.secure();
    return List.generate(32, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String get key => AtlasGateHeaders.key;
}

enum AtlasAccessResult { approved, requested, cancelled }

class AtlasGateStatus {
  /// approved | unknown | pending | denied | banned | expired | revoked
  final String state;
  final bool lockdown;
  final String? name;
  final String? role;
  final int? expiresAt;
  final bool hasRecovery;
  final bool canInvite;

  /// False when the gate could not be asked (offline, not deployed yet).
  final bool reachable;

  const AtlasGateStatus({
    required this.state,
    this.lockdown = false,
    this.name,
    this.role,
    this.expiresAt,
    this.hasRecovery = false,
    this.canInvite = false,
    this.reachable = true,
  });

  const AtlasGateStatus.unreachable() : this(state: 'unreachable', reachable: false);

  bool get approved => state == 'approved';

  /// Only show the wall when the gate explicitly says this device is not in.
  /// If the gate can't be reached, let the normal login run; the proxy decides.
  bool get needsWall =>
      reachable && const {'unknown', 'pending', 'denied', 'banned', 'expired', 'revoked'}.contains(state);

  static AtlasGateStatus fromJson(Map<String, dynamic> j) => AtlasGateStatus(
    state: (j['state'] as String?) ?? 'unknown',
    lockdown: j['lockdown'] == true,
    name: j['name'] as String?,
    role: j['role'] as String?,
    expiresAt: (j['expiresAt'] as num?)?.toInt(),
    hasRecovery: j['hasRecovery'] == true,
    canInvite: j['canInvite'] == true,
  );
}

class AtlasGateResponse {
  final int status;
  final Map<String, dynamic> json;
  final Object? transportError;

  const AtlasGateResponse(this.status, this.json, [this.transportError]);

  bool get ok => status >= 200 && status < 300;
  bool get failedToReach => transportError != null;

  String? get state => json['state'] as String?;

  /// FastAPI nests `{"detail": {"error": ...}}`; our own denials use `state`.
  String? get error {
    final direct = json['error'];
    if (direct is String) return direct;
    final detail = json['detail'];
    if (detail is Map && detail['error'] is String) return detail['error'] as String;
    if (detail is Map && detail['detail'] is String) return detail['detail'] as String;
    if (detail is String) return detail;
    return state;
  }
}

class AtlasGate {
  AtlasGate._();

  static final http.Client _http = http.Client();

  static Future<void> init() => AtlasGateKey.init();

  static Future<(String label, String jfDeviceId)> _identity() async {
    String label = 'Atlas device';
    String jf = '';
    try {
      final id = await DeviceIdentityService.resolve();
      label = (id.deviceName ?? id.deviceModel ?? id.platform).trim();
      if (label.isEmpty) label = id.platform;
    } catch (_) {}
    try {
      final storage = await StorageService.getInstance();
      jf = await storage.getOrCreateClientIdentifier();
    } catch (_) {}
    return (label.length > 60 ? label.substring(0, 60) : label, jf);
  }

  static Future<AtlasGateResponse> _call(
      String method,
      String path, {
        Map<String, dynamic>? body,
        Map<String, String>? query,
        String? jfToken,
        Duration timeout = const Duration(seconds: 8),
      }) async {
    final uri = Uri.parse('$kAtlasGateBase$path').replace(queryParameters: query);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Atlas-Key': AtlasGateKey.key,
      if (jfToken != null && jfToken.isNotEmpty) 'X-Atlas-Jf-Token': jfToken,
    };
    try {
      final http.Response res;
      if (method == 'GET') {
        res = await _http.get(uri, headers: headers).timeout(timeout);
      } else {
        res = await _http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)).timeout(timeout);
      }
      Map<String, dynamic> json = const {};
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) json = decoded;
        if (decoded is List) json = {'items': decoded};
      } catch (_) {}
      return AtlasGateResponse(res.statusCode, json);
    } catch (e) {
      return AtlasGateResponse(0, const {}, e);
    }
  }

  static Future<AtlasGateStatus> status() async {
    final r = await _call('GET', '/status', timeout: const Duration(seconds: 6));
    if (r.failedToReach || !r.ok || !r.json.containsKey('state')) return const AtlasGateStatus.unreachable();
    return AtlasGateStatus.fromJson(r.json);
  }

  static Future<AtlasGateResponse> requestAccess({required String name, required String phone}) async {
    final (label, jf) = await _identity();
    return _call('POST', '/request', body: {'name': name, 'phone': phone, 'label': label, 'jfDeviceId': jf});
  }

  static Future<AtlasGateResponse> redeem(String code) async {
    final (label, jf) = await _identity();
    return _call('POST', '/redeem', body: {'code': code, 'label': label, 'jfDeviceId': jf});
  }

  /// Tell the gate which Quick Connect code this device is about to show, so a
  /// trusted device approving that code also approves this device. Best effort.
  static Future<void> registerEnrollment(String qcCode) async {
    final (label, jf) = await _identity();
    await _call(
      'POST',
      '/enroll/start',
      body: {'qcCode': qcCode, 'label': label, 'jfDeviceId': jf},
      timeout: const Duration(seconds: 5),
    );
  }

  // Trusted-device calls. They need a live Jellyfin token as well as the key.

  static Future<AtlasGateResponse> enrollPreview(String code, String jfToken) =>
      _call('GET', '/trusted/enroll-preview', query: {'code': code}, jfToken: jfToken);

  static Future<AtlasGateResponse> enroll(String code, String jfToken) =>
      _call('POST', '/trusted/enroll', body: {'code': code}, jfToken: jfToken);

  static Future<AtlasGateResponse> createGuestPass(String name, int hours, String jfToken) =>
      _call('POST', '/trusted/invite', body: {'name': name, 'hours': hours}, jfToken: jfToken);

  static Future<AtlasGateResponse> devices(String jfToken) => _call('GET', '/trusted/devices', jfToken: jfToken);

  static Future<AtlasGateResponse> revokeDevice(int id, String jfToken) =>
      _call('POST', '/trusted/devices/$id/revoke', jfToken: jfToken);

  static Future<AtlasGateResponse> newRecoveryCode(String jfToken) =>
      _call('POST', '/trusted/recovery-code', jfToken: jfToken);
}
