import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'unconfigured account makes no requests and preserves credentials',
    (tester) async {
      final service = _FakeAccountTransport();
      final opened = <String>[];
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: AccountPage(
              endpoint: 'http://127.0.0.1:18080',
              available: false,
              transport: service,
              persistSession: false,
              initialToken: 'existing-test-token',
              onOpenExternal: (url) async => opened.add(url),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вход пока недоступен'), findsOneWidget);
      expect(find.textContaining('аккаунт не нужен'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-phone')), findsNothing);
      expect(service.requests, isEmpty);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Telegram registration collects no phone and purchases stay off',
    (tester) async {
      final service = _FakeAccountTransport();
      final opened = <String>[];
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: AccountPage(
              endpoint: 'http://unused.invalid',
              transport: service,
              persistSession: false,
              onOpenExternal: (url) async => opened.add(url),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Войти в Dropo'), findsOneWidget);
      expect(find.text('Войти через Telegram'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-phone')), findsNothing);
      expect(opened, isEmpty);
      await tester.tap(find.byKey(const ValueKey('account-submit')));
      await tester.pump();
      expect(
        opened,
        contains('https://t.me/dropo_test?start=login_test-challenge'),
      );
      expect(service.authBodies.single, {'purpose': 'login'});
      expect(find.text('Ожидаем подтверждение в Telegram'), findsOneWidget);

      service.authApproved = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Локальный пользователь'), findsOneWidget);
      expect(find.text('Dropo Free'), findsOneWidget);
      expect(find.text('150'), findsNothing);
      expect(find.text('Dropo Boost · скоро'), findsOneWidget);
      expect(find.text('Telegram подключён'), findsOneWidget);

      final purchase = tester.widget<FilledButton>(
        find.byKey(const ValueKey('account-buy-speed')),
      );
      expect(purchase.onPressed, isNull);
      expect(service.requests.where((r) => r.$2 == '/v1/products'), isEmpty);
      expect(
        service.requests.where((r) => r.$2.startsWith('/v1/orders')),
        isEmpty,
      );
      expect(opened.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test('account endpoint requires HTTPS except explicit local debug mode', () {
    for (final value in [
      '',
      'http://accounts.example.com',
      'https://user:secret@accounts.example.com',
      'https://accounts.example.com?token=secret',
      'https://accounts.example.com/#callback',
      'https://localhost',
    ]) {
      expect(
        accountEndpointAvailable(value, allowLocalDevelopment: false),
        isFalse,
      );
    }
    expect(
      accountEndpointAvailable(
        'https://accounts.example.com',
        allowLocalDevelopment: false,
      ),
      isTrue,
    );
    expect(
      accountEndpointAvailable(
        'http://127.0.0.1:18080',
        allowLocalDevelopment: false,
      ),
      isFalse,
    );
    expect(
      accountEndpointAvailable(
        'http://127.0.0.1:18080',
        allowLocalDevelopment: true,
      ),
      isTrue,
    );
    expect(
      accountEndpointAvailable(
        'http://[::1]:18080',
        allowLocalDevelopment: true,
      ),
      isTrue,
    );
  });

  testWidgets('server purchase capability alone cannot enable billing', (
    tester,
  ) async {
    final service = _FakeAccountTransport()..purchasingAvailable = true;
    await _pumpAccount(tester, service, initialToken: 'stored-session');
    expect(find.text('Dropo Boost · скоро'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('account-buy-speed')))
          .onPressed,
      isNull,
    );
    expect(service.requests.where((r) => r.$2 == '/v1/products'), isEmpty);
  });

  testWidgets(
    'temporary backend error preserves stored session and retry restores it',
    (tester) async {
      final service = _FakeAccountTransport()
        ..meFailure = const AccountApiException(
          'Temporarily unavailable',
          status: 503,
          code: 'database_unavailable',
        );
      final calls = <String>[];
      const channel = MethodChannel('dropo/account_session');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'read'
            ? jsonEncode({
                'endpoint': 'https://accounts.example.com',
                'token': 'stored-session',
              })
            : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _pumpAccount(tester, service, persistSession: true);
      expect(find.text('Аккаунт временно недоступен'), findsOneWidget);
      expect(calls, ['read']);
      service.meFailure = null;
      await tester.tap(find.byKey(const ValueKey('account-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Локальный пользователь'), findsOneWidget);
      expect(calls, ['read', 'read']);
      expect(service.authBodies, isEmpty);
      await tester.tap(find.text('Выйти'));
      await tester.pumpAndSettle();
      expect(calls.last, 'clear');
      expect(find.text('Войти в Dropo'), findsOneWidget);
    },
  );

  testWidgets(
    'expired session clears credential only on authentication rejection',
    (tester) async {
      final service = _FakeAccountTransport()
        ..meFailure = const AccountApiException(
          'Expired',
          status: 401,
          code: 'invalid_session',
        );
      final calls = <String>[];
      const channel = MethodChannel('dropo/account_session');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return call.method == 'read'
            ? jsonEncode({
                'endpoint': 'https://accounts.example.com',
                'token': 'expired-session',
              })
            : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _pumpAccount(tester, service, persistSession: true);
      expect(find.text('Войти в Dropo'), findsOneWidget);
      expect(calls, ['read', 'clear']);
      expect(find.textContaining('Сессия завершена'), findsOneWidget);
    },
  );

  testWidgets('cancelled authentication ignores late approval', (tester) async {
    final service = _FakeAccountTransport()
      ..pendingPoll = Completer<Map<String, dynamic>>();
    final opened = <String>[];
    await _pumpAccount(tester, service, opened: opened);
    await tester.tap(find.byKey(const ValueKey('account-submit')));
    await tester.pump();
    expect(opened.length, 1);
    await tester.tap(find.text('Отменить'));
    await tester.pump();
    service.pendingPoll!.complete({'status': 'approved'});
    await tester.pumpAndSettle();
    expect(find.text('Войти в Dropo'), findsOneWidget);
    expect(service.requests.where((r) => r.$2.endsWith('/exchange')), isEmpty);
  });

  testWidgets('protected credential cannot cross backend origins', (
    tester,
  ) async {
    final service = _FakeAccountTransport();
    const channel = MethodChannel('dropo/account_session');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      return call.method == 'read'
          ? jsonEncode({
              'endpoint': 'https://other-accounts.example.com',
              'token': 'foreign-session',
            })
          : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await _pumpAccount(tester, service, persistSession: true);
    expect(find.text('Войти в Dropo'), findsOneWidget);
    expect(service.requests.where((r) => r.$2 == '/v1/me'), isEmpty);
  });

  testWidgets(
    'failed protected write keeps explicit memory session across navigation',
    (tester) async {
      final service = _FakeAccountTransport()..authApproved = true;
      final calls = <String>[];
      const channel = MethodChannel('dropo/account_session');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'write') {
          final record =
              jsonDecode((call.arguments as Map)['token'] as String) as Map;
          expect(record['endpoint'], 'https://accounts.example.com');
          expect(record['token'], 'test-access-token');
          throw PlatformException(code: 'storage_unavailable');
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _pumpAccount(tester, service, persistSession: true);
      await tester.tap(find.byKey(const ValueKey('account-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Локальный пользователь'), findsOneWidget);
      expect(find.textContaining('только до закрытия'), findsOneWidget);
      expect(calls, ['read', 'write', 'clear']);
      await _pumpAccount(tester, service, persistSession: true);
      expect(find.text('Локальный пользователь'), findsOneWidget);
      expect(calls, ['read', 'write', 'clear']);
      expect(service.authBodies.length, 1);
      await tester.tap(find.text('Выйти'));
      await tester.pumpAndSettle();
      expect(calls.last, 'clear');
    },
  );

  testWidgets('local review is labelled mock rather than real Telegram', (
    tester,
  ) async {
    final service = _FakeAccountTransport()
      ..development = true
      ..authURL = 'http://127.0.0.1:18081/dev/telegram/test-challenge';
    final opened = <String>[];
    await _pumpAccount(
      tester,
      service,
      opened: opened,
      endpoint: 'http://127.0.0.1:18081',
    );
    expect(find.textContaining('не настоящий вход'), findsOneWidget);
    expect(find.text('Проверить локальный вход'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('account-submit')));
    await tester.pump();
    expect(find.text('Ожидаем локальное подтверждение'), findsOneWidget);
    expect(opened.single, service.authURL);
    await tester.tap(find.text('Отменить'));
    await tester.pumpAndSettle();
  });

  testWidgets('authentication rejects arbitrary external URL', (tester) async {
    final service = _FakeAccountTransport()
      ..authURL = 'https://untrusted.example/login';
    final opened = <String>[];
    await _pumpAccount(tester, service, opened: opened);
    await tester.tap(find.byKey(const ValueKey('account-submit')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.textContaining('неполную заявку'), findsOneWidget);
    expect(
      service.requests.where(
        (r) => r.$1 == 'GET' && r.$2.startsWith('/v1/auth/challenges/'),
      ),
      isEmpty,
    );
  });

  testWidgets('completed mock login never claims Telegram connected', (
    tester,
  ) async {
    final service = _FakeAccountTransport()
      ..development = true
      ..authApproved = true
      ..authURL = 'http://127.0.0.1:18081/dev/telegram/test-challenge';
    final opened = <String>[];
    await _pumpAccount(
      tester,
      service,
      opened: opened,
      endpoint: 'http://127.0.0.1:18081',
    );
    await tester.tap(find.byKey(const ValueKey('account-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Локальный тестовый аккаунт'), findsOneWidget);
    expect(find.text('Telegram не подключён'), findsOneWidget);
    expect(find.text('Telegram подключён'), findsNothing);
    expect(opened.single, service.authURL);
  });

  testWidgets('registration and signed-in layouts fit phone and large text', (
    tester,
  ) async {
    for (final signedIn in [false, true]) {
      await _pumpAccount(
        tester,
        _FakeAccountTransport(),
        initialToken: signedIn ? 'stored-session' : null,
        size: const Size(320, 568),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('account-phone')), findsNothing);
    }
  });

  testWidgets('capture registration previews when requested', (tester) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    const captureDirectory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
    if (captureDirectory.isEmpty) {
      throw StateError('Set an external capture directory');
    }
    await tester.runAsync(() async {
      final inter = FontLoader('Inter')
        ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await inter.load();
      await icons.load();
    });
    for (final size in [const Size(1100, 760), const Size(390, 844)]) {
      final key = GlobalKey();
      await _pumpAccount(
        tester,
        _FakeAccountTransport(),
        size: size,
        captureKey: key,
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(captureDirectory);
        await directory.create(recursive: true);
        await File(
          '${directory.path}/registration-${size.width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

Future<void> _pumpAccount(
  WidgetTester tester,
  _FakeAccountTransport service, {
  List<String>? opened,
  String? initialToken,
  bool persistSession = false,
  Size size = const Size(1100, 760),
  double textScale = 1,
  GlobalKey? captureKey,
  String endpoint = 'https://accounts.example.com',
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = AccountPage(
    key: UniqueKey(),
    endpoint: endpoint,
    transport: service,
    persistSession: persistSession,
    initialToken: initialToken,
    onOpenExternal: (url) async {
      opened?.add(url);
    },
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF030708),
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: captureKey == null
            ? page
            : RepaintBoundary(key: captureKey, child: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeAccountTransport implements AccountTransport {
  final List<(String, String)> requests = [];
  final List<Map<String, dynamic>> authBodies = [];
  bool authApproved = false;
  bool orderPaid = false;
  bool purchasingAvailable = false;
  bool development = false;
  AccountApiException? meFailure;
  Completer<Map<String, dynamic>>? pendingPoll;
  String authURL = 'https://t.me/dropo_test?start=login_test-challenge';

  @override
  void close() {}

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    requests.add((method, path));
    if (path == '/v1/capabilities') {
      return {
        'authMode': 'telegram_bot',
        'phoneRequired': false,
        'registrationAvailable': true,
        'purchasingAvailable': purchasingAvailable,
        'development': development,
      };
    }
    if (path == '/v1/products') {
      return {
        'products': [
          {
            'id': 'speed_30d',
            'name': 'Ускорение VPN',
            'description': 'Приоритетные маршруты на 30 дней.',
            'stars': 150,
            'durationDays': 30,
          },
        ],
      };
    }
    if (path == '/v1/auth/challenges' && method == 'POST') {
      authBodies.add(Map<String, dynamic>.from(body!));
      return {
        'challengeToken': 'test-challenge',
        'status': 'pending',
        'telegramUrl': authURL,
      };
    }
    if (path == '/v1/auth/challenges/test-challenge' && method == 'GET') {
      if (pendingPoll != null) return pendingPoll!.future;
      return {'status': authApproved ? 'approved' : 'pending'};
    }
    if (path == '/v1/auth/challenges/test-challenge/exchange') {
      return {'accessToken': 'test-access-token', 'account': _account()};
    }
    if (path == '/v1/me') {
      if (meFailure != null) throw meFailure!;
      return {'account': _account()};
    }
    if (path == '/v1/sessions/current' && method == 'DELETE') {
      return {'success': true};
    }
    if (path == '/v1/orders' && method == 'POST') {
      return {
        'orderId': 'order-test',
        'status': 'pending',
        'invoiceUrl': 'https://t.me/invoice-test',
        'amountStars': 150,
      };
    }
    if (path == '/v1/orders/order-test') {
      return {
        'orderId': 'order-test',
        'status': orderPaid ? 'paid' : 'pending',
      };
    }
    throw StateError('Unexpected request: $method $path');
  }

  Map<String, Object?> _account() => {
    'id': 'user-test',
    'displayName': 'Локальный пользователь',
    'maskedPhone': '+• ••• •••-45-67',
    'plan': orderPaid ? 'Dropo Speed' : 'Dropo Free',
    if (orderPaid)
      'speedBoostUntil': DateTime.now()
          .add(const Duration(days: 30))
          .toUtc()
          .toIso8601String(),
  };
}
