import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

enum _PlanetState { disconnected, connected, error, connecting }

Future<ui.Image?> _texture(_PlanetState state) => atlasPlanetTextureForTesting(
  connected: state == _PlanetState.connected || state == _PlanetState.error,
  hasError: state == _PlanetState.error,
  busy: state == _PlanetState.connecting,
);

bool _warmEmission(int red, int green, int blue) =>
    red > 50 && red > green + 8 && green > blue + 8;

bool _stateColor(int red, int green, int blue, _PlanetState state) =>
    switch (state) {
      _PlanetState.disconnected =>
        (red - green).abs() <= 4 && (green - blue).abs() <= 4,
      _PlanetState.connected => green > red + 3 && green > blue + 3,
      _PlanetState.error => red > green + 3 && red > blue + 3,
      _PlanetState.connecting => red > green + 3 && green > blue + 3,
    };

void _expectSurfacePixels(
  Uint8List pixels,
  int width,
  int height,
  _PlanetState state,
) {
  var sampled = 0;
  var matched = 0;
  var warm = 0;
  final centerX = width / 2;
  final centerY = height / 2;
  // The inner disk excludes the atmospheric glow and silhouette. Skip dark
  // shadow pixels: the regression concerns the visible surface, not shading.
  final radiusSquared = (width * 0.34) * (width * 0.34);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x + 0.5 - centerX;
      final dy = y + 0.5 - centerY;
      if (dx * dx + dy * dy > radiusSquared) continue;
      final i = (y * width + x) * 4;
      final red = pixels[i];
      final green = pixels[i + 1];
      final blue = pixels[i + 2];
      if (red < 12 && green < 12 && blue < 12) continue;
      sampled++;
      // Only connected city emissions may be gold. They must remain a small
      // minority; this exemption cannot hide a gray sphere with a green rim.
      if (state == _PlanetState.connected && _warmEmission(red, green, blue)) {
        warm++;
      } else if (_stateColor(red, green, blue, state)) {
        matched++;
      }
    }
  }
  expect(
    sampled,
    greaterThan(width * height * 0.1),
    reason: 'A substantial visible surface must exist, not only colored lights',
  );
  expect(
    warm / sampled,
    lessThan(0.2),
    reason: 'Warm city lights must not replace the state-colored terrain',
  );
  expect(
    matched / (sampled - warm),
    greaterThan(0.93),
    reason:
        '${state.name}: the sphere surface itself must have the state color '
        '($matched of $sampled visible pixels matched)',
  );
}

Future<void> _verifyAndCapture(
  WidgetTester tester,
  _PlanetState state,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('surface-capture')),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(rgba, isNotNull);
      _expectSurfacePixels(
        rgba!.buffer.asUint8List(),
        image.width,
        image.height,
        state,
      );
      if (const bool.fromEnvironment('DROPO_UI_CAPTURE')) {
        const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
        if (directory.isEmpty) {
          throw StateError(
            'Set DROPO_UI_CAPTURE_DIR to a directory outside the repository.',
          );
        }
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(png!.buffer.asUint8List());
      }
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(await preloadAtlasPlanetForTesting(), isTrue);
  });

  for (final state in _PlanetState.values) {
    test(
      '${state.name} cached detailed texture colors the whole map',
      () async {
        final image = await _texture(state);
        expect(image, isNotNull);
        expect(await _texture(state), same(image));
        expect(image!.width, 1024);
        expect(image.height, 512);
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(rgba, isNotNull);
        final pixels = rgba!.buffer.asUint8List();
        final total = image.width * image.height;
        var opaque = 0;
        var visible = 0;
        var matched = 0;
        var warm = 0;
        final colors = <int>{};
        for (var i = 0; i < pixels.length; i += 4) {
          final red = pixels[i], green = pixels[i + 1], blue = pixels[i + 2];
          if (pixels[i + 3] == 255) opaque++;
          colors.add(red << 16 | green << 8 | blue);
          if (red < 12 && green < 12 && blue < 12) continue;
          visible++;
          if (state == _PlanetState.connected &&
              _warmEmission(red, green, blue)) {
            warm++;
          } else if (_stateColor(red, green, blue, state)) {
            matched++;
          }
        }
        expect(
          opaque,
          total,
          reason: 'No transparent gaps on the rotating globe',
        );
        expect(
          colors.length,
          greaterThan(state == _PlanetState.connected ? 256 : 100),
          reason: 'Preserve detailed terrain after state-color mapping',
        );
        for (var y = 0; y < image.height; y++) {
          final left = y * image.width * 4;
          final right = left + (image.width - 1) * 4;
          expect(
            pixels.sublist(left, left + 4),
            pixels.sublist(right, right + 4),
            reason:
                '${state.name}: the longitude seam must not flash on rotation',
          );
        }
        expect(
          visible,
          greaterThan(total * 0.5),
          reason:
              'The detailed surface must remain visible, not only its lights',
        );
        expect(
          warm / visible,
          lessThan(0.2),
          reason: 'Connected gold city emissions are a bounded minority',
        );
        if (state == _PlanetState.connected) {
          expect(
            warm,
            greaterThan(100),
            reason: 'City lights are actually present',
          );
        }
        expect(
          matched / (visible - warm),
          greaterThan(0.93),
          reason: 'All terrain is state-colored before GPU sphere projection',
        );
        // The image belongs to the shared cache and must not be disposed here.
      },
    );
  }

  test(
    'states have distinct shared textures and preserve precedence',
    () async {
      final textures = await Future.wait(_PlanetState.values.map(_texture));
      expect(textures.toSet(), hasLength(_PlanetState.values.length));
      expect(
        await atlasPlanetTextureForTesting(
          connected: true,
          busy: true,
          hasError: true,
        ),
        same(await _texture(_PlanetState.error)),
      );
      expect(
        await atlasPlanetTextureForTesting(connected: true, busy: true),
        same(await _texture(_PlanetState.connecting)),
      );
    },
  );

  test(
    'warm emission is lit only when connected and neutral clouds stay terrain',
    () {
      const city = Color(0xFFFFCD64);
      const cloud = Color(0xFFBEBEBE);
      for (final state in _PlanetState.values) {
        Color mapped(Color source) => atlasPlanetMappedPixelForTesting(
          source,
          connected:
              state == _PlanetState.connected || state == _PlanetState.error,
          hasError: state == _PlanetState.error,
          busy: state == _PlanetState.connecting,
        );
        final cityColor = mapped(city).toARGB32();
        final red = (cityColor >> 16) & 255;
        final green = (cityColor >> 8) & 255;
        final blue = cityColor & 255;
        if (state == _PlanetState.connected) {
          expect(_warmEmission(red, green, blue), isTrue);
          expect(red, greaterThan(220));
        } else {
          expect(_stateColor(red, green, blue, state), isTrue);
          expect(
            [red, green, blue].every((channel) => channel < 80),
            isTrue,
            reason:
                '${state.name}: an unlit city must not remain a bright hotspot',
          );
        }
        final cloudColor = mapped(cloud).toARGB32();
        expect(
          _stateColor(
            (cloudColor >> 16) & 255,
            (cloudColor >> 8) & 255,
            cloudColor & 255,
            state,
          ),
          isTrue,
          reason:
              'Clouds should be detailed state-colored terrain, not emissions',
        );
        expect(mapped(city).a, 1);
        expect(mapped(cloud).a, 1);
      }
    },
  );

  test(
    'near-white city cores require warm neighbors, preserving isolated clouds',
    () {
      const core = Color(0xFFF6F3EC);
      const warmNeighbor = Color(0xFFFFC56A);
      const darkTerrain = Color(0xFF303030);
      expect(atlasPlanetEmissionForTesting(core), 0);
      expect(atlasPlanetEmissionForTesting(core, neighbors: [core]), 0);
      expect(
        atlasPlanetEmissionForTesting(core, neighbors: [warmNeighbor]),
        greaterThan(0.95),
      );
      expect(
        atlasPlanetEmissionForTesting(darkTerrain, neighbors: [warmNeighbor]),
        0,
        reason: 'Nearby city lights must not erase dark terrain detail',
      );
      for (final state in _PlanetState.values) {
        Color mapped(List<Color> neighbors) => atlasPlanetMappedPixelForTesting(
          core,
          neighbors: neighbors,
          connected:
              state == _PlanetState.connected || state == _PlanetState.error,
          hasError: state == _PlanetState.error,
          busy: state == _PlanetState.connecting,
        );
        final city = mapped([warmNeighbor]).toARGB32();
        if (state == _PlanetState.connected) {
          expect(
            city,
            core.toARGB32(),
            reason: 'The lit city keeps its white core',
          );
        } else {
          final red = (city >> 16) & 255;
          final green = (city >> 8) & 255;
          final blue = city & 255;
          expect(_stateColor(red, green, blue, state), isTrue);
          expect(
            [red, green, blue].every((channel) => channel < 80),
            isTrue,
            reason:
                '${state.name}: pale city cores extinguish with the warm halo',
          );
        }
        final cloud = mapped([]).toARGB32();
        expect(
          _stateColor(
            (cloud >> 16) & 255,
            (cloud >> 8) & 255,
            cloud & 255,
            state,
          ),
          isTrue,
          reason:
              'The same isolated near-white pixel remains state-colored cloud',
        );
        expect(mapped([]).computeLuminance(), greaterThan(0.2));
      }
    },
  );

  testWidgets(
    'rendered surface changes gray to green to red to amber to gray',
    (tester) async {
      debugMobileShellOverride = false;
      addTearDown(() => debugMobileShellOverride = null);
      tester.view.physicalSize = const Size(360, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ValueNotifier(_PlanetState.disconnected);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('surface-capture'),
                child: ColoredBox(
                  color: const Color(0xFF05070A),
                  child: ValueListenableBuilder<_PlanetState>(
                    valueListenable: state,
                    builder: (context, value, _) => buildAtlasPlanetForTesting(
                      connected:
                          value == _PlanetState.connected ||
                          value == _PlanetState.error,
                      hasError: value == _PlanetState.error,
                      busy: value == _PlanetState.connecting,
                      motionEnabled: false,
                      size: 320,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final (index, next) in const [
        _PlanetState.disconnected,
        _PlanetState.connected,
        _PlanetState.error,
        _PlanetState.connecting,
        _PlanetState.disconnected,
      ].indexed) {
        state.value = next;
        await tester.pump();
        expect(find.byKey(ValueKey('planet-${next.name}')), findsOneWidget);
        await _verifyAndCapture(tester, next, '$index-${next.name}-surface');
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
