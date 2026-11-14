import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/navigation_tabs.dart';
import '../utils/platform_detector.dart';

/// One tab of [AtlasNativeTabBar]: its label and SF Symbol.
typedef AtlasTabItem = ({String title, String symbol});

/// Atlas: the bottom bar on iPhone and iPad is UIKit's own `UITabBar` (Liquid Glass on iOS 26),
/// tinted with the selected theme. See `ios/Runner/AtlasNativeTabBar.swift`.
class AtlasNativeTabBar extends StatefulWidget {
  const AtlasNativeTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.showLabels,
    required this.onSelected,
    this.onLongPress,
  });

  /// The video side's tabs as bar items.
  static List<AtlasTabItem> itemsFor(List<NavigationTab> tabs) => [
    for (final tab in tabs) (title: tab.getLabel(), symbol: symbolFor(tab.id)),
  ];

  final List<AtlasTabItem> items;
  final int selectedIndex;
  final bool showLabels;
  final ValueChanged<int> onSelected;
  final ValueChanged<int>? onLongPress;

  /// iPhone and iPad (not Apple TV, not the web).
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && !PlatformDetector.isAppleTV();

  /// SF Symbols for each tab.
  static String symbolFor(NavigationTabId id) => switch (id) {
    NavigationTabId.discover => 'house.fill',
    NavigationTabId.explore => 'safari.fill',
    NavigationTabId.libraries => 'square.stack.fill',
    NavigationTabId.liveTv => 'tv.fill',
    NavigationTabId.search => 'magnifyingglass',
    NavigationTabId.downloads => 'arrow.down.circle.fill',
    NavigationTabId.settings => 'gearshape.fill',
  };

  @override
  State<AtlasNativeTabBar> createState() => _AtlasNativeTabBarState();
}

class _AtlasNativeTabBarState extends State<AtlasNativeTabBar> {
  static const _viewType = 'atlas/native_tab_bar';

  MethodChannel? _channel;
  String? _sentParams;
  double _barHeight = 49;

  Map<String, Object?> _params(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return {
      'items': [
        for (final item in widget.items) {'title': item.title, 'symbol': item.symbol},
      ],
      'selected': widget.selectedIndex,
      'showLabels': widget.showLabels,
      'tint': scheme.primary.toARGB32(),
      'unselectedTint': scheme.onSurfaceVariant.toARGB32(),
      'background': scheme.surfaceContainer.toARGB32(),
      'dark': Theme.of(context).brightness == Brightness.dark,
    };
  }

  void _sendIfChanged(Map<String, Object?> params) {
    final channel = _channel;
    if (channel == null) return;
    final encoded = jsonEncode(params);
    if (encoded == _sentParams) return;
    _sentParams = encoded;
    channel.invokeMethod<void>('update', params);
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final count = widget.items.length;
    switch (call.method) {
      case 'select':
        final index = call.arguments as int;
        if (index >= 0 && index < count) widget.onSelected(index);
      case 'longPress':
        final index = call.arguments as int;
        if (index >= 0 && index < count) widget.onLongPress?.call(index);
      case 'height':
        final height = (call.arguments as num).toDouble();
        if (mounted && (height - _barHeight).abs() >= 0.5) setState(() => _barHeight = height);
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final params = _params(context);
    _sendIfChanged(params);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: _barHeight + bottomInset,
      child: UiKitView(
        viewType: _viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (id) {
          _channel = MethodChannel('${_viewType}_$id')..setMethodCallHandler(_onNativeCall);
          // The view was built from these; only later changes need sending.
          _sentParams = jsonEncode(params);
          // Anything that changed while the view was being created.
          if (mounted) _sendIfChanged(_params(context));
        },
      ),
    );
  }
}
