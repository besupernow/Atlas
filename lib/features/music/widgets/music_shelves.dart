import 'package:flutter/material.dart';

import '../../../focus/locked_hub_controller.dart';
import '../../../media/media_hub.dart';
import '../../../media/media_item.dart';
import '../../../widgets/hub_section.dart';

/// One horizontal row of albums, artists or songs.
class MusicShelf {
  const MusicShelf({required this.id, required this.title, required this.icon, required this.items, this.onItemTap});

  final String id;
  final String title;
  final IconData icon;
  final List<MediaItem> items;

  /// Replaces the default (open the album/artist, play the song).
  final ValueChanged<MediaItem>? onItemTap;
}

/// Atlas: a column of [MusicShelf] rows with TV D-pad moving between rows (left/right stays
/// inside a row). Empty shelves are skipped. Up from the first row calls [onNavigateUp]; down
/// from the last calls [onNavigateDown]; left from a row's first card calls
/// [onNavigateToSidebar].
class MusicShelves extends StatefulWidget {
  const MusicShelves({
    super.key,
    required this.shelves,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateToSidebar,
  });

  final List<MusicShelf> shelves;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onNavigateToSidebar;

  @override
  State<MusicShelves> createState() => MusicShelvesState();
}

class MusicShelvesState extends State<MusicShelves> {
  final _focusMemory = HubFocusMemory();
  final Map<String, GlobalKey<HubSectionState>> _keys = {};

  List<MusicShelf> get _visible => [for (final shelf in widget.shelves) if (shelf.items.isNotEmpty) shelf];

  GlobalKey<HubSectionState> _keyFor(String id) => _keys.putIfAbsent(id, () => GlobalKey<HubSectionState>());

  bool get hasContent => _visible.isNotEmpty;

  /// Focus the first row (TV), keeping the card it was last on.
  bool focusFirst() => _focus(0);

  /// Focus the last row.
  bool focusLast() => _focus(_visible.length - 1);

  bool _focus(int index) {
    final visible = _visible;
    if (index < 0 || index >= visible.length) return false;
    final state = _keyFor(visible[index].id).currentState;
    if (state == null) return false;
    state.requestFocusFromMemory();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visible.length; i++)
          HubSection(
            key: _keyFor(visible[i].id),
            hub: MediaHub(
              id: 'atlas-music-${visible[i].id}',
              title: visible[i].title,
              type: 'music',
              items: visible[i].items,
              size: visible[i].items.length,
            ),
            focusMemory: _focusMemory,
            icon: visible[i].icon,
            onItemTap: visible[i].onItemTap,
            onVerticalNavigation: (isUp) {
              final target = isUp ? i - 1 : i + 1;
              if (target >= 0 && target < visible.length) return _focus(target);
              if (!isUp) widget.onNavigateDown?.call();
              return false;
            },
            onNavigateUp: widget.onNavigateUp,
            onNavigateToSidebar: widget.onNavigateToSidebar,
          ),
      ],
    );
  }
}
