import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedSourceBridge extends MockCoreBridge {
  final sources = [
    VpnSourceInfo.fromJson({
      'id': 'personal',
      'name': 'Моя подписка',
      'node_count': 1,
    }),
  ];
  Completer<List<VpnSourceInfo>>? pendingSources;
  bool connected = false;
  bool externalStarting = false;
  int starts = 0;
  int routeWrites = 0;
  int observedStarting = 0;

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'routingMode': 'blocked_only',
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
  };

  @override
  Future<CoreStatus> status() async {
    if (externalStarting) observedStarting++;
    return (await super.status()).copyWith(
      connected: connected,
      running: connected,
      connecting: externalStarting,
      vpnState: externalStarting
          ? 'starting'
          : connected
          ? 'connected'
          : 'stopped',
    );
  }

  @override
  Future<SubscriptionInfo> subscription() async => SubscriptionInfo(
    hasSubscription: true,
    url: '',
    proxyCount: sources.length,
  );

  @override
  Future<VpnSourcesSnapshot> vpnSourcesSnapshot() async => VpnSourcesSnapshot(
    sources: sources,
    autoSelect: true,
    running: connected,
  );

  @override
  Future<List<VpnSourceInfo>> vpnSources() async =>
      pendingSources == null ? sources : await pendingSources!.future;

  @override
  Future<List<RouteService>> routes({bool live = false}) async => const [
    RouteService(
      tag: 'youtube',
      name: 'YouTube',
      method: 'Прямое подключение',
      selectedMethod: 'auto',
      requiresVpn: false,
      delayMs: 0,
      domainSuffixes: ['youtube.example.test'],
      homeVisible: true,
    ),
  ];

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    routeWrites++;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (value) starts++;
    connected = value;
    return {'success': true};
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _pump(WidgetTester tester, _DelayedSourceBridge bridge) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dropoThemeForTesting(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: DropoHomePage(bridge: bridge),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = _key(key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
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

  setUp(() {
    debugMobileShellOverride = true;
    debugAndroidPlatformOverride = true;
  });

  tearDown(() {
    debugMobileShellOverride = null;
    debugAndroidPlatformOverride = null;
  });

  testWidgets('source preparation blocks route edits and duplicate Connect', (
    tester,
  ) async {
    final bridge = _DelayedSourceBridge();
    await _pump(tester, bridge);
    await _tap(tester, 'toggle-home-route-services');
    await _tap(tester, 'home-service-row-youtube');
    final route = find.descendant(
      of: _key('service-route-youtube-vpn'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(route).onPressed, isNotNull);

    final pending = Completer<List<VpnSourceInfo>>();
    bridge.pendingSources = pending;
    await _tap(tester, 'home-connect');
    expect(tester.widget<FilledButton>(_key('home-connect')).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(route).onPressed, isNull);
    await _tap(tester, 'service-route-youtube-vpn');
    expect(bridge.routeWrites, 0);
    await _tap(tester, 'home-connect');
    expect(bridge.starts, 0);

    pending.complete(bridge.sources);
    await tester.pumpAndSettle();
    expect(bridge.starts, 1);
    expect(bridge.connected, isTrue);
    expect(bridge.routeWrites, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('start is not repeated if another session starts during lookup', (
    tester,
  ) async {
    final bridge = _DelayedSourceBridge();
    await _pump(tester, bridge);
    final pending = Completer<List<VpnSourceInfo>>();
    bridge.pendingSources = pending;
    await _tap(tester, 'home-connect');

    bridge.externalStarting = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(bridge.observedStarting, greaterThan(0));
    pending.complete(bridge.sources);
    await tester.pumpAndSettle();
    expect(bridge.starts, 0);
    expect(bridge.routeWrites, 0);

    bridge.externalStarting = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    bridge.pendingSources = null;
    await _tap(tester, 'home-connect');
    expect(bridge.starts, 1);
    expect(bridge.connected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
