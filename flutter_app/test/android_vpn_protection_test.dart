import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidVpnProtection', () {
    test('keeps native protection flags tri-state until observed', () {
      final unknown = AndroidVpnProtection.fromJson(const {
        'success': true,
        'observed': false,
        'alwaysOn': true,
        'lockdown': true,
        'killSwitchActive': true,
      });

      expect(unknown.observed, isFalse);
      expect(unknown.alwaysOn, isNull);
      expect(unknown.lockdown, isNull);
      expect(unknown.killSwitchActive, isNull);
      expect(unknown.confirmedKillSwitch, isFalse);

      final partial = AndroidVpnProtection.fromJson(const {
        'observed': true,
        'alwaysOn': true,
        'lockdown': 'unknown',
      });
      expect(partial.alwaysOn, isTrue);
      expect(partial.lockdown, isNull);
      expect(partial.killSwitchActive, isNull);
      expect(partial.confirmedKillSwitch, isFalse);
    });

    test('confirms kill switch only when every required signal is true', () {
      final protected = AndroidVpnProtection.fromJson(const {
        'observed': true,
        'alwaysOn': true,
        'lockdown': true,
        'killSwitchActive': true,
      });
      final alwaysOnOnly = AndroidVpnProtection.fromJson(const {
        'observed': true,
        'alwaysOn': true,
        'lockdown': false,
        'killSwitchActive': false,
      });

      expect(protected.confirmedKillSwitch, isTrue);
      expect(alwaysOnOnly.confirmedKillSwitch, isFalse);
    });
  });

  test('reconnecting core state remains a connection-in-progress state', () {
    final status = CoreStatus.fromJson(const {
      'vpnState': 'reconnecting',
      'connected': false,
      'running': true,
    });

    expect(status.vpnState, 'reconnecting');
    expect(status.connecting, isTrue);
    expect(status.connected, isFalse);
    expect(status.running, isTrue);
  });

  test(
    'ChannelCoreBridge uses the dedicated Android protection methods',
    () async {
      const channel = MethodChannel('dropo/test-android-vpn-protection');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'androidVpnProtection') {
              return <String, Object?>{
                'success': true,
                'observed': true,
                'alwaysOn': true,
                'lockdown': true,
                'killSwitchActive': true,
              };
            }
            if (call.method == 'androidOpenVpnSettings') {
              return <String, Object?>{'success': true, 'opened': true};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final bridge = ChannelCoreBridge(channel: channel);
      final protection = await bridge.androidVpnProtection();
      final opened = await bridge.androidOpenVpnSettings();

      expect(protection.confirmedKillSwitch, isTrue);
      expect(opened['opened'], isTrue);
      expect(calls, ['androidVpnProtection', 'androidOpenVpnSettings']);
    },
  );

  test('ChannelCoreBridge preserves native protection errors', () async {
    const channel = MethodChannel('dropo/test-android-vpn-protection-error');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, Object?>{
            'success': false,
            'error': 'system VPN status unavailable',
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final bridge = ChannelCoreBridge(channel: channel);
    await expectLater(
      bridge.androidVpnProtection(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'system VPN status unavailable',
        ),
      ),
    );
  });

  test('mock bridge never claims system protection', () async {
    final bridge = MockCoreBridge();

    expect((await bridge.androidVpnProtection()).observed, isFalse);
    expect((await bridge.androidOpenVpnSettings())['success'], isFalse);
  });

  testWidgets('protection card does not call Always-on alone a kill switch', (
    tester,
  ) async {
    var settingsOpened = false;
    final protection = AndroidVpnProtection.fromJson(const {
      'observed': true,
      'alwaysOn': true,
      'lockdown': false,
      'killSwitchActive': false,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: androidVpnProtectionCardForTest(
            protection: protection,
            onOpenSettings: () => settingsOpened = true,
          ),
        ),
      ),
    );

    expect(find.text('Блокировка трафика выключена'), findsOneWidget);
    expect(find.textContaining('Это не kill switch'), findsOneWidget);
    expect(find.textContaining('Kill switch активен'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('android-open-vpn-settings')));
    expect(settingsOpened, isTrue);
  });

  testWidgets('protection card labels only confirmed lockdown as active', (
    tester,
  ) async {
    final protection = AndroidVpnProtection.fromJson(const {
      'observed': true,
      'alwaysOn': true,
      'lockdown': true,
      'killSwitchActive': true,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: androidVpnProtectionCardForTest(protection: protection),
        ),
      ),
    );

    expect(find.text('Защита от утечки включена'), findsOneWidget);
    expect(find.textContaining('Kill switch активен'), findsOneWidget);
  });

  testWidgets('ordinary Android settings include system protection status', (
    tester,
  ) async {
    debugMobileShellOverride = true;
    debugAndroidPlatformOverride = true;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugMobileShellOverride = null);
    addTearDown(() => debugAndroidPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DropoHomePage(bridge: MockCoreBridge()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await openSection(tester, 'app-settings');

    expect(find.text('ЗАЩИТА СОЕДИНЕНИЯ'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('android-vpn-protection-card')),
      findsOneWidget,
    );
    expect(find.text('Статус защиты не определён'), findsOneWidget);
    expect(find.text('Открыть настройки VPN'), findsOneWidget);
  });
}
