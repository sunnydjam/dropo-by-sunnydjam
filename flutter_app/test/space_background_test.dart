import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _SpaceFlags extends ChangeNotifier {
  bool enabled = true, active = true, ticker = true, reducedMotion = false;
  int builds = 0, taps = 0;
  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
CustomPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_key('atlas-space-motion')).painter!;
double _seconds(WidgetTester tester) =>
    atlasSpaceSecondsForTesting(_painter(tester));

Future<void> _pumpBackground(
  WidgetTester tester,
  _SpaceFlags flags, {
  double initialSeconds = 0,
}) async {
  tester.view.physicalSize = const Size(820, 560);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: flags,
          builder: (context, _) {
            flags.builds++;
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: flags.reducedMotion),
              child: TickerMode(
                enabled: flags.ticker,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    buildAtlasSpaceBackgroundForTesting(
                      motionEnabled: flags.enabled,
                      active: flags.active,
                      initialSeconds: initialSeconds,
                    ),
                    Center(
                      child: FilledButton(
                        key: const ValueKey('foreground-control'),
                        onPressed: () => flags.taps++,
                        child: const Text('Подключить'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<List<int>> _pixels(WidgetTester tester, {String? captureName}) async {
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      _key('atlas-space-background'),
    );
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
      if (captureName != null &&
          const bool.fromEnvironment('DROPO_UI_CAPTURE') &&
          directory.isNotEmpty) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/$captureName.png',
        ).writeAsBytes(png!.buffer.asUint8List());
      }
      return bytes!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  setUp(() {
    debugMobileShellOverride = false;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() => debugMobileShellOverride = null);

  test('stars are deterministic, sparse, dim and never wrap suddenly', () {
    const size = Size(820, 560);
    final first = atlasSpaceStarsForTesting(size, 0);
    expect(first.length, inInclusiveRange(40, 90));
    expect(atlasSpaceStarsForTesting(size, 0), first);
    final last = atlasSpaceStarsForTesting(size, 180);
    for (var index = 0; index < first.length; index++) {
      expect(first[index].$2, inInclusiveRange(0.45, 1.15));
      expect(first[index].$3, inInclusiveRange(0.06, 0.4));
      expect((first[index].$1 - last[index].$1).distance, lessThan(0.0001));
      expect(first[index].$3, closeTo(last[index].$3, 0.0001));
    }
    for (var second = 0; second < 180; second++) {
      final before = atlasSpaceStarsForTesting(size, second.toDouble());
      final after = atlasSpaceStarsForTesting(size, second + 1);
      for (var index = 0; index < before.length; index++) {
        expect(
          (before[index].$1 - after[index].$1).distance * 60,
          lessThan(2.4),
          reason: 'Decorative drift stays under 2.4 pixels per minute',
        );
        expect((before[index].$3 - after[index].$3).abs(), lessThan(0.05));
      }
    }
  });

  test('sun is absent for one minute with a smooth rare rise and fall', () {
    for (var second = 0; second <= 60; second++) {
      expect(atlasSpaceSunForTesting(second.toDouble()), 0);
    }
    expect(atlasSpaceSunForTesting(120), 1);
    expect(atlasSpaceSunForTesting(180), 0);
    expect(atlasSpaceSunForTesting(61), lessThan(0.001));
    expect(atlasSpaceSunForTesting(179), lessThan(0.001));
    for (var second = 0; second < 180; second++) {
      expect(
        (atlasSpaceSunForTesting(second.toDouble()) -
                atlasSpaceSunForTesting(second + 1))
            .abs(),
        lessThan(0.027),
      );
    }
  });

  testWidgets('canvas repaints at most 15 fps without rebuilding controls', (
    tester,
  ) async {
    final flags = _SpaceFlags();
    await _pumpBackground(tester, flags);
    final painter = _painter(tester);
    final builds = flags.builds;
    final rect = tester.getRect(_key('foreground-control'));
    var repaints = 0;
    void onRepaint() => repaints++;
    painter.addListener(onRepaint);
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    expect(repaints, inInclusiveRange(14, 16));
    expect(flags.builds, builds);
    expect(identical(painter, _painter(tester)), isTrue);
    expect(tester.getRect(_key('foreground-control')), rect);
    await tester.tap(_key('foreground-control'));
    expect(flags.taps, 1, reason: 'The decorative layer never absorbs clicks');
    painter.removeListener(onRepaint);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    flags.dispose();
  });

  for (final gate in ['setting', 'reduced-motion', 'ticker', 'page']) {
    testWidgets('$gate freezes and resumes the existing background phase', (
      tester,
    ) async {
      final flags = _SpaceFlags();
      await _pumpBackground(tester, flags);
      await tester.pump(const Duration(seconds: 4));
      flags.update(() {
        if (gate == 'setting') flags.enabled = false;
        if (gate == 'reduced-motion') flags.reducedMotion = true;
        if (gate == 'ticker') flags.ticker = false;
        if (gate == 'page') flags.active = false;
      });
      await tester.pump();
      final stopped = _seconds(tester);
      await tester.pump(const Duration(seconds: 20));
      expect(_seconds(tester), stopped);
      expect(tester.binding.transientCallbackCount, 0);
      flags.update(() {
        flags.enabled = flags.ticker = flags.active = true;
        flags.reducedMotion = false;
      });
      await tester.pump();
      expect(_seconds(tester), closeTo(stopped, 0.01));
      await tester.pump(const Duration(seconds: 2));
      expect(_seconds(tester) - stopped, closeTo(2, 0.08));
      await tester.pumpWidget(const SizedBox.shrink());
      flags.dispose();
    });
  }

  testWidgets('hidden pauses, inactive visible desktop keeps its slow motion', (
    tester,
  ) async {
    final flags = _SpaceFlags();
    await _pumpBackground(tester, flags);
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final stopped = _seconds(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(_seconds(tester), stopped);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_seconds(tester), closeTo(stopped, 0.01));
    await tester.pump(const Duration(seconds: 2));
    expect(_seconds(tester) - stopped, closeTo(2, 0.08));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    flags.dispose();
  });

  testWidgets('modal pauses background until the original route is visible', (
    tester,
  ) async {
    final flags = _SpaceFlags();
    await _pumpBackground(tester, flags);
    await tester.pump(const Duration(seconds: 2));
    final context = tester.element(_key('foreground-control'));
    final dialog = showDialog<void>(
      context: context,
      builder: (context) => const AlertDialog(content: Text('О приложении')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final stopped = _seconds(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(_seconds(tester), stopped);
    Navigator.of(context).pop();
    await dialog;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2));
    expect(_seconds(tester), greaterThan(stopped));
    await tester.pumpWidget(const SizedBox.shrink());
    flags.dispose();
  });

  testWidgets('night and peak sunrise remain almost entirely near black', (
    tester,
  ) async {
    for (final time in [0.0, 120.0]) {
      final flags = _SpaceFlags()..enabled = false;
      await _pumpBackground(tester, flags, initialSeconds: time);
      await tester.pump();
      final bytes = await _pixels(
        tester,
        captureName: time == 0 ? 'space-night' : 'space-sunrise',
      );
      var basePixels = 0, brightPixels = 0, warmPixels = 0;
      for (var pixel = 0; pixel < bytes.length; pixel += 4) {
        final red = bytes[pixel],
            green = bytes[pixel + 1],
            blue = bytes[pixel + 2];
        if (red == 5 && green == 7 && blue == 10) basePixels++;
        if (red > 70 || green > 70 || blue > 70) brightPixels++;
        if (red > green + 3 && red > blue + 3) {
          warmPixels++;
          expect(pixel ~/ 4 ~/ 820, greaterThan(450));
        }
        expect(bytes[pixel + 3], 255);
      }
      final pixelCount = bytes.length ~/ 4;
      expect(basePixels / pixelCount, greaterThan(0.90));
      expect(brightPixels / pixelCount, lessThan(0.0005));
      expect(warmPixels, time == 0 ? 0 : greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      flags.dispose();
    }
  });

  testWidgets('non-home background is plain opaque black without animations', (
    tester,
  ) async {
    final flags = _SpaceFlags()..active = false;
    await _pumpBackground(tester, flags, initialSeconds: 120);
    await tester.pump();
    final bytes = await _pixels(tester);
    for (var pixel = 0; pixel < bytes.length; pixel += 4) {
      expect(bytes.sublist(pixel, pixel + 4), [5, 7, 10, 255]);
    }
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    flags.dispose();
  });
}
