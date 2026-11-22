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
  String savedRoutingMode = 'blocked_only';
  int connectionChecks = 0;
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
    'routingMode': savedRoutingMode,
  };
  @override
  Future<CoreStatus> status() async => (await super.status()).copyWith(
    connected: connected,
    running: connected,
    vpnResponse: snapshot,
  );

  @override
  Future<Map<String, dynamic>> runConnectionCheck() async {
    connectionChecks++;
    return super.runConnectionCheck();
  }
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

  test('response rejects future clock samples and the full stale boundary', () {
    final now = DateTime.utc(2026, 10, 11, 12);
    VpnResponseSnapshot measured(Duration age, {String state = 'ok'}) =>
        VpnResponseSnapshot(
          state: state,
          latencyMs: 83,
          checkedAt: now.subtract(age),
        );
    expect(
      measured(const Duration(seconds: 90)).observationAt(now),
      VpnResponseObservation.available,
    );
    expect(
      measured(const Duration(seconds: 90, microseconds: 1)).observationAt(now),
      VpnResponseObservation.stale,
    );
    final future = measured(const Duration(microseconds: -1));
    expect(future.observationAt(now), VpnResponseObservation.unavailable);
    expect(future.labelAt(now), 'Нет данных');
    expect(future.ageLabelAt(now), 'Время замера неизвестно');
    expect(
      measured(const Duration(seconds: -1), state: 'failed').observationAt(now),
      VpnResponseObservation.unavailable,
    );
    expect(
      measured(const Duration(minutes: 2), state: 'failed').observationAt(now),
      VpnResponseObservation.stale,
    );
    final timezoneSample = VpnResponseSnapshot.fromJson({
      'state': 'ok',
      'latencyMs': 83,
      'checkedAt': '2026-10-11T15:00:00+03:00',
    });
    expect(timezoneSample.observationAt(now), VpnResponseObservation.available);
  });

  test(
    'unknown disabled and missing observations cannot inherit a latency',
    () {
      final now = DateTime.utc(2026, 10, 11, 12);
      for (final state in [
        'unavailable',
        'disabled',
        'unknown',
        '',
        'offline',
      ]) {
        final snapshot = VpnResponseSnapshot(
          state: state,
          latencyMs: 999,
          checkedAt: now.subtract(const Duration(minutes: 3)),
        );
        expect(snapshot.observationAt(now), VpnResponseObservation.unavailable);
        expect(snapshot.labelAt(now), 'Нет данных');
      }
      for (final invalidTimestamp in [null, '', 'not-a-time']) {
        final snapshot = VpnResponseSnapshot.fromJson({
          'state': 'ok',
          'latencyMs': 83,
          'checkedAt': invalidTimestamp,
        });
        expect(snapshot.observationAt(now), VpnResponseObservation.unavailable);
        expect(snapshot.ageLabelAt(now), 'Замер ещё не получен');
      }
      for (final latency in [null, 0, -1]) {
        expect(
          VpnResponseSnapshot(
            state: 'ok',
            latencyMs: latency,
            checkedAt: now,
          ).observationAt(now),
          VpnResponseObservation.unavailable,
        );
      }
      expect(
        const VpnResponseSnapshot(state: 'failed').observationAt(now),
        VpnResponseObservation.failed,
      );
    },
  );

  test('pending and a new session never reuse the old measured value', () {
    final now = DateTime.utc(2026, 10, 11, 12);
    final retained = VpnResponseSnapshot(
      state: 'pending',
      latencyMs: 999,
      checkedAt: now.subtract(const Duration(minutes: 3)),
      sessionGeneration: 1,
      sourceId: 'previous-source',
    );
    expect(retained.observationAt(now), VpnResponseObservation.pending);
    expect(retained.labelAt(now), 'Проверяем…');
    final newSession = VpnResponseSnapshot.fromJson({
      'state': 'pending',
      'sessionGeneration': 2,
      'sourceId': 'new-source',
      'nodeId': 'manually-selected-node',
    });
    expect(newSession.sessionGeneration, 2);
    expect(newSession.sourceId, 'new-source');
    expect(newSession.nodeId, 'manually-selected-node');
    expect(newSession.latencyMs, isNull);
    expect(newSession.checkedAt, isNull);
    expect(newSession.labelAt(now), 'Проверяем…');
  });

  test('mode explanations never equate a probe with all routed traffic', () {
    const snapshot = VpnResponseSnapshot();
    final selective = snapshot.scopeDescription('blocked_only');
    expect(selective, contains('«По сервисам»'));
    expect(selective, contains('не описывает прямой трафик'));
    expect(selective, isNot(contains('«Всё через VPN»')));
    final full = snapshot.scopeDescription('all_traffic');
    expect(full, contains('«Всё через VPN»'));
    expect(full, contains('не проверка всех сайтов'));
    expect(full, isNot(contains('«По сервисам»')));
    final unknown = snapshot.scopeDescription('unknown-mode');
    expect(unknown, contains('только к проверяемому VPN-источнику'));
    expect(unknown, isNot(contains('«Всё через VPN»')));
    expect(unknown, isNot(contains('«По сервисам»')));
  });

  for (final (state, label, detail) in [
    ('pending', 'Проверяем…', 'Проверка в фоне'),
    ('failed', 'Нет ответа', 'Тестовый адрес'),
    ('stale', 'Данные устарели', 'Нужен свежий замер'),
    ('unavailable', 'Нет данных', 'Замер не получен'),
  ]) {
    testWidgets('$state response leaves connection controls active', (
      tester,
    ) async {
      final bridge = _TelemetryBridge()
        ..snapshot = VpnResponseSnapshot(
          state: state,
          latencyMs: 999,
          checkedAt: DateTime.now().toUtc(),
        );
      await _pump(tester, bridge, const Size(1100, 760), 1);
      final metric = find.byKey(const ValueKey('vpn-response-panel'));
      expect(metric, state == 'failed' ? findsOneWidget : findsNothing);
      if (state == 'failed') {
        expect(
          find.descendant(of: metric, matching: find.text(label)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: metric, matching: find.text(detail)),
          findsOneWidget,
        );
      }
      expect(find.text('999 мс'), findsNothing);
      final power = tester.widget<FilledButton>(
        find.byKey(const ValueKey('home-connect')),
      );
      expect(power.onPressed, isNotNull);
      expect(find.text('Отключить'), findsOneWidget);
      expect(find.text('Ошибка VPN'), findsNothing);
      expect(find.text('Подключаем…'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'response-state-$state');
      if (state == 'failed') {
        await tester.tap(metric);
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Тестовый адрес не ответил. Это не означает, что интернет не работает.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('vpn-response-details')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'подтверждает запуск VPN, но не доступность всех сайтов',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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
      expect(find.textContaining('не игровой пинг'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Отклик через VPN'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-version')));
      await tester.pumpAndSettle();
      expect(find.text('Джамуха (sunnydjam)'), findsOneWidget);
      // The account footer may show Telegram behind the modal. The About
      // content itself must not invent a developer Telegram contact.
      final aboutDialog = find.ancestor(
        of: find.text('О приложении'),
        matching: find.byType(Dialog),
      );
      expect(aboutDialog, findsOneWidget);
      expect(
        find.descendant(of: aboutDialog, matching: find.text('Telegram')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'about-${size.width.toInt()}-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('full VPN explanation uses the actual current routing mode', (
    tester,
  ) async {
    final bridge = _TelemetryBridge()..savedRoutingMode = 'all_traffic';
    await _pump(tester, bridge, const Size(820, 560), 1);
    await tester.tap(find.byKey(const ValueKey('vpn-response-compact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('vpn-response-details')));
    await tester.pumpAndSettle();
    final explanation = find.byKey(const ValueKey('vpn-response-explanation'));
    expect(
      find.descendant(
        of: explanation,
        matching: find.textContaining('В режиме «Всё через VPN»'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: explanation,
        matching: find.textContaining('В режиме «По сервисам»'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('HTTP response help entry opens help without starting probes', (
    tester,
  ) async {
    final bridge = _TelemetryBridge()
      ..snapshot = const VpnResponseSnapshot(state: 'failed');
    await _pump(tester, bridge, const Size(390, 568), 2);
    final metric = find.byKey(const ValueKey('vpn-response-compact'));
    expect(
      find.descendant(of: metric, matching: find.text('VPN · Нет ответа')),
      findsOneWidget,
    );
    await tester.tap(metric);
    await tester.pumpAndSettle();
    final help = find.byKey(const ValueKey('vpn-response-open-help'));
    await tester.ensureVisible(help);
    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('vpn-response-explanation')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('guided-help-section')), findsOneWidget);
    expect(bridge.connectionChecks, 0);
    expect(bridge.connected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disconnected hides measurement and preference saves', (
    tester,
  ) async {
    final bridge = _TelemetryBridge()..connected = false;
    await _pump(tester, bridge, const Size(820, 560), 1);
    expect(find.byKey(const ValueKey('vpn-response-compact')), findsNothing);
    await openSection(tester, 'app-settings');
    final toggle = find.byKey(
      const ValueKey('setting-switch-Анимации интерфейса'),
    );
    await tester.ensureVisible(toggle);
    await tester.pump();
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
