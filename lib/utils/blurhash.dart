import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// BlurHash placeholders for server artwork.
///
/// Jellyfin sends a tiny BlurHash string for every image it lists
/// (`ImageBlurHashes` on each item, keyed by image type then image tag).
/// [BlurHashRegistry] remembers them by tag as items are parsed, and
/// [OptimizedMediaImage] paints the decoded blur instantly while the real
/// artwork downloads, so a page shows its colors before a single image
/// request finishes.
class BlurHashRegistry {
  BlurHashRegistry._();

  static final Map<String, String> _byTag = {};
  static const int _maxEntries = 8000;

  /// Record every hash in a Jellyfin `ImageBlurHashes` object.
  static void registerJellyfin(Object? imageBlurHashes) {
    if (imageBlurHashes is! Map) return;
    for (final byTag in imageBlurHashes.values) {
      if (byTag is! Map) continue;
      byTag.forEach((tag, hash) {
        if (tag is String && hash is String && hash.length >= 6) {
          if (_byTag.length >= _maxEntries) _byTag.clear();
          _byTag[tag] = hash;
        }
      });
    }
  }

  /// The hash for an image path or URL carrying a `tag=` query parameter.
  static String? forImagePath(String? path) {
    if (path == null || _byTag.isEmpty) return null;
    final at = path.indexOf('tag=');
    if (at < 0) return null;
    var end = path.indexOf('&', at);
    if (end < 0) end = path.length;
    final tag = Uri.decodeQueryComponent(path.substring(at + 4, end));
    return _byTag[tag];
  }
}

/// Decodes a BlurHash into a small image. Flutter scales it up with
/// bilinear filtering, which is exactly the soft blur we want.
@immutable
class BlurHashImage extends ImageProvider<BlurHashImage> {
  const BlurHashImage(this.hash, {this.decodeWidth = 32, this.decodeHeight = 32});

  final String hash;
  final int decodeWidth;
  final int decodeHeight;

  @override
  Future<BlurHashImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(BlurHashImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load());
  }

  Future<ImageInfo> _load() async {
    final pixels = decodeBlurHash(hash, decodeWidth, decodeHeight);
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: decodeWidth,
      height: decodeHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    buffer.dispose();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is BlurHashImage &&
      other.hash == hash &&
      other.decodeWidth == decodeWidth &&
      other.decodeHeight == decodeHeight;

  @override
  int get hashCode => Object.hash(hash, decodeWidth, decodeHeight);
}

const String _chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#\$%*+,-.:;=?@[]^_{|}~';

int _decode83(String str, int start, int end) {
  var value = 0;
  for (var i = start; i < end; i++) {
    final digit = _chars.indexOf(str[i]);
    if (digit < 0) throw const FormatException('Invalid BlurHash character');
    value = value * 83 + digit;
  }
  return value;
}

double _sRgbToLinear(int value) {
  final v = value / 255.0;
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

int _linearToSrgb(double value) {
  final v = value.clamp(0.0, 1.0);
  final s = v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  return (s * 255 + 0.5).floor().clamp(0, 255);
}

double _signPow(double value, double exp) => math.pow(value.abs(), exp).toDouble() * (value < 0 ? -1 : 1);

/// Standard BlurHash decode to RGBA8888 pixels. Throws [FormatException] on a
/// malformed hash.
Uint8List decodeBlurHash(String hash, int width, int height, {double punch = 1.0}) {
  if (hash.length < 6) throw const FormatException('BlurHash too short');
  final sizeFlag = _decode83(hash, 0, 1);
  final numY = sizeFlag ~/ 9 + 1;
  final numX = sizeFlag % 9 + 1;
  if (hash.length != 4 + 2 * numX * numY) throw const FormatException('BlurHash length mismatch');

  final maxValue = (_decode83(hash, 1, 2) + 1) / 166 * punch;
  final colors = List<List<double>>.filled(numX * numY, const [0, 0, 0]);
  final dc = _decode83(hash, 2, 6);
  colors[0] = [_sRgbToLinear(dc >> 16), _sRgbToLinear((dc >> 8) & 255), _sRgbToLinear(dc & 255)];
  for (var i = 1; i < numX * numY; i++) {
    final ac = _decode83(hash, 4 + i * 2, 6 + i * 2);
    colors[i] = [
      _signPow((ac ~/ (19 * 19) - 9) / 9.0, 2) * maxValue,
      _signPow(((ac ~/ 19) % 19 - 9) / 9.0, 2) * maxValue,
      _signPow((ac % 19 - 9) / 9.0, 2) * maxValue,
    ];
  }

  final pixels = Uint8List(width * height * 4);
  final cosX = List<double>.filled(width * numX, 0);
  for (var x = 0; x < width; x++) {
    for (var i = 0; i < numX; i++) {
      cosX[x * numX + i] = math.cos(math.pi * x * i / width);
    }
  }
  var p = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var j = 0; j < numY; j++) {
        final cy = math.cos(math.pi * y * j / height);
        for (var i = 0; i < numX; i++) {
          final basis = cosX[x * numX + i] * cy;
          final c = colors[i + j * numX];
          r += c[0] * basis;
          g += c[1] * basis;
          b += c[2] * basis;
        }
      }
      pixels[p++] = _linearToSrgb(r);
      pixels[p++] = _linearToSrgb(g);
      pixels[p++] = _linearToSrgb(b);
      pixels[p++] = 255;
    }
  }
  return pixels;
}
