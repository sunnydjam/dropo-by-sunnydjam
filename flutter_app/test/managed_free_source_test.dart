import 'package:dropo/main.dart';
import 'package:flutter_test/flutter_test.dart';

class _FreeTransport implements AccountTransport {
  Map<String, dynamic> response = {'available': false};
  int requests = 0;
  bool fail = false;

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    requests++;
    expect(method, 'GET');
    expect(path, '/v1/vpn/free-source');
    expect(token, isNull);
    expect(body, isNull);
    if (fail) throw StateError('https://free.example.com/sub/private-fixture');
    return response;
  }

  @override
  void close() {}
}

void main() {
  test(
    'offer listing and missing consent never request backend or save source',
    () async {
      final api = _FreeTransport();
      final client = ManagedFreeSourceClient(
        endpoint: 'https://api.example.test',
        transport: api,
      );
      expect(client.providers.single.id, 'dropo-free');
      expect(client.providers.single.website, isEmpty);
      var saves = 0;
      Future<Map<String, dynamic>> save(
        String id,
        String name,
        String uri,
        bool consent,
      ) async {
        saves++;
        return {'success': true};
      }

      expect(
        (await client.add('dropo-free', false, save: save))['success'],
        isFalse,
      );
      expect(
        (await client.add('vpn-checker-ru-part9', true, save: save))['success'],
        isFalse,
      );
      expect(api.requests, 0);
      expect(saves, 0);
    },
  );

  test(
    'unconfigured service honestly unavailable without network or source mutation',
    () async {
      for (final endpoint in [
        '',
        'http://remote.example.test',
        'https://user:pass@api.example.test',
      ]) {
        final api = _FreeTransport();
        final client = ManagedFreeSourceClient(
          endpoint: endpoint,
          transport: api,
        );
        expect(client.providers, isEmpty);
        final result = await client.add(
          'dropo-free',
          true,
          save: (_, _, _, _) async => throw StateError('must not save'),
        );
        expect(result['success'], isFalse);
        expect(result['error'], contains('недоступен'));
        expect(api.requests, 0);
      }
    },
  );

  test(
    'managed provider is resolved only after consent and saved through typed source API',
    () async {
      final api = _FreeTransport()
        ..response = {
          'available': true,
          'provider': {
            'id': 'dropo-free',
            'name': 'Ignored remote label',
            'subscriptionUrl': 'https://free.example.com/sub/private-fixture',
          },
        };
      final client = ManagedFreeSourceClient(
        endpoint: 'https://api.example.test',
        transport: api,
      );
      var saves = 0;
      final result = await client.add(
        'dropo-free',
        true,
        save: (id, name, uri, consent) async {
          saves++;
          expect(id, 'dropo-free');
          expect(name, 'Dropo Free');
          expect(uri, 'https://free.example.com/sub/private-fixture');
          expect(consent, isTrue);
          return {'success': true};
        },
      );
      expect(api.requests, 1);
      expect(saves, 1);
      expect(result, {'success': true});
      expect(result.toString(), isNot(contains('private-fixture')));
    },
  );

  test('unavailable or wrong provider never becomes a source', () async {
    for (final response in <Map<String, dynamic>>[
      {'available': false},
      {
        'available': true,
        'provider': {
          'id': 'vpn-checker-ru-part9',
          'subscriptionUrl': 'https://free.example.com/sub/private-fixture',
        },
      },
      {
        'available': true,
        'provider': {'id': 'dropo-free'},
      },
    ]) {
      final api = _FreeTransport()..response = response;
      final client = ManagedFreeSourceClient(
        endpoint: 'https://api.example.test',
        transport: api,
      );
      final result = await client.add(
        'dropo-free',
        true,
        save: (_, _, _, _) async => throw StateError('must not save'),
      );
      expect(result['success'], isFalse);
      expect(result.toString(), isNot(contains('private-fixture')));
      expect(api.requests, 1);
    }
  });

  test(
    'managed subscription validates HTTPS public hosts without credentials',
    () {
      for (final value in [
        'https://free.example.com/sub/private-fixture',
        'https://FREE.EXAMPLE.COM./sub/private-fixture?cache=1',
        'https://8.8.8.8/sub/private-fixture',
        'https://[2001:4860:4860::8888]/sub/private-fixture',
      ]) {
        expect(
          managedFreeSubscriptionUrlValid(value),
          isTrue,
          reason: 'valid public fixture',
        );
      }
      for (final value in [
        '',
        'http://free.example.com/sub/private-fixture',
        'vless://key@free.example.com:443',
        'https://user:password@free.example.com/sub/private-fixture',
        'https://free.example.com/sub/private-fixture#token',
        'https://localhost/sub/private-fixture',
        'https://LOCALHOST./sub/private-fixture',
        'https://router.local/sub/private-fixture',
        'https://intranet/sub/private-fixture',
        'https://127.0.0.1/sub/private-fixture',
        'https://10.0.0.1/sub/private-fixture',
        'https://172.16.0.1/sub/private-fixture',
        'https://192.168.1.1/sub/private-fixture',
        'https://100.64.0.1/sub/private-fixture',
        'https://169.254.0.1/sub/private-fixture',
        'https://0.0.0.0/sub/private-fixture',
        'https://[::1]/sub/private-fixture',
        'https://[fc00::1]/sub/private-fixture',
        'https://[fe80::1]/sub/private-fixture',
        'https://[::ffff:192.168.1.1]/sub/private-fixture',
      ]) {
        expect(
          managedFreeSubscriptionUrlValid(value),
          isFalse,
          reason: 'invalid/private fixture',
        );
      }
    },
  );

  test(
    'backend malformed URL and transport/save errors do not leak subscription credentials',
    () async {
      final api = _FreeTransport()
        ..response = {
          'available': true,
          'provider': {
            'id': 'dropo-free',
            'subscriptionUrl': 'http://free.example.com/sub/private-fixture',
          },
        };
      final client = ManagedFreeSourceClient(
        endpoint: 'https://api.example.test',
        transport: api,
      );
      final invalid = await client.add(
        'dropo-free',
        true,
        save: (_, _, _, _) async => throw StateError('must not save'),
      );
      expect(invalid['success'], isFalse);
      expect(invalid.toString(), isNot(contains('private-fixture')));
      api.response['provider'] = {
        'id': 'dropo-free',
        'subscriptionUrl': 'https://free.example.com/sub/private-fixture',
      };
      final failed = await client.add(
        'dropo-free',
        true,
        save: (_, _, _, _) async => {
          'success': false,
          'error':
              'download https://free.example.com/sub/private-fixture failed',
        },
      );
      expect(failed['success'], isFalse);
      expect(failed.toString(), isNot(contains('private-fixture')));
      api.fail = true;
      final network = await client.add(
        'dropo-free',
        true,
        save: (_, _, _, _) async => throw StateError('must not save'),
      );
      expect(network['success'], isFalse);
      expect(network.toString(), isNot(contains('private-fixture')));
    },
  );
}
