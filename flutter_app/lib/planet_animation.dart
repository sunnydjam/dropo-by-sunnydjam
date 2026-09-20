part of 'main.dart';

// The original Dropo backdrop used slow map drift, glowing city nodes and
// pulses on quadratic network links. Keep that motion language on the Atlas
// globe; these decorative links do not represent real connections or probes.
class _AtlasAnimatedPlanet extends StatefulWidget {
  const _AtlasAnimatedPlanet({required this.connected, required this.size});
  final bool connected;
  final double size;

  @override
  State<_AtlasAnimatedPlanet> createState() => _AtlasAnimatedPlanetState();
}

class _AtlasAnimatedPlanetState extends State<_AtlasAnimatedPlanet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 90),
    );
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateMotion();
  }

  void _updateMotion() {
    final animate =
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!animate && _controller.isAnimating) {
      _controller.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      key: const ValueKey('atlas-planet'),
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          child: Image.asset(
            'assets/atlas-earth.png',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
          builder: (context, child) => Opacity(
            opacity: widget.connected ? 1 : 0.62,
            child: Transform.translate(
              offset: Offset(0, math.sin(_controller.value * math.pi * 4) * 2),
              child: CustomPaint(
                key: const ValueKey('atlas-planet-motion'),
                foregroundPainter: _AtlasNetworkPulsePainter(_controller.value),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _AtlasNetworkPulsePainter extends CustomPainter {
  const _AtlasNetworkPulsePainter(this.phase);
  final double phase;
  static const _nodes = <Offset>[
    Offset(0.167, 0.483),
    Offset(0.515, 0.326),
    Offset(0.642, 0.278),
    Offset(0.800, 0.367),
    Offset(0.765, 0.630),
    Offset(0.500, 0.671),
    Offset(0.158, 0.674),
  ];
  static const _edges = <(int, int, double)>[
    (0, 1, -0.07),
    (1, 2, -0.01),
    (2, 3, -0.02),
    (3, 4, 0.01),
    (4, 5, 0.04),
    (5, 0, 0.01),
    (0, 6, -0.01),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    Offset at(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    for (var i = 0; i < _edges.length; i++) {
      final (from, to, bend) = _edges[i];
      final a = at(_nodes[from]), c = at(_nodes[to]);
      final b = Offset(
        (a.dx + c.dx) / 2,
        (a.dy + c.dy) / 2 + bend * size.height,
      );
      for (var pulse = 0; pulse < 2; pulse++) {
        final t = (phase * 12 + i * 0.13 + pulse * 0.5) % 1;
        final u = 1 - t;
        final point = a * (u * u) + b * (2 * u * t) + c * (t * t);
        final fade = math.sin(t * math.pi);
        paint.color = _atlasMint.withValues(alpha: 0.18 * fade);
        canvas.drawCircle(point, 3.6, paint);
        paint.color = const Color(0xFFD6FFEA).withValues(alpha: 0.85 * fade);
        canvas.drawCircle(point, 1.15, paint);
      }
    }
    for (var i = 0; i < _nodes.length; i++) {
      final glow = (math.sin(phase * math.pi * 16 + i * 0.77) + 1) * 0.5;
      paint.color = _atlasMint.withValues(alpha: 0.08 + glow * 0.18);
      canvas.drawCircle(at(_nodes[i]), 3 + glow * 3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AtlasNetworkPulsePainter oldDelegate) =>
      oldDelegate.phase != phase;
}
