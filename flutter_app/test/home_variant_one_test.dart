import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _VariantBridge extends MockCoreBridge {
  _VariantBridge({this.connected = false, this.reduceMotion = true});
  final bool reduceMotion;
  bool connected;
  final external = <String>[];

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': reduceMotion,
  };

  @override
  Future<CoreStatus> status() async =>
      (await super.status()).copyWith(connected: connected, running: connected);

  @override
  Future<void> openExternal(String url) async => external.add(url);
}

class _DisplayTransport implements AccountTransport {
  String name = 'Джамуха';
  DateTime? turboUntil;
  int profileReads = 0;
  bool failProfile = false;
  Completer<Map<String, dynamic>>? firstProfile;
  final paths = <String>[];

  Map<String, dynamic> get profile => {
    'account': {
      'displayName': name,
      'telegramUsername': 'dropo_owner',
      'id': 'private-account-identifier',
      'maskedPhone': 'private-phone-value',
      'plan': 'Dropo Free',
      if (turboUntil != null)
        'speedBoostUntil': turboUntil!.toUtc().toIso8601String(),
    },
  };

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    paths.add(path);
    if (path == '/v1/me') {
      profileReads++;
      if (failProfile) throw StateError('Test account offline');
      if (profileReads == 1 && firstProfile != null) {
        return firstProfile!.future;
      }
      return profile;
    }
    if (path == '/v1/capabilities') {
      return {
        'registrationAvailable': true,
        'phoneRequired': false,
        'authMode': 'telegram_bot',
        'purchasingAvailable': false,
      };
    }
    return {'success': true};
  }

  @override
  void close() {}
}

class _LiveProfileClient extends OwnedVPNClient {
  _LiveProfileClient() : super(endpoint: 'https://api.droponevedimka.ru');
  final applied = <DateTime?>[];
  @override
  Future<Map<String, dynamic>> synchronizeEntitlement(
    CoreBridge bridge,
    String token,
    DateTime? turboUntil, {
    AccountTransport? transport,
    bool Function()? isCurrent,
    bool windowsLive = false,
  }) async {
    expect(isCurrent!(), true);
    final hadTurbo = applied.lastOrNull != null;
    applied.add(turboUntil);
    return {
      'success': true,
      'turboActivated': windowsLive && !hadTurbo && turboUntil != null,
      'turboRemoved': windowsLive && hadTurbo && turboUntil == null,
    };
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  bool mobile = false,
  double scale = 1,
  bool connected = false,
  String mode = 'blocked_only',
  _VariantBridge? providedBridge,
  OwnedVPNClient? ownedVPN,
}) async {
  debugMobileShellOverride = mobile;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final bridge = providedBridge ?? _VariantBridge(connected: connected);
  await bridge.setRoutingMode(mode);
  await bridge.saveSubscription('https://example.test/fixture-subscription');
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('variant-one-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: bridge.reduceMotion,
          ),
          child: child!,
        ),
        home: DropoHomePage(bridge: bridge, ownedVPN: ownedVPN),
      ),
    ),
  );
  if (bridge.reduceMotion) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
  if (directory.isEmpty) throw StateError('A capture directory is required.');
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('variant-one-capture')),
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
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    expect(await preloadAtlasPlanetForTesting(), isTrue);
    if (const bool.fromEnvironment('DROPO_UI_CAPTURE') && Platform.isWindows) {
      for (final family in ['Consolas', 'monospace']) {
        await (FontLoader(family)..addFont(
              File(
                'C:/Windows/Fonts/consola.ttf',
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            ))
            .load();
      }
    }
  });

  tearDown(() {
    debugMobileShellOverride = null;
    debugAndroidPlatformOverride = null;
    debugAccountTransport = null;
    debugAccountSessionToken = null;
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  for (final tier in ['free', 'turbo', 'expired']) {
    testWidgets('Turbo offer before connection follows $tier entitlement', (
      tester,
    ) async {
      final api = _DisplayTransport()
        ..firstProfile = Completer<Map<String, dynamic>>();
      if (tier != 'free') {
        api.turboUntil = DateTime.now().add(
          Duration(days: tier == 'turbo' ? 1 : -1),
        );
      }
      debugAccountTransport = api;
      debugAccountSessionToken = 'fixture-restored-session';
      await _pump(tester, size: const Size(1200, 820), mode: 'all_traffic');
      expect(api.profileReads, 1);
      expect(find.byKey(const ValueKey('free-plan-banner')), findsNothing);
      api.firstProfile!.complete(api.profile);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('free-plan-banner')),
        tier == 'turbo' ? findsNothing : findsOneWidget,
      );
      expect(find.text('Отключить'), findsNothing);
      if (tier != 'turbo') {
        expect(find.text('Купить Турбо'), findsOneWidget);
        await _tap(tester, 'free-plan-turbo');
        expect(find.byKey(const ValueKey('turbo-section')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Android purchase button stays hidden while Turbo restores', (
    tester,
  ) async {
    debugAndroidPlatformOverride = true;
    final api = _DisplayTransport()
      ..firstProfile = Completer<Map<String, dynamic>>()
      ..turboUntil = DateTime.now().add(const Duration(days: 1));
    debugAccountTransport = api;
    debugAccountSessionToken = 'fixture-restored-session';
    await _pump(tester, size: const Size(390, 844), mobile: true);
    final purchase = find.byKey(const ValueKey('android-buy-boost'));
    expect(api.profileReads, 1);
    expect(purchase, findsNothing);
    api.firstProfile!.complete(api.profile);
    await tester.pumpAndSettle();
    expect(purchase, findsNothing);
    expect(find.text(api.name), findsOneWidget);
  });

  testWidgets('an external Turbo grant and revocation update the open home', (
    tester,
  ) async {
    final api = _DisplayTransport();
    debugAccountTransport = api;
    debugAccountSessionToken = 'fixture-restored-session';
    await _pump(tester, size: const Size(1200, 820));
    final offer = find.byKey(const ValueKey('free-plan-banner'));
    expect(offer, findsOneWidget);
    api.turboUntil = DateTime.now().add(const Duration(days: 1));
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(offer, findsNothing);
    api.turboUntil = null;
    api.failProfile = true;
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(offer, findsNothing);
    api.failProfile = false;
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpAndSettle();
    expect(offer, findsOneWidget);
    expect(api.paths.where((p) => p == '/v1/capabilities'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Windows applies a grant and revoke during VPN and displays both notices',
    (tester) async {
      final api = _DisplayTransport();
      final profiles = _LiveProfileClient();
      final bridge = _VariantBridge(connected: true);
      debugAccountTransport = api;
      debugAccountSessionToken = 'fixture-restored-session';
      await _pump(
        tester,
        size: const Size(1200, 820),
        providedBridge: bridge,
        ownedVPN: profiles,
      );
      final until = DateTime.now().toUtc().add(const Duration(days: 2));
      api.turboUntil = until;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('free-plan-banner')), findsNothing);
      expect(profiles.applied.where((expiry) => expiry == until), hasLength(1));
      expect(find.text('Dropo Turbo активирован'), findsOneWidget);
      api.turboUntil = null;
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(profiles.applied, [null, until, null]);
      expect(find.text('Dropo Turbo отключён'), findsOneWidget);
      expect(find.byKey(const ValueKey('free-plan-banner')), findsOneWidget);
      expect(bridge.connected, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isWindows,
  );

  testWidgets('returning from a gift link checks Turbo before the next timer', (
    tester,
  ) async {
    final api = _DisplayTransport();
    debugAccountTransport = api;
    debugAccountSessionToken = 'fixture-restored-session';
    await _pump(tester, size: const Size(390, 844), mobile: true);
    expect(find.byKey(const ValueKey('free-plan-banner')), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    api.turboUntil = DateTime.now().add(const Duration(days: 1));
    await tester.pump(const Duration(minutes: 2));
    expect(api.profileReads, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.profileReads, 2);
    expect(find.byKey(const ValueKey('free-plan-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (name, size, mobile, scale) in [
    ('windows', const Size(1200, 820), false, 1.0),
    ('compact', const Size(684, 461), false, 1.0),
    ('android', const Size(390, 844), true, 1.0),
    ('android-small', const Size(320, 568), true, 1.0),
    ('android-large-text', const Size(320, 568), true, 2.0),
  ]) {
    testWidgets(
      'bottom Turbo card fits $name and keeps the primary action reachable',
      (tester) async {
        debugAccountTransport = _DisplayTransport();
        await _pump(
          tester,
          size: size,
          mobile: mobile,
          scale: scale,
          mode: 'all_traffic',
        );
        final offer = find.byKey(const ValueKey('free-plan-banner'));
        final card = tester.getRect(offer),
            action = tester.getRect(find.byKey(const ValueKey('home-connect')));
        expect(card.bottom, lessThanOrEqualTo(size.height));
        expect(card.bottom, greaterThan(size.height * .6));
        expect(card.overlaps(action), false);
        if (!mobile) {
          final turbo = tester.getRect(
            find.byKey(const ValueKey('free-plan-turbo')),
          );
          final version = tester.getRect(
            find.byKey(const ValueKey('app-version')),
          );
          final brand = tester.getRect(find.text('Dropo').first);
          expect(size.height - card.bottom, closeTo(6, .1));
          expect(turbo.top - card.top, greaterThanOrEqualTo(5));
          expect(card.bottom - turbo.bottom, greaterThanOrEqualTo(5));
          expect(version.left, greaterThanOrEqualTo(brand.right));
          expect(version.center.dy, closeTo(brand.center.dy, 8));
        }
        expect(tester.takeException(), isNull);
        await _capture(tester, 'bottom-turbo-$name');
        await _tap(tester, 'free-plan-turbo');
        expect(find.byKey(const ValueKey('account-section')), findsOneWidget);
      },
    );
  }

  test(
    'account display strips controls, bounds public name and rejects bad username',
    () {
      final snapshot = AccountDisplaySnapshot.fromJson({
        'displayName': '\u202eДжамуха\n\t${'я' * 100}',
        'telegramUsername': 'https://untrusted.example/avatar.png',
      });
      expect(snapshot.displayName.runes.length, 80);
      expect(snapshot.displayName, startsWith('Джамуха'));
      expect(snapshot.displayName, isNot(contains('\u202e')));
      expect(snapshot.telegramUsername, isEmpty);
      expect(AccountDisplaySnapshot.fromJson({}).displayName, 'Аккаунт');
    },
  );

  for (final (size, mobile, scale) in [
    (const Size(684, 461), false, 1.0),
    (const Size(820, 560), false, 1.0),
    (const Size(1536, 1024), false, 1.0),
    (const Size(390, 844), true, 1.0),
    (const Size(320, 568), true, 2.0),
  ]) {
    testWidgets(
      'mode changes preserve Earth and equal segments at $size $scale',
      (tester) async {
        await _pump(
          tester,
          size: size,
          mobile: mobile,
          scale: scale,
          connected: true,
        );
        final planet = find.byKey(const ValueKey('atlas-planet'));
        final connect = find.byKey(const ValueKey('home-connect'));
        final selected = find.byKey(const ValueKey('home-routing-selected'));
        final all = find.byKey(const ValueKey('home-routing-all-vpn'));
        final before = tester.getSize(planet);
        final actionSize = tester.getSize(connect);
        final selectedSize = tester.getSize(selected);
        final planetRect = tester.getRect(planet);
        final selectedRect = tester.getRect(selected);
        expect(tester.getSize(all), selectedSize);
        expect(
          find.text('Только выбранные сервисы. Остальное — напрямую.'),
          findsNothing,
        );
        await _capture(
          tester,
          'variant-one-${size.width.toInt()}-$scale-services',
        );
        await _tap(tester, 'home-routing-all-vpn');
        expect(tester.getSize(planet), before);
        expect(tester.getSize(connect), actionSize);
        expect(tester.getSize(selected), selectedSize);
        expect(tester.getSize(all), selectedSize);
        if (scale == 1) {
          expect(tester.getRect(planet), planetRect);
          expect(tester.getRect(selected), selectedRect);
        }
        expect(find.byKey(const ValueKey('routing-tab-apps')), findsNothing);
        await _tap(tester, 'home-routing-selected');
        expect(tester.getSize(planet), before);
        expect(find.byKey(const ValueKey('service-search')), findsOneWidget);
        expect(tester.getSize(selected), selectedSize);
        if (scale == 1) {
          expect(tester.getRect(planet), planetRect);
          expect(tester.getRect(selected), selectedRect);
        }
        final manualTabs = find.byType(TabBar);
        await tester.ensureVisible(manualTabs);
        await tester.pumpAndSettle();
        if (scale == 1) {
          final tabBarRect = tester.getRect(manualTabs);
          for (final tab in ['apps', 'protected', 'domains']) {
            final rect = tester.getRect(
              find.byKey(ValueKey('routing-tab-$tab')),
            );
            expect(rect.left, greaterThanOrEqualTo(tabBarRect.left));
            expect(rect.right, lessThanOrEqualTo(tabBarRect.right));
          }
        }
        await _capture(
          tester,
          'variant-one-${size.width.toInt()}-$scale-services-expanded',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Windows reveals routing after connection and hides it on disconnect',
    (tester) async {
      final bridge = _VariantBridge(reduceMotion: false);
      await _pump(
        tester,
        size: const Size(960, 640),
        providedBridge: bridge,
        mode: 'all_traffic',
      );
      final selector = find.byKey(const ValueKey('home-routing-selected'));
      expect(selector, findsNothing);
      bridge.connected = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      final reveal = find
          .ancestor(of: selector, matching: find.byType(Opacity))
          .first;
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Opacity>(reveal).opacity, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<Opacity>(reveal).opacity, 1);
      bridge.connected = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(selector, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Android reveals routing while keeping the planet centered', (
    tester,
  ) async {
    final bridge = _VariantBridge();
    await _pump(
      tester,
      size: const Size(390, 844),
      mobile: true,
      mode: 'all_traffic',
      providedBridge: bridge,
    );
    final planet = find.byKey(const ValueKey('atlas-planet'));
    final selected = find.byKey(const ValueKey('home-routing-selected'));
    final all = find.byKey(const ValueKey('home-routing-all-vpn'));
    final planetBefore = tester.getRect(planet);
    expect(selected, findsNothing);
    expect(all, findsNothing);
    expect(find.byKey(const ValueKey('home-update-slot')), findsNothing);
    expect(find.byKey(const ValueKey('home-routing-live')), findsNothing);
    bridge.connected = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-routing-live')), findsOneWidget);
    expect(tester.widget<OutlinedButton>(selected).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(all).onPressed, isNotNull);
    expect(tester.getRect(planet).size, planetBefore.size);
    expect(tester.getCenter(planet).dx, planetBefore.center.dx);
    await tester.ensureVisible(selected);
    await tester.tap(selected);
    await tester.pumpAndSettle();
    expect((await bridge.appConfig())['routingMode'], 'blocked_only');
    expect(bridge.connected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (size, mobile, scale) in [
    (const Size(684, 461), false, 1.0),
    (const Size(820, 560), false, 1.0),
    (const Size(1536, 1024), false, 1.0),
    (const Size(390, 844), true, 1.0),
    (const Size(320, 568), true, 2.0),
  ]) {
    testWidgets(
      'connected variant keeps account and controls reachable at $size $scale',
      (tester) async {
        debugAccountTransport = _DisplayTransport();
        debugAccountSessionToken = 'test-only-profile-session';
        await _pump(
          tester,
          size: size,
          mobile: mobile,
          scale: scale,
          connected: true,
        );
        expect(find.byKey(const ValueKey('planet-connected')), findsOneWidget);
        final account = find.byKey(const ValueKey('nav-account'));
        expect(account.hitTestable(), findsOneWidget);
        expect(tester.getRect(account).height, greaterThanOrEqualTo(48));
        expect(
          find.byKey(const ValueKey('app-version')).hitTestable(),
          findsOneWidget,
        );
        await _capture(
          tester,
          'variant-one-${size.width.toInt()}-$scale-connected',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('disabled guest capability never creates a background profile', (
    tester,
  ) async {
    final service = _DisplayTransport();
    debugAccountTransport = service;
    await _pump(tester, size: const Size(820, 560));
    expect(service.paths, ['/v1/capabilities']);
    expect(
      service.paths.where((path) => path.startsWith('/v1/auth/')),
      isEmpty,
    );
    expect(find.text('Войти через Telegram'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-connect')).hitTestable(),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'offline profile leaves stored-account presentation and VPN independent',
    (tester) async {
      final service = _DisplayTransport()..failProfile = true;
      debugAccountTransport = service;
      debugAccountSessionToken = 'test-only-profile-session';
      await _pump(tester, size: const Size(820, 560), connected: true);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('account-display-name')))
            .data,
        'Аккаунт',
      );
      expect(service.paths, ['/v1/capabilities', '/v1/me']);
      expect(find.byKey(const ValueKey('free-plan-banner')), findsNothing);
      expect(
        find.byKey(const ValueKey('home-connect')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('planet-connected')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('connected action uses the Android-style dark capsule', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1536, 1024), connected: true);
    final action = tester.widget<FilledButton>(
      find.byKey(const ValueKey('home-connect')),
    );
    expect(action.style!.backgroundColor!.resolve({}), const Color(0xED102019));
    expect(action.style!.side!.resolve({})!.color, const Color(0x558CAF9D));
    expect(find.text('Отключить'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('atlas-planet'))).width,
      600,
    );
    await _capture(tester, 'variant-one-desktop-connected-1536');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('anonymous account is anchored below the desktop navigation', (
    tester,
  ) async {
    await _pump(tester, size: const Size(820, 560));
    final account = find.byKey(const ValueKey('nav-account'));
    expect(account, findsOneWidget);
    final accountRect = tester.getRect(account);
    expect(accountRect.left, lessThan(208));
    expect(accountRect.bottom, greaterThan(530));
    expect(
      tester.getRect(find.byKey(const ValueKey('nav-help'))).bottom,
      lessThan(accountRect.top),
    );
    expect(find.text('Войти через Telegram'), findsOneWidget);
    expect(
      find.ancestor(of: account, matching: find.byType(Scrollable)),
      findsNothing,
    );
    await _tap(tester, 'nav-account');
    expect(find.byKey(const ValueKey('account-section')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone account stays bottom-left and drawer has one account link',
    (tester) async {
      await _pump(tester, size: const Size(390, 844), mobile: true);
      final account = find.byKey(const ValueKey('nav-account'));
      final version = find.byKey(const ValueKey('app-version'));
      expect(tester.getRect(account).bottom, 844);
      expect(
        tester.getRect(account).right,
        lessThanOrEqualTo(tester.getRect(version).left),
      );
      await _tap(tester, 'toggle-navigation');
      expect(account, findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-drawer-footer')),
        findsOneWidget,
      );
      await _tap(tester, 'nav-account');
      expect(find.byKey(const ValueKey('account-section')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saved public account name restores independently and updates after logout',
    (tester) async {
      final service = _DisplayTransport();
      debugAccountTransport = service;
      debugAccountSessionToken = 'test-only-profile-session';
      await _pump(tester, size: const Size(820, 560));
      expect(find.text('Джамуха'), findsOneWidget);
      expect(find.text('@dropo_owner'), findsOneWidget);
      expect(find.text('private-phone-value'), findsNothing);
      expect(service.paths, ['/v1/capabilities', '/v1/me']);
      service.name = 'Новое имя';
      await _tap(tester, 'nav-account');
      expect(find.text('Новое имя'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Выйти'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-display-name')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('account-display-name')))
            .data,
        'Войти через Telegram',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late background profile cannot restore a signed-out name', (
    tester,
  ) async {
    final service = _DisplayTransport()
      ..firstProfile = Completer<Map<String, dynamic>>();
    debugAccountTransport = service;
    debugAccountSessionToken = 'test-only-profile-session';
    await _pump(tester, size: const Size(820, 560));
    await _tap(tester, 'nav-account');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Выйти'));
    await tester.pumpAndSettle();
    service.firstProfile!.complete(service.profile);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('account-display-name')))
          .data,
      'Войти через Telegram',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
