import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'navigation_helpers.dart';

class _SpaceBridge extends MockCoreBridge {
  bool connected = true;
  bool hasError = false;
  bool connecting = false;
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
    hasError: hasError,
    error: hasError ? 'Тестовая ошибка соединения' : '',
    connecting: connecting,
    vpnState: hasError
        ? 'failed'
        : connecting
        ? 'starting'
        : connected
        ? 'connected'
        : 'stopped',
  );
  @override
  Future<List<VpnSourceInfo>> vpnSources() async => [
    VpnSourceInfo.fromJson({
      'id': 'preview-source',
      'name': 'Моя подписка',
      'kind': 'subscription',
      'selected_node': 0,
      'node_count': 1,
      'node_names': ['Сервер 1'],
      'active': connected,
    }),
  ];
  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    toggles++;
    connected = value;
    return super.setConnected(value);
  }
}

Future<void> _pumpScene(
  WidgetTester tester,
  _SpaceBridge bridge,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await bridge.saveSubscription('https://example.test/subscription');
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('space-screen-capture'),
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
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

double _phase(WidgetTester tester) => atlasSpacePhaseForTesting(
  tester
      .widget<CustomPaint>(find.byKey(const ValueKey('atlas-space-motion')))
      .painter!,
);

Future<void> _capture(
  WidgetTester tester,
  String name, {
  double pixelRatio = 1,
}) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
  if (directory.isEmpty) {
    throw StateError('Set a capture directory outside the repository.');
  }
  await tester.runAsync(() async {
    final rendered = await tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('space-screen-capture')),
        )
        .toImage(pixelRatio: pixelRatio);
    try {
      final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(png!.buffer.asUint8List());
    } finally {
      rendered.dispose();
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
      await (FontLoader('Consolas')..addFont(
            File(
              'C:/Windows/Fonts/consola.ttf',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
  });
  setUp(() {
    debugMobileShellOverride = false;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() => debugMobileShellOverride = null);

  for (final (size, scale) in [
    (const Size(820, 560), 1.0),
    (const Size(684, 461), 1.0),
    (const Size(1100, 760), 1.0),
    (const Size(390, 568), 2.0),
  ]) {
    testWidgets('space shell keeps controls usable at $size scale $scale', (
      tester,
    ) async {
      final bridge = _SpaceBridge();
      await _pumpScene(tester, bridge, size, scale);
      expect(find.byKey(const ValueKey('planet-connected')), findsOneWidget);
      final action = find.byKey(const ValueKey('home-connect'));
      expect(action.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('app-version')).hitTestable(),
        findsOneWidget,
      );
      final actionRect = tester.getRect(action);
      final initialPhase = _phase(tester);
      await _capture(tester, 'home-${size.width.toInt()}-night-$scale');
      if (size.width == 820) {
        await _capture(tester, 'home-820-night-hidpi', pixelRatio: 2);
      }
      await tester.pump(const Duration(seconds: 120));
      await tester.pump();
      expect(_phase(tester), greaterThan(initialPhase));
      expect(tester.getRect(action), actionRect);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'home-${size.width.toInt()}-sunrise-$scale');
      await tester.tap(action);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.toggles, 1);
      expect(bridge.connected, isFalse);
      expect(find.byKey(const ValueKey('planet-disconnected')), findsOneWidget);
      await _capture(tester, 'home-${size.width.toInt()}-disconnected-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final state in ['error', 'connecting']) {
    testWidgets('night planet preserves $state full-screen state', (
      tester,
    ) async {
      final bridge = _SpaceBridge()
        ..connected = false
        ..hasError = state == 'error'
        ..connecting = state == 'connecting';
      await _pumpScene(tester, bridge, const Size(820, 560), 1);
      expect(find.byKey(ValueKey('planet-$state')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'home-820-$state');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('navigation modal and saved preference pause space background', (
    tester,
  ) async {
    final bridge = _SpaceBridge();
    await _pumpScene(tester, bridge, const Size(820, 560), 1);
    await tester.tap(find.byKey(const ValueKey('app-version')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    var paused = _phase(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(_phase(tester), paused);
    Navigator.of(tester.element(find.text('О приложении'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await openSection(tester, 'settings');
    paused = _phase(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(_phase(tester), paused);
    await _capture(tester, 'settings-820');
    await openSection(tester, 'app-settings');
    final toggle = find.byKey(
      const ValueKey('setting-switch-Анимации интерфейса'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect((await bridge.appConfig())['reduceMotion'], isTrue);
    await openSection(tester, 'home');
    paused = _phase(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(_phase(tester), paused);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
