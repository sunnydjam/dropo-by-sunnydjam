import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('public demo entry works without a configured backend', (
    tester,
  ) async {
    final real = _RejectAccountRequests();
    final vaultCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dropo/account_session'),
      (call) async {
        vaultCalls.add(call.method);
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountPage(
            endpoint: '',
            available: false,
            transport: real,
            initialToken: 'real-session-must-stay-untouched',
            onOpenExternal: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-demo-open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('ДЕМО / DEMO'), findsOneWidget);
    await _login(tester);
    expect(find.byKey(const ValueKey('account-demo-profile')), findsOneWidget);
    await _tapVisible(tester, 'account-demo-logout');
    expect(find.byKey(const ValueKey('account-demo-profile')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Вход пока недоступен'), findsOneWidget);
    expect(real.requests, 0);
    expect(vaultCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'demo rejects wrong credentials and accepts reusable public credentials',
    (tester) async {
      await _pumpDemo(tester);
      await _login(tester, password: 'incorrect');
      expect(find.byKey(const ValueKey('account-demo-profile')), findsNothing);
      expect(find.textContaining('Неверный демо-логин'), findsOneWidget);
      await _login(tester);
      expect(
        find.byKey(const ValueKey('account-demo-profile')),
        findsOneWidget,
      );
      await _tapVisible(tester, 'account-demo-logout');
      await _login(tester);
      expect(
        find.byKey(const ValueKey('account-demo-profile')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'demo session changes are local, reset is confirmed and next login is fresh',
    (tester) async {
      await _pumpDemo(tester);
      await _login(tester);
      await _tapVisible(tester, 'account-demo-sessions');
      expect(
        find.byKey(const ValueKey('account-demo-other-session')),
        findsOneWidget,
      );
      await _tapVisible(tester, 'account-demo-revoke');
      expect(
        find.byKey(const ValueKey('account-demo-other-session')),
        findsNothing,
      );
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'account-demo-reset');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-demo-profile')),
        findsOneWidget,
      );
      await _tapVisible(tester, 'account-demo-reset');
      await _tapVisible(tester, 'account-demo-reset-confirm');
      expect(find.byKey(const ValueKey('account-demo-profile')), findsNothing);
      await _login(tester);
      await _tapVisible(tester, 'account-demo-sessions');
      expect(
        find.byKey(const ValueKey('account-demo-other-session')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('demo remains usable on narrow screens with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpDemo(tester, textScale: 2);
    await _login(tester);
    await _tapVisible(tester, 'account-demo-sessions');
    await _tapVisible(tester, 'account-demo-revoke');
    expect(
      find.byKey(const ValueKey('account-demo-other-session')),
      findsNothing,
    );
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, 'account-demo-logout');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDemo(WidgetTester tester, {double textScale = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AccountDemoPage(
        onOpenExternal: (_) async {
          fail(
            'Demo authentication and local actions must not open external links',
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _login(
  WidgetTester tester, {
  String password = accountDemoPassword,
}) async {
  final username = find.byKey(const ValueKey('account-demo-username'));
  final passwordField = find.byKey(const ValueKey('account-demo-password'));
  await tester.ensureVisible(username);
  await tester.enterText(username, accountDemoUsername);
  await tester.ensureVisible(passwordField);
  await tester.enterText(passwordField, password);
  await _tapVisible(tester, 'account-demo-submit');
}

Future<void> _tapVisible(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

class _RejectAccountRequests implements AccountTransport {
  int requests = 0;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    requests++;
    throw StateError('Demo must never use the real account service');
  }

  @override
  void close() {}
}
