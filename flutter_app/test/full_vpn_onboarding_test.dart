import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FirstRunBridge extends MockCoreBridge {
  String mode = 'all_traffic';
  bool connected = false;
  bool failCatalog = false;
  bool failAdd = false;
  bool failConnect = false;
  int publicAdds = 0;
  int starts = 0;
  bool consent = false;
  List<VpnSourceInfo> sources = [];

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'routingMode': mode,
    'autoStartPrompted': true,
    'checkUpdates': false,
  };

  @override
  Future<Map<String, dynamic>> routingMode() async => {
    'success': true,
    'mode': mode,
  };

  @override
  Future<Map<String, dynamic>> setRoutingMode(String value) async {
    mode = value;
    return {'success': true, 'mode': value, 'sourceRequired': sources.isEmpty};
  }

  @override
  Future<CoreStatus> status() async =>
      (await super.status()).copyWith(connected: connected, running: connected);

  @override
  Future<SubscriptionInfo> subscription() async => SubscriptionInfo(
    hasSubscription: sources.any((source) => !source.disabled),
    url: '',
    proxyCount: sources.length,
  );

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => sources;

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async {
    if (failCatalog) throw StateError('offline');
    return const [
      PublicVpnProviderInfo(
        id: 'public',
        name: 'Публичный источник',
        description: '',
        website: 'https://example.test',
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool accepted,
  ) async {
    publicAdds++;
    consent = accepted;
    if (failAdd) {
      return {'success': false, 'error': 'Каталог временно недоступен'};
    }
    sources = [
      VpnSourceInfo.fromJson({
        'id': 'free',
        'public_catalog_id': id,
        'node_count': 1,
        'node_names': ['Сервер'],
      }),
    ];
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (value) starts++;
    if (value && failConnect) {
      return {'success': false, 'error': 'Источник не отвечает'};
    }
    connected = value;
    return {'success': true};
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _pump(
  WidgetTester tester,
  _FirstRunBridge bridge, {
  Size size = const Size(820, 560),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: DropoHomePage(bridge: bridge),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void main() {
  testWidgets(
    'full mode can be selected without a source and does not connect implicitly',
    (tester) async {
      final bridge = _FirstRunBridge()..mode = 'blocked_only';
      await _pump(tester, bridge);
      await _tap(tester, 'home-routing-all-vpn');
      expect(bridge.mode, 'all_traffic');
      expect(bridge.starts, 0);
      expect(bridge.publicAdds, 0);
      expect(_key('full-vpn-onboarding'), findsNothing);
      await _tap(tester, 'home-connect');
      expect(_key('full-vpn-onboarding'), findsOneWidget);
      expect(bridge.publicAdds, 0);
      await _tap(tester, 'onboarding-cancel');
      expect(bridge.starts, 0);
      expect(bridge.publicAdds, 0);
      expect(bridge.mode, 'all_traffic');
    },
  );

  testWidgets('free connection requires consent and then starts once', (
    tester,
  ) async {
    final bridge = _FirstRunBridge();
    await _pump(tester, bridge);
    await _tap(tester, 'home-connect');
    expect(find.textContaining('не сеть Dropo'), findsOneWidget);
    expect(bridge.publicAdds, 0);
    await _tap(tester, 'onboarding-free-public');
    expect(bridge.consent, isTrue);
    expect(bridge.publicAdds, 1);
    expect(bridge.starts, 1);
    expect(bridge.connected, isTrue);
    expect(_key('full-vpn-onboarding'), findsNothing);
    await _tap(tester, 'home-connect');
    await _tap(tester, 'home-connect');
    expect(bridge.starts, 2);
    expect(bridge.publicAdds, 1);
    expect(_key('full-vpn-onboarding'), findsNothing);
  });

  testWidgets(
    'failed free import can retry and never silently connects direct',
    (tester) async {
      final bridge = _FirstRunBridge()..failAdd = true;
      await _pump(tester, bridge);
      await _tap(tester, 'home-connect');
      await _tap(tester, 'onboarding-free-public');
      expect(find.text('Каталог временно недоступен'), findsOneWidget);
      expect(bridge.starts, 0);
      expect(bridge.mode, 'all_traffic');
      bridge.failAdd = false;
      await _tap(tester, 'onboarding-free-public');
      expect(bridge.starts, 1);
      expect(bridge.publicAdds, 2);
    },
  );

  testWidgets(
    'unavailable catalog offers retry, own source or explicit selective mode',
    (tester) async {
      final bridge = _FirstRunBridge()..failCatalog = true;
      await _pump(tester, bridge);
      await _tap(tester, 'home-connect');
      expect(_key('onboarding-retry-catalog'), findsOneWidget);
      expect(_key('onboarding-own-source'), findsOneWidget);
      expect(bridge.mode, 'all_traffic');
      await _tap(tester, 'onboarding-services-mode');
      expect(bridge.mode, 'blocked_only');
      expect(bridge.starts, 0);
      expect(bridge.publicAdds, 0);
    },
  );

  testWidgets('disabled sources are never silently re-enabled by onboarding', (
    tester,
  ) async {
    final bridge = _FirstRunBridge()
      ..sources = [
        VpnSourceInfo.fromJson({'id': 'disabled', 'disabled': true}),
      ];
    await _pump(tester, bridge);
    await _tap(tester, 'home-connect');
    expect(_key('onboarding-free-public'), findsNothing);
    expect(find.textContaining('не включаем отключённые'), findsOneWidget);
    await _tap(tester, 'onboarding-own-source');
    expect(_key('sources-section'), findsOneWidget);
    expect(bridge.publicAdds, 0);
    expect(bridge.starts, 0);
  });

  testWidgets('connection failure remains accessible after status polling', (
    tester,
  ) async {
    final bridge = _FirstRunBridge()..failConnect = true;
    await _pump(tester, bridge);
    await _tap(tester, 'home-connect');
    await _tap(tester, 'onboarding-free-public');
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('Источник не отвечает'), findsOneWidget);
    expect(_key('planet-error'), findsOneWidget);
    expect(bridge.connected, isFalse);
    expect(bridge.mode, 'all_traffic');
  });

  testWidgets('free onboarding fits a small window with large text', (
    tester,
  ) async {
    final bridge = _FirstRunBridge();
    await _pump(tester, bridge, size: const Size(390, 568), scale: 2);
    await _tap(tester, 'home-connect');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'onboarding-free-public');
    expect(tester.takeException(), isNull);
    expect(bridge.starts, 1);
  });
}
