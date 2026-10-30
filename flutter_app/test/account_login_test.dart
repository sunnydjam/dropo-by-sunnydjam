import 'dart:async';
import 'dart:convert';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('password entry requires server support; no local demo remains', (
    tester,
  ) async {
    final api = _PasswordTransport()..passwordAvailable = false;
    await _pump(tester, api);
    expect(find.byKey(const ValueKey('account-password-open')), findsNothing);
    expect(find.byKey(const ValueKey('account-demo-open')), findsNothing);
    expect(find.text('Войти через Telegram'), findsOneWidget);
    expect(api.requests.where((r) => r.path.contains('/auth/')), isEmpty);
  });

  testWidgets('real password login stores only bearer, restores and logs out', (
    tester,
  ) async {
    final api = _PasswordTransport();
    final vault = _mockVault(tester);
    await _pump(tester, api, persist: true);
    await _login(tester);
    expect(find.text('Play Review'), findsOneWidget);
    expect(find.textContaining('Тестовый аккаунт на сервере'), findsOneWidget);
    expect(find.text('Восстановить доступ'), findsNothing);
    expect(api.logins.single.body, containsPair('username', 'play.review.1'));
    expect(
      api.logins.single.body,
      containsPair('password', 'SyntheticPassword!1'),
    );
    final saved =
        vault.singleWhere((call) => call.method == 'write').arguments as Map;
    final record = jsonDecode(saved['token'] as String) as Map;
    expect(record, {
      'endpoint': 'https://accounts.example.com',
      'token': 'password-bearer',
    });
    expect(saved.toString(), isNot(contains('SyntheticPassword')));
    expect(saved.toString(), isNot(contains('play.review.1')));

    await _pump(tester, api, initialToken: 'password-bearer');
    expect(find.text('Play Review'), findsOneWidget);
    expect(api.requests.last.path, '/v1/me');
    await _tap(tester, find.text('Выйти'));
    expect(find.text('Войти в Dropo'), findsOneWidget);
    expect(api.requests.last.method, 'DELETE');
    expect(api.requests.last.path, '/v1/sessions/current');
  });

  testWidgets(
    'wrong password clears form secret and leaves secure store unchanged',
    (tester) async {
      final api = _PasswordTransport()..rejectLogin = true;
      final vault = _mockVault(tester);
      await _pump(tester, api, persist: true);
      await _login(tester);
      expect(find.text('Неверный логин или пароль.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('account-password-value')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(vault.map((call) => call.method), ['read']);
      expect(find.text('Play Review'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('account-password-cancel')));
      expect(find.text('Войти в Dropo'), findsOneWidget);
    },
  );

  testWidgets(
    'password revoke uses real confirmation/consume and current bearer without Telegram',
    (tester) async {
      final api = _PasswordTransport();
      await _pump(tester, api, initialToken: 'password-bearer');
      await _tap(tester, find.text('Управление сессиями'));
      await _tap(tester, find.byKey(const ValueKey('account-sessions-revoke')));
      expect(api.confirmations, isEmpty);
      await _enter(tester, 'account-sessions-password', 'SyntheticPassword!1');
      await _tap(tester, find.byKey(const ValueKey('account-sessions-revoke')));
      final request = api.confirmations.single;
      expect(request.token, 'password-bearer');
      expect(request.body, {
        'action': 'sessions.revoke_others',
        'password': 'SyntheticPassword!1',
      });
      expect(
        api.requests.last.path,
        '/v1/action-confirmations/password-confirmation/consume',
      );
      expect(find.text('Активные сессии'), findsNothing);
    },
  );

  testWidgets(
    'password deletion really consumes and clears bearer; wrong password preserves account',
    (tester) async {
      final api = _PasswordTransport()..rejectConfirmation = true;
      final vault = _mockVault(tester);
      await _pump(tester, api, initialToken: 'password-bearer', persist: true);
      await _tap(tester, find.byKey(const ValueKey('account-delete')));
      expect(find.textContaining('новый пустой профиль'), findsOneWidget);
      await _enter(tester, 'account-delete-password', 'WrongPassword!1');
      await _tap(tester, find.byKey(const ValueKey('account-delete-confirm')));
      expect(find.text('Неверный логин или пароль.'), findsOneWidget);
      expect(vault.map((call) => call.method), ['read']);
      expect(api.requests.where((r) => r.path.endsWith('/consume')), isEmpty);
      api.rejectConfirmation = false;
      await _enter(tester, 'account-delete-password', 'SyntheticPassword!1');
      await _tap(tester, find.byKey(const ValueKey('account-delete-confirm')));
      expect(vault.map((call) => call.method), ['read', 'clear']);
      expect(find.text('Войти в Dropo'), findsOneWidget);
      expect(api.confirmations.last.body!['action'], 'account.delete');
      expect(
        api.requests.where((r) => r.path == '/v1/action-confirmations'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'lost deletion response can be checked using receipt without new password action',
    (tester) async {
      final api = _PasswordTransport()..loseDeleteResponse = true;
      await _pump(tester, api, initialToken: 'password-bearer');
      await _tap(tester, find.byKey(const ValueKey('account-delete')));
      await _enter(tester, 'account-delete-password', 'SyntheticPassword!1');
      await _tap(tester, find.byKey(const ValueKey('account-delete-confirm')));
      expect(find.textContaining('Проверить результат'), findsWidgets);
      expect(
        find.byKey(const ValueKey('account-delete-open-telegram')),
        findsNothing,
      );
      await _tap(tester, find.byKey(const ValueKey('account-delete-check')));
      expect(find.text('Войти в Dropo'), findsOneWidget);
      expect(api.confirmations.length, 1);
    },
  );

  testWidgets('disposed password login never persists late server session', (
    tester,
  ) async {
    final api = _PasswordTransport()
      ..pendingLogin = Completer<Map<String, dynamic>>();
    final vault = _mockVault(tester);
    await _pump(tester, api, persist: true);
    await _tap(tester, find.byKey(const ValueKey('account-password-open')));
    await _enter(tester, 'account-password-username', 'play.review.1');
    await _enter(tester, 'account-password-value', 'SyntheticPassword!1');
    await tester.ensureVisible(
      find.byKey(const ValueKey('account-password-submit')),
    );
    await tester.tap(find.byKey(const ValueKey('account-password-submit')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    api.pendingLogin!.complete(api.loginResponse);
    await tester.pumpAndSettle();
    expect(vault.map((call) => call.method), ['read']);
    expect(api.requests.last.path, '/v1/sessions/current');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'password login and session actions fit narrow screens and large text',
    (tester) async {
      final api = _PasswordTransport();
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, api, textScale: 2);
      await _login(tester);
      await _tap(tester, find.text('Управление сессиями'));
      await _enter(tester, 'account-sessions-password', 'SyntheticPassword!1');
      await _tap(tester, find.byKey(const ValueKey('account-sessions-revoke')));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _PasswordTransport api, {
  bool persist = false,
  String? initialToken,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
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
          transport: api,
          persistSession: persist,
          initialToken: initialToken,
          onOpenExternal: (_) async =>
              fail('Password flows must not open Telegram or external URLs'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> _login(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('account-password-open')));
  await _enter(tester, 'account-password-username', 'play.review.1');
  await _enter(tester, 'account-password-value', 'SyntheticPassword!1');
  await _tap(tester, find.byKey(const ValueKey('account-password-submit')));
}

List<MethodCall> _mockVault(WidgetTester tester) {
  const channel = MethodChannel('dropo/account_session');
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    call,
  ) async {
    calls.add(call);
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  return calls;
}

class _Request {
  _Request(this.method, this.path, this.token, this.body);
  final String method, path;
  final String? token;
  final Map<String, dynamic>? body;
}

class _PasswordTransport implements AccountTransport {
  final requests = <_Request>[];
  bool passwordAvailable = true,
      rejectLogin = false,
      rejectConfirmation = false;
  bool loseDeleteResponse = false;
  String action = '';
  Completer<Map<String, dynamic>>? pendingLogin;
  Iterable<_Request> get logins =>
      requests.where((r) => r.path == '/v1/auth/password');
  Iterable<_Request> get confirmations =>
      requests.where((r) => r.path == '/v1/action-confirmations/password');
  Map<String, dynamic> get account => {
    'id': 'synthetic-password-user',
    'displayName': 'Play Review',
    'username': 'play.review.1',
    'authMethod': 'password',
    'demoAccount': true,
  };
  Map<String, dynamic> get loginResponse => {
    'accessToken': 'password-bearer',
    'expiresIn': 3600,
    'account': account,
  };

  @override
  void close() {}

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    requests.add(_Request(method, path, token, body));
    if (path == '/v1/capabilities') {
      return {
        'authMode': 'telegram_bot',
        'registrationAvailable': true,
        'phoneRequired': false,
        'passwordLoginAvailable': passwordAvailable,
        'accountDeletionAvailable': true,
      };
    }
    if (path == '/v1/auth/password') {
      if (rejectLogin) {
        throw const AccountApiException(
          'Неверный логин или пароль.',
          status: 401,
        );
      }
      return pendingLogin?.future ?? loginResponse;
    }
    if (path == '/v1/me') return {'account': account};
    if (path == '/v1/sessions/current') return {};
    if (path == '/v1/sessions') {
      return {
        'sessions': [
          {'deviceName': 'Android', 'current': true},
          {'deviceName': 'Second device', 'current': false},
        ],
      };
    }
    if (path == '/v1/action-confirmations/password') {
      if (rejectConfirmation) {
        throw const AccountApiException(
          'Неверный логин или пароль.',
          status: 401,
        );
      }
      action = body!['action'] as String;
      return {
        'confirmationToken': 'password-confirmation',
        'status': 'approved',
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 2))
            .toUtc()
            .toIso8601String(),
      };
    }
    if (path == '/v1/action-confirmations/password-confirmation') {
      return {'status': 'exchanged', 'deleted': true, 'sessionsRevoked': true};
    }
    if (path.endsWith('/consume')) {
      if (loseDeleteResponse) {
        loseDeleteResponse = false;
        throw TimeoutException('synthetic lost response');
      }
      return {
        'success': true,
        if (action == 'account.delete') ...{
          'deleted': true,
          'sessionsRevoked': true,
        },
      };
    }
    throw StateError('Unexpected request: $method $path');
  }
}
