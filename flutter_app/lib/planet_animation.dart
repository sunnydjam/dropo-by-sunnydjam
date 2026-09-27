part of 'main.dart';

// A bundled equirectangular night atlas is projected onto an axial sphere.
// City lights are decorative; they never report real VPN probes or traffic.
class _AtlasAnimatedPlanet extends StatefulWidget {
  const _AtlasAnimatedPlanet({
    required this.connected,
    required this.size,
    this.busy = false,
    this.hasError = false,
    this.motionEnabled = true,
    this.textureAvailable = true,
  });
  final bool connected, busy, hasError, motionEnabled, textureAvailable;
  final double size;

  @override
  State<_AtlasAnimatedPlanet> createState() => _AtlasAnimatedPlanetState();
}

class _AtlasAnimatedPlanetState extends State<_AtlasAnimatedPlanet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  final _phase = ValueNotifier<double>(0);
  final _lights = ValueNotifier<double>(0);
  _AtlasGlobeTexture? _texture;
  bool _visible = true;
  int _lastFrame = -1;
  double _previousPhase = 0;
  double _lightElapsed = 0;
  bool get _lit => widget.connected && !widget.hasError && !widget.busy;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..addListener(_advance);
    WidgetsBinding.instance.addObserver(this);
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    _lights.value = _lit ? 1 : 0;
    if (widget.textureAvailable) {
      _texture = _AtlasGlobeTexture.ready;
      if (_texture == null) unawaited(_loadTexture());
    }
  }

  Future<void> _loadTexture() async {
    final texture = await _AtlasGlobeTexture.load();
    if (mounted && widget.textureAvailable && texture != null) {
      setState(() => _texture = texture);
    }
  }

  // Quantize decorative repaint to 30 fps, independent of monitor refresh.
  // The home widget and connection button are never rebuilt by this listener.
  void _advance() {
    final frame = (_controller.value * 1800).floor();
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    final delta = (_controller.value - _previousPhase) % 1;
    _previousPhase = _controller.value;
    if (_lit && _lights.value < 1) {
      _lightElapsed += delta * 60;
      final progress = (_lightElapsed / 0.6).clamp(0.0, 1.0);
      _lights.value = progress * progress * (3 - 2 * progress);
    }
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
    final wasLit =
        oldWidget.connected && !oldWidget.hasError && !oldWidget.busy;
    if (_lit != wasLit) {
      _lightElapsed = 0;
      _lights.value = 0;
    }
    if (oldWidget.textureAvailable != widget.textureAvailable) {
      _texture = widget.textureAvailable ? _AtlasGlobeTexture.ready : null;
      if (widget.textureAvailable && _texture == null) {
        unawaited(_loadTexture());
      }
    }
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
    // Hidden/reduced-motion views settle immediately, never resume a stale
    // transition or require another ticker just to light the cities.
    if (!animate) _lights.value = _lit ? 1 : 0;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _phase.dispose();
    _lights.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _AtlasPlanetPalette.select(
      connected: widget.connected,
      busy: widget.busy,
      hasError: widget.hasError,
    );
    return ExcludeSemantics(
      child: RepaintBoundary(
        key: const ValueKey('atlas-planet'),
        child: SizedBox.square(
          dimension: widget.size,
          child: KeyedSubtree(
            key: ValueKey('planet-${palette.name}'),
            child: CustomPaint(
              key: const ValueKey('atlas-planet-motion'),
              foregroundPainter: _AtlasGlobePainter(
                phase: _phase,
                lights: _lights,
                texture: _texture,
                palette: palette,
                connected: widget.connected && !widget.hasError && !widget.busy,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Surface colors are baked into each raster, not applied as a drawVertices
// color filter. Both ocean and land must keep their state color on every GPU.
enum _AtlasPlanetPalette {
  disconnected(0xFFAAB4B2, 0xFF1A1A1A),
  connected(0xFF5CF0B0, 0xFF03251A),
  error(0xFFFF6969, 0xFF321012),
  connecting(0xFFFFCF78, 0xFF322511);

  const _AtlasPlanetPalette(this.toneARGB, this.oceanARGB);
  final int toneARGB, oceanARGB;
  Color get tone => Color(toneARGB);
  Color get ocean => Color(oceanARGB);

  static _AtlasPlanetPalette select({
    required bool connected,
    required bool busy,
    required bool hasError,
  }) => hasError
      ? error
      : busy
      ? connecting
      : connected
      ? _AtlasPlanetPalette.connected
      : disconnected;
}

class _AtlasGlobeSurface {
  _AtlasGlobeSurface(this.image)
    : shader = ImageShader(
        image,
        TileMode.repeated,
        TileMode.clamp,
        Float64List.fromList([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
        filterQuality: FilterQuality.low,
      );
  final ui.Image image;
  final ImageShader shader;
}

// Four shared 1024x512 state textures (~8 MiB total), retained for the UI
// process lifetime. The atlas is decoded once; no rasterization on status changes
// or animation frames, and switching state does not reset the longitude.
class _AtlasGlobeTexture {
  _AtlasGlobeTexture(this.surfaces);
  final Map<_AtlasPlanetPalette, _AtlasGlobeSurface> surfaces;
  static Future<_AtlasGlobeTexture?>? _pending;
  static _AtlasGlobeTexture? ready;
  static Future<_AtlasGlobeTexture?> load() => _pending ??= _create();

  static double _luminance(int r, int g, int b) =>
      r * 0.2126 + g * 0.7152 + b * 0.0722;

  // Warm pixels belong to the decorative city emission, not the green terrain.
  // A continuous mask retains anti-aliased edges without yellow dots in the
  // disconnected/error textures. Neutral clouds cannot activate this mask.
  static double _emission(int r, int g, int b) =>
      math.min(
        ((r - g * 0.88 - 3) / 20).clamp(0.0, 1.0),
        ((g - b * 1.10 - 2) / 24).clamp(0.0, 1.0),
      ) *
      ((math.max(r, g) - 35) / 35).clamp(0.0, 1.0);

  static double _emissionWithNeighbor(
    int r,
    int g,
    int b,
    double warmNeighbor,
  ) {
    final warm = _emission(r, g, b);
    final luminance = _luminance(r, g, b);
    // Bright city cores can be almost white. Only classify those as emission
    // when adjacent to a strong warm light; isolated neutral clouds stay intact.
    if (luminance <= 95 || warmNeighbor <= 0.4) return warm;
    return math.max(
      warm,
      warmNeighbor * ((luminance - 70) / 60).clamp(0.0, 1.0),
    );
  }

  static double _emissionAt(Uint8List pixels, int x, int y) {
    final i = (y * 1024 + x) * 4;
    final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
    var warmNeighbor = 0.0;
    if (_luminance(r, g, b) > 95 && _emission(r, g, b) < 1) {
      for (final distance in const [1, 2]) {
        for (final dy in [-distance, 0, distance]) {
          for (final dx in [-distance, 0, distance]) {
            if (dx == 0 && dy == 0) continue;
            final n = (((y + dy).clamp(0, 511) * 1024) + (x + dx) % 1024) * 4;
            warmNeighbor = math.max(
              warmNeighbor,
              _emission(pixels[n], pixels[n + 1], pixels[n + 2]),
            );
          }
        }
      }
    }
    return _emissionWithNeighbor(r, g, b, warmNeighbor);
  }

  static (int, int, int) _mapPixel(
    int r,
    int g,
    int b,
    _AtlasPlanetPalette palette, {
    double? unlitLuminance,
    double? emissionAmount,
  }) {
    final light = emissionAmount ?? _emission(r, g, b);
    final luminance = _luminance(r, g, b);
    final terrain =
        luminance * (1 - light) +
        (unlitLuminance ?? math.min(luminance, 28.0)) * light;
    int channel(double value) => value.round().clamp(0, 255);
    switch (palette) {
      case _AtlasPlanetPalette.connected:
        // Preserve texture detail and the original warm light color. The broad
        // surface remains emerald, including the ocean and soft cloud layer.
        final green = math.max(g.toDouble(), 14 + luminance * 0.80);
        final red = math.min(r.toDouble(), green * 0.57);
        final blue = math.min(b.toDouble(), green * 0.72);
        return (
          channel(red * (1 - light) + r * light),
          channel(green * (1 - light) + g * light),
          channel(blue * (1 - light) + b * light),
        );
      case _AtlasPlanetPalette.disconnected:
        final gray = channel(9 + terrain * 1.10);
        return (gray, gray, gray);
      case _AtlasPlanetPalette.error:
        return (
          channel(18 + terrain * 1.12),
          channel(4 + terrain * 0.32),
          channel(6 + terrain * 0.33),
        );
      case _AtlasPlanetPalette.connecting:
        return (
          channel(23 + terrain * 1.12),
          channel(13 + terrain * 0.75),
          channel(4 + terrain * 0.27),
        );
    }
  }

  static double _unlitNeighborhood(
    Uint8List pixels,
    Float32List emission,
    int x,
    int y,
  ) {
    var sum = 0.0, weight = 0.0;
    // Bounded local estimate replaces emission, not the surrounding landscape.
    // Longitude wraps; latitude clamps, exactly like the projected atlas.
    for (final dy in const [-4, 0, 4]) {
      for (final dx in const [-4, 0, 4]) {
        final i = (((y + dy).clamp(0, 511) * 1024) + (x + dx) % 1024) * 4;
        final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
        final unlit = 1 - emission[i ~/ 4];
        sum += _luminance(r, g, b) * unlit;
        weight += unlit;
      }
    }
    return weight > 0.2 ? sum / weight : 28;
  }

  static void _closeSeam(Uint8List pixels) {
    // Blend only an eight-pixel strip at the atlas edges, not the source asset.
    // Exact matching edge colors prevent a vertical seam during axial rotation.
    for (var y = 0; y < 512; y++) {
      final left = y * 1024 * 4, right = left + 1023 * 4;
      for (var channel = 0; channel < 3; channel++) {
        final seam = (pixels[left + channel] + pixels[right + channel]) / 2;
        for (var x = 0; x < 8; x++) {
          final t = 1 - x / 8;
          for (final i in [left + x * 4 + channel, right - x * 4 + channel]) {
            pixels[i] = (pixels[i] * (1 - t) + seam * t).round();
          }
        }
      }
    }
  }

  static Future<ui.Image> _imageFromPixels(Uint8List pixels) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      1024,
      512,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Future<_AtlasGlobeTexture?> _create() async {
    final surfaces = <_AtlasPlanetPalette, _AtlasGlobeSurface>{};
    try {
      final source = await rootBundle.load('assets/maps/earth_night_atlas.png');
      final codec = await ui.instantiateImageCodec(
        source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
        targetWidth: 1024,
        targetHeight: 512,
      );
      late final Uint8List pixels;
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (data == null) return null;
          pixels = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
      final emission = Float32List(1024 * 512);
      for (var y = 0; y < 512; y++) {
        for (var x = 0; x < 1024; x++) {
          emission[y * 1024 + x] = _emissionAt(pixels, x, y);
        }
        if (y % 32 == 31) await Future<void>.delayed(Duration.zero);
      }
      final terrain = Float32List(1024 * 512);
      for (var y = 0; y < 512; y++) {
        for (var x = 0; x < 1024; x++) {
          final i = (y * 1024 + x) * 4;
          terrain[y * 1024 + x] = emission[i ~/ 4] > 0
              ? _unlitNeighborhood(pixels, emission, x, y)
              : _luminance(pixels[i], pixels[i + 1], pixels[i + 2]);
        }
        if (y % 32 == 31) await Future<void>.delayed(Duration.zero);
      }
      for (final palette in _AtlasPlanetPalette.values) {
        final mapped = Uint8List(pixels.length);
        for (var i = 0; i < pixels.length; i += 4) {
          final (r, g, b) = _mapPixel(
            pixels[i],
            pixels[i + 1],
            pixels[i + 2],
            palette,
            unlitLuminance: terrain[i ~/ 4],
            emissionAmount: emission[i ~/ 4],
          );
          mapped[i] = r;
          mapped[i + 1] = g;
          mapped[i + 2] = b;
          mapped[i + 3] = 255;
          if (i % 131072 == 131068) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        _closeSeam(mapped);
        surfaces[palette] = _AtlasGlobeSurface(await _imageFromPixels(mapped));
      }
      return ready = _AtlasGlobeTexture(Map.unmodifiable(surfaces));
    } catch (_) {
      for (final surface in surfaces.values) {
        surface.shader.dispose();
        surface.image.dispose();
      }
      // Decorative asset failure cannot block the VPN; atmosphere remains.
      return null;
    }
  }
}

class _AtlasGlobePainter extends CustomPainter {
  _AtlasGlobePainter({
    required this.phase,
    required this.lights,
    required this.texture,
    required this.palette,
    required this.connected,
  }) : super(repaint: Listenable.merge([phase, lights]));

  final ValueNotifier<double> phase;
  final ValueNotifier<double> lights;
  final _AtlasGlobeTexture? texture;
  final _AtlasPlanetPalette palette;
  Color get tone => palette.tone;
  final bool connected;
  static const _columns = 73, _rows = 37;
  static final _sphere = _createSphere();
  static final _texCoords = _createTexCoords();
  static final _triangles = _createTriangles();
  final _positions = Float32List(_columns * _rows * 2);
  final _depths = Float32List(_columns * _rows);
  final _visibleTriangles = Uint16List((_columns - 1) * (_rows - 1) * 6);

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
      ..color = tone.withValues(alpha: connected ? 0.17 : 0.09)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.025);
    canvas.drawCircle(center, radius * 1.005, glow);
    canvas.drawCircle(center, radius, Paint()..color = palette.ocean);
    canvas.save();
    canvas.clipPath(Path()..addOval(globe));
    final imageTexture = texture?.surfaces[palette];
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
      final surfacePaint = Paint()..shader = imageTexture.shader;
      if (connected && lights.value < 1) {
        // Briefly attenuate warm emission in the already-green connected
        // surface, never blend from a gray state texture. If a renderer ignores
        // this optional effect the cities simply appear immediately; the baked
        // whole-surface green state is still correct on that renderer.
        final dim = 1 - lights.value;
        surfacePaint.colorFilter = ColorFilter.matrix([
          1 - 0.92 * dim,
          0,
          0,
          0,
          0,
          -0.60 * dim,
          1,
          0,
          0,
          4 * dim,
          0,
          0,
          1 - 0.75 * dim,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
      }
      canvas.drawVertices(vertices, BlendMode.srcOver, surfacePaint);
      vertices.dispose();
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.30)],
          stops: const [0.30, 1],
        ).createShader(globe),
    );
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.85
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(
              tone,
              Colors.white,
              connected ? 0.30 : 0,
            )!.withValues(alpha: 0.95),
            tone.withValues(alpha: 0.55),
            tone.withValues(alpha: 0.10),
          ],
          stops: const [0, 0.4, 1],
        ).createShader(globe),
    );
  }

  @override
  bool shouldRepaint(covariant _AtlasGlobePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.lights != lights ||
      oldDelegate.texture != texture ||
      oldDelegate.palette != palette ||
      oldDelegate.connected != connected;
}

@visibleForTesting
Widget buildAtlasPlanetForTesting({
  bool connected = false,
  bool busy = false,
  bool hasError = false,
  bool motionEnabled = true,
  bool textureAvailable = true,
  double size = 280,
}) => _AtlasAnimatedPlanet(
  connected: connected,
  busy: busy,
  hasError: hasError,
  motionEnabled: motionEnabled,
  textureAvailable: textureAvailable,
  size: size,
);

@visibleForTesting
Future<bool> preloadAtlasPlanetForTesting() async =>
    await _AtlasGlobeTexture.load() != null;

// Borrowed cached image: test callers must not dispose it.
@visibleForTesting
Future<ui.Image?> atlasPlanetTextureForTesting({
  bool connected = false,
  bool busy = false,
  bool hasError = false,
}) async => (await _AtlasGlobeTexture.load())
    ?.surfaces[_AtlasPlanetPalette.select(
      connected: connected,
      busy: busy,
      hasError: hasError,
    )]
    ?.image;

@visibleForTesting
double atlasPlanetPhaseForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).phase.value;

@visibleForTesting
double atlasPlanetLightsForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).lights.value;

@visibleForTesting
Color atlasPlanetMappedPixelForTesting(
  Color source, {
  bool connected = false,
  bool busy = false,
  bool hasError = false,
  List<Color> neighbors = const [],
}) {
  final argb = source.toARGB32();
  final (r, g, b) = _AtlasGlobeTexture._mapPixel(
    (argb >> 16) & 255,
    (argb >> 8) & 255,
    argb & 255,
    _AtlasPlanetPalette.select(
      connected: connected,
      busy: busy,
      hasError: hasError,
    ),
    emissionAmount: atlasPlanetEmissionForTesting(source, neighbors: neighbors),
  );
  return Color.fromARGB(255, r, g, b);
}

@visibleForTesting
double atlasPlanetEmissionForTesting(
  Color source, {
  List<Color> neighbors = const [],
}) {
  var warmNeighbor = 0.0;
  for (final neighbor in neighbors.take(16)) {
    final argb = neighbor.toARGB32();
    warmNeighbor = math.max(
      warmNeighbor,
      _AtlasGlobeTexture._emission(
        (argb >> 16) & 255,
        (argb >> 8) & 255,
        argb & 255,
      ),
    );
  }
  final argb = source.toARGB32();
  return _AtlasGlobeTexture._emissionWithNeighbor(
    (argb >> 16) & 255,
    (argb >> 8) & 255,
    argb & 255,
    warmNeighbor,
  );
}

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
