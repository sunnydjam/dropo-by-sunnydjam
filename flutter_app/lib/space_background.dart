part of 'main.dart';

// A purely decorative, local canvas. No images, packages, network activity or
// connection status is involved in the background. The planet owns VPN state.
class _AtlasSpaceBackground extends StatefulWidget {
  const _AtlasSpaceBackground({
    this.motionEnabled = true,
    this.active = true,
    this.initialSeconds = 0,
  });

  final bool motionEnabled, active;
  final double initialSeconds;

  @override
  State<_AtlasSpaceBackground> createState() => _AtlasSpaceBackgroundState();
}

class _AtlasSpaceBackgroundState extends State<_AtlasSpaceBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _durationSeconds = 180.0;
  late final AnimationController _controller;
  late final ValueNotifier<double> _seconds;
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

  // Only the canvas repaints. At most 15 background paints per second, even on
  // high-refresh monitors; controls, layout and the planet are not rebuilt.
  void _advance() {
    final frame = (_controller.value * _durationSeconds * 15).floor();
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
    this.twinkles,
  );
  final double x, y, radius, opacity, offset, period;
  final bool twinkles;

  Offset position(Size size, double seconds) {
    final phase = seconds / 180 * math.pi * 2 + offset;
    // A continuous tiny ellipse (peak speed < 2.4 px/min), not a scrolling
    // particle field. Every parameter wraps seamlessly at 180 seconds.
    return Offset(
      5 + x * math.max(0, size.width - 10) + math.sin(phase) * 1.1,
      5 + y * math.max(0, size.height - 10) + math.cos(phase) * 0.65,
    );
  }

  double alpha(double seconds) => twinkles
      ? opacity *
            (0.78 + 0.22 * math.sin(seconds / period * math.pi * 2 + offset))
      : opacity;
}

class _AtlasSpacePainter extends CustomPainter {
  _AtlasSpacePainter({required this.seconds, required this.active})
    : super(repaint: seconds);

  final ValueNotifier<double> seconds;
  final bool active;
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
    canvas.drawRect(Offset.zero & size, Paint()..color = _atlasBackground);
    if (!active || size.isEmpty) return;
    final time = seconds.value;
    final starPaint = Paint();
    for (var index = 0; index < starCount(size); index++) {
      final star = _stars[index];
      starPaint.color = const Color(
        0xFFD5DEEC,
      ).withValues(alpha: star.alpha(time));
      canvas.drawCircle(star.position(size, time), star.radius, starPaint);
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
      oldDelegate.active != active || oldDelegate.seconds != seconds;
}

@visibleForTesting
Widget buildAtlasSpaceBackgroundForTesting({
  bool motionEnabled = true,
  bool active = true,
  double initialSeconds = 0,
}) => _AtlasSpaceBackground(
  motionEnabled: motionEnabled,
  active: active,
  initialSeconds: initialSeconds,
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
  double seconds,
) => _AtlasSpacePainter._stars
    .take(_AtlasSpacePainter.starCount(size))
    .map(
      (star) =>
          (star.position(size, seconds), star.radius, star.alpha(seconds)),
    )
    .toList(growable: false);

@visibleForTesting
double atlasSpaceSunForTesting(double seconds) =>
    _AtlasSpacePainter.sunVisibility(seconds);
