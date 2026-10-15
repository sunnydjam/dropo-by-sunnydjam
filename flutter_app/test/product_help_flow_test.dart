import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_helpers.dart';

class _ProductBridge extends MockCoreBridge {
  String mode = 'all_traffic';
  bool connected = false;
  bool unavailable = false;
  bool denied = false;
  int starts = 0;
  int freeAdds = 0;
  int readOnlyChecks = 0;
  int oldChecks = 0;
  int diagnosticReads = 0;
  List<VpnSourceInfo> sources = [];

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'routingMode': mode,
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
  };

  @override
  Future<Map<String, dynamic>> routingMode() async => {
    'success': true,
    'mode': mode,
  };

  @override
  Future<Map<String, dynamic>> setRoutingMode(String value) async {
    mode = value;
    return {'success': true, 'mode': value};
  }

  @override
  Future<CoreStatus> status() async => (await super.status()).copyWith(
    connected: connected,
    running: connected,
    vpnState: connected ? 'connected' : 'stopped',
  );

  @override
  Future<SubscriptionInfo> subscription() async => SubscriptionInfo(
    hasSubscription: sources.any((source) => !source.disabled),
    url: '',
    proxyCount: sources.length,
  );

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => sources;

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async => const [
    PublicVpnProviderInfo(
      id: 'dropo-free',
      name: 'Dropo Free',
      description: '',
      website: '',
    ),
  ];

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool consent,
  ) async {
    expect(consent, isTrue);
    freeAdds++;
    if (unavailable) {
      return {'success': false, 'error': 'Источник временно недоступен'};
    }
    sources = [
      VpnSourceInfo.fromJson({'id': 'free', 'node_count': 1}),
    ];
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (value) starts++;
    if (value && denied) {
      return {'success': false, 'error': 'Разрешение VPN не предоставлено'};
    }
    connected = value;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> runQuickCheck() async {
    oldChecks++;
    throw StateError('Mutating quick check must not be used by Help');
  }

  @override
  Future<String> diagnostics() async {
    diagnosticReads++;
    return 'private diagnostic fixture';
  }

  @override
  Future<Map<String, dynamic>> runConnectionCheck() async {
    readOnlyChecks++;
    return {
      'success': false,
      'readOnly': true,
      'sessionValid': true,
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'services': [
        {
          'name': 'private source fixture',
          'url': 'https://private.test/secret-key',
          'success': true,
          'routeVerified': false,
        },
        {
          'name': 'private service fixture',
          'error': 'private log fixture',
          'success': false,
          'routeVerified': false,
        },
      ],
    };
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, String key) async {
  if (_key(key).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _key(key),
      180,
      scrollable: find
          .descendant(
            of: _key('guided-help-page'),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _ProductBridge bridge, {
  bool mobile = true,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  debugMobileShellOverride = mobile;
  debugAndroidPlatformOverride = mobile;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('product-flow-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dropoThemeForTesting(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_PRODUCT_HELP_CAPTURE')) return;
  const directory = String.fromEnvironment('DROPO_PRODUCT_HELP_CAPTURE_DIR');
  if (directory.isEmpty) throw StateError('Capture directory required');
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      _key('product-flow-capture'),
    );
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  test('route verification requires explicit transport evidence', () {
    expect(
      ConnectionHealthResult.fromJson({
        'success': true,
        'expectedRoute': 'vpn',
      }).routeVerified,
      isFalse,
    );
    expect(
      ConnectionHealthResult.fromJson({
        'success': true,
        'routeVerified': true,
      }).routeVerified,
      isTrue,
    );
  });
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // The headless test runner cannot discover system fonts. Use the host's
    // existing monospace font only for optional local visual captures; normal
    // tests and production do not acquire an OS-path dependency.
    if (const bool.fromEnvironment('DROPO_PRODUCT_HELP_CAPTURE') &&
        Platform.isWindows) {
      final font = File('C:/Windows/Fonts/consola.ttf');
      if (await font.exists()) {
        final bytes = ByteData.sublistView(await font.readAsBytes());
        for (final family in ['Consolas', 'monospace']) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
      }
    }
    await preloadAtlasPlanetForTesting();
  });

  // Source onboarding and help fixtures represent a user with saved VPN data
  // consent; vpn_disclosure_test.dart exercises the separate first-time flow.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dropo/core'), (
          call,
        ) async {
          if (call.method == 'getVpnDisclosureConsent') {
            return {
              'accepted': true,
              'version': VpnDisclosureConsentStore.version,
            };
          }
          throw MissingPluginException('Unexpected method: ${call.method}');
        });
  });

  tearDown(() {
    debugMobileShellOverride = null;
    debugAndroidPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dropo/core'), null);
  });

  for (final mode in ['all_traffic', 'blocked_only']) {
    testWidgets(
      'Android first connection keeps $mode and needs explicit Free consent',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = _ProductBridge()..mode = mode;
        await _pump(tester, bridge);
        await _tap(tester, 'home-connect');
        expect(_key('full-vpn-onboarding'), findsOneWidget);
        expect(_key('onboarding-android-permission'), findsOneWidget);
        expect(_key('onboarding-services-mode'), findsNothing);
        expect(bridge.starts, 0);
        expect(bridge.freeAdds, 0);
        expect(bridge.mode, mode);
        if (mode == 'all_traffic') {
          await _capture(tester, 'android-first-connection');
        }
        await _tap(tester, 'onboarding-free-dropo-free');
        expect(bridge.starts, 1);
        expect(bridge.freeAdds, 1);
        expect(bridge.mode, mode);
        expect(_key('planet-connected'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel and disabled sources never start or re-enable a source', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _ProductBridge()
      ..sources = [
        VpnSourceInfo.fromJson({'id': 'disabled', 'disabled': true}),
      ];
    await _pump(tester, bridge);
    await _tap(tester, 'home-connect');
    expect(_key('onboarding-free-dropo-free'), findsNothing);
    await _tap(tester, 'onboarding-cancel');
    expect(bridge.starts, 0);
    expect(bridge.freeAdds, 0);
    expect(bridge.sources.single.disabled, isTrue);
    await _tap(tester, 'home-connect');
    await _tap(tester, 'onboarding-own-source');
    expect(_key('sources-section'), findsOneWidget);
    expect(bridge.starts, 0);
  });

  testWidgets(
    'Android permission denial is recoverable without changing mode',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _ProductBridge()..denied = true;
      await _pump(tester, bridge);
      await _tap(tester, 'home-connect');
      await _tap(tester, 'onboarding-free-dropo-free');
      expect(_key('planet-error'), findsOneWidget);
      expect(bridge.connected, isFalse);
      expect(bridge.mode, 'all_traffic');
      bridge.denied = false;
      await _tap(tester, 'home-connect');
      expect(bridge.connected, isTrue);
      expect(bridge.freeAdds, 1);
      expect(bridge.starts, 2);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      'Help uses safe check and preview before copying (${mobile ? 'phone' : 'desktop'})',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = _ProductBridge()..connected = true;
        await _pump(
          tester,
          bridge,
          mobile: mobile,
          size: mobile ? const Size(390, 844) : const Size(1536, 1024),
        );
        await openSection(tester, 'guided-help');
        expect(_key('guided-help-section'), findsOneWidget);
        expect(bridge.readOnlyChecks, 0);
        await _tap(tester, 'guided-help-scenario-no_internet');
        await _tap(tester, 'guided-help-check');
        expect(bridge.readOnlyChecks, 1);
        expect(bridge.oldChecks, 0);
        expect(bridge.connected, isTrue);
        expect(
          find.textContaining('Отказ одного адреса не означает'),
          findsOneWidget,
        );
        await _capture(
          tester,
          mobile ? 'android-guided-help' : 'desktop-guided-help',
        );
        await _tap(tester, 'guided-help-report');
        expect(_key('safe-support-preview'), findsOneWidget);
        final preview = tester
            .widget<Text>(_key('safe-support-preview-text'))
            .data!;
        expect(preview, contains('checks_total: 2'));
        expect(preview, isNot(contains('private')));
        expect(bridge.diagnosticReads, 0);
        await _capture(
          tester,
          mobile ? 'android-support-preview' : 'desktop-support-preview',
        );
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
        await openSection(tester, 'home');
        await _capture(
          tester,
          mobile ? 'android-home-current' : 'desktop-home-current',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('first connection and safe help fit a small large-text phone', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _ProductBridge();
    await _pump(tester, bridge, size: const Size(320, 568), scale: 2);
    await _tap(tester, 'home-connect');
    expect(_key('full-vpn-onboarding'), findsOneWidget);
    await _capture(tester, 'android-first-connection-320-large-text');
    await _tap(tester, 'onboarding-free-dropo-free');
    expect(bridge.connected, isTrue);
    await openSection(tester, 'guided-help');
    await _capture(tester, 'android-guided-help-choices-320-large-text');
    await _tap(tester, 'guided-help-scenario-no_internet');
    await _tap(tester, 'guided-help-check');
    await _capture(tester, 'android-guided-help-320-large-text');
    await _tap(tester, 'guided-help-report');
    expect(_key('safe-support-preview'), findsOneWidget);
    expect(bridge.diagnosticReads, 0);
    await _capture(tester, 'android-support-preview-320-large-text');
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(_key('safe-support-preview'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('safe Android bridge check cannot fall back to mutating method', (
    tester,
  ) async {
    const channel = MethodChannel('dropo/test-safe-help');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return jsonEncode({'success': true, 'readOnly': true});
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await ChannelCoreBridge(channel: channel).runConnectionCheck();
    expect(calls.single.method, 'call');
    expect(
      (calls.single.arguments as Map)['method'],
      'RunClientQuickCheckReadOnly',
    );
    expect((calls.single.arguments as Map)['argsJson'], '[]');
  });
}
