import 'dart:async';

import 'package:flutter/widgets.dart';

import '../mpv/mpv.dart';
import '../services/atlas_adaptive_streaming.dart';

/// Atlas adaptive streaming: remembers how fast this device's connection
/// measured during playback, so the next play can open on a level it can
/// actually carry (sent to the server as `AtlasStartBitrate`).
///
/// Reads the player's own bandwidth estimate every few seconds and keeps the
/// best one of the session; that's what's saved when playback ends. The best,
/// not the last, because a level being transcoded can only download as fast as
/// the server encodes it, which drags the estimate down.
class AtlasAbrSampler extends StatefulWidget {
  const AtlasAbrSampler({super.key, required this.player});

  final Player player;

  @override
  State<AtlasAbrSampler> createState() => _AtlasAbrSamplerState();
}

class _AtlasAbrSamplerState extends State<AtlasAbrSampler> {
  Timer? _timer;
  int _best = 0;
  int _samples = 0;
  int? _baseline;

  bool get _eligible {
    final type = widget.player.playerType;
    return AtlasAdaptiveStreaming.enabled && (type == 'exoplayer' || type == 'avplayer' || type == 'web');
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant AtlasAbrSampler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _flush();
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    _timer = null;
    _best = 0;
    _samples = 0;
    _baseline = AtlasAdaptiveStreaming.rememberedBandwidth;
    if (!_eligible) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_sample()));
  }

  Future<void> _sample() async {
    final Map<String, dynamic> stats;
    try {
      stats = await widget.player.getStats();
    } catch (_) {
      return;
    }
    final estimate = stats['bandwidthEstimate'];
    if (estimate is! num || estimate <= 0) return;
    _samples++;
    if (estimate > _best) _best = estimate.round();
    // Save as it goes too, so a killed app still remembers.
    if (_samples == 6) unawaited(AtlasAdaptiveStreaming.rememberBandwidth(_best, baseline: _baseline));
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    // Two samples at least: the very first is the player's guess, not a measurement.
    if (_samples >= 2 && _best > 0) unawaited(AtlasAdaptiveStreaming.rememberBandwidth(_best, baseline: _baseline));
  }

  @override
  void dispose() {
    _flush();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
