import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _StarsAPI implements AccountTransport {
  String status = 'pending', activation = 'provisioning';
  int orders = 0, polls = 0;
  int price = 150, days = 30;
  int? invoicePrice;
  int? invoiceDays;
  String invoiceProductId = 'speed_30d';
  bool includeInvoiceProduct = true;
  bool failCatalog = false;
  Completer<Map<String, dynamic>>? heldPoll;
  final until = DateTime.now()
      .add(const Duration(days: 30))
      .toUtc()
      .toIso8601String();
  @override
  void close() {}
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    if (path == '/v1/capabilities') {
      return {
        'registrationAvailable': true,
        'purchasingAvailable': true,
        'development': false,
      };
    }
    if (path == '/v1/products') {
      if (failCatalog) throw StateError('Catalog unavailable');
      return {
        'products': [
          {
            'id': 'speed_30d',
            'name': 'Dropo Турбо — $days дней',
            'stars': price,
            'durationDays': days,
          },
        ],
      };
    }
    if (path == '/v1/me') {
      return {
        'account': {
          'id': 'buyer',
          'displayName': 'Покупатель',
          'authMethod': 'telegram',
          'telegramUserId': 12345,
          'plan': status == 'paid' ? 'Dropo Speed' : 'Dropo Free',
          if (status == 'paid') 'speedBoostUntil': until,
        },
      };
    }
    if (path == '/v1/orders') {
      expect(body, {'productId': 'speed_30d', 'termsAccepted': true});
      orders++;
      return {
        'orderId': 'fixture',
        'invoiceUrl': 'https://t.me/\$stars-fixture',
        'amountStars': invoicePrice ?? price,
        if (includeInvoiceProduct)
          'product': {
            'id': invoiceProductId,
            'stars': invoicePrice ?? price,
            'durationDays': invoiceDays ?? days,
          },
        'status': 'pending',
      };
    }
    if (path == '/v1/orders/fixture') {
      polls++;
      if (heldPoll != null) return heldPoll!.future;
      return {'orderId': 'fixture', 'status': status, 'activation': activation};
    }
    throw StateError('Unexpected request $method $path');
  }
}

void main() {
  const enabled =
      bool.fromEnvironment('DROPO_PURCHASES_ENABLED') &&
      !bool.fromEnvironment('DROPO_PLAY_DISTRIBUTION');
  test('profile readiness tracks purchases, renewals and refunds', () {
    final free = {'status': 'ready', 'freeSubscriptionUrl': 'free'};
    final boost = {
      ...free,
      'boostUntilUnix': 200,
      'boostSubscriptionUrl': 'boost',
    };
    expect(ownedVPNProfileMatchesEntitlement(free, 200, 100), false);
    expect(ownedVPNProfileMatchesEntitlement(boost, 200, 100), true);
    expect(ownedVPNProfileMatchesEntitlement(boost, 300, 100), false);
    expect(ownedVPNProfileMatchesEntitlement(boost, 0, 100), false);
    expect(ownedVPNProfileMatchesEntitlement(free, 0, 100), true);
    expect(ownedVPNProfileMatchesEntitlement(boost, 200, 201), true);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    _StarsAPI api,
    Future<Map<String, dynamic>> Function(String, bool) apply,
    List<String> opened, {
    GlobalKey? capture,
  }) async {
    if (capture != null &&
        Platform.environment['DROPO_TEST_CAPTURE_DIR'] != null) {
      await tester.runAsync(() async {
        await (FontLoader(
          'Inter',
        )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
      ),
      home: Scaffold(
        body: AccountPage(
          endpoint: 'https://dropo.fun',
          showTurbo: true,
          persistSession: false,
          initialToken: 'fixture-session',
          transport: api,
          onOpenExternal: (url) async {
            opened.add(url);
          },
          onVPNProfile: apply,
        ),
      ),
    );
    await tester.pumpWidget(
      capture == null ? app : RepaintBoundary(key: capture, child: app),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPurchase(WidgetTester tester) async {
    final buy = find.byKey(const ValueKey('account-buy-speed'));
    await tester.ensureVisible(buy);
    await tester.tap(buy);
    await tester.pumpAndSettle();
    expect(find.text('Подтвердите покупку'), findsOneWidget);
  }

  Future<void> pay(WidgetTester tester) async {
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('purchase-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets(
    'purchase consent and refund use catalog and saved order amounts',
    (tester) async {
      final api = _StarsAPI()
        ..price = 250
        ..days = 60;
      final opened = <String>[];
      await pumpPage(tester, api, (_, _) async => {'success': true}, opened);
      await openPurchase(tester);
      expect(find.textContaining('250 Stars за 60 дней.'), findsOneWidget);
      expect(find.textContaining('150 Stars за 30 дней.'), findsNothing);
      await pay(tester);
      expect(opened, hasLength(1));
      api.price =
          400; // Later catalog changes must not change this order's refund.
      api.status = 'refunded';
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.textContaining('250 Stars возвращены'), findsOneWidget);
      expect(find.textContaining('400 Stars возвращены'), findsNothing);
    },
    skip: !enabled,
  );

  testWidgets('unavailable catalog does not offer an invented purchase price', (
    tester,
  ) async {
    final api = _StarsAPI()..failCatalog = true;
    await pumpPage(tester, api, (_, _) async => {'success': true}, []);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('account-buy-speed')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('150 Stars'), findsNothing);
    expect(api.orders, 0);
  }, skip: !enabled);

  testWidgets(
    'a changed invoice price requires new consent before opening Telegram',
    (tester) async {
      final api = _StarsAPI()..invoicePrice = 250;
      final opened = <String>[];
      await pumpPage(tester, api, (_, _) async => {'success': true}, opened);
      await openPurchase(tester);
      await pay(tester);
      expect(opened, isEmpty);
      expect(find.textContaining('Цена изменилась.'), findsOneWidget);
      expect(api.polls, 0);
    },
    skip: !enabled,
  );

  for (final changed in ['duration', 'product', 'missing quote']) {
    testWidgets(
      'changed or unconfirmed invoice $changed cannot reuse old consent',
      (tester) async {
        final api = _StarsAPI();
        if (changed == 'duration') api.invoiceDays = 10;
        if (changed == 'product') api.invoiceProductId = 'different-product';
        if (changed == 'missing quote') api.includeInvoiceProduct = false;
        final opened = <String>[];
        await pumpPage(tester, api, (_, _) async => {'success': true}, opened);
        await openPurchase(tester);
        await pay(tester);
        expect(opened, isEmpty);
        expect(
          find.textContaining('Условия тарифа изменились или не подтверждены.'),
          findsOneWidget,
        );
        expect(api.polls, 0);
      },
      skip: !enabled,
    );
  }

  testWidgets('reopening a changed quote reloads terms before new consent', (
    tester,
  ) async {
    final api = _StarsAPI()..invoicePrice = 250;
    final opened = <String>[];
    await pumpPage(tester, api, (_, _) async => {'success': true}, opened);
    await openPurchase(tester);
    await pay(tester);
    expect(opened, isEmpty);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    api
      ..price = 250
      ..days = 60
      ..invoicePrice = null;
    await openPurchase(tester);
    expect(find.textContaining('250 Stars за 60 дней.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('purchase-confirm')))
          .onPressed,
      isNull,
    );
    await pay(tester);
    expect(opened, hasLength(1));
    expect(api.orders, 2);
  }, skip: !enabled);

  testWidgets('catalog refresh failure can retry without taking payment', (
    tester,
  ) async {
    final api = _StarsAPI();
    final opened = <String>[];
    await pumpPage(tester, api, (_, _) async => {'success': true}, opened);
    api.failCatalog = true;
    await tester.tap(find.byKey(const ValueKey('account-buy-speed')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Не удалось обновить тариф.'), findsOneWidget);
    expect(api.orders, 0);
    api
      ..failCatalog = false
      ..price = 250;
    await openPurchase(tester);
    expect(find.textContaining('250 Stars за 30 дней.'), findsOneWidget);
    expect(api.orders, 0);
    expect(opened, isEmpty);
  }, skip: !enabled);

  testWidgets(
    '150 Stars waits for backend delivery and native application without another charge',
    (tester) async {
      final api = _StarsAPI(), opened = <String>[];
      int applies = 0;
      bool nativeReady = false;
      final capture = GlobalKey();
      await pumpPage(
        tester,
        api,
        (_, _) async {
          applies++;
          return {
            'success': api.status != 'paid' || nativeReady,
            'error': 'Повторите применение профиля.',
          };
        },
        opened,
        capture: capture,
      );
      await openPurchase(tester);
      expect(find.textContaining('без автопродления'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('purchase-confirm')),
            )
            .onPressed,
        isNull,
      );
      final directory = Platform.environment['DROPO_TEST_CAPTURE_DIR'];
      if (directory != null) {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$directory/stars-confirmation.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await pay(tester);
      expect(api.orders, 1);
      expect(opened, ['https://t.me/\$stars-fixture']);
      final before = applies;
      api.status = 'paid';
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Активируем Турбо'), findsOneWidget);
      expect(applies, before);
      api.activation = 'ready';
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('Оплата сохранена.'), findsOneWidget);
      expect(api.orders, 1);
      nativeReady = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(applies, greaterThan(before));
      expect(api.orders, 1);
      expect(tester.takeException(), isNull);
    },
    skip: !enabled,
  );

  testWidgets('polls cannot overlap and refunded payment never activates', (
    tester,
  ) async {
    final api = _StarsAPI(), opened = <String>[];
    var applies = 0;
    await pumpPage(tester, api, (_, _) async {
      applies++;
      return {'success': true};
    }, opened);
    await openPurchase(tester);
    api.heldPoll = Completer<Map<String, dynamic>>();
    await pay(tester);
    final before = applies;
    final polls = api.polls;
    await tester.pump(const Duration(seconds: 12));
    expect(api.polls, polls);
    api.status = 'refunded';
    api.heldPoll!.complete({'status': 'refunded'});
    await tester.pumpAndSettle();
    expect(find.textContaining('150 Stars возвращены'), findsOneWidget);
    expect(applies, before);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(api.orders, 1);
  }, skip: !enabled);

  testWidgets('profile preparation failure prevents taking payment', (
    tester,
  ) async {
    final api = _StarsAPI();
    await pumpPage(
      tester,
      api,
      (_, _) async => {
        'success': false,
        'error': 'Профиль устройства требует обновления.',
      },
      [],
    );
    await tester.tap(find.byKey(const ValueKey('account-buy-speed')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(api.orders, 0);
    expect(find.text('Профиль устройства требует обновления.'), findsOneWidget);
  }, skip: !enabled);

  testWidgets('purchase confirmation fits a phone with large text', (
    tester,
  ) async {
    await pumpPage(tester, _StarsAPI(), (_, _) async => {'success': true}, []);
    await tester.binding.setSurfaceSize(const Size(390, 700));
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await openPurchase(tester);
    expect(find.text('Условия покупки и возврата'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  }, skip: !enabled);
}
