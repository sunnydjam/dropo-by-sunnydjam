import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _PlanetFlags extends ChangeNotifier {
  bool connected = false;
  bool error = false;
  bool busy = false;
  bool enabled = true;
  bool reducedMotion = false;
  bool ticker = true;
  int parentBuilds = 0;
  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
CustomPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_key('atlas-planet-motion')).foregroundPainter!;
double _phase(WidgetTester tester) =>
    atlasPlanetPhaseForTesting(_painter(tester));

Future<void> _pumpPlanet(WidgetTester tester, _PlanetFlags flags) async {
  tester.view.physicalSize = const Size(420, 420);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF071F17),
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
      ),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: flags,
          builder: (context, _) {
            flags.parentBuilds++;
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: flags.reducedMotion),
              child: TickerMode(
                enabled: flags.ticker,
                child: Center(
                  child: RepaintBoundary(
                    key: const ValueKey('rotation-capture'),
                    child: ColoredBox(
                      color: const Color(0xFF071F17),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          buildAtlasPlanetForTesting(
                            connected: flags.connected,
                            busy: flags.busy,
                            hasError: flags.error,
                            motionEnabled: flags.enabled,
                            size: 320,
                          ),
                          FilledButton(
                            key: const ValueKey('fixed-button'),
                            onPressed: () {},
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xEE071F17),
                              foregroundColor: Colors.white,
                            ),
                            child: Text(
                              flags.connected ? 'Отключить' : 'Подключить',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  const directory = String.fromEnvironment(
    'DROPO_UI_CAPTURE_DIR',
    defaultValue: 'build/planet-rotation-review',
  );
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      _key('rotation-capture'),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    expect(
      await preloadAtlasPlanetForTesting(),
      isTrue,
      reason: 'Bundled geographic texture must decode without a network',
    );
  });
  setUp(() {
    debugMobileShellOverride = false;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() => debugMobileShellOverride = null);

  for (final (state, color) in const [
    ('disconnected', Color(0xFFAAB4B2)),
    ('connected', Color(0xFF5CF0B0)),
    ('error', Color(0xFFFF6969)),
    ('connecting', Color(0xFFFFCF78)),
  ]) {
    testWidgets(
      '$state sphere rotates its surface without rebuilding the button',
      (tester) async {
        final flags = _PlanetFlags()
          ..connected = state == 'connected' || state == 'error'
          ..error = state == 'error'
          ..busy = state == 'connecting';
        await _pumpPlanet(tester, flags);
        expect(_key('planet-$state'), findsOneWidget);
        final painter = _painter(tester);
        expect(atlasPlanetColorForTesting(painter), color);
        final first = atlasPlanetSurfacePointForTesting(painter, 15, 20);
        final initialPhase = _phase(tester);
        final button = tester.getRect(_key('fixed-button'));
        final builds = flags.parentBuilds;
        await _capture(tester, '$state-t0');
        await tester.pump(const Duration(seconds: 3));
        final rotated = atlasPlanetSurfacePointForTesting(
          _painter(tester),
          15,
          20,
        );
        expect(_phase(tester) - initialPhase, closeTo(0.05, 0.002));
        expect((first.$1 - rotated.$1).abs(), greaterThan(0.15));
        expect(
          (first.$3 - rotated.$3).abs(),
          greaterThan(0.02),
          reason:
              'Depth changes: this is not a flat image rotating in its plane',
        );
        expect(identical(_painter(tester), painter), isTrue);
        expect(flags.parentBuilds, builds);
        expect(tester.getRect(_key('fixed-button')), button);
        await _capture(tester, '$state-t3');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.binding.transientCallbackCount, 0);
        flags.dispose();
      },
    );
  }

  testWidgets(
    'hidden pauses, visible inactive desktop rotates and resume keeps phase',
    (tester) async {
      final flags = _PlanetFlags();
      await _pumpPlanet(tester, flags);
      await tester.pump(const Duration(seconds: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      final hidden = _phase(tester);
      await tester.pump(const Duration(seconds: 7));
      expect(_phase(tester), hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(_phase(tester), closeTo(hidden, 0.001));
      await tester.pump(const Duration(seconds: 2));
      expect(_phase(tester) - hidden, closeTo(2 / 60, 0.002));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      flags.dispose();
    },
  );

  for (final gate in ['setting', 'reduced-motion', 'ticker']) {
    testWidgets('$gate pauses and resumes without jumping or leaking tickers', (
      tester,
    ) async {
      final flags = _PlanetFlags();
      await _pumpPlanet(tester, flags);
      await tester.pump(const Duration(seconds: 2));
      flags.update(() {
        if (gate == 'setting') flags.enabled = false;
        if (gate == 'reduced-motion') flags.reducedMotion = true;
        if (gate == 'ticker') flags.ticker = false;
      });
      await tester.pump();
      final stopped = _phase(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(_phase(tester), stopped);
      expect(tester.binding.transientCallbackCount, 0);
      flags.update(() {
        flags.enabled = true;
        flags.reducedMotion = false;
        flags.ticker = true;
      });
      await tester.pump();
      expect(_phase(tester), closeTo(stopped, 0.001));
      await tester.pump(const Duration(seconds: 1));
      expect(_phase(tester), greaterThan(stopped));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
      flags.dispose();
    });
  }

  testWidgets('modal pauses globe and closing it resumes previous phase', (
    tester,
  ) async {
    final flags = _PlanetFlags();
    await _pumpPlanet(tester, flags);
    await tester.pump(const Duration(seconds: 2));
    final context = tester.element(_key('fixed-button'));
    final dialog = showDialog<void>(
      context: context,
      builder: (context) => const AlertDialog(title: Text('О приложении')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final paused = _phase(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_phase(tester), paused);
    Navigator.of(context).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await dialog;
    await tester.pump(const Duration(seconds: 2));
    expect(_phase(tester), greaterThan(paused));
    await tester.pumpWidget(const SizedBox.shrink());
    flags.dispose();
  });

  testWidgets(
    'full orbit stays bounded and 144 Hz does not repaint at 144 fps',
    (tester) async {
      final flags = _PlanetFlags()..connected = true;
      await _pumpPlanet(tester, flags);
      var notifications = 0;
      var previous = _phase(tester);
      for (var frame = 0; frame < 144; frame++) {
        await tester.pump(const Duration(microseconds: 6944));
        if (_phase(tester) != previous) notifications++;
        previous = _phase(tester);
      }
      expect(notifications, inInclusiveRange(29, 31));
      final start = _phase(tester);
      for (var quarter = 1; quarter <= 4; quarter++) {
        await tester.pump(const Duration(seconds: 15));
        for (final (latitude, longitude) in const [
          (0.0, 0.0),
          (90.0, 180.0),
          (-80.0, -175.0),
          (45.0, 120.0),
        ]) {
          final (x, y, depth) = atlasPlanetSurfacePointForTesting(
            _painter(tester),
            latitude,
            longitude,
          );
          expect(x * x + y * y + depth * depth, closeTo(1, 0.000001));
        }
        await _capture(tester, 'orbit-quarter-$quarter');
        expect(tester.takeException(), isNull);
      }
      expect(_phase(tester), closeTo(start, 1 / 1800));
      await tester.pumpWidget(const SizedBox.shrink());
      flags.dispose();
    },
  );

  testWidgets(
    'status changes preserve rotation phase and error overrides connected color',
    (tester) async {
      final flags = _PlanetFlags();
      await _pumpPlanet(tester, flags);
      await tester.pump(const Duration(seconds: 3));
      final before = _phase(tester);
      flags.update(() {
        flags.connected = true;
        flags.error = true;
      });
      await tester.pump();
      expect(_phase(tester), before);
      expect(_key('planet-error'), findsOneWidget);
      expect(
        atlasPlanetColorForTesting(_painter(tester)),
        const Color(0xFFFF6969),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_phase(tester), greaterThan(before));
      flags.update(() => flags.error = false);
      await tester.pump();
      expect(_key('planet-connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      flags.dispose();
    },
  );
}
