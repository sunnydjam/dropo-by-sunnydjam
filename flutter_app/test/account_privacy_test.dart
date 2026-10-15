import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public privacy URLs use the Dropo domain without credentials', () {
    expect(dropoPrivacyPolicyUrl, 'https://dropo.fun/privacy');
    expect(dropoAccountDeletionUrl, 'https://dropo.fun/account/delete');
    for (final value in [dropoPrivacyPolicyUrl, dropoAccountDeletionUrl]) {
      final uri = Uri.parse(value);
      expect(uri.scheme, 'https');
      expect(uri.host, 'dropo.fun');
      expect(uri.userInfo, isEmpty);
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
    }
  });

  testWidgets('account disclosure and public links precede optional sign-in', (
    tester,
  ) async {
    final service = _DeletionTransport();
    final opened = <String>[];
    await _pumpAccount(tester, service, signedIn: false, opened: opened);
    expect(
      find.byKey(const ValueKey('account-auth-disclosure')),
      findsOneWidget,
    );
    expect(find.textContaining('Telegram ID'), findsOneWidget);
    expect(
      service.requests.where((item) => item.path.contains('/auth/')),
      isEmpty,
    );
    for (final key in ['account-privacy-policy', 'account-deletion-page']) {
      final link = find.byKey(ValueKey(key));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pump();
    }
    expect(opened, [dropoPrivacyPolicyUrl, dropoAccountDeletionUrl]);
    expect(opened.every((value) => !Uri.parse(value).hasQuery), isTrue);
  });

  testWidgets('logout revokes only current session and never deletes account', (
    tester,
  ) async {
    final service = _DeletionTransport();
    await _pumpAccount(tester, service);
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();
    expect(
      service.requests
          .where((item) => item.path == '/v1/sessions/current')
          .length,
      1,
    );
    expect(
      service.requests.where(
        (item) => item.path.contains('/action-confirmations'),
      ),
      isEmpty,
    );
    expect(find.text('Войти в Dropo'), findsOneWidget);
  });

  testWidgets(
    'deletion requires explicit confirmation and complete server success',
    (tester) async {
      final service = _DeletionTransport();
      final calls = _mockVault(tester);
      await _pumpAccount(tester, service, persistSession: true);
      await _openDelete(tester);
      expect(find.textContaining('Это не обычный выход'), findsOneWidget);
      expect(find.textContaining('локальные журналы'), findsOneWidget);
      expect(service.deleteActions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
      await tester.pumpAndSettle();
      expect(service.deleteActions.single.body, {'action': 'account.delete'});
      expect(service.deleteActions.single.token, 'stored-session');
      expect(service.consumeRequests.single.token, 'stored-session');
      expect(calls, ['read', 'clear']);
      expect(find.text('Войти в Dropo'), findsOneWidget);
      expect(
        find.textContaining('Личные VPN-источники и настройки'),
        findsOneWidget,
      );
    },
  );

  testWidgets('cancelling deletion leaves account and credentials intact', (
    tester,
  ) async {
    final service = _DeletionTransport();
    final calls = _mockVault(tester);
    await _pumpAccount(tester, service, persistSession: true);
    await _openDelete(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Тестовый аккаунт'), findsOneWidget);
    expect(service.deleteActions, isEmpty);
    expect(calls, ['read']);
  });

  testWidgets('offline creation failure preserves account and can retry', (
    tester,
  ) async {
    final service = _DeletionTransport()
      ..createFailure = const SocketException('offline');
    final calls = _mockVault(tester);
    await _pumpAccount(tester, service, persistSession: true);
    await _openDelete(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Нет связи с сервером аккаунтов'),
      findsOneWidget,
    );
    expect(calls, ['read']);
    expect(service.consumeRequests, isEmpty);
    service.createFailure = null;
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pumpAndSettle();
    expect(calls, ['read', 'clear']);
    expect(find.text('Войти в Dropo'), findsOneWidget);
  });

  for (final response in [
    <String, dynamic>{},
    <String, dynamic>{'success': true},
    <String, dynamic>{'success': true, 'deleted': true},
    <String, dynamic>{
      'success': true,
      'deleted': false,
      'sessionsRevoked': true,
    },
    <String, dynamic>{
      'success': 'true',
      'deleted': true,
      'sessionsRevoked': true,
    },
  ]) {
    testWidgets(
      'malformed deletion success never erases local token: $response',
      (tester) async {
        final service = _DeletionTransport()..consumeResponse = response;
        final calls = _mockVault(tester);
        await _pumpAccount(tester, service, persistSession: true);
        await _openDelete(tester);
        await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Не удалось подтвердить результат'),
          findsOneWidget,
        );
        expect(calls, ['read']);
        expect(find.text('Тестовый аккаунт'), findsOneWidget);
        service.consumeResponse = _DeletionTransport.success;
        await tester.tap(find.byKey(const ValueKey('account-delete-check')));
        await tester.pumpAndSettle();
        expect(service.deleteActions.length, 1);
        expect(service.consumeRequests.length, 2);
        expect(calls, ['read', 'clear']);
        expect(find.text('Войти в Dropo'), findsOneWidget);
      },
    );
  }

  testWidgets('lost consume response is recoverable by the same confirmation', (
    tester,
  ) async {
    final service = _DeletionTransport()
      ..consumeFailure = const SocketException('lost response');
    final calls = _mockVault(tester);
    await _pumpAccount(tester, service, persistSession: true);
    await _openDelete(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pumpAndSettle();
    expect(calls, ['read']);
    service.consumeFailure = null;
    service.status = 'exchanged';
    await tester.tap(find.byKey(const ValueKey('account-delete-check')));
    await tester.pumpAndSettle();
    expect(service.deleteActions.length, 1);
    expect(service.consumeRequests.map((item) => item.path).toSet().length, 1);
    expect(calls, ['read', 'clear']);
    expect(find.text('Войти в Dropo'), findsOneWidget);
  });

  testWidgets(
    'native clear failure exposes local retry without duplicate erasure',
    (tester) async {
      final service = _DeletionTransport();
      var fail = true;
      final calls = _mockVault(
        tester,
        clear: () {
          if (fail) throw PlatformException(code: 'storage_unavailable');
        },
      );
      await _pumpAccount(tester, service, persistSession: true);
      await _openDelete(tester);
      await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Завершите очистку устройства'), findsOneWidget);
      expect(
        find.textContaining('Не удалось удалить сохранённый токен'),
        findsOneWidget,
      );
      expect(find.text('Войти в Dropo'), findsNothing);
      expect(service.consumeRequests.length, 1);
      fail = false;
      await tester.tap(
        find.byKey(const ValueKey('account-delete-cleanup-retry')),
      );
      await tester.pumpAndSettle();
      expect(calls, ['read', 'clear', 'clear']);
      expect(service.consumeRequests.length, 1);
      expect(find.text('Войти в Dropo'), findsOneWidget);
    },
  );

  testWidgets('cancelled pending deletion fences late Telegram approval', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final service = _DeletionTransport()..pendingStatus = pending;
    await _pumpAccount(tester, service);
    await _openDelete(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
    await tester.pumpAndSettle();
    pending.complete({'status': 'approved'});
    await tester.pumpAndSettle();
    expect(service.consumeRequests, isEmpty);
    expect(find.text('Тестовый аккаунт'), findsOneWidget);
  });

  testWidgets(
    'expired deletion stops polling and never consumes late approval',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final service = _DeletionTransport()
        ..pendingStatus = pending
        ..createOverride = {
          'expiresAt': DateTime.now()
              .add(const Duration(seconds: 2))
              .toUtc()
              .toIso8601String(),
        };
      final calls = _mockVault(tester);
      await _pumpAccount(tester, service, persistSession: true);
      await _openDelete(tester);
      await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.textContaining('Время подтверждения истекло'),
        findsOneWidget,
      );
      final requestCount = service.requests.length;
      pending.complete({'status': 'approved'});
      await tester.pump(const Duration(seconds: 8));
      expect(service.requests.length, requestCount);
      expect(service.consumeRequests, isEmpty);
      expect(calls, ['read']);
      await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('server denial stops deletion and keeps the account', (
    tester,
  ) async {
    final service = _DeletionTransport()..status = 'denied';
    final calls = _mockVault(tester);
    await _pumpAccount(tester, service, persistSession: true);
    await _openDelete(tester);
    await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Удаление отклонено'), findsOneWidget);
    final requestCount = service.requests.length;
    await tester.pump(const Duration(seconds: 8));
    expect(service.requests.length, requestCount);
    expect(service.consumeRequests, isEmpty);
    expect(calls, ['read']);
    await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('unsafe deletion link and invalid expiry are not opened', (
    tester,
  ) async {
    for (final invalid in [
      {'telegramUrl': 'https://evil.example/delete'},
      {'expiresAt': 'not-a-date'},
      {'confirmationToken': '../private'},
    ]) {
      final service = _DeletionTransport()..createOverride = invalid;
      final opened = <String>[];
      await _pumpAccount(tester, service, opened: opened);
      await _openDelete(tester);
      await tester.tap(find.byKey(const ValueKey('account-delete-confirm')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(service.consumeRequests, isEmpty);
      expect(find.textContaining('некорректное подтверждение'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('deletion dialog is scrollable at phone size and large text', (
    tester,
  ) async {
    final service = _DeletionTransport();
    await _pumpAccount(
      tester,
      service,
      size: const Size(320, 568),
      textScale: 2,
    );
    await _openDelete(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('account-delete-confirm')),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('account-delete-cancel')));
    await tester.pumpAndSettle();
  });
}

List<String> _mockVault(WidgetTester tester, {void Function()? clear}) {
  final calls = <String>[];
  const channel = MethodChannel('dropo/account_session');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    calls.add(call.method);
    if (call.method == 'clear') clear?.call();
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
  return calls;
}

Future<void> _openDelete(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('account-delete'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _pumpAccount(
  WidgetTester tester,
  _DeletionTransport service, {
  bool signedIn = true,
  bool persistSession = false,
  List<String>? opened,
  Size size = const Size(1100, 1000),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: AccountPage(
          key: UniqueKey(),
          endpoint: 'https://accounts.example.com',
          transport: service,
          initialToken: signedIn ? 'stored-session' : null,
          persistSession: persistSession,
          onOpenExternal: (value) async => opened?.add(value),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _AccountRequest {
  _AccountRequest(this.method, this.path, this.token, this.body);
  final String method, path;
  final String? token;
  final Map<String, dynamic>? body;
}

class _DeletionTransport implements AccountTransport {
  static const success = <String, dynamic>{
    'success': true,
    'deleted': true,
    'sessionsRevoked': true,
  };
  final requests = <_AccountRequest>[];
  Iterable<_AccountRequest> get deleteActions => requests.where(
    (item) => item.method == 'POST' && item.path == '/v1/action-confirmations',
  );
  Iterable<_AccountRequest> get consumeRequests =>
      requests.where((item) => item.path.endsWith('/consume'));
  Object? createFailure, consumeFailure;
  Map<String, dynamic>? createOverride;
  Map<String, dynamic> consumeResponse = success;
  Completer<Map<String, dynamic>>? pendingStatus;
  String status = 'approved';

  @override
  void close() {}

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    requests.add(_AccountRequest(method, path, token, body));
    if (path == '/v1/capabilities') {
      return {
        'registrationAvailable': true,
        'phoneRequired': false,
        'authMode': 'telegram_bot',
        'accountDeletionAvailable': true,
      };
    }
    if (path == '/v1/me') {
      return {
        'account': {'id': 'test-id', 'displayName': 'Тестовый аккаунт'},
      };
    }
    if (path == '/v1/sessions/current') return {'success': true};
    if (path == '/v1/action-confirmations') {
      if (createFailure != null) throw createFailure!;
      return {
        'confirmationToken': 'delete-test-confirmation',
        'status': 'pending',
        'telegramUrl': 'https://t.me/DropoRigistration_bot',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 10))
            .toUtc()
            .toIso8601String(),
        ...?createOverride,
      };
    }
    if (path == '/v1/action-confirmations/delete-test-confirmation') {
      if (pendingStatus != null) return pendingStatus!.future;
      return {
        'status': status,
        if (status == 'exchanged') ...{
          'deleted': true,
          'sessionsRevoked': true,
        },
      };
    }
    if (path.endsWith('/consume')) {
      if (consumeFailure != null) throw consumeFailure!;
      return consumeResponse;
    }
    throw StateError('Unexpected request: $method $path');
  }
}
