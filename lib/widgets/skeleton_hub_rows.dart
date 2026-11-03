import 'package:flutter/material.dart';

import '../services/device_performance.dart';
import 'media_card.dart' show SkeletonLoader;

/// Placeholder rows shaped like the Home screen's hubs (a title and a row of
/// posters), shown while the first hubs load instead of a lone spinner.
/// The whole block pulses gently; it holds still on the reduced effects tier.
class SkeletonHubRows extends StatefulWidget {
  const SkeletonHubRows({super.key, this.rows = 3});

  final int rows;

  @override
  State<SkeletonHubRows> createState() => _SkeletonHubRowsState();
}

class _SkeletonHubRowsState extends State<SkeletonHubRows> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.55,
  );

  @override
  void initState() {
    super.initState();
    if (!DevicePerformance.isReduced) _pulse.repeat(reverse: true);
    if (DevicePerformance.isReduced) _pulse.value = 1;
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final posterWidth = width >= 1200
        ? 170.0
        : width >= 700
        ? 145.0
        : 118.0;
    final posterHeight = posterWidth * 1.5;
    return FadeTransition(
      opacity: _pulse,
      child: IgnorePointer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var row = 0; row < widget.rows; row++)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 0, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonLoader(
                      borderRadius: const BorderRadius.all(Radius.circular(6)),
                      child: SizedBox(width: row.isEven ? 170 : 130, height: 20),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: posterHeight + 34,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: double.infinity,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < (width / (posterWidth + 12)).ceil() + 1; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      SkeletonLoader(
                                        borderRadius: const BorderRadius.all(Radius.circular(10)),
                                        child: SizedBox(width: posterWidth, height: posterHeight),
                                      ),
                                      const SizedBox(height: 8),
                                      SkeletonLoader(
                                        borderRadius: const BorderRadius.all(Radius.circular(4)),
                                        child: SizedBox(width: posterWidth * 0.8, height: 12),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
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
    );
  }
}
