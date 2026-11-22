import 'package:flutter/widgets.dart';

/// Atlas: when [index] changes (a different tab is shown), the content rises a few pixels and
/// fades up from slightly smaller, instead of cutting straight to the new tab. The child is
/// kept as is (tabs keep their state); only how it's painted moves.
class TabSwitchFade extends StatefulWidget {
  const TabSwitchFade({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<TabSwitchFade> createState() => _TabSwitchFadeState();
}

class _TabSwitchFadeState extends State<TabSwitchFade> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: 1,
  );
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: const Cubic(0.05, 0.7, 0.1, 1.0));

  @override
  void didUpdateWidget(TabSwitchFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index && !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        if (t >= 1) return child!;
        return Opacity(
          opacity: (t * 1.6).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
          ),
        );
      },
    );
  }
}
