import 'dart:convert';
import 'package:dropo/account_session_store.dart';
import 'package:dropo/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends NativeAccountSessionStore {
  _Vault(this.value, {String scope = 'account'}) : super(null, scope);
  String? value;
  int writes = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async {
    value = token;
    writes++;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _ProfileCheckpoint implements Exception {}

class _GuestAPI implements AccountTransport {
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    if (path == '/public/v1/catalog') return {};
    if (path == '/v1/vpn/profile') {
      expect(token, 'fixture-guest-session');
      throw _ProfileCheckpoint();
    }
    fail(
      'Guest identity must not bind as a registered account or enroll twice',
    );
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const endpoint = 'https://api.droponevedimka.ru';
  final secret = base64UrlEncode(List<int>.filled(32, 7)).replaceAll('=', '');
  const installation = 'fixture-installation-01';
  String profile({bool linked = true}) => base64UrlEncode(
    utf8.encode(
      jsonEncode({
        'format': 1,
        'origin': 'https://dropo.fun',
        'secret': secret,
        'installationId': installation,
        'linked': linked,
      }),
    ),
  );

  test(
    'preview upgrade keeps the registered session and installation recovery secret',
    () async {
      final primary = _Vault(
        jsonEncode({
          'endpoint': 'https://dropo.fun',
          'token': 'fixture-registered-session',
        }),
      );
      final managed = _Vault(profile(), scope: 'managed-vpn-v1');
      final identity = ProtectedAccountIdentityStore(
        endpoint: endpoint,
        native: primary,
      );
      final client = OwnedVPNClient(
        endpoint: endpoint,
        store: managed,
        identityStore: identity,
      );
      final original = managed.value;
      await client.prepareAccountIdentity();
      final record = await identity.read();
      expect(record['token'], 'fixture-registered-session');
      expect(record['accountKind'], 'registered');
      expect(record['installationSecret'], secret);
      expect(record['installationId'], installation);
      expect(record['endpoint'], 'https://dropo.fun');
      expect(managed.value, original);
    },
  );

  test(
    'existing different identity and local suppression survive upgrade',
    () async {
      for (final extra in [
        {
          'installationSecret': base64UrlEncode(
            List<int>.filled(32, 8),
          ).replaceAll('=', ''),
        },
        {'suppressed': true},
      ]) {
        final primary = _Vault(
          jsonEncode({'version': 2, 'endpoint': endpoint, ...extra}),
        );
        final original = primary.value;
        final client = OwnedVPNClient(
          endpoint: endpoint,
          store: _Vault(profile(), scope: 'managed-vpn-v1'),
          identityStore: ProtectedAccountIdentityStore(
            endpoint: endpoint,
            native: primary,
          ),
        );
        await client.prepareAccountIdentity();
        expect(primary.value, original);
        expect(primary.writes, 0);
      }
    },
  );

  test('a stale startup cannot modify the current account vault', () async {
    final primary = _Vault(null);
    final client = OwnedVPNClient(
      endpoint: endpoint,
      store: _Vault(profile(), scope: 'managed-vpn-v1'),
      identityStore: ProtectedAccountIdentityStore(
        endpoint: endpoint,
        native: primary,
      ),
    );
    await client.prepareAccountIdentity(canWrite: () => false);
    expect(primary.value, isNull);
    expect(primary.writes, 0);
  });

  test(
    'managed Free reuses the existing guest without a registered bind',
    () async {
      final primary = _Vault(
        jsonEncode({
          'version': 2,
          'endpoint': 'https://dropo.fun',
          'accountKind': 'guest',
          'token': 'fixture-guest-session',
          'installationSecret': secret,
          'installationId': installation,
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        }),
      );
      final managed = _Vault(null, scope: 'managed-vpn-v1');
      final api = _GuestAPI();
      const channel = MethodChannel('dropo/account_session');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'read' ? primary.value : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final client = OwnedVPNClient(
        endpoint: endpoint,
        store: managed,
        identityStore: ProtectedAccountIdentityStore(
          endpoint: endpoint,
          native: primary,
        ),
      );
      await expectLater(
        client.enroll(
          api,
          (a, b, c, d) async =>
              throw StateError('No native source update before a profile'),
          (raw, min) async => {'success': true, 'revision': 1},
        ),
        throwsA(isA<_ProfileCheckpoint>()),
      );
      expect(api.calls, ['GET /public/v1/catalog', 'POST /v1/vpn/profile']);
      final record =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(managed.value!)),
                ),
              )
              as Map;
      expect(record['secret'], secret);
      expect(record['installationId'], installation);
      expect(record['guestToken'], 'fixture-guest-session');
    },
  );
}
