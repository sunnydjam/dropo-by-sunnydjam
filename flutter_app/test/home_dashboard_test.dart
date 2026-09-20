import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'navigation_helpers.dart';

class _HomeBridge extends MockCoreBridge {
  bool connected = false;
  bool failStatus = false;
  bool failStart = false;
  bool failSources = false;
  bool failSettingsSave = false;
  bool error = false;
  String activeSource = 'personal';
  int toggles = 0;
  int policyWrites = 0;
  Completer<List<VpnSourceInfo>>? pendingSources;
  Completer<void>? pendingConnection;

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
  Future<Map<String, dynamic>> saveAppConfig(AppConfig config) async {
    if (failSettingsSave) throw StateError('Тест: настройки не сохранены');
    return super.saveAppConfig(config);
  }

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
    if (pendingConnection != null) await pendingConnection!.future;
    connected = value;
    return super.setConnected(value);
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    policyWrites++;
    return super.setFreeAccessServiceMethod(tag, method);
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

class _PolicyContractBridge extends _HomeBridge {
  _PolicyContractBridge(this.mobile);
  final bool mobile;
  String savedPolicy = 'auto';

  @override
  Future<List<RouteService>> routes({bool live = false}) async => [
    for (final route in await super.routes(live: live))
      if (route.tag == 'youtube')
        route.copyWith(selectedMethod: savedPolicy, zapretSupported: true)
      else
        route,
  ];

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    policyWrites++;
    savedPolicy = method == 'auto' && !mobile ? 'direct' : method;
    return {'success': true, 'method': savedPolicy};
  }
}

Future<void> _pumpHome(
  WidgetTester tester,
  _HomeBridge bridge, {
  Size size = const Size(1120, 800),
  double scale = 1,
  GlobalKey? capture,
  bool motion = false,
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
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: !motion,
        ),
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
  if (key.startsWith('nav-')) {
    await openSection(tester, key.substring(4));
    return;
  }
  final finder = find.byKey(ValueKey(key));
  if (key.startsWith('nav-') && finder.evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('toggle-navigation')));
    await tester.pump();
  }
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
    // Compact-layout geometry must use the shipped font, not Ahem's square
    // test glyphs, even when screenshots are not being captured.
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
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
        find.byTooltip('Доступность сервисов проверяется отдельно.'),
        findsOneWidget,
      );
      await _tap(tester, 'nav-logs');
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
    expect(find.byKey(const ValueKey('nav-settings')), findsOneWidget);
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
    await _tap(tester, 'nav-settings');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Профили'), findsNothing);
    expect(find.text('Дополнительно'), findsOneWidget);
    await _tap(tester, 'nav-advanced');
    expect(find.text('Профили'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-work')), findsOneWidget);
    await _tap(tester, 'nav-help');
    expect(find.text('Статистика'), findsOneWidget);
    expect(find.text('Выход'), findsOneWidget);
    expect(find.text('О приложении'), findsOneWidget);
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
          await _tap(tester, 'nav-service-settings');
          await _tap(tester, 'toggle-home-route-services');
          await _tap(tester, 'toggle-home-route-services');
          expect(tester.takeException(), isNull);
          await _tap(tester, 'add-home-route-service');
          expect(find.text('Добавить сервис'), findsWidgets);
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

  for (final size in [
    const Size(700, 500),
    const Size(684, 461),
    const Size(390, 844),
    const Size(320, 568),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'compact shell ${size.width}x${size.height} at $scale remains usable',
        (tester) async {
          await _pumpHome(tester, _HomeBridge(), size: size, scale: scale);
          final connect = find.byKey(const ValueKey('home-connect'));
          if (scale == 1) {
            expect(
              tester.getRect(connect).bottom,
              lessThanOrEqualTo(size.height),
              reason: 'Primary action must be in the first viewport',
            );
          }
          await _tap(tester, 'toggle-navigation');
          expect(
            find.byKey(const ValueKey('navigation-drawer')),
            findsOneWidget,
          );
          await _tap(tester, 'nav-services');
          expect(find.byType(ServiceRoutesPage), findsOneWidget);
          expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
          await _tap(tester, 'nav-home');
          await _tap(tester, 'home-routing-all-vpn');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    '700x500 keeps planet, modes and service entry on screen without dropdowns',
    (tester) async {
      await _pumpHome(tester, _HomeBridge(), size: const Size(700, 500));
      for (final key in [
        'atlas-planet',
        'home-connect',
        'home-routing-selected',
        'home-routing-all-vpn',
        'nav-service-settings',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(
          rect.bottom,
          lessThanOrEqualTo(500),
          reason: '$key must fit the compact first viewport',
        );
        expect(rect.right, lessThanOrEqualTo(700));
      }
      expect(find.byType(DropdownButton<String>), findsNothing);
      final before = tester.getRect(find.byKey(const ValueKey('home-connect')));
      await _tap(tester, 'toggle-navigation');
      expect(
        tester.getRect(find.byKey(const ValueKey('home-connect'))),
        before,
        reason: 'Drawer overlays; it must not reflow content',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'navigation-toggle',
      );
    },
  );

  testWidgets(
    'mouse hover does not interrupt the screen; click and outside tap work',
    (tester) async {
      await _pumpHome(tester, _HomeBridge(), size: const Size(700, 500));
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(600, 480));
      await mouse.moveTo(const Offset(26, 100));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
      await mouse.moveTo(const Offset(600, 480));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
      await _tap(tester, 'toggle-navigation');
      await tester.tapAt(const Offset(600, 480));
      await tester.pump();
      expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(700, 500), const Size(390, 844)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'connection action stays centred on planet at $size / $scale',
        (tester) async {
          final bridge = _HomeBridge();
          await bridge.saveSubscription('https://example.test/subscription');
          await _pumpHome(tester, bridge, size: size, scale: scale);
          void expectCentred() {
            final planet = tester.getRect(
              find.byKey(const ValueKey('atlas-planet')),
            );
            final action = tester.getRect(
              find.byKey(const ValueKey('home-connect')),
            );
            final status = tester.getRect(
              find.byKey(const ValueKey('home-connection-state')),
            );
            expect((action.center - planet.center).distance, lessThan(0.1));
            expect(action.height, greaterThanOrEqualTo(48));
            expect(action.left, greaterThanOrEqualTo(planet.left));
            expect(action.right, lessThanOrEqualTo(planet.right));
            expect(action.bottom, lessThanOrEqualTo(planet.bottom));
            expect(status.bottom, lessThan(planet.top));
            expect(tester.takeException(), isNull);
          }

          expectCentred();
          expect(find.text('Подключить'), findsOneWidget);
          await _tap(tester, 'home-connect');
          await tester.pump(const Duration(seconds: 2));
          await tester.pump();
          expect(bridge.toggles, 1);
          expect(find.text('Подключено'), findsOneWidget);
          expect(find.text('Отключить'), findsOneWidget);
          expectCentred();
          await _tap(tester, 'home-connect');
          await tester.pump(const Duration(seconds: 2));
          await tester.pump();
          expect(bridge.toggles, 2);
          expect(find.text('Отключено'), findsOneWidget);
          expectCentred();
        },
      );
    }
  }

  testWidgets('planet action cannot submit a second connection while busy', (
    tester,
  ) async {
    final bridge = _HomeBridge()..pendingConnection = Completer<void>();
    await bridge.saveSubscription('https://example.test/subscription');
    await _pumpHome(tester, bridge, size: const Size(700, 500));
    await _tap(tester, 'home-connect');
    final action = find.byKey(const ValueKey('home-connect'));
    expect(bridge.toggles, 1);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(
      find.descendant(
        of: action,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await tester.tap(action);
    await tester.pump();
    expect(bridge.toggles, 1);
    bridge.pendingConnection!.complete();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
    expect(find.text('Отключить'), findsOneWidget);
  });

  testWidgets('compact dropdown has a touch target and persists a route', (
    tester,
  ) async {
    final bridge = _HomeBridge();
    await bridge.saveSubscription('https://example.test/subscription');
    await _pumpHome(tester, bridge, size: const Size(700, 500));
    await _tap(tester, 'nav-service-settings');
    final dropdown = find.byKey(const ValueKey('home-route-policy-openai-vpn'));
    expect(tester.getSize(dropdown).height, greaterThanOrEqualTo(48));
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('home-route-openai-direct')).last,
    );
    await tester.pumpAndSettle();
    expect(bridge.policyWrites, 1);
    expect(
      find.byKey(const ValueKey('home-route-policy-openai-direct')),
      findsOneWidget,
    );
    await _tap(tester, 'toggle-home-route-services');
    expect(find.byType(DropdownButton<String>), findsNothing);
    await _tap(tester, 'toggle-home-route-services');
    await _tap(tester, 'add-home-route-service');
    expect(find.byKey(const ValueKey('add-home-route-google')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mobile in [false, true]) {
    testWidgets(
      'route choices match the ${mobile ? 'Android' : 'Windows'} API contract',
      (tester) async {
        debugMobileShellOverride = mobile;
        addTearDown(() => debugMobileShellOverride = null);
        final bridge = _PolicyContractBridge(mobile);
        await _pumpHome(tester, bridge, size: const Size(700, 500));
        await _tap(tester, 'nav-service-settings');
        final policy = mobile ? 'auto' : 'direct';
        final dropdown = tester.widget<DropdownButton<String>>(
          find.byKey(ValueKey('home-route-policy-youtube-$policy')),
        );
        expect(
          dropdown.items!.map((item) => item.value).toList(),
          mobile ? ['auto', 'direct', 'vpn'] : ['direct', 'vpn', 'zapret'],
        );
        expect(dropdown.value, policy);
        expect(
          bridge.policyWrites,
          0,
          reason: 'Navigation never rewrites saved routes',
        );
        await tester.tap(
          find.byKey(ValueKey('home-route-policy-youtube-$policy')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('home-route-youtube-vpn')).last,
        );
        await tester.pumpAndSettle();
        expect(bridge.policyWrites, 1);
        expect(
          find.byKey(const ValueKey('home-route-policy-youtube-vpn')),
          findsOneWidget,
        );
        await _tap(tester, 'nav-home');
        await _tap(tester, 'nav-service-settings');
        expect(
          find.byKey(const ValueKey('home-route-policy-youtube-vpn')),
          findsOneWidget,
        );
        expect(bridge.policyWrites, 1);
      },
    );
  }

  testWidgets('Android drawer preserves Space and connected route guards', (
    tester,
  ) async {
    debugMobileShellOverride = true;
    addTearDown(() => debugMobileShellOverride = null);
    final bridge = _HomeBridge()..connected = true;
    await bridge.saveSubscription('https://example.test/subscription');
    await _pumpHome(tester, bridge, size: const Size(390, 844));
    await _tap(tester, 'nav-service-settings');
    for (final dropdown in tester.widgetList<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    )) {
      expect(dropdown.onChanged, isNull);
    }
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('home-routing-all-vpn')),
          )
          .onPressed,
      isNull,
    );
    await _tap(tester, 'nav-dropo_space');
    expect(find.byKey(const ValueKey('dropo-space-section')), findsOneWidget);
    await _tap(tester, 'toggle-navigation');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const ValueKey('navigation-drawer')), findsNothing);
    expect(find.byKey(const ValueKey('dropo-space-section')), findsOneWidget);
    expect(bridge.policyWrites, 0);
    expect(bridge.toggles, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back returns to the entry screen without changing policies', (
    tester,
  ) async {
    final bridge = _HomeBridge();
    await _pumpHome(tester, bridge, size: const Size(700, 500));
    await _tap(tester, 'nav-service-settings');
    await _tap(tester, 'section-back');
    expect(find.byKey(const ValueKey('home-connect')), findsOneWidget);
    await _tap(tester, 'nav-settings');
    await _tap(tester, 'nav-service-settings');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-section')), findsOneWidget);
    expect(bridge.policyWrites, 0);
  });

  testWidgets('simple settings recover after a transport error', (
    tester,
  ) async {
    final bridge = _HomeBridge()..failSettingsSave = true;
    await _pumpHome(tester, bridge, size: const Size(700, 500));
    await _tap(tester, 'nav-app-settings');
    final row = find.ancestor(
      of: find.text('Автозапуск'),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SwitchSetting',
      ),
    );
    final toggle = find.descendant(of: row, matching: find.byType(Switch));
    final original = tester.widget<Switch>(toggle).value;
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, original);
    expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
    expect(find.textContaining('Тест: настройки не сохранены'), findsOneWidget);
    bridge.failSettingsSave = false;
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, !original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('planet moves, freezes in background and honors reduced motion', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      _HomeBridge(),
      motion: true,
      size: const Size(700, 500),
    );
    CustomPainter? painter() => tester
        .widget<CustomPaint>(find.byKey(const ValueKey('atlas-planet-motion')))
        .foregroundPainter;
    final first = painter();
    await tester.pump(const Duration(seconds: 1));
    final moved = painter();
    expect(moved!.shouldRepaint(first!), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 1));
    final paused = painter();
    await tester.pump(const Duration(seconds: 2));
    expect(painter()!.shouldRepaint(paused!), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(painter()!.shouldRepaint(paused), isTrue);
    await _pumpHome(
      tester,
      _HomeBridge(),
      motion: false,
      size: const Size(700, 500),
    );
    final still = painter();
    await tester.pump(const Duration(seconds: 2));
    expect(painter()!.shouldRepaint(still!), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'minimal home and settings have labelled 48px targets and readable contrast',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pumpHome(tester, _HomeBridge(), size: const Size(700, 500));
        for (final section in ['home', 'settings']) {
          if (section != 'home') await _tap(tester, 'nav-settings');
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('capture compact shell, drawer and portrait', (tester) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    const captureDir = String.fromEnvironment(
      'DROPO_UI_CAPTURE_DIR',
      defaultValue: 'build/ui-review',
    );
    for (final state in [
      'compact-700',
      'disconnected-700',
      'drawer-700',
      'settings-700',
      'services-700',
      'portrait',
      'text-200',
      'motion-a',
      'motion-b',
    ]) {
      final bridge = _HomeBridge()..connected = state != 'disconnected-700';
      await bridge.saveSubscription('https://example.test/subscription');
      for (final tag in ['youtube', 'discord', 'meta', 'openai']) {
        await bridge.setFreeAccessServiceMethod(tag, 'vpn');
      }
      final key = GlobalKey();
      await _pumpHome(
        tester,
        bridge,
        capture: key,
        size: state == 'portrait' ? const Size(390, 844) : const Size(700, 500),
        scale: state == 'text-200' ? 2 : 1,
        motion: state.startsWith('motion-'),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/atlas-earth.png'),
          key.currentContext!,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      if (state == 'drawer-700') await _tap(tester, 'toggle-navigation');
      if (state == 'settings-700') await _tap(tester, 'nav-settings');
      if (state == 'services-700') await _tap(tester, 'nav-service-settings');
      if (state == 'motion-b') await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(captureDir).create(recursive: true);
        await File(
          '$captureDir/$state.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
