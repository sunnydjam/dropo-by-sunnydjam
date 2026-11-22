import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Render the real home page; all connection data stays in this test bridge.
class _DrOppoBridge extends MockCoreBridge {
  _DrOppoBridge(String state)
    : connected = state == 'connected',
      error = state == 'error',
      busy = state == 'connecting';

  bool connected;
  final bool error, busy;
  int toggles = 0;

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'checkUpdates': false,
    'autoStartPrompted': true,
  };

  @override
  Future<CoreStatus> status() async => (await super.status()).copyWith(
    connected: connected,
    running: connected,
    hasError: error,
    error: error ? 'Не удалось подключиться к серверу' : '',
    connecting: busy,
    vpnState: error
        ? 'failed'
        : busy
        ? 'starting'
        : connected
        ? 'connected'
        : 'stopped',
  );

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => [
    VpnSourceInfo.fromJson({
      'id': 'droppo-preview-source',
      'name': 'Моя подписка',
      'kind': 'subscription',
      'selected_node': 0,
      'node_count': 1,
      'node_names': ['Сервер 1'],
      'active': connected,
    }),
  ];

  @override
  Future<VpnSourcesSnapshot> vpnSourcesSnapshot() async => VpnSourcesSnapshot(
    sources: await vpnSources(),
    autoSelect: true,
    running: connected,
    autoSelectSupported: true,
    fallbackSupported: true,
  );

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    toggles++;
    connected = value;
    return super.setConnected(value);
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));

CustomPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(_key('atlas-planet-motion')).foregroundPainter!;

Future<void> _pumpHome(
  WidgetTester tester,
  _DrOppoBridge bridge,
  Size viewport,
  double scale,
) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await bridge.saveSubscription('https://example.test/subscription');
  await bridge.setRoutingMode('blocked_only');
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('droppo-home-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
  if (directory.isEmpty) {
    throw StateError('Set a capture directory outside the repository.');
  }
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(_key('droppo-home-capture'))
        .toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png').writeAsBytes(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    expect(await preloadAtlasPlanetForTesting(), isTrue);
    if (const bool.fromEnvironment('DROPO_UI_CAPTURE') && Platform.isWindows) {
      for (final family in ['Consolas', 'monospace']) {
        await (FontLoader(family)..addFont(
              File(
                'C:/Windows/Fonts/consola.ttf',
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            ))
            .load();
      }
    }
  });

  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() => debugMobileShellOverride = null);

  for (final (platform, viewport, scale) in const [
    ('windows', Size(1536, 900), 1.0),
    ('windows', Size(700, 500), 1.0),
    ('android', Size(390, 844), 1.0),
    ('android', Size(320, 640), 1.6),
  ]) {
    for (final (state, pose) in const [
      ('connected', 'flying'),
      ('disconnected', 'waiting'),
      ('error', 'puzzled'),
      ('connecting', 'waiting'),
    ]) {
      testWidgets(
        'DrOppo $pose for $state fits $platform $viewport text $scale',
        (tester) async {
          debugMobileShellOverride = platform == 'android';
          final bridge = _DrOppoBridge(state);
          await _pumpHome(tester, bridge, viewport, scale);
          expect(_key('planet-$state'), findsOneWidget);
          expect(atlasPlanetMascotPoseForTesting(_painter(tester)), pose);

          final scene = tester.getRect(_key('atlas-planet-motion'));
          final localMascot = atlasPlanetMascotBoundsForTesting(
            _painter(tester),
            scene.size,
          );
          final mascot = localMascot.shift(scene.topLeft);
          final action = _key('home-connect');
          final actionRect = tester.getRect(action);
          expect(localMascot.isEmpty, isFalse);
          expect(localMascot.left, greaterThanOrEqualTo(0));
          expect(localMascot.top, greaterThanOrEqualTo(0));
          expect(localMascot.right, lessThanOrEqualTo(scene.width));
          expect(localMascot.bottom, lessThanOrEqualTo(scene.height));
          expect(
            mascot.overlaps(actionRect),
            isFalse,
            reason: 'The character must leave the connection action visible.',
          );
          expect(action.hitTestable(), findsOneWidget);
          expect(actionRect.height, greaterThanOrEqualTo(48));
          expect(
            tester.widget<FilledButton>(action).onPressed,
            state == 'connecting' ? isNull : isNotNull,
          );
          expect(tester.takeException(), isNull);

          final mode = _key('home-routing-selected');
          final modeRect = tester.getRect(mode);
          final captureName =
              'droppo-$platform-${viewport.width.toInt()}-$state-$scale';
          if (state == 'error') {
            // Real error notices retain priority over decorative artwork.
            // Capture that initial presentation, then use the existing
            // collapse action to inspect DrOppo without changing the error.
            await _capture(tester, '$captureName-notice');
            expect(_key('dismiss-notice').hitTestable(), findsOneWidget);
            await tester.tap(_key('dismiss-notice'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(_key('reopen-notice'), findsOneWidget);
            expect(_key('planet-error'), findsOneWidget);
            expect(
              atlasPlanetMascotPoseForTesting(_painter(tester)),
              'puzzled',
            );
            expect(action.hitTestable(), findsOneWidget);
            expect(tester.getRect(action), actionRect);
            expect(tester.getRect(mode), modeRect);
            expect(tester.getRect(_key('atlas-planet-motion')), scene);
            expect(tester.takeException(), isNull);
          }
          await _capture(tester, captureName);

          // Decorative animation may repaint, but must not move the primary
          // controls or the service-mode selector below it.
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          expect(tester.getRect(action), actionRect);
          expect(tester.getRect(mode), modeRect);
          expect(tester.takeException(), isNull);

          if (state == 'connected') {
            // A real pointer action must still reach the real connection
            // callback, independently of the decorative foreground painter.
            await tester.tap(action);
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            expect(bridge.toggles, 1);
            expect(bridge.connected, isFalse);
            expect(
              atlasPlanetMascotPoseForTesting(_painter(tester)),
              'waiting',
            );
            expect(tester.getRect(action), actionRect);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
