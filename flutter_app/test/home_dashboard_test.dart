import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _HomeBridge extends MockCoreBridge {
  bool connected = false;
  bool failStatus = false;
  bool failStart = false;
  bool failSources = false;
  bool error = false;
  String activeSource = 'personal';
  int toggles = 0;
  Completer<List<VpnSourceInfo>>? pendingSources;

  @override
  Future<void> ensureStarted() async {
    if (failStart) throw StateError('Ядро недоступно');
  }

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
  };

  @override
  Future<CoreStatus> status() async {
    if (failStatus) throw StateError('Ядро недоступно');
    return (await super.status()).copyWith(
      connected: connected,
      running: connected,
      hasError: error,
      error: error ? 'Не удалось подключиться к серверу' : '',
    );
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    toggles++;
    connected = value;
    return super.setConnected(value);
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async {
    if (failSources) throw StateError('Источник недоступен');
    if (pendingSources != null) return pendingSources!.future;
    return [
      for (final id in ['personal', 'public'])
        VpnSourceInfo.fromJson({
          'id': id,
          'name': id == 'personal' ? 'Моя подписка' : 'Публичный каталог',
          'kind': 'subscription',
          'selected_node': 0,
          'node_count': 1,
          'node_names': ['Сервер 1'],
          'active': id == activeSource && connected,
          'public_catalog_id': id == 'public' ? 'catalog' : '',
        }),
    ];
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  _HomeBridge bridge, {
  Size size = const Size(1120, 800),
  double scale = 1,
  GlobalKey? capture,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF36D399),
          brightness: Brightness.dark,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: capture,
        child: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
    if (const bool.fromEnvironment('DROPO_UI_CAPTURE')) {
      await (FontLoader(
        'Inter',
      )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets(
    'home separates saved source from active session and retains actions',
    (tester) async {
      final bridge = _HomeBridge();
      await bridge.saveSubscription('https://example.test/private-token');
      await _pumpHome(tester, bridge);
      expect(find.text('Отключено'), findsOneWidget);
      expect(find.textContaining('первый по приоритету'), findsOneWidget);
      expect(find.textContaining('используется сейчас'), findsNothing);
      expect(find.textContaining('private-token'), findsNothing);
      expect(find.text('Стратегии обхода'), findsNothing);
      expect(find.text('Рабочие сети не добавлены'), findsNothing);
      await _tap(tester, 'home-connect');
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(bridge.toggles, 1);
      expect(find.text('Подключено'), findsOneWidget);
      expect(
        find.textContaining('Доступность сервисов проверяется отдельно'),
        findsOneWidget,
      );
      await _tap(tester, 'home-diagnostics');
      expect(find.text('Копировать всё'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source editor remains reachable from the new home', (
    tester,
  ) async {
    await _pumpHome(tester, _HomeBridge());
    await _tap(tester, 'home-manage-sources');
    expect(find.byType(VpnSourcesDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup core error retains an actionable explanation', (
    tester,
  ) async {
    await _pumpHome(tester, _HomeBridge()..error = true);
    expect(find.text('Не удалось подключиться к серверу'), findsOneWidget);
    expect(find.text('Подключено'), findsNothing);
    expect(find.byKey(const ValueKey('home-diagnostics')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'missing active source never presents the first subscription as live',
    (tester) async {
      await _pumpHome(
        tester,
        _HomeBridge()
          ..connected = true
          ..activeSource = '',
      );
      expect(find.text('VPN-источник не подтверждён'), findsOneWidget);
      expect(find.textContaining('используется сейчас'), findsNothing);
      expect(find.text('Моя подписка'), findsNothing);
    },
  );

  testWidgets(
    'source fetch timeout is optional and does not hold the ready gate',
    (tester) async {
      final bridge = _HomeBridge()
        ..pendingSources = Completer<List<VpnSourceInfo>>();
      await _pumpHome(tester, bridge);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('home-connect')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Отключено'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('Источник не подтверждён'), findsOneWidget);
      expect(find.text('Нет связи с ядром'), findsNothing);
      bridge.pendingSources!.complete([]);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offline state suppresses stale active source and offers retry', (
    tester,
  ) async {
    final bridge = _HomeBridge()..connected = true;
    await _pumpHome(tester, bridge);
    expect(find.textContaining('используется сейчас'), findsOneWidget);
    bridge.failStatus = true;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    }
    expect(find.text('Нет связи с ядром'), findsOneWidget);
    expect(find.textContaining('используется сейчас'), findsNothing);
    expect(find.byKey(const ValueKey('home-retry-core')), findsOneWidget);
    bridge.failStatus = false;
    await _tap(tester, 'home-retry-core');
    expect(find.text('Подключено'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public fallback is clearly labelled and cleared after stop', (
    tester,
  ) async {
    final bridge = _HomeBridge()
      ..connected = true
      ..activeSource = 'public';
    await _pumpHome(tester, bridge);
    expect(find.text('Используется бесплатный резерв'), findsOneWidget);
    bridge.connected = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Используется бесплатный резерв'), findsNothing);
    expect(find.textContaining('используется сейчас'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard can activate the connection button', (tester) async {
    final bridge = _HomeBridge();
    await _pumpHome(tester, bridge);
    var focused = false;
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context != null &&
          context.findAncestorWidgetOfExactType<FilledButton>()?.key ==
              const ValueKey('home-connect')) {
        focused = true;
        break;
      }
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.toggles, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Atlas retains advanced navigation in Settings', (tester) async {
    await _pumpHome(tester, _HomeBridge());
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Профили'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-work-networks')), findsOneWidget);
    expect(find.text('Статистика'), findsOneWidget);
    expect(find.text('Выход'), findsOneWidget);
    expect(find.text('Atlas'), findsOneWidget);
    await _tap(tester, 'nav-home');
    expect(find.byKey(const ValueKey('home-connect')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mobile in [false, true]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'home layout ${mobile ? 'mobile' : 'desktop'} at $scale text scale',
        (tester) async {
          debugMobileShellOverride = mobile;
          addTearDown(() => debugMobileShellOverride = null);
          await _pumpHome(
            tester,
            _HomeBridge(),
            size: mobile ? const Size(390, 844) : const Size(960, 640),
            scale: scale,
          );
          expect(tester.takeException(), isNull);
          await _tap(tester, 'toggle-home-route-services');
          if (!mobile) await _tap(tester, 'toggle-home-route-services');
          expect(tester.takeException(), isNull);
          await _tap(tester, 'add-home-route-service');
          expect(find.text('Добавить сервис на главную'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('render isolated home states when explicitly requested', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    for (final state in [
      'connected',
      'disconnected',
      'error',
      'public',
      'compact',
      'large-text',
      'all-vpn',
      'zapret',
    ]) {
      final bridge = _HomeBridge()
        ..connected = state != 'disconnected' && state != 'error'
        ..error = state == 'error'
        ..activeSource = state == 'public' ? 'public' : 'personal';
      if (state == 'all-vpn') await bridge.setRoutingMode('all_traffic');
      if (state == 'zapret') {
        await bridge.setFreeAccessServiceMethod('youtube', 'zapret');
      }
      final key = GlobalKey();
      await _pumpHome(
        tester,
        bridge,
        capture: key,
        size: state == 'compact' || state == 'large-text'
            ? const Size(960, 640)
            : const Size(1484, 1016),
        scale: state == 'large-text' ? 2 : 1,
      );
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage('assets/atlas-earth.png'),
          key.currentContext!,
        );
      });
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ui-review').create(recursive: true);
        await File(
          'build/ui-review/home-$state.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
