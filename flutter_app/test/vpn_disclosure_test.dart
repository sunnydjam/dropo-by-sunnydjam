import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dropo/core');
Finder _key(String value) => find.byKey(ValueKey(value));

class _ConsentBridge extends MockCoreBridge {
  int starts = 0;
  int sourceReads = 0;
  final opened = <String>[];

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
  };

  @override
  Future<List<VpnSourceInfo>> vpnSources() async {
    sourceReads++;
    return [
      VpnSourceInfo.fromJson({'id': 'personal', 'node_count': 1}),
    ];
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (value) starts++;
    return super.setConnected(value);
  }

  @override
  Future<void> openExternal(String link) async => opened.add(link);
}

void _mock(Future<Object?> Function(MethodCall)? handler) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);

Future<void> _home(WidgetTester tester, _ConsentBridge bridge) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dropoThemeForTesting(),
      home: DropoHomePage(bridge: bridge),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugAndroidPlatformOverride = true;
    debugMobileShellOverride = true;
  });
  tearDown(() {
    _mock(null);
    debugAndroidPlatformOverride = null;
    debugMobileShellOverride = null;
  });

  test(
    'native consent requires current version and a strict boolean',
    () async {
      for (final response in [
        null,
        {},
        {'accepted': 'true', 'version': 1},
        {'accepted': true, 'version': 0},
        {'accepted': true, 'version': 2},
      ]) {
        _mock((_) async => response);
        expect(await VpnDisclosureConsentStore().isAccepted(), isFalse);
      }
      _mock((_) async => {'accepted': true, 'version': 1});
      expect(await VpnDisclosureConsentStore().isAccepted(), isTrue);
    },
  );

  test('saving requires semantic success and verified persistence', () async {
    _mock(
      (call) async => call.method == 'acceptVpnDisclosureConsent'
          ? {'success': true}
          : {'accepted': false, 'version': 1},
    );
    await expectLater(VpnDisclosureConsentStore().accept(), throwsStateError);
    _mock((_) async => null);
    await expectLater(VpnDisclosureConsentStore().accept(), throwsStateError);
  });

  testWidgets(
    'personal source also requires consent before source lookup/start',
    (tester) async {
      var accepted = false;
      var writes = 0;
      _mock((call) async {
        if (call.method == 'acceptVpnDisclosureConsent') {
          expect(call.arguments, {'version': 1});
          writes++;
          accepted = true;
          return {'success': true};
        }
        return {'accepted': accepted, 'version': 1};
      });
      final bridge = _ConsentBridge();
      await _home(tester, bridge);
      final reads = bridge.sourceReads;
      await _tap(tester, 'home-connect');
      expect(_key('vpn-data-disclosure'), findsOneWidget);
      expect(bridge.sourceReads, reads);
      expect(bridge.starts, 0);
      await _tap(tester, 'vpn-disclosure-privacy');
      expect(bridge.opened, [dropoPrivacyPolicyUrl]);
      expect(writes, 0);
      await _tap(tester, 'vpn-disclosure-accept');
      expect(writes, 1);
      expect(bridge.starts, 1);
      expect(_key('vpn-data-disclosure'), findsNothing);
      await _tap(tester, 'home-connect'); // Stop does not ask again.
      await _tap(tester, 'home-connect'); // Saved consent is reused.
      expect(bridge.starts, 2);
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('decline and system back never write consent or start VPN', (
    tester,
  ) async {
    var writes = 0;
    _mock((call) async {
      if (call.method == 'acceptVpnDisclosureConsent') writes++;
      return {'accepted': false, 'version': 1};
    });
    final bridge = _ConsentBridge();
    await _home(tester, bridge);
    await _tap(tester, 'home-connect');
    await _tap(tester, 'vpn-disclosure-decline');
    expect(bridge.starts, 0);
    await _tap(tester, 'home-connect');
    await Navigator.of(tester.element(_key('vpn-data-disclosure'))).maybePop();
    await tester.pumpAndSettle();
    expect(bridge.starts, 0);
    expect(writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native storage failure cannot fall through to VPN', (
    tester,
  ) async {
    _mock((_) async => throw PlatformException(code: 'storage_failed'));
    final bridge = _ConsentBridge();
    await _home(tester, bridge);
    await _tap(tester, 'home-connect');
    expect(bridge.starts, 0);
    expect(find.textContaining('Подключение не запущено.'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saving error is retryable, with explicit consent only', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => vpnDisclosureDialogForTest(
                onAccept: () async {
                  attempts++;
                  if (attempts == 1) throw StateError('disk');
                },
                onOpenPrivacy: () async {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await _tap(tester, 'vpn-disclosure-accept');
    expect(_key('vpn-disclosure-error'), findsOneWidget);
    expect(_key('vpn-data-disclosure'), findsOneWidget);
    await _tap(tester, 'vpn-disclosure-accept');
    expect(attempts, 2);
    expect(_key('vpn-data-disclosure'), findsNothing);
  });

  testWidgets('disclosure scrolls at 320px with 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var accepted = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => vpnDisclosureDialogForTest(
                onAccept: () async => accepted = true,
                onOpenPrivacy: () async {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'vpn-disclosure-accept');
    expect(accepted, isTrue);
    expect(tester.takeException(), isNull);
  });
}
