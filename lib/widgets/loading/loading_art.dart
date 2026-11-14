import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/image_cache_service.dart';
import '../../utils/app_logger.dart';
import 'strip_cache_stub.dart'
    if (dart.library.io) 'strip_cache_io.dart'
    if (dart.library.js_interop) 'strip_cache_web.dart';

/// Random backdrops from the server, served before anyone signs in by the
/// atlas-share service (`/atlas-share/artwork`).
const String kLoadingArtEndpoint = 'https://atlas.besupernow.com/atlas-share/artwork?count=6';

// Strip geometry. web/index.html draws the same strip with the same numbers
// so the hand-off from the web splash to this screen doesn't jump.
const double kArtTileWidth = 640;
const double kArtTileHeight = 360;

/// How much neighbouring backdrops overlap, cross-fading into each other.
const double kArtOverlap = 224;

/// Drift speed in screen pixels per second. Slow on purpose: it should read
/// like a mirage, not a ticker.
const double kArtScrollSpeed = 8;

/// The art also floats gently up and down (this fraction of the letter
/// height, over [kArtFloatPeriod] seconds) and its brightness breathes
/// between [kArtShimmerLow] and 1 over [kArtShimmerPeriod] seconds.
const double kArtFloatAmount = 0.035;
const double kArtFloatPeriod = 14;
const double kArtShimmerLow = 0.8;
const double kArtShimmerPeriod = 7;

/// The wordmark's art is this many times taller than the letters, so the
/// letters show a crop from the middle of the backdrops.
const double kArtHeightFactor = 1.25;

class LoadingArt {
  LoadingArt._();

  /// The ready-made strip to show right away: on native the one saved last
  /// launch, on web the one the web splash is already showing. No network,
  /// no image loading, so the art is up from the first frame.
  static Future<ui.Image?> cachedStrip() async {
    final bytes = await readCachedStrip();
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      appLogger.d('Loading art: cached strip unreadable: $e');
      return null;
    }
  }

  /// Builds a fresh random strip in the background and saves it for the
  /// NEXT launch; the current screen keeps what it has. (Native only; the
  /// web splash refreshes its own.)
  static Future<void> prepareNextLaunch() async {
    if (!kRefreshesOwnStrip) return;
    final urls = await _fetch();
    if (urls.isEmpty) return;
    final strip = await buildStrip(urls);
    if (strip == null) return;
    try {
      await saveForNextLaunch(strip);
    } finally {
      strip.dispose();
    }
  }

  /// Saves [strip] as the one the next launch starts with.
  static Future<void> saveForNextLaunch(ui.Image strip) async {
    if (!kRefreshesOwnStrip) return;
    try {
      final data = await strip.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) await writeCachedStrip(data.buffer.asUint8List());
    } catch (e) {
      appLogger.d('Loading art: could not save strip: $e');
    }
  }

  static const _prefsKey = 'atlas_loading_art';

  /// The URLs to use now: the web splash's, the cached list from last time
  /// (refreshed in the background for next launch), or a fresh fetch on the
  /// very first launch.
  static Future<List<String>> urls({List<String>? handoff}) async {
    if (handoff != null && handoff.isNotEmpty) return handoff;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    final cached = prefs?.getStringList(_prefsKey);
    final fresh = _fetch().then((list) async {
      if (list.isNotEmpty) {
        try {
          await prefs?.setStringList(_prefsKey, list);
        } catch (_) {}
      }
      return list;
    });
    if (cached != null && cached.isNotEmpty) {
      unawaited(fresh);
      return cached;
    }
    return fresh.timeout(const Duration(milliseconds: 2500), onTimeout: () => const <String>[]);
  }

  static Future<List<String>> _fetch() async {
    try {
      final res = await http.get(Uri.parse(kLoadingArtEndpoint)).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body);
      final images = body is Map ? body['images'] : null;
      if (images is! List) return const [];
      return [
        for (final i in images)
          if (i is Map && i['url'] is String && (i['url'] as String).startsWith('https://')) i['url'] as String,
      ];
    } catch (e) {
      appLogger.d('Loading art: fetch failed: $e');
      return const [];
    }
  }

  /// Loads the backdrops and paints them into one seamless, horizontally
  /// tileable strip: each backdrop cross-fades into the next, and the last
  /// one fades into the first so the strip can loop forever.
  static Future<ui.Image?> buildStrip(List<String> urls) async {
    final loaded = await Future.wait(urls.map(_resolve));
    final images = loaded.whereType<ui.Image>().toList();
    if (images.isEmpty) return null;
    try {
      return await _paintStrip(images);
    } finally {
      for (final img in images) {
        img.dispose();
      }
    }
  }

  static Future<ui.Image?> _resolve(String url) {
    final completer = Completer<ui.Image?>();
    final provider = CachedNetworkImageProvider(url, cacheManager: kIsWeb ? null : PlexImageCacheManager.instance);
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        stream.removeListener(listener);
        return null;
      },
    );
  }

  static Future<ui.Image> _paintStrip(List<ui.Image> images) {
    const w = kArtTileWidth;
    const h = kArtTileHeight;
    const step = kArtTileWidth - kArtOverlap;
    final n = images.length;
    final period = (n * step).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, period.toDouble(), h));
    canvas.clipRect(Rect.fromLTWH(0, 0, period.toDouble(), h));
    const fade = kArtOverlap / kArtTileWidth;

    void draw(ui.Image img, double x) {
      final dst = Rect.fromLTWH(x, 0, w, h);
      // Cover-crop to the tile's 16:9.
      final iw = img.width.toDouble();
      final ih = img.height.toDouble();
      const target = w / h;
      final Rect src;
      if (iw / ih > target) {
        final cw = ih * target;
        src = Rect.fromLTWH((iw - cw) / 2, 0, cw, ih);
      } else {
        final ch = iw / target;
        src = Rect.fromLTWH(0, (ih - ch) / 2, iw, ch);
      }
      canvas.saveLayer(dst, Paint());
      canvas.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.medium);
      canvas.drawRect(
        dst,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            dst.centerLeft,
            dst.centerRight,
            const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
            const [0, fade, 1 - fade, 1],
          ),
      );
      canvas.restore();
    }

    // The last backdrop again, one step before the start: its fading tail
    // is what the strip shows right after it wraps.
    draw(images[n - 1], -step);
    for (var i = 0; i < n; i++) {
      draw(images[i], i * step);
    }
    final picture = recorder.endRecording();
    return picture.toImage(period, h.round()).whenComplete(picture.dispose);
  }
}
