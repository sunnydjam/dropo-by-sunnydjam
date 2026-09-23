part of 'main.dart';

// The surface is projected from bundled map data, not a rotating photograph.
// City lights are decorative; they never report real VPN probes or traffic.
class _AtlasAnimatedPlanet extends StatefulWidget {
  const _AtlasAnimatedPlanet({
    required this.connected,
    required this.size,
    this.busy = false,
    this.hasError = false,
    this.motionEnabled = true,
  });
  final bool connected, busy, hasError, motionEnabled;
  final double size;

  @override
  State<_AtlasAnimatedPlanet> createState() => _AtlasAnimatedPlanetState();
}

class _AtlasAnimatedPlanetState extends State<_AtlasAnimatedPlanet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  final _phase = ValueNotifier<double>(0);
  _AtlasGlobeTexture? _texture;
  bool _visible = true;
  int _lastFrame = -1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..addListener(_advance);
    WidgetsBinding.instance.addObserver(this);
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    _texture = _AtlasGlobeTexture.ready;
    if (_texture == null) unawaited(_loadTexture());
  }

  Future<void> _loadTexture() async {
    final texture = await _AtlasGlobeTexture.load();
    if (mounted && texture != null) setState(() => _texture = texture);
  }

  // Quantize decorative repaint to 30 fps, independent of monitor refresh.
  // The home widget and connection button are never rebuilt by this listener.
  void _advance() {
    final frame = (_controller.value * 1800).floor();
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    _phase.value = _controller.value;
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
  void didUpdateWidget(covariant _AtlasAnimatedPlanet oldWidget) {
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
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.hasError
        ? 'error'
        : widget.busy
        ? 'connecting'
        : widget.connected
        ? 'connected'
        : 'disconnected';
    final tone = widget.hasError
        ? const Color(0xFFFF6969)
        : widget.busy
        ? const Color(0xFFFFCF78)
        : widget.connected
        ? _atlasMint
        : const Color(0xFFAAB4B2);
    return ExcludeSemantics(
      child: RepaintBoundary(
        key: const ValueKey('atlas-planet'),
        child: SizedBox.square(
          dimension: widget.size,
          child: KeyedSubtree(
            key: ValueKey('planet-$state'),
            child: CustomPaint(
              key: const ValueKey('atlas-planet-motion'),
              foregroundPainter: _AtlasGlobePainter(
                phase: _phase,
                texture: _texture,
                tone: tone,
                connected: widget.connected && !widget.hasError && !widget.busy,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Shared 1024x512 texture (~2 MiB), retained for the UI process lifetime.
// Parsing/rasterization happens once, not during frames or status refreshes.
class _AtlasGlobeTexture {
  _AtlasGlobeTexture(this.image)
    : shader = ImageShader(
        image,
        TileMode.repeated,
        TileMode.clamp,
        Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
        filterQuality: FilterQuality.low,
      );
  final ui.Image image;
  final ImageShader shader;
  static Future<_AtlasGlobeTexture?>? _pending;
  static _AtlasGlobeTexture? ready;
  static Future<_AtlasGlobeTexture?> load() => _pending ??= _create();

  static Future<_AtlasGlobeTexture?> _create() async {
    try {
      final source = await rootBundle.loadString(
        'assets/maps/ne_110m_land.geojson',
      );
      final document = jsonDecode(source) as Map<String, dynamic>;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const width = 1024.0, height = 512.0;
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, width, height),
        Paint()..color = const Color(0xFF121212),
      );
      final land = Paint()..color = const Color(0xFF999999);
      final coast = Paint()
        ..color = const Color(0xFFBBBBBB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.55;
      for (final feature in document['features'] as List<dynamic>) {
        final geometry = feature['geometry'] as Map<String, dynamic>;
        final coordinates = geometry['coordinates'] as List<dynamic>;
        final polygons = geometry['type'] == 'Polygon'
            ? <List<dynamic>>[coordinates]
            : geometry['type'] == 'MultiPolygon'
            ? coordinates.cast<List<dynamic>>()
            : const <List<dynamic>>[];
        for (final polygon in polygons) {
          final path = Path()..fillType = PathFillType.evenOdd;
          for (final ring in polygon) {
            var first = true;
            for (final point in ring) {
              final x = ((point[0] as num).toDouble() + 180) / 360 * width;
              final y = (90 - (point[1] as num).toDouble()) / 180 * height;
              if (first) {
                path.moveTo(x, y);
                first = false;
              } else {
                path.lineTo(x, y);
              }
            }
            path.close();
          }
          canvas.drawPath(path, land);
          canvas.drawPath(path, coast);
        }
      }
      final grid = Paint()
        ..color = const Color(0xFF3C3C3C)
        ..strokeWidth = 0.7;
      for (var lon = -180; lon <= 180; lon += 30) {
        final x = (lon + 180) / 360 * width;
        canvas.drawLine(Offset(x, 0), Offset(x, height), grid);
      }
      for (var lat = -60; lat <= 60; lat += 30) {
        final y = (90 - lat) / 180 * height;
        canvas.drawLine(Offset(0, y), Offset(width, y), grid);
      }
      final picture = recorder.endRecording();
      try {
        return ready = _AtlasGlobeTexture(await picture.toImage(1024, 512));
      } finally {
        picture.dispose();
      }
    } catch (_) {
      // Decorative asset failure cannot block the VPN; atmosphere remains.
      return null;
    }
  }
}

class _AtlasGlobePainter extends CustomPainter {
  _AtlasGlobePainter({
    required this.phase,
    required this.texture,
    required this.tone,
    required this.connected,
  }) : super(repaint: phase);

  final ValueNotifier<double> phase;
  final _AtlasGlobeTexture? texture;
  final Color tone;
  final bool connected;
  static const _columns = 73, _rows = 37;
  static final _sphere = _createSphere();
  static final _texCoords = _createTexCoords();
  static final _triangles = _createTriangles();
  final _positions = Float32List(_columns * _rows * 2);
  final _depths = Float32List(_columns * _rows);
  final _visibleTriangles = Uint16List((_columns - 1) * (_rows - 1) * 6);
  static final _cities = <(double, double)>[
    (51.5, -0.1),
    (48.9, 2.4),
    (52.5, 13.4),
    (41.0, 29.0),
    (30.0, 31.2),
    (25.2, 55.3),
    (-1.3, 36.8),
    (-26.2, 28.0),
    (40.7, -74.0),
    (34.1, -118.2),
    (-23.5, -46.6),
    (19.4, -99.1),
    (1.4, 103.8),
    (35.7, 139.7),
    (-33.9, 151.2),
    (28.6, 77.2),
  ].map((city) => _unit(city.$1, city.$2)).toList(growable: false);

  static (double, double, double) _unit(double latitude, double longitude) {
    final lat = latitude * math.pi / 180, lon = longitude * math.pi / 180;
    return (
      math.cos(lat) * math.sin(lon),
      math.sin(lat),
      math.cos(lat) * math.cos(lon),
    );
  }

  static Float64List _createSphere() {
    final vertices = Float64List(_columns * _rows * 3);
    for (var row = 0; row < _rows; row++) {
      for (var column = 0; column < _columns; column++) {
        final (x, y, z) = _unit(90 - row * 5, column * 5 - 180);
        final i = (row * _columns + column) * 3;
        vertices[i] = x;
        vertices[i + 1] = y;
        vertices[i + 2] = z;
      }
    }
    return vertices;
  }

  static Float32List _createTexCoords() {
    final coordinates = Float32List(_columns * _rows * 2);
    for (var row = 0; row < _rows; row++) {
      for (var column = 0; column < _columns; column++) {
        final i = (row * _columns + column) * 2;
        coordinates[i] = column / (_columns - 1) * 1024;
        coordinates[i + 1] = row / (_rows - 1) * 512;
      }
    }
    return coordinates;
  }

  static Uint16List _createTriangles() {
    final indices = <int>[];
    for (var row = 0; row < _rows - 1; row++) {
      for (var column = 0; column < _columns - 1; column++) {
        final a = row * _columns + column, b = a + _columns;
        indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
      }
    }
    return Uint16List.fromList(indices);
  }

  // Fixed camera tilt and light, rotating longitude of the entire sphere.
  (double, double, double) project(double x, double y, double z) {
    final longitude = (20 / 180 + phase.value * 2) * math.pi;
    final cos = math.cos(longitude), sin = math.sin(longitude);
    final depth = x * sin + z * cos;
    return (
      x * cos - z * sin,
      y * 0.9612617 - depth * 0.2756374,
      y * 0.2756374 + depth * 0.9612617,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.435;
    final globe = Rect.fromCircle(center: center, radius: radius);
    final glow = Paint()
      ..color = tone.withValues(alpha: connected ? 0.27 : 0.12)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.045);
    canvas.drawCircle(center, radius * 1.015, glow);
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF091510));
    canvas.save();
    canvas.clipPath(Path()..addOval(globe));
    final imageTexture = texture;
    if (imageTexture != null) {
      final longitude = (20 / 180 + phase.value * 2) * math.pi;
      final cos = math.cos(longitude), sin = math.sin(longitude);
      for (var i = 0; i < _depths.length; i++) {
        final x = _sphere[i * 3],
            y = _sphere[i * 3 + 1],
            z = _sphere[i * 3 + 2];
        final depth = x * sin + z * cos;
        _positions[i * 2] = center.dx + (x * cos - z * sin) * radius;
        _positions[i * 2 + 1] =
            center.dy - (y * 0.9612617 - depth * 0.2756374) * radius;
        _depths[i] = y * 0.2756374 + depth * 0.9612617;
      }
      var visible = 0;
      for (var i = 0; i < _triangles.length; i += 3) {
        final a = _triangles[i], b = _triangles[i + 1], c = _triangles[i + 2];
        if (_depths[a] + _depths[b] + _depths[c] <= 0) continue;
        _visibleTriangles[visible++] = a;
        _visibleTriangles[visible++] = b;
        _visibleTriangles[visible++] = c;
      }
      final vertices = ui.Vertices.raw(
        VertexMode.triangles,
        _positions,
        textureCoordinates: _texCoords,
        indices: Uint16List.sublistView(_visibleTriangles, 0, visible),
      );
      canvas.drawVertices(
        vertices,
        BlendMode.srcOver,
        Paint()
          ..shader = imageTexture.shader
          ..colorFilter = ColorFilter.mode(tone, BlendMode.modulate),
      );
      vertices.dispose();
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.94,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
          stops: const [0.1, 1],
        ).createShader(globe),
    );
    _paintCities(canvas, center, radius);
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone.withValues(alpha: 0.9), tone.withValues(alpha: 0.16)],
        ).createShader(globe),
    );
  }

  void _paintCities(Canvas canvas, Offset center, double radius) {
    final projected = <(Offset, double)>[];
    for (final (x, y, z) in _cities) {
      final (px, py, depth) = project(x, y, z);
      projected.add((
        Offset(center.dx + px * radius, center.dy - py * radius),
        depth,
      ));
    }
    final light = Paint();
    for (var i = 0; i < projected.length; i++) {
      final (point, depth) = projected[i];
      if (depth <= 0) continue;
      final fade = math.min(1.0, depth * 5);
      final pulse = connected
          ? (math.sin(phase.value * math.pi * 24 + i) + 1) / 2
          : 0.0;
      light.color = tone.withValues(
        alpha: (connected ? 0.14 + pulse * 0.18 : 0.11) * fade,
      );
      canvas.drawCircle(
        point,
        (connected ? 4 + pulse * 2 : 3) * radius / 120,
        light,
      );
      light.color = Color.lerp(
        tone,
        Colors.white,
        connected ? 0.72 : 0.25,
      )!.withValues(alpha: (connected ? 0.9 : 0.45) * fade);
      canvas.drawCircle(point, math.max(0.65, radius / 105), light);
    }
    if (!connected) return;
    for (final (from, to) in const [
      (0, 2),
      (2, 3),
      (3, 5),
      (4, 6),
      (6, 7),
      (8, 9),
      (12, 13),
    ]) {
      final (a, depthA) = projected[from];
      final (b, depthB) = projected[to];
      if (depthA <= 0.12 || depthB <= 0.12) continue;
      final control = (a + b) / 2 + Offset(0, -radius * 0.07);
      final arc = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(control.dx, control.dy, b.dx, b.dy);
      canvas.drawPath(
        arc,
        Paint()
          ..color = tone.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
      final t = (phase.value * 18 + from * 0.13) % 1, u = 1 - t;
      final point = a * (u * u) + control * (2 * u * t) + b * (t * t);
      canvas.drawCircle(
        point,
        1.15,
        light..color = tone.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AtlasGlobePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.texture != texture ||
      oldDelegate.tone != tone ||
      oldDelegate.connected != connected;
}

@visibleForTesting
Widget buildAtlasPlanetForTesting({
  bool connected = false,
  bool busy = false,
  bool hasError = false,
  bool motionEnabled = true,
  double size = 280,
}) => _AtlasAnimatedPlanet(
  connected: connected,
  busy: busy,
  hasError: hasError,
  motionEnabled: motionEnabled,
  size: size,
);

@visibleForTesting
Future<bool> preloadAtlasPlanetForTesting() async =>
    await _AtlasGlobeTexture.load() != null;

@visibleForTesting
double atlasPlanetPhaseForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).phase.value;

@visibleForTesting
Color atlasPlanetColorForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).tone;

@visibleForTesting
(double, double, double) atlasPlanetSurfacePointForTesting(
  CustomPainter painter,
  double latitude,
  double longitude,
) {
  final (x, y, z) = _AtlasGlobePainter._unit(latitude, longitude);
  return (painter as _AtlasGlobePainter).project(x, y, z);
}
