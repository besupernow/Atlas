import 'package:flutter/material.dart';

import '../utils/platform_detector.dart';
import 'focused_scroll_scaffold.dart';
import 'settings_section.dart' show kTvSettingsMaxWidth;

/// Standard scaffold for settings pages made of ordinary list rows.
class SettingsPage extends StatelessWidget {
  final Widget title;
  final List<Widget>? children;
  final List<Widget>? slivers;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;
  final bool pinned;
  final bool automaticallyImplyLeading;
  final VoidCallback? onBackPressed;

  const SettingsPage({
    super.key,
    required this.title,
    required List<Widget> this.children,
    this.actions,
    this.padding,
    this.pinned = true,
    this.automaticallyImplyLeading = true,
    this.onBackPressed,
  }) : slivers = null;

  const SettingsPage.slivers({
    super.key,
    required this.title,
    required List<Widget> this.slivers,
    this.actions,
    this.pinned = true,
    this.automaticallyImplyLeading = true,
    this.onBackPressed,
  }) : children = null,
       padding = null;

  @override
  Widget build(BuildContext context) {
    var pageSlivers = slivers ?? [_buildListSliver()];
    // TV: keep the page in a readable centred column instead of stretching
    // rows (and their values) across the whole 16:9 screen. Each sliver is
    // padded on its own so fill-remaining / pinned slivers keep working.
    final width = MediaQuery.sizeOf(context).width;
    if (PlatformDetector.isTV() && width > kTvSettingsMaxWidth + 64) {
      final side = (width - kTvSettingsMaxWidth) / 2;
      pageSlivers = [
        for (final s in pageSlivers)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: s,
          ),
      ];
    }
    return FocusedScrollScaffold(
      title: title,
      actions: actions,
      pinned: pinned,
      automaticallyImplyLeading: automaticallyImplyLeading,
      onBackPressed: onBackPressed,
      slivers: pageSlivers,
    );
  }

  Widget _buildListSliver() {
    final list = SliverList(delegate: SliverChildListDelegate(children!));
    final pagePadding = padding;
    if (pagePadding == null) return list;
    return SliverPadding(padding: pagePadding, sliver: list);
  }
}
