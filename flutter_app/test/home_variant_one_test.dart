import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _VariantBridge extends MockCoreBridge {
  _VariantBridge({this.connected = false});
  bool connected;
  final external = <String>[];

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
  };

  @override
  Future<CoreStatus> status() async =>
      (await super.status()).copyWith(connected: connected, running: connected);

  @override
  Future<void> openExternal(String url) async => external.add(url);
}

class _DisplayTransport implements AccountTransport {
  String name = 'Джамуха';
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

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  bool mobile = false,
  double scale = 1,
  bool connected = false,
  String mode = 'blocked_only',
  _VariantBridge? providedBridge,
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
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    debugAccountTransport = null;
    debugAccountSessionToken = null;
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

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
        await _pump(tester, size: size, mobile: mobile, scale: scale);
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
        expect(
          find.byKey(const ValueKey('toggle-home-route-services')),
          findsNothing,
        );
        await _tap(tester, 'home-routing-selected');
        expect(tester.getSize(planet), before);
        await _tap(tester, 'toggle-home-route-services');
        expect(tester.getSize(planet), before);
        expect(tester.getSize(selected), selectedSize);
        if (scale == 1) {
          expect(tester.getRect(planet), planetRect);
          expect(tester.getRect(selected), selectedRect);
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
    'Android disabled mode explanation keeps planet and selector stable',
    (tester) async {
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
      final modesBefore = tester.getRect(selected);
      final updateSlot = tester.getRect(
        find.byKey(const ValueKey('home-update-slot')),
      );
      expect(updateSlot.overlaps(planetBefore), isFalse);
      expect(
        find.byKey(const ValueKey('home-routing-read-only')),
        findsNothing,
      );
      bridge.connected = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Отключите VPN, чтобы сменить режим'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(selected).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(all).onPressed, isNull);
      expect(tester.getRect(planet), planetBefore);
      expect(tester.getRect(selected), modesBefore);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
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
      expect(
        find.byKey(const ValueKey('home-connect')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('planet-connected')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('connected action is transparent over a larger real Earth', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1536, 1024), connected: true);
    final action = tester.widget<FilledButton>(
      find.byKey(const ValueKey('home-connect')),
    );
    expect(action.style!.backgroundColor!.resolve({}), Colors.transparent);
    expect(action.style!.side!.resolve({})!.color, const Color(0xFF5CF0B0));
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
