import 'dart:convert';

import 'package:http/http.dart' as http;

/// Public share links for one movie or episode (the atlas-share service on
/// the Mac mini, routed at `/atlas-share/` on the Atlas+ domain).
const String kAtlasShareOrigin = 'https://atlas.besupernow.com';
const String kAtlasShareBase = '$kAtlasShareOrigin/atlas-share';

/// Durations the service accepts, in hours.
const List<int> kShareDurationsHours = [1, 6, 12, 24, 48, 72, 96, 120, 144, 168];

String shareDurationLabel(int hours) => hours < 48 ? '$hours hr${hours == 1 ? '' : 's'}' : '${hours ~/ 24} days';

class AtlasShareException implements Exception {
  AtlasShareException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AtlasShareLink {
  AtlasShareLink({required this.url, required this.expiresAt, required this.singleUse});

  final String url;
  final DateTime expiresAt;
  final bool singleUse;
}

class AtlasShareItem {
  AtlasShareItem(this.json);

  final Map<String, dynamic> json;

  String get title => json['name'] as String? ?? 'Untitled';
  String? get seriesName => json['seriesName'] as String?;
  int? get season => json['season'] as int?;
  int? get episode => json['episode'] as int?;
  int? get year => json['year'] as int?;
  String? get overview => json['overview'] as String?;
  String? get rating => json['officialRating'] as String?;
  String? get backdropUrl => json['backdropUrl'] as String?;
  String? get posterUrl => json['posterUrl'] as String?;
  String? get logoUrl => json['logoUrl'] as String?;
  Duration? get runtime {
    final ticks = json['runTimeTicks'];
    return ticks is num ? Duration(microseconds: ticks ~/ 10) : null;
  }

  bool get isEpisode => json['type'] == 'Episode';
}

class AtlasShareSession {
  AtlasShareSession(this.json);

  final Map<String, dynamic> json;

  String get id => json['session'] as String;
  String get streamUrl => '$kAtlasShareOrigin${json['streamPath']}';
  DateTime get expiresAt => DateTime.fromMillisecondsSinceEpoch((json['expiresAt'] as num).toInt() * 1000);
  bool get singleUse => json['singleUse'] == true;
  String? get sharedBy => json['sharedBy'] as String?;
  AtlasShareItem get item => AtlasShareItem(json['item'] as Map<String, dynamic>);
}

class AtlasShareApi {
  AtlasShareApi._();

  static const _json = {'Content-Type': 'application/json'};

  static Never _fail(http.Response r) {
    try {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      throw AtlasShareException(body['error'] as String? ?? 'error', body['message'] as String? ?? 'Something went wrong.');
    } on AtlasShareException {
      rethrow;
    } catch (_) {
      throw AtlasShareException('http_${r.statusCode}', "Couldn't reach Atlas+ (HTTP ${r.statusCode}).");
    }
  }

  /// Create a link. [jellyfinToken] is the sharer's own session token; the
  /// service checks they can see the item before sharing it.
  static Future<AtlasShareLink> create({
    required String jellyfinToken,
    required String itemId,
    required int hours,
    required bool singleUse,
  }) async {
    final r = await http
        .post(
      Uri.parse('$kAtlasShareBase/create'),
      headers: {..._json, 'X-Emby-Token': jellyfinToken},
      body: jsonEncode({'itemId': itemId, 'hours': hours, 'singleUse': singleUse}),
    )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return AtlasShareLink(
      url: body['url'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch((body['expiresAt'] as num).toInt() * 1000),
      singleUse: body['singleUse'] == true,
    );
  }

  static Future<AtlasShareSession> redeem(String code) async {
    final r = await http
        .post(Uri.parse('$kAtlasShareBase/redeem'), headers: _json, body: jsonEncode({'code': code}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) _fail(r);
    return AtlasShareSession(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Tell the service the guest is done (stops the server's transcode).
  static Future<void> end(String sessionId) async {
    try {
      await http.post(Uri.parse('$kAtlasShareBase/s/$sessionId/end')).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
