import 'dart:async';
import 'dart:convert';

import 'package:dropo/account_session_store.dart';
import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guest_identity_test.dart'
    show MemoryVault, GuestApi, coordinator, registered;

class DeletionApi extends GuestApi {
  DeletionApi(super.vault);

  bool supported = true, loseResponse = false, confirmReady = true;
  bool expiredFirstBearer = false;
  bool revoked = false;
  Completer<void>? keyGate;
  void Function()? afterAccept;
  String? serverKey;

  List<String> get submittedKeys => calls
      .where((call) => call.path == '/v1/guest/deletion-key')
      .map((call) => call.body!['deletionSecret'] as String)
      .toList();

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    if (path == '/v1/me' && revoked) {
      calls.add((method: method, path: path, token: token, body: body));
      throw const AccountApiException(
        'Revoked',
        status: 401,
        code: 'invalid_session',
      );
    }
    if (path == '/v1/capabilities') {
      final caps = await super.request(method, path, token: token, body: body);
      if (supported) caps['guestWebDeletionAvailable'] = true;
      return caps;
    }
    if (path != '/v1/guest/deletion-key') {
      return super.request(method, path, token: token, body: body);
    }
    calls.add((method: method, path: path, token: token, body: body));
    expect(method, 'PUT');
    final saved =
        (vault.record['privateState'] as Map)['guest_web_deletion'] as Map;
    // Checks the durable native record at the request boundary, not just state.
    expect(body!['deletionSecret'], saved['secret']);
    expect(saved['registered'], false);
    expect(saved['installationId'], vault.record['installationId']);
    expect(body.keys, ['deletionSecret']);
    expect(body['deletionSecret'], isNot(vault.record['installationSecret']));
    expect(token, startsWith('guest-token-'));
    if (expiredFirstBearer && token == 'guest-token-1') {
      throw const AccountApiException(
        'Expired',
        status: 401,
        code: 'invalid_session',
      );
    }
    serverKey = body['deletionSecret'] as String;
    afterAccept?.call();
    await keyGate?.future;
    if (loseResponse) throw const AccountApiException('Offline', status: 503);
    return {'ready': confirmReady};
  }
}

class GatedVault extends MemoryVault {
  Completer<void>? readGate;
  Completer<void>? readStarted;

  @override
  Future<String?> read() async {
    if (readGate != null) {
      if (readStarted?.isCompleted == false) readStarted!.complete();
      await readGate!.future;
    }
    return super.read();
  }
}

Map<dynamic, dynamic>? savedDeletion(MemoryVault vault) =>
    (vault.record['privateState'] as Map?)?['guest_web_deletion'] as Map?;

Future<void> openDialog(
  WidgetTester tester,
  GuestIdentityCoordinator identity, {
  Future<void> Function(String)? open,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => GuestWebDeletionDialog(
                identity: identity,
                onOpenExternal: open ?? (_) async {},
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'key is independent, saved before request and cached after confirmation',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      expect(api.submittedKeys, isEmpty);
      final code = await identity.guestWebDeletionCode();
      expect(code, matches(RegExp(r'^dg1\.[A-Za-z0-9_-]{43}$')));
      final secret = code.substring(4);
      expect(base64Url.decode('$secret='), hasLength(32));
      expect(
        base64UrlEncode(base64Url.decode('$secret=')).replaceAll('=', ''),
        secret,
      );
      expect(savedDeletion(vault)!['registered'], true);
      identity.guestWebDeletionAvailable = false;
      api.loseResponse = true;
      expect(await identity.guestWebDeletionCode(), code);
      expect(api.submittedKeys, [secret]);
    },
  );

  test(
    'a lost response survives restart and retries exactly the same key',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..loseResponse = true;
      final identity = coordinator(vault, api);
      await identity.restore();
      await expectLater(
        identity.guestWebDeletionCode(),
        throwsA(isA<AccountApiException>()),
      );
      final secret = api.serverKey;
      expect(savedDeletion(vault)!['registered'], false);
      identity.dispose();
      api.loseResponse = false;
      final restored = coordinator(vault, api);
      addTearDown(restored.dispose);
      await restored.restore();
      expect(await restored.guestWebDeletionCode(), 'dg1.$secret');
      expect(api.submittedKeys, [secret, secret]);
    },
  );

  test('native storage failure prevents publishing a deletion key', () async {
    final vault = MemoryVault();
    final api = DeletionApi(vault);
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    vault.failWrite = true;
    await expectLater(identity.guestWebDeletionCode(), throwsStateError);
    expect(api.submittedKeys, isEmpty);
    expect(savedDeletion(vault), isNull);
  });

  test(
    'confirmation write failure never returns a falsely provisioned code',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)
        ..afterAccept = () => vault.failWrite = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await expectLater(identity.guestWebDeletionCode(), throwsStateError);
      expect(savedDeletion(vault)!['registered'], false);
      final secret = api.serverKey;
      vault.failWrite = false;
      api.afterAccept = null;
      expect(await identity.guestWebDeletionCode(), 'dg1.$secret');
      expect(api.submittedKeys, [secret, secret]);
    },
  );

  test('unconfirmed server response leaves the code unprovisioned', () async {
    final vault = MemoryVault();
    final api = DeletionApi(vault)..confirmReady = false;
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    await expectLater(identity.guestWebDeletionCode(), throwsFormatException);
    expect(savedDeletion(vault)!['registered'], false);
  });

  test(
    'old server missing capability never creates or submits a key',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..supported = false;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      expect(identity.guestWebDeletionAvailable, false);
      await expectLater(
        identity.guestWebDeletionCode(),
        throwsA(isA<AccountApiException>()),
      );
      expect(api.submittedKeys, isEmpty);
      expect(savedDeletion(vault), isNull);
    },
  );

  test('corrupted saved key fails closed without rotating it', () async {
    final vault = MemoryVault();
    final api = DeletionApi(vault);
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    await identity.writePrivateState('guest_web_deletion', {
      'installationId': identity.installationId,
      'secret': 'not-a-canonical-secret',
      'registered': true,
    });
    await expectLater(identity.guestWebDeletionCode(), throwsFormatException);
    expect(api.submittedKeys, isEmpty);
    expect(savedDeletion(vault)!['secret'], 'not-a-canonical-secret');
  });

  test('simultaneous reveal actions share one saved key and request', () async {
    final vault = MemoryVault();
    final api = DeletionApi(vault)..keyGate = Completer<void>();
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    final one = identity.guestWebDeletionCode();
    final two = identity.guestWebDeletionCode();
    while (api.submittedKeys.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    api.keyGate!.complete();
    expect(await one, await two);
    expect(api.submittedKeys, hasLength(1));
  });

  test(
    'account switch while storage is pending prevents any old request',
    () async {
      final vault = GatedVault();
      final api = DeletionApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      vault.readGate = Completer<void>();
      vault.readStarted = Completer<void>();
      final reveal = identity.guestWebDeletionCode();
      final cancelled = expectLater(
        reveal,
        throwsA(isA<AccountIdentityChanged>()),
      );
      await vault.readStarted!.future;
      final logout = identity.logout();
      vault.readGate!.complete();
      await logout;
      await cancelled;
      expect(api.submittedKeys, isEmpty);
      expect(savedDeletion(vault), isNull);
    },
  );

  test(
    'late server reply cannot expose a code after registered linking',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..keyGate = Completer<void>();
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      final reveal = identity.guestWebDeletionCode();
      final cancelled = expectLater(
        reveal,
        throwsA(isA<AccountIdentityChanged>()),
      );
      while (api.submittedKeys.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await identity.acceptRegisteredSession('registered-proof', registered);
      api.keyGate!.complete();
      await cancelled;
      expect(identity.accountKind, 'registered');
      expect(savedDeletion(vault), isNull);
      expect(
        () => identity.guestWebDeletionCode(),
        throwsA(isA<AccountIdentityChanged>()),
      );
    },
  );

  test(
    'expired bearer refreshes once without changing deletion credential',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..expiredFirstBearer = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      api.now = api.now.add(const Duration(hours: 2));
      final code = await identity.guestWebDeletionCode();
      expect(identity.token, 'guest-token-2');
      expect(api.submittedKeys, [code.substring(4), code.substring(4)]);
    },
  );

  test(
    'external deletion revokes identity and clears saved code without revival',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.guestWebDeletionCode();
      await identity.writePrivateState('incidents', {'consent': true});
      api.terminalCode = 'installation_revoked';
      api.now = api.now.add(const Duration(hours: 2));
      await identity.resume();
      expect(identity.suppressed, true);
      expect(identity.token, isNull);
      expect(vault.record['privateState'], isNull);
      final enrollments = api.enrollments;
      await identity.restore();
      expect(api.enrollments, enrollments);
    },
  );

  test(
    'quick return from deletion page checks revocation inside cooldown',
    () async {
      final vault = MemoryVault();
      final api = DeletionApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.guestWebDeletionCode();
      identity.checkGuestProfileOnReturn();
      api.revoked = true;
      api.terminalCode = 'installation_revoked';
      // Time has not advanced: a normal resume would be throttled for 30 seconds.
      await identity.resume();
      expect(identity.suppressed, true);
      expect(vault.record['privateState'], isNull);
      final enrollments = api.enrollments;
      await identity.resume();
      expect(api.enrollments, enrollments);
    },
  );

  testWidgets(
    '360x640 dialog reveals explicitly, copies exactly and links safely',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final copies = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copies.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final vault = MemoryVault();
      final api = DeletionApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await tester.runAsync(identity.restore);
      identity.setForeground(false);
      final opened = <String>[];
      await openDialog(tester, identity, open: (url) async => opened.add(url));
      expect(api.submittedKeys, isEmpty);
      expect(copies, isEmpty);
      expect(find.byKey(const ValueKey('guest-web-delete-code')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('guest-web-delete-reveal')),
      );
      await tester.tap(find.byKey(const ValueKey('guest-web-delete-reveal')));
      await tester.pumpAndSettle();
      expect(copies, isEmpty);
      final codeWidget = tester.widget<SelectableText>(
        find.byKey(const ValueKey('guest-web-delete-code')),
      );
      expect(codeWidget.data, 'dg1.${api.serverKey}');
      await tester.ensureVisible(
        find.byKey(const ValueKey('guest-web-delete-copy')),
      );
      await tester.tap(find.byKey(const ValueKey('guest-web-delete-copy')));
      await tester.pumpAndSettle();
      expect(copies, [codeWidget.data]);
      await tester.ensureVisible(
        find.byKey(const ValueKey('guest-web-delete-open')),
      );
      await tester.tap(find.byKey(const ValueKey('guest-web-delete-open')));
      await tester.pumpAndSettle();
      expect(opened, ['https://accounts.example.test/account/delete']);
      expect(tester.takeException(), isNull);
      await identity.logout();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-web-delete-code')), findsNothing);
      expect(find.byKey(const ValueKey('guest-web-delete-copy')), findsNothing);
      expect(
        find.byKey(const ValueKey('guest-web-delete-reveal')),
        findsNothing,
      );
      expect(copies, [codeWidget.data]);
    },
  );

  testWidgets(
    'failed provisioning never renders or copies an unconfirmed code',
    (tester) async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..loseResponse = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await tester.runAsync(identity.restore);
      identity.setForeground(false);
      final copies = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copies.add(call.arguments);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await openDialog(tester, identity);
      await tester.tap(find.byKey(const ValueKey('guest-web-delete-reveal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-web-delete-code')), findsNothing);
      expect(find.byKey(const ValueKey('guest-web-delete-copy')), findsNothing);
      expect(find.textContaining('Не удалось подтвердить код'), findsOneWidget);
      expect(copies, isEmpty);
      expect(savedDeletion(vault)!['registered'], false);
    },
  );

  testWidgets(
    'late reveal after logout cannot render or queue clipboard write',
    (tester) async {
      final vault = MemoryVault();
      final api = DeletionApi(vault)..keyGate = Completer<void>();
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await tester.runAsync(identity.restore);
      identity.setForeground(false);
      final copies = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copies.add(call.arguments);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await openDialog(tester, identity);
      await tester.tap(find.byKey(const ValueKey('guest-web-delete-reveal')));
      await tester.pump();
      expect(api.submittedKeys, hasLength(1));
      await identity.logout();
      api.keyGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-web-delete-code')), findsNothing);
      expect(find.byKey(const ValueKey('guest-web-delete-copy')), findsNothing);
      expect(
        find.text('Профиль изменился. Закройте это окно.'),
        findsOneWidget,
      );
      expect(copies, isEmpty);
      expect(savedDeletion(vault), isNull);
    },
  );

  testWidgets('registered and demo identities never offer guest code actions', (
    tester,
  ) async {
    final vault = MemoryVault();
    final api = DeletionApi(vault);
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await tester.runAsync(identity.restore);
    identity.setForeground(false);
    await identity.acceptRegisteredSession('demo-proof', {
      ...registered,
      'authMethod': 'password',
      'demoAccount': true,
    });
    await openDialog(tester, identity);
    expect(find.byKey(const ValueKey('guest-web-delete-reveal')), findsNothing);
    expect(find.byKey(const ValueKey('guest-web-delete-copy')), findsNothing);
    expect(api.submittedKeys, isEmpty);
    expect(
      () => identity.guestWebDeletionCode(),
      throwsA(isA<AccountIdentityChanged>()),
    );
  });
}
