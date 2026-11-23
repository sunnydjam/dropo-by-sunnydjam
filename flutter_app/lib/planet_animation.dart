part of 'main.dart';

// Bundled decorative Earth and DrOppo artwork. Neither the city lights nor
// the mascot are telemetry; connection state remains owned by the home panel.
class _AtlasAnimatedPlanet extends StatefulWidget {
  const _AtlasAnimatedPlanet({
    required this.connected,
    required this.size,
    this.busy = false,
    this.connecting = false,
    this.connectionAttempt = 0,
    this.hasError = false,
    this.motionEnabled = true,
    this.textureAvailable = true,
    this.mascotAvailable = true,
    this.onLanded,
  });
  final bool connected, busy, connecting, hasError, motionEnabled;
  final int connectionAttempt;
  final bool textureAvailable, mascotAvailable;
  final double size;
  final VoidCallback? onLanded;

  @override
  State<_AtlasAnimatedPlanet> createState() => _AtlasAnimatedPlanetState();
}

enum _AtlasFlightStage {
  resting(0),
  launch(0.65),
  orbit(2.7),
  landing(0.58),
  landed(0);

  const _AtlasFlightStage(this.seconds);
  final double seconds;
}

typedef _AtlasFlightFrame = ({_AtlasFlightStage stage, double progress});

class _AtlasAnimatedPlanetState extends State<_AtlasAnimatedPlanet>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  final _phase = ValueNotifier<double>(0);
  final _lights = ValueNotifier<double>(0);
  final _flight = ValueNotifier<_AtlasFlightFrame>((
    stage: _AtlasFlightStage.resting,
    progress: 0,
  ));
  _AtlasSceneAssets? _assets;
  bool _visible = true;
  int _lastFrame = -1;
  double _previousPhase = 0;
  double _lightElapsed = 0;
  double _flightElapsed = 0;
  bool get _lit => widget.connected && !widget.hasError && !widget.busy;
  bool get _canLand =>
      widget.connected && !widget.hasError && !widget.connecting;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 70),
    )..addListener(_advance);
    WidgetsBinding.instance.addObserver(this);
    _visible = _isVisible(WidgetsBinding.instance.lifecycleState);
    _lights.value = _lit ? 1 : 0;
    _assets = _AtlasSceneAssets.ready;
    if (_assets == null) unawaited(_loadAssets());
  }

  Future<void> _loadAssets() async {
    final assets = await _AtlasSceneAssets.load();
    if (mounted) setState(() => _assets = assets);
  }

  // Decorative painting is capped at 30 fps. It never rebuilds home controls.
  void _advance() {
    final frame = (_controller.value * 2100).floor();
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    final delta = (_controller.value - _previousPhase) % 1;
    _previousPhase = _controller.value;
    _advanceFlight(delta * 70);
    if (_lit && _lights.value < 1) {
      _lightElapsed += delta * 70;
      final progress = (_lightElapsed / 0.6).clamp(0.0, 1.0);
      _lights.value = progress * progress * (3 - 2 * progress);
    }
    _phase.value = _controller.value;
  }

  void _enterFlightStage(_AtlasFlightStage stage) {
    if (_flight.value.stage == stage) return;
    _flightElapsed = 0;
    _flight.value = (stage: stage, progress: 0);
    if (stage == _AtlasFlightStage.landed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _canLand && _flight.value.stage == stage) {
          widget.onLanded?.call();
        }
      });
    }
  }

  void _advanceFlight(double seconds) {
    final stage = _flight.value.stage;
    if (stage.seconds == 0) return;
    _flightElapsed += seconds;
    if (_flightElapsed >= stage.seconds) {
      switch (stage) {
        case _AtlasFlightStage.launch:
          _enterFlightStage(_AtlasFlightStage.orbit);
          return;
        case _AtlasFlightStage.orbit:
          if (_canLand) {
            _enterFlightStage(_AtlasFlightStage.landing);
            return;
          }
          _flightElapsed %= stage.seconds;
        case _AtlasFlightStage.landing:
          _enterFlightStage(_AtlasFlightStage.landed);
          return;
        case _AtlasFlightStage.resting:
        case _AtlasFlightStage.landed:
          return;
      }
    }
    _flight.value = (stage: stage, progress: _flightElapsed / stage.seconds);
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
    _updateMotion(
      fastConnect: widget.connectionAttempt != oldWidget.connectionAttempt,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = _isVisible(state);
    _updateMotion();
  }

  void _updateMotion({bool fastConnect = false}) {
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
    if (!animate) _lights.value = _lit ? 1 : 0;
    final stage = _flight.value.stage;
    if (widget.hasError || (!_canLand && !widget.connecting)) {
      _enterFlightStage(_AtlasFlightStage.resting);
    } else if (!animate) {
      _enterFlightStage(
        _canLand ? _AtlasFlightStage.landed : _AtlasFlightStage.resting,
      );
    } else if ((widget.connecting || fastConnect) &&
        (stage == _AtlasFlightStage.resting ||
            stage == _AtlasFlightStage.landed)) {
      _enterFlightStage(_AtlasFlightStage.launch);
    } else if (_canLand && stage == _AtlasFlightStage.resting) {
      _enterFlightStage(_AtlasFlightStage.landed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _phase.dispose();
    _lights.dispose();
    _flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _AtlasPlanetPalette.select(
      connected: widget.connected,
      busy: widget.busy,
      hasError: widget.hasError,
    );
    return IgnorePointer(
      child: ExcludeSemantics(
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
                  flight: _flight,
                  texture: widget.textureAvailable ? _assets?.textures : null,
                  mascots: widget.mascotAvailable ? _assets?.mascots : null,
                  palette: palette,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// State colors are baked once into each cached raster, including its land,
// ocean and clouds. This avoids renderer-dependent drawVertices tinting.
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

enum _DrOppoPose {
  flying('assets/mascot/droppo_flying.png'),
  waiting('assets/mascot/droppo_waiting.png'),
  puzzled('assets/mascot/droppo_puzzled.png');

  const _DrOppoPose(this.asset);
  final String asset;
  static _DrOppoPose forPalette(_AtlasPlanetPalette palette) =>
      switch (palette) {
        _AtlasPlanetPalette.connected => flying,
        _AtlasPlanetPalette.error => puzzled,
        _ => waiting,
      };
}

class _DrOppoSprite {
  const _DrOppoSprite(this.image, this.source);
  final ui.Image image;
  final Rect source;

  static Future<_DrOppoSprite?> load(_DrOppoPose pose) async {
    ui.Image? image;
    try {
      final bytes = await rootBundle.load(pose.asset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        targetWidth: 512,
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        image.dispose();
        return null;
      }
      final pixels = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      var left = image.width, top = image.height, right = -1, bottom = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (pixels[(y * image.width + x) * 4 + 3] < 12) continue;
          left = math.min(left, x);
          right = math.max(right, x);
          top = math.min(top, y);
          bottom = math.max(bottom, y);
        }
      }
      if (right < left || bottom < top) {
        image.dispose();
        return null;
      }
      // Padding preserves soft antialiased edges while avoiding generated
      // transparent margins affecting the apparent size across poses.
      final source = Rect.fromLTRB(
        math.max(0, left - 2).toDouble(),
        math.max(0, top - 2).toDouble(),
        math.min(image.width, right + 3).toDouble(),
        math.min(image.height, bottom + 3).toDouble(),
      );
      return _DrOppoSprite(image, source);
    } catch (_) {
      image?.dispose();
      return null;
    }
  }
}

class _AtlasSceneAssets {
  const _AtlasSceneAssets(this.textures, this.mascots);
  final Map<_AtlasPlanetPalette, ui.Image> textures;
  final Map<_DrOppoPose, _DrOppoSprite> mascots;
  static Future<_AtlasSceneAssets>? _pending;
  static _AtlasSceneAssets? ready;
  static Future<_AtlasSceneAssets> load() => _pending ??= _create();

  static Future<_AtlasSceneAssets> _create() async {
    // Every asset is optional decoration. A missing sprite cannot hide the
    // Earth or block connection, and there is no runtime network request.
    final spriteFuture = Future.wait(
      _DrOppoPose.values.map(_DrOppoSprite.load),
    );
    final textures = await _AtlasGlobeTexture.create();
    final sprites = await spriteFuture;
    return ready = _AtlasSceneAssets(Map.unmodifiable(textures), {
      for (final (index, pose) in _DrOppoPose.values.indexed)
        if (sprites[index] != null) pose: sprites[index]!,
    });
  }
}

class _AtlasGlobeTexture {
  // Four 768² state images occupy ~9 MiB, plus three small mascot sprites.
  static const _side = 768;
  static double _luminance(int r, int g, int b) =>
      r * 0.2126 + g * 0.7152 + b * 0.0722;

  static double _emission(int r, int g, int b) =>
      math.min(
        ((r - g * 0.88 - 3) / 20).clamp(0.0, 1.0),
        ((g - b * 1.10 - 2) / 24).clamp(0.0, 1.0),
      ) *
      ((math.max(r, g) - 35) / 35).clamp(0.0, 1.0);

  static double _emissionWithNeighbor(int r, int g, int b, double neighbor) {
    final warm = _emission(r, g, b);
    final luminance = _luminance(r, g, b);
    if (luminance <= 95 || neighbor <= 0.4) return warm;
    return math.max(warm, neighbor * ((luminance - 70) / 60).clamp(0.0, 1.0));
  }

  static double _emissionAt(Uint8List pixels, int x, int y) {
    final i = (y * _side + x) * 4;
    final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
    var neighbor = 0.0;
    if (_luminance(r, g, b) > 95 && _emission(r, g, b) < 1) {
      for (final distance in const [1, 2]) {
        for (final dy in [-distance, 0, distance]) {
          for (final dx in [-distance, 0, distance]) {
            if (dx == 0 && dy == 0) continue;
            final n =
                (((y + dy).clamp(0, _side - 1) * _side) +
                    (x + dx).clamp(0, _side - 1)) *
                4;
            neighbor = math.max(
              neighbor,
              _emission(pixels[n], pixels[n + 1], pixels[n + 2]),
            );
          }
        }
      }
    }
    return _emissionWithNeighbor(r, g, b, neighbor);
  }

  static (int, int, int) mapPixel(
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
        // Broad emerald terrain retains near-mint cloud relief instead of the
        // flat dark-green result of the old projected atlas. Gold stays gold.
        final green = math.min(
          255.0,
          math.max(g.toDouble(), 18 + luminance * 1.12),
        );
        final red = math.min(r.toDouble(), green * 0.74);
        final blue = math.min(b.toDouble(), green * 0.82);
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
    for (final dy in const [-4, 0, 4]) {
      for (final dx in const [-4, 0, 4]) {
        final i =
            (((y + dy).clamp(0, _side - 1) * _side) +
                (x + dx).clamp(0, _side - 1)) *
            4;
        final unlit = (1 - emission[i ~/ 4]) * pixels[i + 3] / 255;
        sum += _luminance(pixels[i], pixels[i + 1], pixels[i + 2]) * unlit;
        weight += unlit;
      }
    }
    return weight > 0.2 ? sum / weight : 28;
  }

  static Future<ui.Image> _imageFromPixels(Uint8List pixels) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      _side,
      _side,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static Future<Map<_AtlasPlanetPalette, ui.Image>> create() async {
    final surfaces = <_AtlasPlanetPalette, ui.Image>{};
    try {
      final source = await rootBundle.load(
        'assets/maps/earth_night_globe.webp',
      );
      final codec = await ui.instantiateImageCodec(
        source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
        targetWidth: _side,
        targetHeight: _side,
      );
      late final Uint8List pixels;
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          if (data == null) return {};
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
      final emission = Float32List(_side * _side);
      for (var y = 0; y < _side; y++) {
        for (var x = 0; x < _side; x++) {
          emission[y * _side + x] = _emissionAt(pixels, x, y);
        }
        if (y % 32 == 31) await Future<void>.delayed(Duration.zero);
      }
      final terrain = Float32List(_side * _side);
      for (var y = 0; y < _side; y++) {
        for (var x = 0; x < _side; x++) {
          final i = (y * _side + x) * 4;
          terrain[y * _side + x] = emission[i ~/ 4] > 0
              ? _unlitNeighborhood(pixels, emission, x, y)
              : _luminance(pixels[i], pixels[i + 1], pixels[i + 2]);
        }
        if (y % 32 == 31) await Future<void>.delayed(Duration.zero);
      }
      for (final palette in _AtlasPlanetPalette.values) {
        final mapped = Uint8List(pixels.length);
        for (var i = 0; i < pixels.length; i += 4) {
          if (i % 131072 == 131068) await Future<void>.delayed(Duration.zero);
          final alpha = pixels[i + 3];
          if (alpha == 0) continue;
          final (r, g, b) = mapPixel(
            pixels[i],
            pixels[i + 1],
            pixels[i + 2],
            palette,
            unlitLuminance: terrain[i ~/ 4],
            emissionAmount: emission[i ~/ 4],
          );
          // decodeImageFromPixels expects premultiplied RGBA. Preserve the
          // artwork's genuine alpha; no rectangular halo on the star field.
          mapped[i] = (r * alpha / 255).round();
          mapped[i + 1] = (g * alpha / 255).round();
          mapped[i + 2] = (b * alpha / 255).round();
          mapped[i + 3] = alpha;
        }
        surfaces[palette] = await _imageFromPixels(mapped);
      }
      return surfaces;
    } catch (_) {
      for (final image in surfaces.values) {
        image.dispose();
      }
      return {};
    }
  }
}

class _AtlasGlobePainter extends CustomPainter {
  _AtlasGlobePainter({
    required this.phase,
    required this.lights,
    required this.flight,
    required this.texture,
    required this.mascots,
    required this.palette,
  }) : super(repaint: Listenable.merge([phase, lights, flight]));

  final ValueNotifier<double> phase, lights;
  final ValueNotifier<_AtlasFlightFrame> flight;
  final Map<_AtlasPlanetPalette, ui.Image>? texture;
  final Map<_DrOppoPose, _DrOppoSprite>? mascots;
  final _AtlasPlanetPalette palette;
  Color get tone => palette.tone;
  bool get _inFlight => switch (flight.value.stage) {
    _AtlasFlightStage.launch ||
    _AtlasFlightStage.orbit ||
    _AtlasFlightStage.landing => true,
    _ => false,
  };
  _DrOppoPose get pose =>
      _inFlight ? _DrOppoPose.flying : _DrOppoPose.forPalette(palette);
  double get _flightProgress =>
      Curves.easeInOut.transform(flight.value.progress);
  double get _landingZoom => switch (flight.value.stage) {
    _AtlasFlightStage.landing => _flightProgress,
    _AtlasFlightStage.landed => 1,
    _ => 0,
  };
  double _orbitAngle(double progress) => math.pi * (0.1 + 2 * progress);
  double get tilt => math.sin(phase.value * 2 * math.pi) * math.pi / 180;
  double _float(Size size) =>
      math.sin(phase.value * 2 * math.pi) *
      math.min(3.0, size.shortestSide * 0.006);
  Rect globeBounds(Size size) => Rect.fromCenter(
    center: size.center(Offset(0, _float(size))),
    width: size.shortestSide * (0.85 - 0.10 * _landingZoom),
    height: size.shortestSide * (0.85 - 0.10 * _landingZoom),
  );

  Rect _restingBounds(Size size, _DrOppoPose pose) {
    final d = size.shortestSide;
    final origin = size.center(Offset.zero) - Offset(d / 2, d / 2);
    final box = switch (pose) {
      _DrOppoPose.flying => Rect.fromLTWH(
        d * 0.595,
        d * 0.025,
        d * 0.33,
        d * 0.235,
      ),
      _DrOppoPose.waiting => Rect.fromLTWH(
        d * 0.39,
        d * 0.035,
        d * 0.22,
        d * 0.155,
      ),
      _DrOppoPose.puzzled => Rect.fromLTWH(
        d * 0.675,
        d * 0.015,
        d * 0.23,
        d * 0.235,
      ),
    };
    final source =
        mascots?[pose]?.source.size ??
        switch (pose) {
          _DrOppoPose.flying => const Size(1.55, 1),
          _DrOppoPose.waiting => const Size(0.80, 1),
          _DrOppoPose.puzzled => const Size(0.95, 1),
        };
    final fitted = applyBoxFit(BoxFit.contain, source, box.size).destination;
    var rect = Alignment.bottomCenter.inscribe(fitted, box);
    // Use the contact point on each alpha-trimmed pose and the visible rim
    // inside the atmospheric padding of the globe texture.
    final anchor = switch (pose) {
      _DrOppoPose.waiting => const Offset(0.46, 0.805),
      _DrOppoPose.puzzled => const Offset(0.47, 0.99),
      _DrOppoPose.flying => const Offset(0.34, 0.94),
    };
    final radius = d * (0.367 - 0.043 * _landingZoom);
    final dx = rect.left + rect.width * anchor.dx - d * 0.5;
    final rimY =
        d * 0.504 - math.sqrt(math.max(0.0, radius * radius - dx * dx));
    rect = rect.shift(Offset(0, rimY - rect.top - rect.height * anchor.dy));
    return rect.shift(origin + Offset(0, _float(size)));
  }

  Rect _orbitBounds(Size size, double progress) {
    final angle = _orbitAngle(progress);
    final depth = math.sin(angle);
    final d = size.shortestSide;
    final base = _restingBounds(size, _DrOppoPose.flying).size;
    final center =
        globeBounds(size).center +
        Offset(
          math.cos(angle) * d * 0.33,
          (-math.cos(angle) * 0.31 + depth * 0.09) * d,
        );
    return Rect.fromCenter(
      center: center,
      width: base.width * (0.84 + depth * 0.14),
      height: base.height * (0.84 + depth * 0.14),
    );
  }

  Rect mascotBounds(Size size) {
    final stage = flight.value.stage;
    if (stage == _AtlasFlightStage.orbit) {
      return _orbitBounds(size, flight.value.progress);
    }
    final hero = _restingBounds(size, pose);
    if (stage == _AtlasFlightStage.landing) {
      return Rect.lerp(_orbitBounds(size, 1), hero, _flightProgress)!;
    }
    if (stage == _AtlasFlightStage.launch) {
      final seated = _restingBounds(size, _DrOppoPose.waiting);
      final target = _orbitBounds(size, 0);
      final lift =
          math.sin(math.pi * _flightProgress) * size.shortestSide * 0.035;
      return Rect.fromCenter(
        center:
            Offset.lerp(seated.center, target.center, _flightProgress)! -
            Offset(0, lift),
        width: target.width,
        height: target.height,
      );
    }
    return hero;
  }

  void _paintMascot(Canvas canvas, Size size) {
    final bounds = mascotBounds(size);
    final roll = switch (flight.value.stage) {
      _AtlasFlightStage.orbit =>
        math.cos(_orbitAngle(flight.value.progress)) * 0.13,
      _AtlasFlightStage.landing => 0.13 * (1 - _flightProgress),
      _AtlasFlightStage.launch => 0.13 * _flightProgress,
      _ => 0.0,
    };
    if (flight.value.stage == _AtlasFlightStage.launch) {
      final seated = _restingBounds(size, _DrOppoPose.waiting);
      _drawMascot(
        canvas,
        _DrOppoPose.waiting,
        seated.shift(bounds.center - seated.center),
        1 - _flightProgress,
        roll,
      );
    }
    _drawMascot(
      canvas,
      pose,
      bounds,
      flight.value.stage == _AtlasFlightStage.launch ? _flightProgress : 1,
      roll,
    );
  }

  void _drawMascot(
    Canvas canvas,
    _DrOppoPose pose,
    Rect bounds,
    double opacity,
    double roll,
  ) {
    final mascot = mascots?[pose];
    if (mascot == null || opacity == 0) return;
    canvas.save();
    canvas.translate(bounds.center.dx, bounds.center.dy);
    canvas.rotate(roll);
    canvas.translate(-bounds.center.dx, -bounds.center.dy);
    canvas.drawImageRect(
      mascot.image,
      mascot.source,
      bounds,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: opacity),
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final globe = globeBounds(size);
    final orbiting = flight.value.stage == _AtlasFlightStage.orbit;
    final behind = orbiting && math.sin(_orbitAngle(flight.value.progress)) < 0;
    final surface = orbiting ? _AtlasPlanetPalette.connecting : palette;
    final image = texture?[surface];
    if (behind) _paintMascot(canvas, size);
    canvas.save();
    canvas.translate(center.dx, center.dy + _float(size));
    canvas.rotate(tilt);
    canvas.translate(-center.dx, -center.dy - _float(size));
    if (image != null) {
      final paint = Paint()..filterQuality = FilterQuality.medium;
      if (orbiting) {
        paint.color = Colors.white.withValues(
          alpha: 0.90 + math.sin(flight.value.progress * math.pi * 4) * 0.07,
        );
      }
      if (surface == _AtlasPlanetPalette.connected && lights.value < 1) {
        final dim = 1 - lights.value;
        paint.colorFilter = ColorFilter.matrix([
          1 - 0.75 * dim,
          0,
          0,
          0,
          0,
          -0.45 * dim,
          1,
          0,
          0,
          0,
          0,
          0,
          1 - 0.60 * dim,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]);
      }
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        globe,
        paint,
      );
    } else {
      // Optional artwork never replaces or blocks the actual connect action.
      final radius = globe.width * 0.46;
      canvas.drawCircle(globe.center, radius, Paint()..color = palette.ocean);
      canvas.drawCircle(
        globe.center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tone.withValues(alpha: 0.75),
      );
    }
    canvas.restore();
    if (!behind) _paintMascot(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _AtlasGlobePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.lights != lights ||
      oldDelegate.flight != flight ||
      oldDelegate.texture != texture ||
      oldDelegate.mascots != mascots ||
      oldDelegate.palette != palette;
}

@visibleForTesting
Widget buildAtlasPlanetForTesting({
  bool connected = false,
  bool busy = false,
  bool connecting = false,
  int connectionAttempt = 0,
  bool hasError = false,
  bool motionEnabled = true,
  bool textureAvailable = true,
  bool mascotAvailable = true,
  VoidCallback? onLanded,
  double size = 280,
}) => _AtlasAnimatedPlanet(
  connected: connected,
  busy: busy,
  connecting: connecting,
  connectionAttempt: connectionAttempt,
  hasError: hasError,
  motionEnabled: motionEnabled,
  textureAvailable: textureAvailable,
  mascotAvailable: mascotAvailable,
  onLanded: onLanded,
  size: size,
);

@visibleForTesting
Future<bool> preloadAtlasPlanetForTesting() async =>
    (await _AtlasSceneAssets.load()).textures.length ==
    _AtlasPlanetPalette.values.length;

// Borrowed cached image: test callers must not dispose it.
@visibleForTesting
Future<ui.Image?> atlasPlanetTextureForTesting({
  bool connected = false,
  bool busy = false,
  bool hasError = false,
}) async =>
    (await _AtlasSceneAssets.load()).textures[_AtlasPlanetPalette.select(
      connected: connected,
      busy: busy,
      hasError: hasError,
    )];

@visibleForTesting
Future<int> atlasPlanetMascotAssetCountForTesting() async =>
    (await _AtlasSceneAssets.load()).mascots.length;

@visibleForTesting
double atlasPlanetPhaseForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).phase.value;

@visibleForTesting
double atlasPlanetLightsForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).lights.value;

@visibleForTesting
Color atlasPlanetColorForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).tone;

@visibleForTesting
double atlasPlanetTiltForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).tilt;

@visibleForTesting
Rect atlasPlanetGlobeBoundsForTesting(CustomPainter painter, Size size) =>
    (painter as _AtlasGlobePainter).globeBounds(size);

@visibleForTesting
String atlasPlanetMascotPoseForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).pose.name;

@visibleForTesting
String atlasPlanetFlightStageForTesting(CustomPainter painter) =>
    (painter as _AtlasGlobePainter).flight.value.stage.name;

@visibleForTesting
Rect atlasPlanetMascotBoundsForTesting(CustomPainter painter, Size size) =>
    (painter as _AtlasGlobePainter).mascotBounds(size);

@visibleForTesting
Color atlasPlanetMappedPixelForTesting(
  Color source, {
  bool connected = false,
  bool busy = false,
  bool hasError = false,
  List<Color> neighbors = const [],
}) {
  final argb = source.toARGB32();
  final (r, g, b) = _AtlasGlobeTexture.mapPixel(
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
  return Color.fromARGB((argb >> 24) & 255, r, g, b);
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
