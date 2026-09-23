part of 'main.dart';

// The original Dropo backdrop used slow map drift, glowing city nodes and
// pulses on quadratic network links. Keep that motion language on the Atlas
// globe; these decorative links do not represent real connections or probes.
class _AtlasAnimatedPlanet extends StatefulWidget {
  const _AtlasAnimatedPlanet({
    required this.connected,
    required this.size,
    this.busy = false,
    this.hasError = false,
  });
  final bool connected, busy, hasError;
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
  void didUpdateWidget(covariant _AtlasAnimatedPlanet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateMotion();
  }

  void _updateMotion() {
    final animate =
        (widget.connected || widget.busy) &&
        !widget.hasError &&
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
  Widget build(BuildContext context) {
    final active = widget.connected && !widget.busy && !widget.hasError;
    final state = widget.hasError
        ? 'error'
        : widget.busy
        ? 'connecting'
        : active
        ? 'connected'
        : 'disconnected';
    final tone = widget.hasError
        ? const Color(0xFFFFB4AB)
        : widget.busy
        ? const Color(0xFFFFD38B)
        : _atlasMuted;
    final asset = Image.asset(
      'assets/atlas-earth.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
    return ExcludeSemantics(
      child: RepaintBoundary(
        key: const ValueKey('atlas-planet'),
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            child: KeyedSubtree(
              key: ValueKey('planet-$state'),
              child: active
                  ? asset
                  : ColorFiltered(
                      colorFilter: ColorFilter.matrix([
                        0.2126 * tone.r,
                        0.7152 * tone.r,
                        0.0722 * tone.r,
                        0,
                        0,
                        0.2126 * tone.g,
                        0.7152 * tone.g,
                        0.0722 * tone.g,
                        0,
                        0,
                        0.2126 * tone.b,
                        0.7152 * tone.b,
                        0.0722 * tone.b,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                      ]),
                      child: asset,
                    ),
            ),
            builder: (context, child) => Opacity(
              opacity: active || widget.busy ? 1 : 0.68,
              child: Transform.translate(
                offset: !active && !widget.busy
                    ? Offset.zero
                    : Offset(0, math.sin(_controller.value * math.pi * 4) * 2),
                child: CustomPaint(
                  key: const ValueKey('atlas-planet-motion'),
                  foregroundPainter: _AtlasNetworkPulsePainter(
                    _controller.value,
                    active: (active || widget.busy) && !widget.hasError,
                    color: widget.busy ? tone : _atlasMint,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AtlasNetworkPulsePainter extends CustomPainter {
  const _AtlasNetworkPulsePainter(
    this.phase, {
    required this.active,
    required this.color,
  });
  final double phase;
  final bool active;
  final Color color;
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
    if (!active) return;
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
        paint.color = color.withValues(alpha: 0.18 * fade);
        canvas.drawCircle(point, 3.6, paint);
        paint.color = Color.lerp(
          color,
          Colors.white,
          0.7,
        )!.withValues(alpha: 0.85 * fade);
        canvas.drawCircle(point, 1.15, paint);
      }
    }
    for (var i = 0; i < _nodes.length; i++) {
      final glow = (math.sin(phase * math.pi * 16 + i * 0.77) + 1) * 0.5;
      paint.color = color.withValues(alpha: 0.08 + glow * 0.18);
      canvas.drawCircle(at(_nodes[i]), 3 + glow * 3, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AtlasNetworkPulsePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.active != active ||
      oldDelegate.color != color;
}
