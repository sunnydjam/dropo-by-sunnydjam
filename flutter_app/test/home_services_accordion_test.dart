import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ServicesBridge extends MockCoreBridge {
  bool connected = false, failWrite = false, failRead = false;
  int routeWrites = 0, disconnects = 0;
  String savedPolicy = 'auto';
  final pins = <String, bool>{};

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'routingMode': 'blocked_only',
  };

  @override
  Future<CoreStatus> status() async =>
      (await super.status()).copyWith(connected: connected, running: connected);

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    if (failRead) throw StateError('catalog offline');
    return [
      for (final tag in ['youtube', 'discord', 'meta', 'openai', 'telegram'])
        RouteService(
          tag: tag,
          name: switch (tag) {
            'youtube' => 'YouTube',
            'discord' => 'Discord',
            'telegram' => 'Telegram',
            _ => tag,
          },
          method: savedPolicy == 'vpn' ? 'VPN' : 'Прямое подключение',
          selectedMethod: tag == 'youtube' ? savedPolicy : 'auto',
          requiresVpn: tag == 'youtube' && savedPolicy == 'vpn',
          delayMs: 0,
          domainSuffixes: ['$tag.example.test'],
          homeVisible: pins[tag] ?? false,
        ),
    ];
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    routeWrites++;
    if (failWrite) return {'success': false, 'error': 'save refused'};
    savedPolicy = method;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setHomeRouteServiceVisible(
    String tag,
    bool visible,
  ) async {
    pins[tag] = visible;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (!value) disconnects++;
    connected = value;
    return super.setConnected(value);
  }
}

class _DesktopServicesBridge extends _ServicesBridge {
  final policies = <String, String>{};
  Completer<void>? pendingPolicy;
  int restarts = 0, strategyWrites = 0;
  String lastPolicyTag = '', strategyMode = 'auto', selectedStrategy = '';

  @override
  Future<List<RouteService>> routes({bool live = false}) async => [
    for (final service in await super.routes(live: live))
      service.copyWith(
        selectedMethod: policies[service.tag] ?? 'direct',
        method: policies[service.tag] == 'vpn' ? 'VPN' : 'Напрямую',
        zapretSupported: service.tag == 'youtube' || service.tag == 'discord',
        zapretStrategyMode: strategyMode,
        zapretSelectedStrategy: selectedStrategy,
        zapretEffectiveStrategyLabel: selectedStrategy == 'native-alt2'
            ? 'Встроенная ALT2'
            : 'Встроенная ALT1',
        zapretStrategyOptions: const [
          ZapretStrategyOption(tag: 'native-alt1', label: 'Встроенная ALT1'),
          ZapretStrategyOption(tag: 'native-alt2', label: 'Встроенная ALT2'),
        ],
      ),
  ];

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    lastPolicyTag = tag;
    if (pendingPolicy != null) await pendingPolicy!.future;
    routeWrites++;
    if (failWrite) return {'success': false, 'error': 'save refused'};
    policies[tag] = method;
    if (connected) restarts++;
    return {'success': true, 'restarted': connected};
  }

  @override
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  ) async {
    strategyWrites++;
    strategyMode = mode;
    selectedStrategy = mode == 'manual' ? strategyTag : '';
    if (connected) restarts++;
    return {'success': true, 'restarted': connected};
  }
}

Future<void> _pump(
  WidgetTester tester,
  _ServicesBridge bridge, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
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
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) =>
    _tap(tester, 'toggle-home-route-services');

Future<void> _search(WidgetTester tester, String query) async {
  final input = find.byKey(const ValueKey('service-search'));
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  await tester.enterText(input, query);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await preloadAtlasPlanetForTesting();
  });

  setUp(() => debugMobileShellOverride = true);
  tearDown(() => debugMobileShellOverride = null);

  testWidgets('home disclosure uses quick rows and searches the full catalog', (
    tester,
  ) async {
    final bridge = _ServicesBridge();
    await _pump(tester, bridge);
    expect(find.byKey(const ValueKey('service-search')), findsNothing);
    expect(find.byKey(const ValueKey('nav-services')), findsNothing);
    await _open(tester);
    expect(find.text('Быстрые 4'), findsOneWidget);
    expect(find.text('Все 5'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-service-row-youtube')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-service-row-telegram')),
      findsNothing,
    );
    await _search(tester, 'TELEGRAM.EXAMPLE');
    expect(
      find.byKey(const ValueKey('home-service-row-telegram')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-service-row-youtube')),
      findsNothing,
    );
    await _tap(tester, 'home-service-row-telegram');
    await _tap(tester, 'service-domains-telegram');
    expect(find.text('telegram.example.test'), findsOneWidget);
    await _tap(tester, 'pin-service-telegram');
    expect(bridge.pins['telegram'], true);
    expect(bridge.routeWrites, 0);
    await _search(tester, '');
    expect(find.text('Быстрые 5'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-service-row-telegram')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all-traffic mode hides services and remembers quick-list policy',
    (tester) async {
      final bridge = _ServicesBridge();
      await _pump(tester, bridge);
      await _open(tester);
      await _tap(tester, 'home-service-row-youtube');
      await _tap(tester, 'service-route-youtube-vpn');
      expect(bridge.savedPolicy, 'vpn');
      await _tap(tester, 'home-routing-all-vpn');
      expect(
        find.byKey(const ValueKey('toggle-home-route-services')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('service-search')), findsNothing);
      await _tap(tester, 'home-routing-selected');
      expect(find.byKey(const ValueKey('service-search')), findsOneWidget);
      expect(bridge.savedPolicy, 'vpn');
      expect(bridge.routeWrites, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connected Android keeps service details read-only without Stop',
    (tester) async {
      final bridge = _ServicesBridge()..connected = true;
      await _pump(tester, bridge);
      await _open(tester);
      await _tap(tester, 'home-service-row-youtube');
      final policy = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('service-route-youtube-vpn')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(policy.onPressed, isNull);
      expect(
        find.byKey(const ValueKey('home-services-read-only')),
        findsOneWidget,
      );
      await _search(tester, 'telegram');
      await _tap(tester, 'home-service-row-telegram');
      await _tap(tester, 'pin-service-telegram');
      expect(bridge.pins['telegram'], true);
      expect(bridge.routeWrites, 0);
      expect(bridge.disconnects, 0);
      expect(bridge.connected, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed route write preserves policy and releases editing lock', (
    tester,
  ) async {
    final bridge = _ServicesBridge()..failWrite = true;
    await _pump(tester, bridge);
    await _open(tester);
    await _tap(tester, 'home-service-row-youtube');
    await _tap(tester, 'service-route-youtube-vpn');
    expect(find.textContaining('save refused'), findsOneWidget);
    expect(bridge.savedPolicy, 'auto');
    bridge.failWrite = false;
    await _tap(tester, 'service-route-youtube-vpn');
    expect(bridge.savedPolicy, 'vpn');
    expect(bridge.routeWrites, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow enlarged text keeps one scroll and no clipped controls', (
    tester,
  ) async {
    await _pump(
      tester,
      _ServicesBridge(),
      size: const Size(320, 568),
      scale: 2,
    );
    await _open(tester);
    await _tap(tester, 'services-all');
    await _search(tester, 'discord');
    await _tap(tester, 'home-service-row-discord');
    await _tap(tester, 'service-route-discord-direct');
    expect(tester.takeException(), isNull);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('home-service-details-discord')),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
  });

  testWidgets('disclosure preserves the planet position and size', (
    tester,
  ) async {
    await _pump(tester, _ServicesBridge());
    final disclosure = find.byKey(const ValueKey('toggle-home-route-services'));
    await tester.ensureVisible(disclosure);
    await tester.pumpAndSettle();
    final planet = find.byKey(const ValueKey('atlas-planet'));
    final before = tester.getRect(planet);
    await tester.tap(disclosure);
    await tester.pumpAndSettle();
    expect(tester.getRect(planet), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard and enlarged text keep search and actions reachable', (
    tester,
  ) async {
    await _pump(
      tester,
      _ServicesBridge(),
      size: const Size(320, 568),
      scale: 2,
    );
    await _open(tester);
    await _search(tester, 'telegram');
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await _tap(tester, 'home-service-row-telegram');
    await _tap(tester, 'service-route-telegram-vpn');
    expect(tester.takeException(), isNull);
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('home-service-details-telegram')),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a failed catalog refresh is explicit and retry restores editing',
    (tester) async {
      final bridge = _ServicesBridge();
      await _pump(tester, bridge);
      await _open(tester);
      await _search(tester, 'telegram');
      await _tap(tester, 'home-service-row-telegram');
      bridge.failRead = true;
      await _tap(tester, 'pin-service-telegram');
      expect(find.textContaining('catalog offline'), findsOneWidget);
      final disabled = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('service-route-telegram-vpn')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(disabled.onPressed, isNull);
      bridge.failRead = false;
      await _tap(tester, 'retry-home-services');
      expect(find.textContaining('catalog offline'), findsNothing);
      await _tap(tester, 'service-route-telegram-vpn');
      expect(bridge.routeWrites, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connected Windows delegates policy reconnect to core and unlocks controls',
    (tester) async {
      debugMobileShellOverride = false;
      final bridge = _DesktopServicesBridge()
        ..connected = true
        ..pendingPolicy = Completer<void>();
      await _pump(tester, bridge, size: const Size(1200, 900));
      await _open(tester);
      await _tap(tester, 'home-service-row-youtube');
      expect(
        find.byKey(const ValueKey('home-services-reconnect-note')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-services-read-only')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('service-route-youtube-auto')),
        findsNothing,
      );

      final vpn = find.byKey(const ValueKey('service-route-youtube-vpn'));
      await tester.ensureVisible(vpn);
      await tester.pumpAndSettle();
      await tester.tap(vpn);
      await tester.pump();
      expect(bridge.lastPolicyTag, 'youtube');
      final pendingButton = tester.widget<OutlinedButton>(
        find.descendant(of: vpn, matching: find.byType(OutlinedButton)),
      );
      expect(pendingButton.onPressed, isNull);
      expect(bridge.disconnects, 0);
      expect(bridge.restarts, 0);

      bridge.pendingPolicy!.complete();
      await tester.pumpAndSettle();
      expect(bridge.policies, {'youtube': 'vpn'});
      expect(bridge.routeWrites, 1);
      expect(bridge.restarts, 1);
      expect(bridge.disconnects, 0);
      expect(bridge.connected, true);
      expect(
        find.textContaining('VPN автоматически переподключён'),
        findsOneWidget,
      );
      final readyButton = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('service-route-youtube-direct')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(readyButton.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connected Windows preserves experimental Zapret and strategy controls',
    (tester) async {
      debugMobileShellOverride = false;
      final bridge = _DesktopServicesBridge()..connected = true;
      await _pump(tester, bridge, size: const Size(1200, 900));
      await _open(tester);
      await _tap(tester, 'home-service-row-discord');
      expect(find.text('Zapret (эксп.)'), findsOneWidget);
      await _tap(tester, 'service-route-discord-zapret');
      expect(bridge.policies, {'discord': 'zapret'});
      await _tap(tester, 'service-route-details-discord');
      expect(
        find.textContaining('Discord Zapret экспериментален'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-zapret-strategy-discord')),
        findsOneWidget,
      );
      await _tap(tester, 'zapret-manual-discord');
      await tester.tap(find.text('Встроенная ALT2').last);
      await tester.pumpAndSettle();
      expect(bridge.strategyMode, 'manual');
      expect(bridge.selectedStrategy, 'native-alt2');
      expect(find.text('Выбрана вручную: Встроенная ALT2'), findsOneWidget);
      await _tap(tester, 'zapret-auto-discord');
      expect(bridge.strategyMode, 'auto');
      expect(bridge.selectedStrategy, isEmpty);
      expect(bridge.strategyWrites, 2);
      expect(bridge.restarts, 3);
      expect(bridge.disconnects, 0);
      expect(bridge.connected, true);
      await _search(tester, 'telegram');
      await _tap(tester, 'home-service-row-telegram');
      final unsupported = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('service-route-telegram-zapret')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(unsupported.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows exposes services only on Home and keeps policies across mode changes',
    (tester) async {
      debugMobileShellOverride = false;
      final bridge = _DesktopServicesBridge();
      await _pump(tester, bridge, size: const Size(1200, 900));
      expect(find.byKey(const ValueKey('nav-services')), findsNothing);
      await _open(tester);
      await _tap(tester, 'home-service-row-youtube');
      await _tap(tester, 'service-route-youtube-vpn');
      await _tap(tester, 'nav-settings');
      expect(find.byKey(const ValueKey('link-service-settings')), findsNothing);
      expect(
        find.byKey(const ValueKey('toggle-home-route-services')),
        findsNothing,
      );
      await _tap(tester, 'link-advanced');
      expect(find.byKey(const ValueKey('link-service-settings')), findsNothing);
      await _tap(tester, 'nav-home');
      expect(find.byKey(const ValueKey('service-search')), findsOneWidget);
      await _tap(tester, 'home-routing-all-vpn');
      expect(
        find.byKey(const ValueKey('toggle-home-route-services')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('service-search')), findsNothing);
      expect(bridge.policies, {'youtube': 'vpn'});
      await _tap(tester, 'home-routing-selected');
      expect(find.byKey(const ValueKey('service-search')), findsOneWidget);
      expect(bridge.policies, {'youtube': 'vpn'});
      expect(bridge.routeWrites, 1);
      expect(bridge.disconnects, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
