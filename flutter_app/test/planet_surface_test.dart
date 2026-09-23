import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

enum _PlanetState { disconnected, connected, error, connecting }

const _palettes = [
  (_PlanetState.disconnected, 0xFF242424, 0xFFA0A0A0),
  (_PlanetState.connected, 0xFF0C542F, 0xFF32E879),
  (_PlanetState.error, 0xFF531919, 0xFFF45454),
  (_PlanetState.connecting, 0xFF58451A, 0xFFFFC252),
];

Future<ui.Image?> _texture(_PlanetState state) => atlasPlanetTextureForTesting(
  connected: state == _PlanetState.connected || state == _PlanetState.error,
  hasError: state == _PlanetState.error,
  busy: state == _PlanetState.connecting,
);

int _countColor(Uint8List pixels, int argb) {
  final red = (argb >> 16) & 0xFF;
  final green = (argb >> 8) & 0xFF;
  final blue = argb & 0xFF;
  var count = 0;
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] == red &&
        pixels[i + 1] == green &&
        pixels[i + 2] == blue &&
        pixels[i + 3] == 255) {
      count++;
    }
  }
  return count;
}

void _expectSurfacePixels(
  Uint8List pixels,
  int width,
  int height,
  _PlanetState state,
) {
  var sampled = 0;
  var matched = 0;
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
      if (red < 35 && green < 35 && blue < 35) continue;
      sampled++;
      final correctColor = switch (state) {
        _PlanetState.disconnected =>
          (red - green).abs() <= 4 && (green - blue).abs() <= 4,
        _PlanetState.connected => green > red + 10 && green > blue + 10,
        _PlanetState.error => red > green + 10 && red > blue + 10,
        _PlanetState.connecting => red > green + 10 && green > blue + 10,
      };
      if (correctColor) matched++;
    }
  }
  expect(
    sampled,
    greaterThan(width * height * 0.1),
    reason: 'A substantial visible surface must exist, not only colored lights',
  );
  expect(
    matched / sampled,
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

  for (final (state, ocean, land) in _palettes) {
    test('${state.name} cached texture colors both ocean and land', () async {
      final image = await _texture(state);
      expect(image, isNotNull);
      expect(await _texture(state), same(image));
      final rgba = await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(rgba, isNotNull);
      final pixels = rgba!.buffer.asUint8List();
      final total = image.width * image.height;
      expect(
        _countColor(pixels, ocean),
        greaterThan(total * 0.25),
        reason: 'The ocean must be colored in the texture, before painting',
      );
      expect(
        _countColor(pixels, land),
        greaterThan(total * 0.1),
        reason: 'Continents must be colored, not left grayscale under a glow',
      );
      // The image belongs to the shared cache and must not be disposed here.
    });
  }

  testWidgets('rendered surface changes gray to green to red to gray', (
    tester,
  ) async {
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
                color: const Color(0xFF071F17),
                child: ValueListenableBuilder<_PlanetState>(
                  valueListenable: state,
                  builder: (context, value, _) => buildAtlasPlanetForTesting(
                    connected:
                        value == _PlanetState.connected ||
                        value == _PlanetState.error,
                    hasError: value == _PlanetState.error,
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
  });
}
