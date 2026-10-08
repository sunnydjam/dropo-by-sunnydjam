import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
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

  testWidgets('Telegram auth and Stars purchase update the account', (
    tester,
  ) async {
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
    expect(find.text('Продолжить в Telegram'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('account-phone')),
      '+7 999 123-45-67',
    );
    await tester.tap(find.byKey(const ValueKey('account-submit')));
    await tester.pump();
    expect(opened, contains('https://t.me/dropo_test?start=login_test'));
    expect(find.text('Ожидаем подтверждение в Telegram'), findsOneWidget);

    service.authApproved = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Локальный пользователь'), findsOneWidget);
    expect(find.text('Dropo Free'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('account-buy-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Я принимаю условия покупки'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('purchase-confirm')));
    await tester.pump();
    expect(opened, contains('https://t.me/invoice-test'));
    expect(find.text('Ждём подтверждение Telegram'), findsOneWidget);

    service.orderPaid = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Dropo Speed'), findsOneWidget);
    expect(find.textContaining('Активно до'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FakeAccountTransport implements AccountTransport {
  final List<(String, String)> requests = [];
  bool authApproved = false;
  bool orderPaid = false;

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
      return {
        'challengeToken': 'test-challenge',
        'status': 'pending',
        'telegramUrl': 'https://t.me/dropo_test?start=login_test',
      };
    }
    if (path == '/v1/auth/challenges/test-challenge' && method == 'GET') {
      return {'status': authApproved ? 'approved' : 'pending'};
    }
    if (path == '/v1/auth/challenges/test-challenge/exchange') {
      return {'accessToken': 'test-access-token', 'account': _account()};
    }
    if (path == '/v1/me') return {'account': _account()};
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
