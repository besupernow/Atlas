import 'package:flutter/material.dart';

import 'skeleton_media_card.dart';

/// First-load placeholder for poster grids (library browse, "see all" hubs,
/// collections, playlists): a full screen of skeleton cards instead of a
/// lone spinner, so the page has its shape the moment it opens. Real cards
/// then paint their BlurHash and finally the artwork in the same slots.
class SkeletonCardGrid extends StatelessWidget {
  const SkeletonCardGrid({super.key, this.count = 24});

  final int count;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final maxExtent = width >= 1200
        ? 190.0
        : width >= 700
        ? 160.0
        : 128.0;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxExtent,
          // 2:3 poster plus room for the two caption lines.
          childAspectRatio: 0.56,
        ),
        delegate: SliverChildBuilderDelegate(
              (context, index) => const IgnorePointer(child: SkeletonMediaCard()),
          childCount: count,
        ),
      ),
    );
  }
}
