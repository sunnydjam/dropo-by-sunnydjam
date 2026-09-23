import 'dart:io';
import 'dart:ui' as ui;
import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'navigation_helpers.dart';

class _TelemetryBridge extends MockCoreBridge {
  bool connected = true;
  VpnResponseSnapshot snapshot = VpnResponseSnapshot.fromJson({
    'state': 'ok',
    'latencyMs': 83,
    'checkedAt': DateTime.now().toUtc().toIso8601String(),
    'target': 'http://www.gstatic.com/generate_204',
  });
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
    vpnResponse: snapshot,
  );
}

Future<void> _pump(
  WidgetTester tester,
  _TelemetryBridge bridge,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('response-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
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

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('response-capture')),
        )
        .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('build/ui-feedback2').create(recursive: true);
    await File(
      'build/ui-feedback2/$name.png',
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
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    expect(await preloadAtlasPlanetForTesting(), isTrue);
    if (const bool.fromEnvironment('DROPO_UI_CAPTURE') && Platform.isWindows) {
      await (FontLoader('Consolas')..addFont(
            File(
              'C:/Windows/Fonts/consola.ttf',
            ).readAsBytes().then((b) => ByteData.sublistView(b)),
          ))
          .load();
    }
  });

  test('response only reports a fresh measured positive latency', () {
    for (final state in ['unavailable', 'pending', 'failed', 'stale']) {
      final snapshot = VpnResponseSnapshot.fromJson({
        'state': state,
        'latencyMs': 999,
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(snapshot.current, isFalse);
      expect(snapshot.label, isNot(contains('999')));
    }
    for (final value in [null, 0, -1]) {
      final snapshot = VpnResponseSnapshot.fromJson({
        'state': 'ok',
        'latencyMs': value,
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(snapshot.current, isFalse);
      expect(snapshot.label, 'Нет данных');
    }
    final stale = VpnResponseSnapshot.fromJson({
      'state': 'ok',
      'latencyMs': 83,
      'checkedAt': DateTime.now()
          .subtract(const Duration(minutes: 3))
          .toUtc()
          .toIso8601String(),
    });
    expect(stale.label, 'Данные устарели');
    expect(
      VpnResponseSnapshot.fromJson({'state': 'ok', 'latencyMs': 83}).current,
      isFalse,
    );
  });

  for (final (size, scale) in [
    (const Size(1100, 760), 1.0),
    (const Size(820, 560), 1.0),
    (const Size(684, 461), 1.0),
    (const Size(390, 568), 2.0),
  ]) {
    testWidgets('response and version fit $size scale $scale', (tester) async {
      await _pump(tester, _TelemetryBridge(), size, scale);
      final header = find.byKey(const ValueKey('compact-header'));
      expect(
        find.descendant(of: header, matching: find.text('Подключение')),
        findsNothing,
      );
      final metric = find.byKey(
        ValueKey(
          size.width >= 1000 ? 'vpn-response-panel' : 'vpn-response-compact',
        ),
      );
      expect(metric, findsOneWidget);
      expect(
        find.byKey(const ValueKey('app-version')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(metric)
            .overlaps(
              tester.getRect(find.byKey(const ValueKey('home-connect'))),
            ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'connected-${size.width.toInt()}-$scale');
      await tester.tap(metric);
      await tester.pumpAndSettle();
      expect(find.text('Отклик через VPN'), findsOneWidget);
      expect(find.textContaining('не пинг конкретной игры'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Отклик через VPN'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-version')));
      await tester.pumpAndSettle();
      expect(find.text('Джамуха (sunnydjam)'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'about-${size.width.toInt()}-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('disconnected hides measurement and preference saves', (
    tester,
  ) async {
    final bridge = _TelemetryBridge()..connected = false;
    await _pump(tester, bridge, const Size(820, 560), 1);
    expect(find.byKey(const ValueKey('vpn-response-compact')), findsNothing);
    await openSection(tester, 'app-settings');
    final toggle = find.byKey(
      const ValueKey('setting-switch-Анимация планеты'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await bridge.appConfig())['reduceMotion'], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explanation never retains a live value after disconnect', (
    tester,
  ) async {
    final bridge = _TelemetryBridge();
    await _pump(tester, bridge, const Size(820, 560), 1);
    await tester.tap(find.byKey(const ValueKey('vpn-response-compact')));
    await tester.pumpAndSettle();
    final explanation = find.byKey(const ValueKey('vpn-response-explanation'));
    expect(explanation, findsOneWidget);
    expect(
      find.descendant(of: explanation, matching: find.textContaining('83 мс')),
      findsNothing,
    );
    bridge.connected = false;
    bridge.snapshot = const VpnResponseSnapshot();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byKey(const ValueKey('vpn-response-compact')), findsNothing);
    expect(explanation, findsOneWidget);
    expect(
      find.descendant(of: explanation, matching: find.textContaining('83 мс')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
