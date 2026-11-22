part of 'main.dart';

// Descriptive text stays available to screen readers, never as a visual popup.
class _AccessibleDescription extends StatelessWidget {
  const _AccessibleDescription({
    required this.message,
    required this.child,
    this.excludeFromSemantics = false,
  });

  final String message;
  final Widget child;
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) => excludeFromSemantics || message.isEmpty
      ? child
      : Semantics(tooltip: message, child: child);
}

// Icon-only actions need a name even when visual tooltips are disabled.
class _AccessibleIconButton extends IconButton {
  _AccessibleIconButton({
    super.key,
    required Widget icon,
    required super.onPressed,
    String? tooltip,
    super.focusNode,
    super.constraints,
    super.mouseCursor,
    super.padding,
    super.color,
    super.style,
    super.visualDensity,
  }) : super(
         icon: Semantics(label: tooltip, child: icon),
       );
}
