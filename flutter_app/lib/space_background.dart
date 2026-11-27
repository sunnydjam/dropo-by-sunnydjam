part of 'main.dart';

// A purely decorative, local canvas. No images, packages, network activity or
// connection status is involved in the background. The planet owns VPN state.
class _AtlasSpaceBackground extends StatefulWidget {
  const _AtlasSpaceBackground({
    this.motionEnabled = true,
    this.active = true,
    this.initialSeconds = 0,
    this.desktop = false,
  });

  final bool motionEnabled, active, desktop;
  final double initialSeconds;

  @override
  State<_AtlasSpaceBackground> createState() => _AtlasSpaceBackgroundState();
}

class _AtlasSpaceBackgroundState extends State<_AtlasSpaceBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _durationSeconds = 180.0;
  late final AnimationController _controller;
  late final ValueNotifier<double> _seconds;
  late final _meteors = _AtlasMeteor.shower(math.Random());
  bool _visible = true;
  int _lastFrame = -1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSeconds % _durationSeconds;
    _seconds = ValueNotifier(initial);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 180),
      value: initial / _durationSeconds,
    )..addListener(_advance);
    WidgetsBinding.instance.addObserver(this);
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
  }

  // Only the canvas repaints. Cap the faster desktop drift at 24 fps while
  // keeping the mobile paint budget at 15 fps.
  void _advance() {
    final framesPerSecond = widget.desktop ? 24 : 15;
    final frame = (_controller.value * _durationSeconds * framesPerSecond)
        .floor();
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    _seconds.value = _controller.value * _durationSeconds;
  }

  bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      (!_isMobileShell && state == AppLifecycleState.inactive);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant _AtlasSpaceBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = _isVisible(state);
    _updateMotion();
  }

  void _updateMotion() {
    final animate =
        widget.active &&
        widget.motionEnabled &&
        _visible &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
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
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        key: const ValueKey('atlas-space-background'),
        child: ClipRect(
          child: CustomPaint(
            key: const ValueKey('atlas-space-motion'),
            painter: _AtlasSpacePainter(
              seconds: _seconds,
              active: widget.active,
              desktop: widget.desktop,
              mobileSky: _isAndroidPlatform,
              meteors:
                  widget.motionEnabled &&
                      !MediaQuery.disableAnimationsOf(context)
                  ? _meteors
                  : const [],
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

class _AtlasStar {
  const _AtlasStar(
    this.x,
    this.y,
    this.radius,
    this.opacity,
    this.offset,
    this.period,
    this.driftPeriod,
    this.twinkles,
  );
  final double x, y, radius, opacity, offset, period, driftPeriod;
  final bool twinkles;

  Offset position(
    Size size,
    double seconds, {
    required bool desktop,
    bool mobileSky = false,
  }) {
    // Both animations close at 180 seconds. Larger, nearer stars move along a
    // wider, faster path so their drift reads against the faint background.
    final depth = (radius - 0.45) / 0.7;
    final phase =
        seconds * math.pi * 2 / (desktop || mobileSky ? driftPeriod : 180) +
        offset;
    return Offset(
      5 +
          x * math.max(0, size.width - 10) +
          math.sin(phase) *
              (desktop
                  ? 18 + depth * 36
                  : mobileSky
                  ? 6 + 16 * depth
                  : 1.1),
      5 +
          y * math.max(0, size.height - 10) +
          math.cos(phase) *
              (desktop
                  ? 12 + depth * 18
                  : mobileSky
                  ? 4 + 8 * depth
                  : .65),
    );
  }

  double alpha(double seconds) => twinkles
      ? opacity *
            (0.78 + 0.22 * math.sin(seconds / period * math.pi * 2 + offset))
      : opacity;
}

class _AtlasMeteor {
  const _AtlasMeteor(
    this.start,
    this.duration,
    this.x,
    this.y,
    this.travel,
    this.slope,
  );
  final double start, duration, x, y, travel, slope;

  // A bounded schedule per mounted sky. Leave both ends of the 180s clock
  // clear so wrapping, backgrounding and resuming never produces a burst.
  static List<_AtlasMeteor> shower(math.Random random) {
    final meteors = <_AtlasMeteor>[];
    for (
      var start = .6 + random.nextDouble();
      start < 176;
      start += 1.4 + random.nextDouble() * 2.1
    ) {
      final count = 3 * (1 + random.nextInt(3));
      for (var i = 0; i < count; i++) {
        meteors.add(
          _AtlasMeteor(
            start + i * .12,
            .85 + random.nextDouble() * .65,
            .2 + random.nextDouble() * .85,
            random.nextDouble() * .88,
            85 + random.nextDouble() * 100,
            .28 + random.nextDouble() * .43,
          ),
        );
      }
    }
    return meteors..sort((a, b) => a.start.compareTo(b.start));
  }

  void paint(Canvas canvas, Size size, double time) {
    final p = (time - start) / duration;
    if (p <= 0 || p >= 1) return;
    final head = Offset(
      size.width * x - travel * p,
      size.height * y + travel * slope * p,
    );
    final tail = head + Offset(travel * .30, -travel * slope * .30);
    final opacity = math.sin(p * math.pi);
    final light = const Color(0xFFDBFFF2).withValues(alpha: opacity * .82);
    final normal = Offset(slope, 1) * .88;
    final trail = ui.Vertices(
      ui.VertexMode.triangles,
      [head - normal, head + normal, tail],
      colors: [light, light, const Color(0x0064CAA9)],
    );
    canvas.drawVertices(trail, BlendMode.src, Paint());
    trail.dispose();
    canvas.drawCircle(head, 1.35, Paint()..color = light);
  }
}

class _AtlasSpacePainter extends CustomPainter {
  _AtlasSpacePainter({
    required this.seconds,
    required this.active,
    required this.desktop,
    required this.mobileSky,
    required this.meteors,
  }) : super(repaint: seconds);

  final ValueNotifier<double> seconds;
  final bool active, desktop, mobileSky;
  final List<_AtlasMeteor> meteors;
  static final _stars = _createStars();
  static const _periods = [12.0, 15.0, 18.0, 20.0, 22.5];

  static List<_AtlasStar> _createStars() {
    final random = math.Random(20260927);
    return List.generate(
      90,
      (index) => _AtlasStar(
        random.nextDouble(),
        random.nextDouble(),
        0.45 + random.nextDouble() * 0.7,
        0.12 + random.nextDouble() * 0.28,
        random.nextDouble() * math.pi * 2,
        _periods[index % _periods.length],
        180 / (3 + index % 4),
        index % 3 == 0,
      ),
      growable: false,
    );
  }

  static int starCount(Size size) =>
      (size.width * size.height / 7600).round().clamp(32, _stars.length);

  // Sixty seconds are completely dark. The remaining two minutes softly rise
  // and fall with zero slope at both ends: no flash, flare or sudden reset.
  static double sunVisibility(double seconds) {
    final position = seconds % 180;
    if (position <= 60) return 0;
    final wave = math.sin((position - 60) / 120 * math.pi);
    return wave * wave;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (mobileSky && !size.isEmpty) {
      // Vertex colours avoid the large uniform array used by the GLES gradient
      // shader on older drivers. The shared diagonal has one continuous colour.
      final sky = ui.Vertices(
        ui.VertexMode.triangleStrip,
        [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight],
        colors: const [
          Color(0xFF071713),
          Color(0xFF030B09),
          Color(0xFF030B09),
          Color(0xFF08130F),
        ],
      );
      canvas.drawVertices(sky, BlendMode.src, Paint());
      sky.dispose();
    } else {
      canvas.drawRect(rect, Paint()..color = _atlasBackground);
    }
    if (!active || size.isEmpty) return;
    final time = seconds.value;
    final starPaint = Paint();
    for (var index = 0; index < starCount(size); index++) {
      final star = _stars[index];
      starPaint.color = const Color(
        0xFFD5DEEC,
      ).withValues(alpha: star.alpha(time) * (desktop ? 1.3 : 1));
      canvas.drawCircle(
        star.position(size, time, desktop: desktop, mobileSky: mobileSky),
        star.radius * (desktop ? 1.18 : 1),
        starPaint,
      );
    }

    for (final meteor in meteors) {
      if (meteor.start > time) break;
      if (time < meteor.start + meteor.duration) {
        meteor.paint(canvas, size, time);
      }
    }
    final visibility = sunVisibility(time);
    if (visibility <= 0) return;
    final radius = math.min(72.0, size.width * 0.14);
    final center = Offset(
      size.width * 0.73,
      size.height + radius - 22 * visibility,
    );
    final haloRadius = radius * 1.9;
    canvas.drawCircle(
      center,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFC99151).withValues(alpha: 0.09 * visibility),
            const Color(0xFF97603C).withValues(alpha: 0.035 * visibility),
            const Color(0x0097603C),
          ],
          stops: const [0.2, 0.62, 1],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.95),
          radius: 1.3,
          colors: [
            const Color(0xFF8A5733).withValues(alpha: 0.32 * visibility),
            const Color(0xFF241810).withValues(alpha: 0.28 * visibility),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFFE4B579).withValues(alpha: 0.19 * visibility)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(covariant _AtlasSpacePainter oldDelegate) =>
      oldDelegate.active != active ||
      oldDelegate.desktop != desktop ||
      oldDelegate.mobileSky != mobileSky ||
      oldDelegate.meteors != meteors ||
      oldDelegate.seconds != seconds;
}

@visibleForTesting
Widget buildAtlasSpaceBackgroundForTesting({
  bool motionEnabled = true,
  bool active = true,
  double initialSeconds = 0,
  bool desktop = false,
}) => _AtlasSpaceBackground(
  motionEnabled: motionEnabled,
  active: active,
  initialSeconds: initialSeconds,
  desktop: desktop,
);

@visibleForTesting
double atlasSpaceSecondsForTesting(CustomPainter painter) =>
    (painter as _AtlasSpacePainter).seconds.value;

@visibleForTesting
double atlasSpacePhaseForTesting(CustomPainter painter) =>
    atlasSpaceSecondsForTesting(painter) / 180;

@visibleForTesting
List<(Offset, double, double)> atlasSpaceStarsForTesting(
  Size size,
  double seconds, {
  bool desktop = false,
}) => _AtlasSpacePainter._stars
    .take(_AtlasSpacePainter.starCount(size))
    .map(
      (star) => (
        star.position(size, seconds, desktop: desktop),
        star.radius,
        star.alpha(seconds),
      ),
    )
    .toList(growable: false);

@visibleForTesting
double atlasSpaceSunForTesting(double seconds) =>
    _AtlasSpacePainter.sunVisibility(seconds);
