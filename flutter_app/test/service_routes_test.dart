import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _CatalogBridge extends MockCoreBridge {
  bool failRead = false, failWrite = false, failSources = false;
  int writes = 0;
  Completer<void>? pendingWrite;
  final policies = <String, String>{};
  final pins = <String, bool>{};
  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
  };
  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    if (failRead) throw StateError('catalog offline');
    return [
      for (final tag in ['youtube', 'discord', 'telegram', 'meta', 'openai'])
        RouteService(
          delayMs: 0,
          tag: tag,
          name:
              {
                'telegram': 'Telegram',
                'youtube': 'YouTube',
                'discord': 'Discord',
              }[tag] ??
              tag,
          method: policies[tag] ?? 'Direct',
          selectedMethod: policies[tag] ?? 'direct',
          requiresVpn: false,
          domainSuffixes: ['$tag.example.test'],
          homeVisible: pins[tag] ?? false,
          zapretSupported: true,
        ),
    ];
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    writes++;
    if (pendingWrite != null) await pendingWrite!.future;
    if (failWrite) return {'success': false, 'error': 'save refused'};
    policies[tag] = method;
    return {'success': true, 'restarted': true};
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
  Future<List<VpnSourceInfo>> vpnSources() async {
    if (failSources) throw StateError('sources offline');
    return [
      VpnSourceInfo.fromJson({
        'id': 'personal',
        'name': 'Моя подписка',
        'active': true,
        'node_names': ['Нидерланды · 1'],
        'node_count': 1,
        'selected_node': 0,
      }),
    ];
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(960, 640),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF36D399),
          brightness: Brightness.dark,
        ),
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

ServiceRoutesPage _page(
  _CatalogBridge bridge, {
  bool enabled = true,
  bool connected = false,
  ValueChanged<bool>? onBusy,
  VoidCallback? onChanged,
}) => ServiceRoutesPage(
  bridge: bridge,
  connected: connected,
  enabled: enabled,
  routingMode: 'blocked_only',
  onBusyChanged: onBusy,
  onChanged: onChanged,
);

Future<void> _tap(WidgetTester tester, String key) async {
  final item = find.byKey(ValueKey(key));
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      180,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _search(WidgetTester tester, String query) async {
  await _tap(tester, 'service-search');
  await tester.enterText(find.byKey(const ValueKey('service-search')), query);
  await tester.pumpAndSettle();
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

  testWidgets('catalog searches domains and pins without changing routing', (
    tester,
  ) async {
    final bridge = _CatalogBridge();
    await _pump(tester, _page(bridge));
    await _search(tester, 'TELEGRAM.EXAMPLE');
    expect(find.byKey(const ValueKey('service-card-telegram')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-card-discord')), findsNothing);
    await _tap(tester, 'pin-service-telegram');
    expect(bridge.pins['telegram'], true);
    expect(bridge.writes, 0);
    await _tap(tester, 'services-pinned');
    expect(find.byKey(const ValueKey('service-card-telegram')), findsOneWidget);
    await _tap(tester, 'pin-service-telegram');
    expect(find.byKey(const ValueKey('service-card-telegram')), findsNothing);
    await _search(tester, 'discord');
    final pin = tester.widget<IconButton>(
      find.byKey(const ValueKey('pin-service-discord')),
    );
    expect(pin.onPressed, isNull);
    expect(pin.tooltip, 'Всегда на главной');
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed writes keep saved policy and release busy lock', (
    tester,
  ) async {
    final bridge = _CatalogBridge()..failWrite = true;
    final busy = <bool>[];
    int changes = 0;
    await _pump(
      tester,
      _page(bridge, onBusy: busy.add, onChanged: () => changes++),
    );
    await _search(tester, 'discord');
    await _tap(tester, 'service-route-discord-vpn');
    expect(find.textContaining('save refused'), findsOneWidget);
    expect(bridge.policies, isEmpty);
    expect(busy, [true, false]);
    expect(changes, 0);
    bridge.failWrite = false;
    await _tap(tester, 'service-route-discord-vpn');
    expect(bridge.policies['discord'], 'vpn');
    expect(changes, 1);
    expect(
      find.textContaining('VPN автоматически переподключён'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('load failure is not an empty or default catalog and can retry', (
    tester,
  ) async {
    final bridge = _CatalogBridge()..failRead = true;
    await _pump(tester, _page(bridge));
    expect(find.textContaining('catalog offline'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('service-route-discord-vpn')),
      findsNothing,
    );
    bridge.failRead = false;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    await _search(tester, 'discord');
    expect(
      find.byKey(const ValueKey('service-route-discord-vpn')),
      findsOneWidget,
    );
  });

  testWidgets('offline and active Android disable policy changes', (
    tester,
  ) async {
    for (final mobile in [false, true]) {
      debugMobileShellOverride = mobile;
      addTearDown(() => debugMobileShellOverride = null);
      await _pump(
        tester,
        _page(_CatalogBridge(), connected: true, enabled: mobile),
      );
      await _search(tester, 'discord');
      final button = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('service-route-discord-vpn')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    }
  });

  testWidgets('pending route write locks navigation then refreshes home', (
    tester,
  ) async {
    final bridge = _CatalogBridge()..pendingWrite = Completer<void>();
    await _pump(tester, DropoHomePage(bridge: bridge));
    await _tap(tester, 'nav-services');
    await _search(tester, 'discord');
    await _tap(tester, 'service-route-discord-vpn');
    // Do not settle the intentional pending operation.
    await tester.tap(find.byKey(const ValueKey('nav-sources')));
    await tester.pump();
    expect(find.byType(ServiceRoutesPage), findsOneWidget);
    expect(find.byType(VpnSourcesDialog), findsNothing);
    bridge.pendingWrite!.complete();
    await tester.pumpAndSettle();
    await _tap(tester, 'nav-sources');
    expect(find.byType(VpnSourcesDialog), findsOneWidget);
    expect(
      tester.widget<VpnSourcesDialog>(find.byType(VpnSourcesDialog)).embedded,
      true,
    );
    await _tap(tester, 'nav-home');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-connect')), findsOneWidget);
    expect(bridge.policies['discord'], 'vpn');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source page masks stale active state and preserves open form across snapshots',
    (tester) async {
      final bridge = _CatalogBridge();
      bool enabled = true;
      late StateSetter update;
      List<VpnSourceInfo>? snapshot;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return VpnSourcesDialog(
              bridge: bridge,
              subscription: const SubscriptionInfo(
                hasSubscription: true,
                url: '',
                proxyCount: 1,
              ),
              embedded: true,
              enabled: enabled,
              sourceSnapshot: snapshot,
            );
          },
        ),
      );
      expect(find.textContaining('Используется сейчас'), findsOneWidget);
      await _tap(tester, 'add-personal-vpn');
      expect(find.text('Скрыть форму'), findsOneWidget);
      final sources = await bridge.vpnSources();
      update(() => snapshot = sources);
      await tester.pumpAndSettle();
      expect(find.text('Скрыть форму'), findsOneWidget);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Используется сейчас'), findsNothing);
      expect(find.textContaining('Статус уточняется'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'sections fit ${mobile ? 'mobile' : 'desktop'} at $scale text scale',
        (tester) async {
          debugMobileShellOverride = mobile;
          addTearDown(() => debugMobileShellOverride = null);
          final bridge = _CatalogBridge();
          await _pump(
            tester,
            DropoHomePage(bridge: bridge),
            size: mobile ? const Size(390, 844) : const Size(960, 640),
            scale: scale,
          );
          if (mobile) {
            await tester.tap(find.text('Еще'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Сервисы'));
            await tester.pumpAndSettle();
          } else {
            await _tap(tester, 'nav-services');
          }
          await _search(tester, 'discord');
          await _tap(tester, 'service-route-discord-vpn');
          expect(bridge.policies['discord'], 'vpn');
          if (mobile) {
            await tester.tap(find.text('Еще'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Источники VPN'));
            await tester.pumpAndSettle();
          } else {
            await _tap(tester, 'nav-sources');
          }
          await _tap(tester, 'add-personal-vpn');
          expect(find.text('Скрыть форму'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('capture native services and sources sections', (tester) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    final key = GlobalKey();
    await _pump(
      tester,
      RepaintBoundary(
        key: key,
        child: DropoHomePage(bridge: _CatalogBridge()),
      ),
      size: const Size(1120, 800),
    );
    for (final section in ['services', 'sources']) {
      await _tap(tester, 'nav-$section');
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/ui-review').create(recursive: true);
        await File(
          'build/ui-review/$section-page.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
  });
}
