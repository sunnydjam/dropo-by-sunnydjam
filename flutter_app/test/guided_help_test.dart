import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _HelpBridge extends MockCoreBridge {
  int legacyChecks = 0;
  int mutations = 0;
  int diagnosticsReads = 0;

  @override
  Future<Map<String, dynamic>> runQuickCheck() async {
    legacyChecks++;
    throw StateError('Legacy check is not allowed in guided help');
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    mutations++;
    return {'success': true};
  }

  @override
  Future<String> diagnostics() async {
    diagnosticsReads++;
    return 'private://sensitive-user-input';
  }
}

CoreStatus _status({
  bool connected = true,
  String state = 'connected',
  String version = '3.0.44-preview',
}) => CoreStatus.fromJson({
  'connected': connected,
  'running': connected,
  'vpnState': state,
  'hasError': false,
  'error': 'private-error-vless://user@203.0.113.10',
  'serviceMessage': 'private service https://secret.test/sub/token',
  'networkModeDescription': 'private path C:/Users/test/config.json',
  'version': {
    'version': version,
    'fullVersion': 'private-build-information',
    'singboxVersion': 'private-kernel-value',
  },
});

Map<String, dynamic> _checks({
  int total = 2,
  int answered = 2,
  bool valid = true,
  bool verified = false,
  DateTime? at,
}) => {
  'success': answered == total,
  'total': 9999999,
  'okCount': -10,
  'failedCount': 987654321,
  'sessionValid': valid,
  'checkedAt': (at ?? DateTime.now()).toUtc().toIso8601String(),
  'error': 'https://private.test/subscription/private-token',
  'output': 'private raw logs',
  'services': [
    for (var i = 0; i < total; i++)
      {
        'serviceTag': 'private-service-tag-$i',
        'name': 'private-service-name',
        'url': 'https://private.test/$i',
        'success': i < answered,
        'expectedRoute': 'private-route-value',
        'error': 'private-source: vless://token@203.0.113.10:443',
        'routeVerified': verified,
        'latencyMs': 69,
      },
  ],
};

Future<void> _pumpHelp(
  WidgetTester tester, {
  required _HelpBridge bridge,
  CoreStatus? status,
  String mode = 'all_traffic',
  List<RouteService> routes = const [],
  bool routesAreLive = false,
  bool coreAvailable = true,
  Future<Map<String, dynamic>> Function()? check,
  VoidCallback? home,
  VoidCallback? sources,
  VoidCallback? services,
  VoidCallback? updates,
  VoidCallback? diagnostics,
  Size size = const Size(800, 900),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('guided-help-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Inter'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: guidedHelpPageForTest(
            bridge: bridge,
            status: status ?? _status(),
            routingMode: mode,
            routes: routes,
            routesAreLive: routesAreLive,
            coreAvailable: coreAvailable,
            onCheckConnection: check,
            onGoHome: home,
            onOpenSources: sources,
            onOpenServices: services,
            onOpenUpdates: updates,
            onOpenDiagnostics: diagnostics,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _choose(WidgetTester tester, String code) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const ValueKey('guided-help-page')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  final target = find.byKey(ValueKey('guided-help-scenario-$code'));
  await tester.scrollUntilVisible(target, 200, scrollable: scrollable);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Future<void> _run(WidgetTester tester) async {
  final target = find.byKey(const ValueKey('guided-help-check'));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['DROPO_GUIDED_HELP_CAPTURE_DIR'];
  if (output == null || output.isEmpty) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('guided-help-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    if (Platform.isWindows &&
        Platform.environment['DROPO_GUIDED_HELP_CAPTURE_DIR'] != null) {
      await (FontLoader('monospace')..addFont(
            File(
              'C:/Windows/Fonts/consola.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  tearDown(() {
    debugAndroidPlatformOverride = null;
    debugMobileShellOverride = null;
  });

  test('support summary is constructed from an allowlist, not raw text', () {
    debugAndroidPlatformOverride = true;
    final report = ConnectionHealthReport.fromJson(_checks(answered: 1));
    final text = buildSafeSupportReport(
      status: _status(),
      routingMode: 'all_traffic',
      report: report,
      scenario: GuidedHelpScenario.serviceUnavailable,
    );
    expect(text, contains('version: 3.0.44-preview'));
    expect(text, contains('platform: android'));
    expect(text, contains('scenario: service_unavailable'));
    expect(text, contains('checks_total: 2'));
    expect(text, contains('checks_responded: 1'));
    expect(text, contains('checks_not_responded: 1'));
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('203.0.113.10')));
    expect(text, isNot(contains('vless://')));
    expect(text, isNot(contains('https://')));
    expect(text, isNot(contains('9999999')));
    expect(text, isNot(contains('987654321')));
  });

  test('arbitrary version, routing and runtime strings never enter report', () {
    final text = buildSafeSupportReport(
      status: _status(
        version: '3.0.44\nhttps://secret.test/token',
        state: 'private-runtime://user@host',
      ),
      routingMode: 'private-mode',
    );
    expect(text, contains('version: unknown'));
    expect(text, contains('mode: unknown'));
    expect(text, contains('runtime: unknown'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('private')));
  });

  test('disconnected, invalid, old or future checks are not exported', () {
    for (final setup in [
      (_status(connected: false, state: 'stopped'), _checks()),
      (_status(state: 'reconnecting'), _checks()),
      (_status(), _checks(valid: false)),
      (
        _status(),
        _checks(at: DateTime.now().subtract(const Duration(minutes: 2))),
      ),
      (_status(), _checks(at: DateTime.now().add(const Duration(minutes: 1)))),
    ]) {
      final text = buildSafeSupportReport(
        status: setup.$1,
        routingMode: 'blocked_only',
        report: ConnectionHealthReport.fromJson(setup.$2),
      );
      expect(text, contains('checks_available: false'));
      expect(text, contains('checks_total: 0'));
    }
  });

  test('unobserved core report never presents retained flags as live', () {
    final text = buildSafeSupportReport(
      status: _status(),
      routingMode: 'all_traffic',
      coreAvailable: false,
      report: ConnectionHealthReport.fromJson(_checks()),
    );
    expect(text, contains('core_observed: false'));
    expect(text, contains('runtime: unknown'));
    expect(text, contains('connected: unknown'));
    expect(text, contains('checks_available: false'));
  });

  testWidgets('opening help and choosing scenarios never starts a probe', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    var checks = 0;
    await _pumpHelp(
      tester,
      bridge: bridge,
      check: () async {
        checks++;
        return _checks();
      },
    );
    expect(find.text('Нет интернета'), findsOneWidget);
    expect(find.text('Не открывается сервис'), findsOneWidget);
    expect(find.text('Не получается обновиться'), findsOneWidget);
    await _choose(tester, 'no_internet');
    await _choose(tester, 'service_unavailable');
    await _choose(tester, 'update_unavailable');
    expect(checks, 0);
    expect(bridge.legacyChecks, 0);
    expect(bridge.mutations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disconnected help offers Home and does not run checks', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    var wentHome = false;
    var checks = 0;
    await _pumpHelp(
      tester,
      bridge: bridge,
      status: _status(connected: false, state: 'stopped'),
      home: () => wentHome = true,
      check: () async {
        checks++;
        return _checks();
      },
    );
    await _choose(tester, 'no_internet');
    expect(find.byKey(const ValueKey('guided-help-check')), findsNothing);
    final action = find.byKey(const ValueKey('guided-help-home'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    expect(wentHome, isTrue);
    expect(checks, 0);
  });

  testWidgets('single endpoint failure is not described as VPN-wide failure', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    var sourceOpened = false;
    await _pumpHelp(
      tester,
      bridge: bridge,
      check: () async => _checks(answered: 1),
      sources: () => sourceOpened = true,
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(find.text('Часть адресов не ответила'), findsOneWidget);
    expect(find.text('Ответили адреса: 1 из 2.'), findsOneWidget);
    expect(find.textContaining('не означает, что весь VPN'), findsOneWidget);
    expect(find.textContaining('203.0.113.10'), findsNothing);
    expect(find.textContaining('private'), findsNothing);
    final action = find.byKey(const ValueKey('guided-help-next'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    expect(sourceOpened, isTrue);
    expect(bridge.legacyChecks, 0);
    expect(bridge.mutations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('HTTP successes never claim every service or VPN privacy works', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    await _pumpHelp(tester, bridge: bridge, check: () async => _checks());
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(find.text('Проверенные адреса отвечают'), findsOneWidget);
    expect(find.textContaining('не проверка входа'), findsOneWidget);
    expect(find.textContaining('не скорость или игровой'), findsOneWidget);
    expect(
      find.textContaining('не подтверждает путь через VPN'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selective service help offers existing Home service controls', (
    tester,
  ) async {
    var opened = false;
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      mode: 'blocked_only',
      services: () => opened = true,
    );
    await _choose(tester, 'service_unavailable');
    expect(find.text('Посмотреть маршруты сервисов'), findsOneWidget);
    final action = find.byKey(const ValueKey('guided-help-next'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    expect(opened, isTrue);
  });

  testWidgets(
    'full VPN service help does not expose selective service action',
    (tester) async {
      await _pumpHelp(tester, bridge: _HelpBridge(), services: () {});
      await _choose(tester, 'service_unavailable');
      expect(find.text('Посмотреть маршруты сервисов'), findsNothing);
      expect(find.text('Посмотреть источники'), findsOneWidget);
    },
  );

  testWidgets('updates help opens settings only by explicit action', (
    tester,
  ) async {
    debugAndroidPlatformOverride = true;
    var opened = false;
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      updates: () => opened = true,
    );
    await _choose(tester, 'update_unavailable');
    expect(opened, isFalse);
    expect(find.textContaining('Preview и обычный выпуск'), findsOneWidget);
    expect(find.byKey(const ValueKey('guided-help-check')), findsNothing);
    final action = find.byKey(const ValueKey('guided-help-updates'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    expect(opened, isTrue);
  });

  testWidgets('route changes discard a pending result', (tester) async {
    final bridge = _HelpBridge();
    final future = Completer<Map<String, dynamic>>();
    Future<Map<String, dynamic>> check() => future.future;
    await _pumpHelp(tester, bridge: bridge, check: check);
    await _choose(tester, 'no_internet');
    await _run(tester);
    await _pumpHelp(tester, bridge: bridge, mode: 'blocked_only', check: check);
    future.complete(_checks());
    await tester.pump();
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    expect(
      find.textContaining('Подключение или маршруты изменились'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unavailable core is unknown rather than disconnected or healthy',
    (tester) async {
      var checks = 0;
      await _pumpHelp(
        tester,
        bridge: _HelpBridge(),
        coreAvailable: false,
        check: () async {
          checks++;
          return _checks();
        },
      );
      await _choose(tester, 'no_internet');
      expect(
        find.text('Не удалось получить состояние подключения'),
        findsOneWidget,
      );
      expect(find.text('Нет активного подключения Dropo'), findsNothing);
      expect(find.byKey(const ValueKey('guided-help-check')), findsNothing);
      expect(checks, 0);
    },
  );

  testWidgets('new source session generation discards old completed report', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    await _pumpHelp(
      tester,
      bridge: bridge,
      status: _status().copyWith(
        vpnResponse: const VpnResponseSnapshot(sessionGeneration: 7),
      ),
      check: () async => _checks(),
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(find.text('Проверенные адреса отвечают'), findsOneWidget);
    await _pumpHelp(
      tester,
      bridge: bridge,
      status: _status().copyWith(
        vpnResponse: const VpnResponseSnapshot(sessionGeneration: 8),
      ),
      check: () async => _checks(),
    );
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reconnecting state invalidates a previous successful result', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    await _pumpHelp(tester, bridge: bridge, check: () async => _checks());
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(find.text('Проверенные адреса отвечают'), findsOneWidget);
    await _pumpHelp(
      tester,
      bridge: bridge,
      status: _status(state: 'reconnecting'),
    );
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    expect(find.text('Подключение сейчас меняется'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('invalid session and old or future result are rejected', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    for (final payload in [
      _checks(valid: false),
      _checks(at: DateTime.now().subtract(const Duration(minutes: 2))),
      _checks(at: DateTime.now().add(const Duration(minutes: 1))),
      {..._checks(), 'checkedAt': null},
    ]) {
      await _pumpHelp(tester, bridge: bridge, check: () async => payload);
      await _choose(tester, 'no_internet');
      await _run(tester);
      expect(find.text('Проверенные адреса отвечают'), findsNothing);
      expect(find.textContaining('Результат устарел'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'scenario change fences pending check and avoids duplicate probes',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      var starts = 0;
      await _pumpHelp(
        tester,
        bridge: _HelpBridge(),
        check: () {
          starts++;
          return pending.future;
        },
      );
      await _choose(tester, 'no_internet');
      await _run(tester);
      await _choose(tester, 'service_unavailable');
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('guided-help-check')),
      );
      expect(button.onPressed, isNull);
      pending.complete(_checks());
      await tester.pump();
      expect(find.text('Проверенные адреса отвечают'), findsNothing);
      expect(starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('timeout is bounded and late report cannot replace timeout', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    var starts = 0;
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      check: () {
        starts++;
        return pending.future;
      },
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    await tester.pump(const Duration(seconds: 56));
    expect(find.textContaining('за 55 секунд'), findsOneWidget);
    expect(
      find.textContaining('Предыдущая проверка ещё завершается'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('guided-help-check')))
          .onPressed,
      isNull,
    );
    pending.complete(_checks());
    await tester.pump();
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    expect(starts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing help fences completion and native error strings', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    await _pumpHelp(tester, bridge: _HelpBridge(), check: () => pending.future);
    await _choose(tester, 'no_internet');
    await _run(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('private-token https://secret.test'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native failure is explained without rendering raw errors', (
    tester,
  ) async {
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      check: () async {
        throw StateError('private-token https://secret.test');
      },
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(
      find.textContaining('Не удалось получить результат'),
      findsOneWidget,
    );
    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets('report preview never copies without explicit confirmation', (
    tester,
  ) async {
    final bridge = _HelpBridge();
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pumpHelp(tester, bridge: bridge);
    final preview = find.byKey(const ValueKey('guided-help-report'));
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('safe-support-preview')), findsOneWidget);
    expect(copied, isEmpty);
    await tester.tap(find.byKey(const ValueKey('safe-support-copy')));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, contains('Dropo support summary v1'));
    expect(copied.single, isNot(contains('private')));
    expect(bridge.diagnosticsReads, 0);
    expect(bridge.mutations, 0);
    expect(find.text('Скопировано'), findsOneWidget);
  });

  testWidgets('result expires instead of implying permanent health', (
    tester,
  ) async {
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      check: () async => _checks(),
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    await tester.pump(const Duration(seconds: 91));
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    expect(find.textContaining('Результат устарел'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('result freshness is relative to checkedAt, not receipt', (
    tester,
  ) async {
    await _pumpHelp(
      tester,
      bridge: _HelpBridge(),
      check: () async =>
          _checks(at: DateTime.now().subtract(const Duration(seconds: 80))),
    );
    await _choose(tester, 'no_internet');
    await _run(tester);
    expect(find.text('Проверенные адреса отвечают'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('Проверенные адреса отвечают'), findsNothing);
    expect(find.textContaining('Результат устарел'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('all scenarios and preview fit 320px at text scale $scale', (
      tester,
    ) async {
      debugAndroidPlatformOverride = true;
      final bridge = _HelpBridge();
      await _pumpHelp(
        tester,
        bridge: bridge,
        size: const Size(320, 568),
        scale: scale,
        check: () async => _checks(answered: 1),
      );
      for (final code in [
        'no_internet',
        'service_unavailable',
        'update_unavailable',
      ]) {
        await _choose(tester, code);
        final page = find.byKey(const ValueKey('guided-help-page'));
        await tester.drag(page, const Offset(0, -900));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      final preview = find.byKey(const ValueKey('guided-help-report'));
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('guided-help-page')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(preview, 200, scrollable: scrollable);
      await tester.ensureVisible(preview);
      await tester.pump();
      await tester.tap(preview);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('safe-support-copy')), findsOneWidget);
      await _capture(tester, 'help-preview-320-$scale');
    });
  }

  testWidgets(
    'phone and desktop scenario list use open rows without nested cards',
    (tester) async {
      for (final size in [const Size(390, 844), const Size(800, 900)]) {
        await _pumpHelp(tester, bridge: _HelpBridge(), size: size);
        expect(find.byType(Card), findsNothing);
        expect(find.byType(Tooltip), findsNothing);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'help-choices-${size.width.toInt()}');
      }
    },
  );
}
