import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved theme values map to effective Flutter modes', () {
    expect(themeModeFromSetting('dark'), ThemeMode.dark);
    expect(themeModeFromSetting('light'), ThemeMode.light);
    expect(themeModeFromSetting('system'), ThemeMode.system);
    expect(themeModeFromSetting('invalid'), ThemeMode.system);
  });

  test(
    'Discord realtime health is background work, not connection blocking',
    () {
      expect(isConnectionBlockingBusyTask('vpn-connect'), isTrue);
      expect(isConnectionBlockingBusyTask('vpn-disconnect'), isTrue);
      expect(isConnectionBlockingBusyTask('discord-realtime-connect'), isFalse);
    },
  );

  test(
    'service catalog keeps the saved policy separate from its effective route',
    () {
      final route = RouteService.fromFreeAccessJson(const {
        'tag': 'discord',
        'name': 'Discord',
        'selectedMethod': 'auto',
        'effectiveMethod': 'vpn',
        'effectiveMethodLabel': 'VPN подписка',
        'requiresVpn': false,
      });

      expect(route.selectedMethod, 'auto');
      expect(route.method, 'VPN подписка');
    },
  );

  testWidgets('dropo Flutter shell keeps the compact map dashboard controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DropoApp());
    await tester.pump();

    expect(find.text('Dr'), findsOneWidget);
    expect(find.text('opo'), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.byIcon(Icons.public), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.text('Подключение'), findsOneWidget);
    expect(find.text('Профили'), findsWidgets);
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Статистика'), findsOneWidget);
    expect(find.text('Логи'), findsOneWidget);
    expect(find.text('О приложении'), findsOneWidget);
    expect(find.text('Выход'), findsOneWidget);
    expect(find.text('vdev'), findsOneWidget);
    expect(find.textContaining('Компоненты готовы:'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('compact Windows home and settings render without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: DropoHomePage(bridge: MockCoreBridge())),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Нужны компоненты'), findsNothing);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Настройки приложения'), findsOneWidget);
    expect(find.text('Встроенный runtime'), findsOneWidget);
    expect(find.text('Всё кроме России'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home routes keep four primary services and can pin another', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DropoHomePage(bridge: MockCoreBridge()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byKey(const ValueKey<String>('home-route-controls')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-routing-selected')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-routing-all-vpn')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-route-youtube-direct')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('toggle-home-route-services')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    for (final tag in const ['youtube', 'discord', 'meta', 'openai']) {
      expect(
        find.byKey(ValueKey<String>('home-route-$tag-direct')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('home-route-$tag-auto')),
        findsNothing,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('add-home-route-service')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final addGoogle = find.byKey(
      const ValueKey<String>('add-home-route-google'),
    );
    tester.widget<ListTile>(addGoogle).onTap!();
    await tester.pump(const Duration(milliseconds: 800));

    expect(
      find.byKey(const ValueKey<String>('home-route-google-direct')),
      findsOneWidget,
    );
    final remove = find.byKey(
      const ValueKey<String>('remove-home-route-google'),
    );
    expect(remove, findsOneWidget);
    await tester.tap(remove);
    await tester.pump(const Duration(milliseconds: 800));
    expect(
      find.byKey(const ValueKey<String>('home-route-google-direct')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('toggle-home-route-services')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey<String>('home-route-youtube-direct')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('home can switch all traffic through VPN immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bridge = MockCoreBridge();
    await bridge.saveSubscription('https://vpn.example/subscription');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DropoHomePage(bridge: bridge),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(
      find.byKey(const ValueKey<String>('home-routing-all-vpn')),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect((await bridge.routingMode())['mode'], 'all_traffic');
    expect(find.text('Весь трафик идёт через VPN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home exposes automatic and manual Zapret strategies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bridge = _RoutePolicyRecordingBridge();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DropoHomePage(bridge: bridge),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(
      find.byKey(const ValueKey<String>('toggle-home-route-services')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey<String>('home-route-discord-zapret')),
    );
    await tester.pump(const Duration(milliseconds: 800));

    expect(
      find.byKey(const ValueKey<String>('home-zapret-strategy-discord')),
      findsOneWidget,
    );
    expect(find.text('Повторить (эксп.)'), findsOneWidget);
    expect(find.text('Zapret (эксп.)'), findsOneWidget);
    expect(
      find.textContaining('Discord Zapret экспериментален'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('zapret-auto-discord')));
    await tester.pump(const Duration(milliseconds: 800));
    expect(bridge.lastStrategyMode, 'auto');

    final manualDropdown = find.byKey(
      const ValueKey<String>('zapret-manual-discord'),
    );
    await tester.ensureVisible(manualDropdown);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(manualDropdown);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Flowseal 1.10.2 ALT13 — Discord').last);
    await tester.pump(const Duration(milliseconds: 800));
    expect(bridge.lastStrategyMode, 'manual');
    expect(bridge.lastStrategyTag, 'flowseal-1102-discord-alt13');
    expect(
      find.text('Активна вручную: Flowseal 1.10.2 ALT13 — Discord'),
      findsOneWidget,
    );
    expect(find.text('Авто (эксп.)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home reports when the complete Zapret catalog has failed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _RoutePolicyRecordingBridge(strategyNotFound: true)
      ..currentMethod = 'zapret';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DropoHomePage(bridge: bridge),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(
      find.byKey(const ValueKey<String>('toggle-home-route-services')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('Результат: подходящая стратегия не найдена'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows service policy is clickable, high contrast, and persists forced VPN',
    (tester) async {
      tester.view.physicalSize = const Size(960, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bridge = _RoutePolicyRecordingBridge();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DropoHomePage(bridge: bridge),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final routeField = find.byKey(
        const ValueKey<String>('service-route-discord-direct'),
      );
      expect(routeField, findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: routeField,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.byKey(const ValueKey<String>('service-route-discord-direct')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('service-route-discord-vpn')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('service-route-discord-zapret')),
        findsOneWidget,
      );
      expect(
        find.textContaining('для voice/video рекомендуется VPN'),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('Сервисы и маршруты')).style?.color,
        const Color(0xFFE8F3EF),
      );
      expect(
        tester.widget<Text>(find.text('Discord')).style?.color,
        const Color(0xFFE8F3EF),
      );

      final zapretButton = find.byKey(
        const ValueKey<String>('service-route-discord-zapret'),
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: zapretButton,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(zapretButton);
      await tester.tap(zapretButton);
      await tester.pump(const Duration(milliseconds: 800));
      expect(bridge.lastMethod, 'zapret');
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: zapretButton,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );

      final vpnButton = find.byKey(
        const ValueKey<String>('service-route-discord-vpn'),
      );
      await tester.ensureVisible(vpnButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(vpnButton);
      await tester.pump(const Duration(milliseconds: 800));

      expect(bridge.lastTag, 'discord');
      expect(bridge.lastMethod, 'vpn');
      expect(
        find.byKey(const ValueKey<String>('service-route-discord-vpn')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Рекомендуемый стабильный маршрут'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Маршрут для Discord сохранён'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows service policy stays clickable while VPN is active and reports reconnect',
    (tester) async {
      tester.view.physicalSize = const Size(960, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bridge = _RoutePolicyRecordingBridge(restarted: true);
      await bridge.setConnected(true);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DropoHomePage(bridge: bridge),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final routeField = find.byKey(
        const ValueKey<String>('service-route-discord-direct'),
      );
      expect(routeField, findsOneWidget);
      final activeVpnButton = find.byKey(
        const ValueKey<String>('service-route-discord-vpn'),
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: activeVpnButton,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.textContaining('dropo безопасно переподключит VPN автоматически'),
        findsOneWidget,
      );

      final vpnButton = find.byKey(
        const ValueKey<String>('service-route-discord-vpn'),
      );
      await tester.ensureVisible(vpnButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(vpnButton);
      await tester.pump(const Duration(milliseconds: 800));

      expect(bridge.lastMethod, 'vpn');
      expect(
        find.textContaining('VPN автоматически переподключён'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android shell uses bottom navigation and requires subscription before VPN start',
    (tester) async {
      debugMobileShellOverride = true;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => debugMobileShellOverride = null);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bridge = MockCoreBridge();
      await tester.pumpWidget(MaterialApp(home: DropoHomePage(bridge: bridge)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Главная'), findsOneWidget);
      expect(find.text('Настройки'), findsOneWidget);
      expect(find.text('Еще'), findsOneWidget);
      expect(find.text('Рабочие сети'), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);

      await tester.tap(
        find
            .ancestor(
              of: find.text('Настройки'),
              matching: find.byType(GestureDetector),
            )
            .last,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Сервисы и маршруты'), findsOneWidget);
      expect(find.text('Авто'), findsWidgets);
      expect(find.text('Через VPN'), findsWidgets);
      expect(find.text('Напрямую'), findsWidgets);
      final androidZapret = find.byKey(
        const ValueKey<String>('service-route-discord-zapret'),
      );
      expect(androidZapret, findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: androidZapret,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(
        find
            .ancestor(
              of: find.text('Еще'),
              matching: find.byType(GestureDetector),
            )
            .last,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Разделы'), findsOneWidget);
      expect(find.text('Профили'), findsOneWidget);
      expect(find.text('Статистика'), findsOneWidget);
      expect(find.text('Логи'), findsOneWidget);
      expect(find.text('Выход'), findsOneWidget);

      await tester.tap(find.text('Логи').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Android core, VpnService и sing-box.'), findsOneWidget);
      expect(find.text('Копировать всё'), findsOneWidget);
      expect(find.text('Открыть папку с логами'), findsNothing);

      await tester.tap(
        find
            .ancestor(
              of: find.text('Главная'),
              matching: find.byType(GestureDetector),
            )
            .last,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.byIcon(Icons.power_settings_new));
      await tester.pump();

      expect(
        find.text('Добавьте VPN-подписку для запуска на Android.'),
        findsOneWidget,
      );
      expect(find.text('Добавить'), findsWidgets);
      expect((await bridge.status()).connected, isFalse);

      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('autostart prompt: ОК returns true (enable autostart)', (
    tester,
  ) async {
    bool? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: autoStartPromptDialogForTest(
          onDecision: (value) => decision = value,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Автозапуск'), findsOneWidget);
    expect(find.text('ОК'), findsOneWidget);
    expect(find.text('Нет, не надо'), findsOneWidget);

    await tester.tap(find.text('ОК'));
    expect(decision, isTrue);
  });

  testWidgets('cold start starts an installed Windows update automatically', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bridge = _UpdateAvailableBridge();
    await tester.pumpWidget(MaterialApp(home: DropoHomePage(bridge: bridge)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Доступна версия 3.0.4'), findsWidgets);
    expect(find.text('Обновить и перезапустить'), findsOneWidget);
    expect(
      bridge.updateCheckCalls,
      1,
      reason: 'each successful Windows initialization must check once',
    );
    expect(
      bridge.updateInstallCalls,
      1,
      reason: 'an installed Windows release must update without another click',
    );

    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets(
    'bundled Windows runtime never shows the legacy component download strip',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: DropoHomePage(bridge: _BundledRuntimePreparingBridge()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(find.textContaining('Нужны компоненты'), findsNothing);
      expect(find.textContaining('Нажмите, чтобы скачать'), findsNothing);
      expect(
        find.textContaining('Встроенный runtime не прошёл проверку'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'bounded background strategy progress is sorted first and reports retries',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final bridge = _StrategyProgressBridge();
      addTearDown(bridge.close);
      await bridge.setConnected(true);
      await tester.pumpWidget(MaterialApp(home: DropoHomePage(bridge: bridge)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      bridge.emit('route-probe-start', const {
        'source': 'background-service-strategy',
        'serviceCount': 2,
        'hasSubscription': false,
        'services': [
          {'tag': 'youtube', 'name': 'YouTube'},
          {'tag': 'discord', 'name': 'Discord'},
        ],
      });
      bridge.emit('route-probe-candidate', const {
        'source': 'background-service-strategy',
        'serviceTag': 'discord',
        'serviceName': 'Discord',
        'methodTag': 'discord-native-2',
        'methodLabel': 'Discord strategy 2',
        'status': 'voice-check',
        'attempt': 1,
        'attemptTotal': 4,
        'strategyIndex': 1,
        'strategyTotal': 4,
        'cycle': 1,
        'cycleTotal': 1,
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('может занять до часа'), findsNothing);
      expect(find.text('Подбирается · попытка 1/4'), findsOneWidget);
      final discordTop = tester.getTopLeft(find.text('Discord').first).dy;
      final youtubeTop = tester.getTopLeft(find.text('YouTube').first).dy;
      expect(discordTop, lessThan(youtubeTop));

      bridge.emit('route-probe-service', const {
        'source': 'background-service-strategy',
        'tag': 'discord',
        'name': 'Discord',
        'methodTag': 'discord-native-2',
        'methodLabel': 'Discord strategy 2',
        'success': false,
        'final': false,
        'retrying': true,
        'status': 'retrying',
        'attempt': 1,
        'attemptTotal': 4,
      });
      bridge.emit('route-probe-candidate', const {
        'source': 'background-service-strategy',
        'serviceTag': 'discord',
        'serviceName': 'Discord',
        'methodLabel': 'Discord strategy 3',
        'status': 'voice-check',
        'attempt': 2,
        'attemptTotal': 4,
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('Discord strategy 2 не сработала'),
        findsOneWidget,
      );
      expect(find.textContaining('попытка 1/4'), findsWidgets);
      expect(find.text('Подбирается · попытка 2/4'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('autostart prompt: «Нет, не надо» returns false (decline)', (
    tester,
  ) async {
    bool? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: autoStartPromptDialogForTest(
          onDecision: (value) => decision = value,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Нет, не надо'));
    expect(decision, isFalse);
  });

  group('AppConfig.autoStartPrompted controls the first-run prompt', () {
    test('missing field is treated as already answered (no prompt)', () {
      expect(AppConfig.fromJson(const {}).autoStartPrompted, isTrue);
    });

    test('explicit false requests the prompt', () {
      expect(
        AppConfig.fromJson(const {
          'autoStartPrompted': false,
        }).autoStartPrompted,
        isFalse,
      );
    });

    test('explicit true suppresses the prompt', () {
      expect(
        AppConfig.fromJson(const {'autoStartPrompted': true}).autoStartPrompted,
        isTrue,
      );
    });

    test('copyWith carries autoStartPrompted through', () {
      final resolved = AppConfig.defaults.copyWith(
        autoStart: false,
        autoStartPrompted: true,
      );
      expect(resolved.autoStart, isFalse);
      expect(resolved.autoStartPrompted, isTrue);
    });
  });

  testWidgets(
    'Dropo Space first-run notice has no checkbox and closes after 8 seconds',
    (tester) async {
      bool? openDropoSpace;
      final info = AndroidCompatibilityInfo.fromJson(const {
        'supported': true,
        'manufacturer': 'Google',
        'brand': 'google',
        'model': 'Pixel',
        'device': 'pixel',
        'sdk': 35,
        'dropoSpaceSupported': true,
        'dropoSpaceReady': false,
        'dropoSpacePaused': false,
        'dropoSpaceCanCreate': true,
        'privateSpaceSupported': true,
        'promptDismissed': false,
        'searchUrl': '',
        'riskApps': [
          {
            'packageName': 'ru.rostel',
            'name': 'Госуслуги',
            'installed': true,
            'inDropoSpace': false,
          },
        ],
      });

      await tester.pumpWidget(
        MaterialApp(
          home: androidCompatibilityNoticeDialogForTest(
            info: info,
            onDecision: (value) => openDropoSpace = value,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Больше не показывать'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Окно закроется через 8 сек.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(openDropoSpace, isNull);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(openDropoSpace, isFalse);
    },
  );

  testWidgets('Dropo Space first-run notice can open the section immediately', (
    tester,
  ) async {
    bool? openDropoSpace;
    final info = AndroidCompatibilityInfo.fromJson(const {
      'supported': true,
      'sdk': 35,
      'dropoSpaceSupported': true,
      'dropoSpaceCanCreate': true,
      'promptDismissed': false,
      'riskApps': [
        {'packageName': 'ru.rostel', 'name': 'Госуслуги', 'installed': true},
      ],
    });

    await tester.pumpWidget(
      MaterialApp(
        home: androidCompatibilityNoticeDialogForTest(
          info: info,
          onDecision: (value) => openDropoSpace = value,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('В Dropo Space'));

    expect(openDropoSpace, isTrue);
    await tester.pump(const Duration(seconds: 8));
    expect(openDropoSpace, isTrue);
  });

  test('UpdateInfo keeps fork Android APK asset details', () {
    final info = UpdateInfo.fromJson(const {
      'success': true,
      'hasUpdate': true,
      'currentVersion': '2.1.6',
      'latestVersion': '2.1.7',
      'releaseURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v2.1.7',
      'downloadURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v2.1.7/dropo-Android-arm64.apk',
      'assetName': 'dropo-Android-arm64.apk',
      'fileSize': 58242990,
      'platform': 'android',
      'selfUpdate': false,
    });

    expect(info.hasUpdate, isTrue);
    expect(info.downloadUrl, contains('dropo-Android-arm64.apk'));
    expect(info.assetName, 'dropo-Android-arm64.apk');
    expect(info.fileSize, 58242990);
    expect(info.platform, 'android');
    expect(info.selfUpdate, isFalse);
  });

  test('DepsStatus preserves Defender degraded-mode diagnostics', () {
    final status = DepsStatus.fromJson(const {
      'managed': true,
      'bundled': true,
      'ready': true,
      'degraded': true,
      'required': 'abc123',
      'installed': 'abc123',
      'sizeMB': 65,
      'blockedComponents': ['legacy-helper.exe'],
      'warning': 'Runtime component unavailable',
    });

    expect(status.bundled, isTrue);
    expect(status.ready, isTrue);
    expect(status.degraded, isTrue);
    expect(status.blockedComponents, ['legacy-helper.exe']);
    expect(status.warning, 'Runtime component unavailable');
  });

  test('UpdateInfo rejects incomplete bridge responses', () {
    final info = UpdateInfo.fromJson(const {});

    expect(info.success, isFalse);
    expect(info.hasUpdate, isFalse);
  });

  test('automatic update policy is limited to installed self-updates', () {
    UpdateInfo info({required bool selfUpdate, bool hasUpdate = true}) {
      return UpdateInfo.fromJson({
        'success': true,
        'hasUpdate': hasUpdate,
        'currentVersion': '3.0.26',
        'latestVersion': '3.0.27',
        'releaseURL': 'https://github.com/example/release',
        'downloadURL': 'https://github.com/example/asset',
        'assetName': selfUpdate
            ? 'dropo-Windows-Setup-x64.exe'
            : 'dropo-Windows-Portable-x64.zip',
        'fileSize': 123456,
        'platform': 'windows',
        'selfUpdate': selfUpdate,
      });
    }

    expect(
      shouldAutomaticallyInstallUpdate(info(selfUpdate: true), enabled: true),
      isTrue,
    );
    expect(
      shouldAutomaticallyInstallUpdate(info(selfUpdate: false), enabled: true),
      isFalse,
    );
    expect(
      shouldAutomaticallyInstallUpdate(info(selfUpdate: true), enabled: false),
      isFalse,
    );
    expect(
      shouldAutomaticallyInstallUpdate(
        info(selfUpdate: true, hasUpdate: false),
        enabled: true,
      ),
      isFalse,
    );
  });

  test('core compatibility rejects a stale build on the local bridge', () {
    const info = <String, dynamic>{
      'bridge': 'dropo-core',
      'version': <String, dynamic>{'version': '3.0.25', 'buildHash': 'b88ccae'},
    };

    expect(
      coreCompatibilityError(
        info,
        expectedVersion: '3.0.25',
        expectedBuildHash: '12ab34cd56ef',
      ),
      contains('b88ccae'),
    );
    expect(
      coreCompatibilityError(
        info,
        expectedVersion: '3.0.25',
        expectedBuildHash: 'b88ccae',
      ),
      isNull,
    );
  });

  test('core compatibility rejects a non-Dropo listener', () {
    expect(
      coreCompatibilityError(
        const <String, dynamic>{'bridge': 'other'},
        expectedVersion: '3.0.25',
        expectedBuildHash: '12ab34cd56ef',
      ),
      contains('другим приложением'),
    );
  });

  test('MockCoreBridge exposes an autonomous Android UI backend', () async {
    final bridge = MockCoreBridge();

    await bridge.ensureStarted();
    expect((await bridge.status()).connected, isFalse);

    final connected = await bridge.setConnected(true);
    expect(connected['success'], isTrue);
    expect((await bridge.status()).connected, isTrue);
    expect(await bridge.logs(), contains('Mock VPN session is connected'));

    final events = await bridge.events(since: 0);
    expect(events.map((event) => event.name), contains('vpn-status-changed'));
  });
}

class _UpdateAvailableBridge extends MockCoreBridge {
  int updateCheckCalls = 0;
  int updateInstallCalls = 0;

  @override
  Future<UpdateInfo> checkUpdates() async {
    updateCheckCalls += 1;
    return UpdateInfo.fromJson(const {
      'success': true,
      'hasUpdate': true,
      'currentVersion': '3.0.3',
      'latestVersion': '3.0.4',
      'releaseURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v3.0.4',
      'downloadURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Windows-Setup-x64.exe',
      'assetName': 'dropo-Windows-Setup-x64.exe',
      'fileSize': 123456,
      'platform': 'windows',
      'selfUpdate': true,
    });
  }

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    updateInstallCalls += 1;
    return {
      'success': false,
      'error': 'Test bridge stops before replacing the running test process',
    };
  }
}

class _BundledRuntimePreparingBridge extends MockCoreBridge {
  @override
  Future<CoreStatus> status() async {
    return CoreStatus.fromJson(const {
      'success': true,
      'connected': false,
      'running': false,
      'connecting': false,
      'hasError': false,
      'configExists': true,
      'singboxExists': false,
      'networkMode': 'auto',
      'networkModeLabel': 'Авто',
      'networkModeDescription': 'Подготовка встроенного runtime.',
      'dependencies': {
        'managed': true,
        'bundled': true,
        'ready': false,
        'degraded': false,
        'required': 'runtime-test',
        'installed': '',
        'sizeMB': 86,
        'warning':
            'Встроенный runtime не прошёл проверку целостности; переустановите приложение из официального пакета',
      },
      'version': {
        'version': '3.0.14',
        'fullVersion': '3.0.14-test',
        'singboxVersion': '1.13.14',
      },
    });
  }
}

class _StrategyProgressBridge extends MockCoreBridge {
  final StreamController<BridgeEvent> _controller =
      StreamController<BridgeEvent>.broadcast();
  int _eventID = 100;

  @override
  bool get prefersPushEvents => true;

  @override
  Stream<BridgeEvent> watchEvents() => _controller.stream;

  void emit(String name, Map<String, dynamic> payload) {
    _controller.add(BridgeEvent(id: _eventID++, name: name, payload: payload));
  }

  Future<void> close() => _controller.close();

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    return const [
      RouteService(
        tag: 'youtube',
        name: 'YouTube',
        method: 'Direct strategy',
        selectedMethod: 'auto',
        requiresVpn: false,
        delayMs: 40,
        domainSuffixes: ['youtube.com'],
      ),
      RouteService(
        tag: 'discord',
        name: 'Discord',
        method: 'Direct strategy',
        selectedMethod: 'auto',
        requiresVpn: false,
        delayMs: 55,
        domainSuffixes: ['discord.com'],
      ),
    ];
  }
}

class _RoutePolicyRecordingBridge extends MockCoreBridge {
  _RoutePolicyRecordingBridge({
    this.restarted = false,
    this.strategyNotFound = false,
  });

  final bool restarted;
  final bool strategyNotFound;
  String lastTag = '';
  String lastMethod = '';
  String currentMethod = 'direct';
  String strategyMode = 'auto';
  String selectedStrategy = '';
  String lastStrategyMode = '';
  String lastStrategyTag = '';

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    return [
      RouteService(
        tag: 'discord',
        name: 'Discord',
        method: 'Discord active decoys x3',
        selectedMethod: currentMethod,
        zapretSupported: true,
        zapretStrategyMode: strategyMode,
        zapretSelectedStrategy: selectedStrategy,
        zapretEffectiveStrategy: 'flowseal-1102-discord-alt13',
        zapretEffectiveStrategyLabel: 'Flowseal 1.10.2 ALT13 — Discord',
        zapretStrategySource: 'auto-saved',
        zapretStrategyNotFound: strategyNotFound,
        zapretStrategyOptions: [
          ZapretStrategyOption(
            tag: 'flowseal-1102-discord-alt13',
            label: 'Flowseal 1.10.2 ALT13 — Discord',
          ),
          ZapretStrategyOption(
            tag: 'discord-zero-v2',
            label: 'Discord zero + SNI split',
          ),
        ],
        requiresVpn: false,
        delayMs: 0,
        domainSuffixes: ['discord.com', 'discord.gg'],
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    lastTag = tag;
    lastMethod = method;
    currentMethod = method;
    return {
      'success': true,
      'tag': tag,
      'method': method,
      'restarted': restarted,
    };
  }

  @override
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  ) async {
    lastStrategyMode = mode;
    lastStrategyTag = strategyTag;
    strategyMode = mode;
    selectedStrategy = mode == 'manual' ? strategyTag : '';
    return {
      'success': true,
      'tag': tag,
      'mode': mode,
      'zapretSelectedStrategy': selectedStrategy,
    };
  }
}
