import 'dart:async';
import 'dart:convert';

import 'package:dropo/account_session_store.dart';
import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const endpoint = 'https://accounts.example.test';
const guest = <String, dynamic>{
  'id': 'guest-account',
  'authMethod': 'guest',
  'displayName': 'Бесплатный профиль',
  'demoAccount': false,
  'plan': 'Dropo Free',
};
const registered = <String, dynamic>{
  'id': 'registered-account',
  'authMethod': 'telegram',
  'displayName': 'User',
  'demoAccount': false,
};

class MemoryVault extends NativeAccountSessionStore {
  String? raw;
  bool failRead = false, failWrite = false;
  final writes = <String>[];
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('Unavailable');
    return raw;
  }

  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('Unavailable');
    raw = value;
    writes.add(value);
  }

  @override
  Future<void> clear() async {
    raw = null;
  }

  Map<String, dynamic> get record =>
      raw == null ? {} : jsonDecode(raw!) as Map<String, dynamic>;
}

class GuestApi implements AccountTransport {
  GuestApi(this.vault);
  final MemoryVault vault;
  bool enabled = true, failEnrollment = false, failDelete = false;
  String? terminalCode;
  Completer<void>? enrollmentGate, linkGate, deleteGate;
  bool expiredDelete = false, lostLinkResponse = false;
  DateTime now = DateTime.utc(2026, 10, 31);
  int issued = 0;
  final calls =
      <
        ({
          String method,
          String path,
          String? token,
          Map<String, dynamic>? body,
        })
      >[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    calls.add((method: method, path: path, token: token, body: body));
    if (path == '/v1/capabilities') {
      return {
        'guestAvailable': enabled,
        'incidentsAvailable': true,
        'registrationAvailable': true,
        'phoneRequired': false,
        'authMode': 'telegram_bot',
      };
    }
    if (path == '/v1/me') {
      return {'account': token == 'old-registered' ? registered : guest};
    }
    if (path == '/v1/auth/guest') {
      final stored = vault.record;
      expect(
        body!['installationSecret'],
        stored['installationSecret'] ??
            (stored['pendingDeletion'] as Map?)?['installationSecret'],
      );
      expect((body['installationSecret'] as String).length, 43);
      final knownId =
          stored['installationId'] ??
          (stored['pendingDeletion'] as Map?)?['installationId'];
      if (knownId != null) expect(body['installationId'], knownId);
      await enrollmentGate?.future;
      if (terminalCode != null) {
        throw AccountApiException(
          'Unavailable',
          status: 403,
          code: terminalCode!,
        );
      }
      if (failEnrollment) {
        throw const AccountApiException('Offline', status: 503);
      }
      return {
        'sessionToken': 'guest-token-${++issued}',
        'installationId': 'installation-1',
        'account': guest,
        'expiresAt': now.add(const Duration(hours: 1)).toIso8601String(),
      };
    }
    if (path == '/v1/guest/link') {
      await linkGate?.future;
      if (lostLinkResponse) {
        throw const AccountApiException('Lost response', status: 503);
      }
      return {
        'linked': true,
        'installationId': 'installation-1',
        'account': registered,
      };
    }
    if (path == '/v1/installations/bind') {
      expect(body!['installationSecret'], vault.record['installationSecret']);
      if (!lostLinkResponse) expect(vault.record['token'], token);
      return {
        'installationId':
            vault.record['installationId'] ?? 'registered-installation',
      };
    }
    if (path == '/v1/guest/account') {
      expect(vault.record['suppressed'], true);
      expect(vault.record['token'], isNull);
      await deleteGate?.future;
      if (expiredDelete && token == 'guest-token-1') {
        throw const AccountApiException(
          'Expired',
          status: 401,
          code: 'invalid_session',
        );
      }
      if (failDelete) throw const AccountApiException('Offline', status: 503);
      return {'success': true, 'deleted': true, 'sessionsRevoked': true};
    }
    if (path == '/v1/sessions/current') return {'success': true};
    throw StateError('Unexpected request: $method $path');
  }

  int get enrollments => calls.where((c) => c.path == '/v1/auth/guest').length;
  @override
  void close() {}
}

GuestIdentityCoordinator coordinator(MemoryVault vault, GuestApi api) =>
    GuestIdentityCoordinator(
      endpoint: endpoint,
      available: true,
      transport: api,
      store: ProtectedAccountIdentityStore(endpoint: endpoint, native: vault),
      platform: 'windows',
      appVersion: '3.0.52',
      now: () => api.now,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'nonpersistent identity never reads or writes native private state',
    () async {
      final vault = MemoryVault()
        ..failRead = true
        ..failWrite = true;
      final api = GuestApi(vault);
      final identity = GuestIdentityCoordinator(
        endpoint: endpoint,
        available: true,
        persistSession: false,
        initialToken: 'old-registered',
        transport: api,
        store: ProtectedAccountIdentityStore(endpoint: endpoint, native: vault),
        platform: 'windows',
      );
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.writePrivateState('incidents', {'consent': false});
      expect(await identity.readPrivateState('incidents'), {'consent': false});
      expect(vault.writes, isEmpty);
      expect(vault.raw, isNull);
    },
  );

  test(
    'existing registered account binds installation without guest registration',
    () async {
      final vault = MemoryVault()
        ..raw = jsonEncode({'endpoint': endpoint, 'token': 'old-registered'});
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      expect(identity.token, 'old-registered');
      expect(identity.installationId, 'registered-installation');
      expect(api.enrollments, 0);
      expect(
        api.calls.where((c) => c.path == '/v1/installations/bind').length,
        1,
      );
    },
  );

  test(
    'demo login replaces guest session without linking or binding',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.acceptRegisteredSession('demo-token', {
        ...registered,
        'demoAccount': true,
        'authMethod': 'password',
      });
      expect(identity.token, 'demo-token');
      expect(identity.installationId, isNull);
      expect(
        api.calls.where(
          (c) =>
              c.path == '/v1/guest/link' || c.path == '/v1/installations/bind',
        ),
        isEmpty,
      );
      expect(api.calls.last.token, 'guest-token-1');
      expect(api.calls.last.path, '/v1/sessions/current');
    },
  );

  test(
    'pending deletion prevents identity replacement and retains durable intent',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault)..failDelete = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.deleteGuest();
      await expectLater(
        identity.acceptRegisteredSession('new-proof', registered),
        throwsA(isA<AccountApiException>()),
      );
      expect(identity.deletionPending, true);
      expect(vault.record['pendingDeletion'], isNotNull);
    },
  );

  test(
    'failed suppression stops use but reports persistence failure',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      vault.failWrite = true;
      await expectLater(identity.logout(), throwsStateError);
      expect(identity.token, isNull);
      expect(identity.suppressed, true);
      expect(vault.record['suppressed'], isNot(true));
    },
  );

  test('late link completion cannot replace a logout tombstone', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)..linkGate = Completer<void>();
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    final linking = identity.acceptRegisteredSession('new-proof', registered);
    final rejected = expectLater(linking, throwsStateError);
    while (!api.calls.any((c) => c.path == '/v1/guest/link')) {
      await Future<void>.delayed(Duration.zero);
    }
    await identity.logout();
    api.linkGate!.complete();
    await rejected;
    expect(identity.token, isNull);
    expect(vault.record['suppressed'], true);
  });

  test('disposed deletion retry cannot renew the guest credential', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)
      ..deleteGate = Completer<void>()
      ..expiredDelete = true;
    final identity = coordinator(vault, api);
    await identity.restore();
    final deletion = identity.deleteGuest();
    while (!api.calls.any((c) => c.path == '/v1/guest/account')) {
      await Future<void>.delayed(Duration.zero);
    }
    identity.dispose();
    api.deleteGate!.complete();
    await deletion;
    expect(api.enrollments, 1);
  });

  test('expired deletion bearer renews only the known installation', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)..expiredDelete = true;
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    await identity.deleteGuest();
    final renewals = api.calls
        .where((call) => call.path == '/v1/auth/guest')
        .toList();
    expect(renewals.length, 2);
    expect(renewals.last.body!['installationId'], 'installation-1');
    expect(identity.deletionPending, false);
    expect(identity.suppressed, true);
  });

  test('disabled capability leaves an absent identity untouched', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)..enabled = false;
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    expect(identity.token, isNull);
    expect(api.enrollments, 0);
    expect(vault.writes, isEmpty);
  });

  test(
    'unreadable, malformed and different-origin vault never enroll',
    () async {
      for (final raw in [
        null,
        '{',
        '{"endpoint":"https://other.example","token":"old"}',
        '{"endpoint":"$endpoint","version":9}',
      ]) {
        final vault = MemoryVault()
          ..raw = raw
          ..failRead = raw == null;
        final api = GuestApi(vault);
        final identity = coordinator(vault, api);
        await identity.restore();
        expect(identity.state, 'storage_error');
        expect(api.calls, isEmpty);
        expect(vault.writes, isEmpty);
        identity.dispose();
      }
    },
  );

  test('legacy registered token wins over automatic guest creation', () async {
    final vault = MemoryVault()
      ..raw = jsonEncode({'endpoint': endpoint, 'token': 'old-registered'});
    final api = GuestApi(vault);
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    expect(identity.accountKind, 'registered');
    expect(identity.token, 'old-registered');
    expect(api.enrollments, 0);
    await identity.writePrivateState('incidents', {'consent': false});
    expect(vault.record['token'], 'old-registered');
    expect(vault.record['version'], 2);
  });

  test(
    'secret committed before enrollment and reused after lost response',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault)..failEnrollment = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      final secret = vault.record['installationSecret'];
      expect(secret, isNotNull);
      expect(identity.token, isNull);
      api.failEnrollment = false;
      await identity.restore();
      expect(api.enrollments, 2);
      expect(vault.record['installationSecret'], secret);
      expect(identity.token, 'guest-token-1');
      expect(identity.installationId, 'installation-1');
      expect(identity.accountKind, 'guest');
    },
  );

  test('secure write failure sends no enrollment request', () async {
    final vault = MemoryVault()..failWrite = true;
    final api = GuestApi(vault);
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    await identity.restore();
    expect(api.enrollments, 0);
    expect(identity.token, isNull);
  });

  test('concurrent restoration is single flight', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)..enrollmentGate = Completer<void>();
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    final first = identity.restore();
    final second = identity.restore();
    while (api.enrollments == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.enrollments, 1);
    api.enrollmentGate!.complete();
    await Future.wait([first, second]);
    expect(api.enrollments, 1);
  });

  test(
    'short-lived renewal preserves installation and identity epoch',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      final epoch = identity.identityEpoch;
      final secret = vault.record['installationSecret'];
      api.now = api.now.add(const Duration(minutes: 56));
      await identity.resume();
      expect(identity.token, 'guest-token-2');
      expect(identity.identityEpoch, epoch);
      expect(identity.installationId, 'installation-1');
      expect(vault.record['installationSecret'], secret);
    },
  );

  test(
    'terminal installation response persists suppression across restart',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault)..terminalCode = 'requires_login';
      final identity = coordinator(vault, api);
      await identity.restore();
      identity.dispose();
      expect(vault.record['suppressed'], true);
      expect(vault.record['installationSecret'], isNull);
      final next = coordinator(vault, api);
      addTearDown(next.dispose);
      await next.restore();
      expect(api.enrollments, 1);
      expect(next.suppressed, true);
    },
  );

  test(
    'logout suppresses auto-creation and clears private event state',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      await identity.restore();
      await identity.writePrivateState('incidents', {
        'events': [
          {'kind': 'probe_failed'},
        ],
      });
      await identity.logout();
      expect(identity.token, isNull);
      expect(vault.record['privateState'], isNull);
      identity.dispose();
      final next = coordinator(vault, api);
      addTearDown(next.dispose);
      await next.restore();
      expect(next.suppressed, true);
      expect(api.enrollments, 1);
    },
  );

  test(
    'offline deletion retries only deletion after restart, without resurrection',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault)..failDelete = true;
      final identity = coordinator(vault, api);
      await identity.restore();
      await identity.deleteGuest();
      expect(identity.token, isNull);
      expect(identity.deletionPending, true);
      identity.dispose();
      api.failDelete = false;
      final next = coordinator(vault, api);
      addTearDown(next.dispose);
      await next.restore();
      expect(next.suppressed, true);
      expect(next.deletionPending, false);
      expect(api.enrollments, 1);
      expect(vault.record['installationSecret'], isNull);
    },
  );

  test(
    'link preserves installation binding across logout and fresh proven login',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      final epoch = identity.identityEpoch;
      final secret = vault.record['installationSecret'];
      await identity.acceptRegisteredSession('registered-proof', registered);
      final link = api.calls.singleWhere((c) => c.path == '/v1/guest/link');
      expect(link.token, 'guest-token-1');
      expect(link.body, {'accountToken': 'registered-proof'});
      expect(identity.token, 'registered-proof');
      expect(identity.accountKind, 'registered');
      expect(identity.identityEpoch, greaterThan(epoch));
      expect(vault.record['installationSecret'], secret);
      expect(
        api.calls.where((c) => c.path == '/v1/installations/bind'),
        isEmpty,
      );
      await identity.logout();
      expect(identity.token, isNull);
      expect(identity.installationId, isNull);
      expect(vault.record['installationSecret'], secret);
      await identity.acceptRegisteredSession('fresh-proof', registered);
      expect(identity.installationId, 'installation-1');
      expect(identity.token, 'fresh-proof');
      final bind = api.calls.singleWhere(
        (c) => c.path == '/v1/installations/bind',
      );
      expect(bind.token, 'fresh-proof');
      expect(bind.body!['installationSecret'], secret);
      expect(api.enrollments, 1);
    },
  );

  test(
    'lost link response is confirmed by binding the same installation',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault)..lostLinkResponse = true;
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      final secret = vault.record['installationSecret'];
      await identity.acceptRegisteredSession('registered-proof', registered);
      expect(identity.token, 'registered-proof');
      expect(identity.installationId, 'installation-1');
      expect(vault.record['installationSecret'], secret);
      final confirmation = api.calls.singleWhere(
        (call) => call.path == '/v1/installations/bind',
      );
      expect(confirmation.token, 'registered-proof');
      expect(confirmation.body!['installationSecret'], secret);
    },
  );

  test(
    'private writes from a suppressed identity are typed cancellation',
    () async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await identity.restore();
      await identity.logout();
      await expectLater(
        identity.writePrivateState('incidents', {'consent': false}),
        throwsA(isA<AccountIdentityChanged>()),
      );
      expect(vault.record['privateState'], isNull);
    },
  );

  test('late enrollment cannot overwrite logout suppression', () async {
    final vault = MemoryVault();
    final api = GuestApi(vault)..enrollmentGate = Completer<void>();
    final identity = coordinator(vault, api);
    addTearDown(identity.dispose);
    final restore = identity.restore();
    while (api.enrollments == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await identity.logout();
    api.enrollmentGate!.complete();
    await restore;
    expect(identity.suppressed, true);
    expect(vault.record['token'], isNull);
  });

  test(
    'private-state updates preserve concurrent identity changes and enforce bound',
    () async {
      final vault = MemoryVault();
      final store = ProtectedAccountIdentityStore(
        endpoint: endpoint,
        native: vault,
      );
      await Future.wait([
        store.update(
          (record) => record.addAll({
            'token': 'registered-token',
            'accountKind': 'registered',
          }),
        ),
        store.writePrivateState('incidents', {'consent': false}),
      ]);
      expect(vault.record['token'], 'registered-token');
      expect(await store.readPrivateState('incidents'), {'consent': false});
      await expectLater(
        store.writePrivateState('incidents', {'x': 'x' * 8192}),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'guest profile has no Telegram requirement and offers explicit deletion',
    (tester) async {
      final vault = MemoryVault();
      final api = GuestApi(vault);
      final identity = coordinator(vault, api);
      addTearDown(identity.dispose);
      await tester.runAsync(identity.restore);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountPage(
              endpoint: endpoint,
              onOpenExternal: (_) async {},
              transport: api,
              identity: identity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guest-profile-title')), findsOneWidget);
      expect(find.textContaining('Telegram и пароль не нужны'), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-link-telegram')), findsOneWidget);
      expect(find.byKey(const ValueKey('guest-delete')), findsOneWidget);
      expect(
        api.calls.where((c) => c.path.contains('/auth/challenges')),
        isEmpty,
      );
      identity.setForeground(false);
    },
  );
}
