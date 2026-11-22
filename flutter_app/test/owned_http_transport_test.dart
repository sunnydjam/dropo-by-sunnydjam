import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dropo/main.dart';
import 'package:dropo/owned_http_transport.dart';
import 'package:dropo/pinned_tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cert = File(
    'test/fixtures/tls/owned-transport-test-cert.pem',
  ).readAsBytesSync();
  final key = File(
    'test/fixtures/tls/bootstrap-test-key.pem',
  ).readAsBytesSync();
  SecurityContext trust() =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(cert);
  SecurityContext serving() => SecurityContext()
    ..useCertificateChainBytes(cert)
    ..usePrivateKeyBytes(key);

  test('only exact canonical endpoints receive compiled reserve mapping', () {
    final api = ownedHttpRoutes(
      Uri.parse('https://api.droponevedimka.ru/v1/me'),
      OwnedHttpResource.account,
    );
    expect(api.map((r) => r.address?.address), [
      '109.120.152.117',
      '91.229.239.99',
    ]);
    expect(
      api.last.uri.toString(),
      'https://ms-api.ordaflow.net/dropo-api/v1/me',
    );
    expect(
      ownedHttpRoutes(
        Uri.parse('https://api.droponevedimka.ru/public/v1/catalog'),
        OwnedHttpResource.account,
      ).last.uri.path,
      '/dropo-api/public/v1/catalog',
    );
    final sub = ownedHttpRoutes(
      Uri.parse(
        'https://app.droponevedimka.ru/managed/v1/subscription/token.signature',
      ),
      OwnedHttpResource.subscription,
    );
    expect(
      sub.last.uri.toString(),
      'https://ms-api.ordaflow.net/dropo-subscription/managed/v1/subscription/token.signature',
    );
    for (final origin in [
      'https://dropo.fun',
      'https://custom.example',
      'https://api.droponevedimka.ru.evil.invalid',
      'https://api.droponevedimka.ru:444',
    ]) {
      final other = ownedHttpRoutes(
        Uri.parse('$origin/v1/me'),
        OwnedHttpResource.account,
      );
      expect(other, hasLength(1));
      expect(other.single.address, isNull);
    }
    for (final url in [
      'http://app.droponevedimka.ru/managed/v1/subscription/t',
      'https://app.droponevedimka.ru:444/managed/v1/subscription/t',
      'https://app.droponevedimka.ru.evil.invalid/managed/v1/subscription/t',
      'https://user@app.droponevedimka.ru/managed/v1/subscription/t',
      'https://app.droponevedimka.ru/managed/v1/subscription/t?redirect=1',
      'https://app.droponevedimka.ru/managed/v1/subscription/',
      'https://app.droponevedimka.ru/managed/v1/subscription/../admin',
      'https://app.droponevedimka.ru/managed/v1/subscription/t%2Fadmin',
    ]) {
      expect(
        () => ownedHttpRoutes(Uri.parse(url), OwnedHttpResource.subscription),
        throwsFormatException,
      );
    }
    expect(
      () => ownedHttpRoutes(
        Uri.parse('https://api.droponevedimka.ru/admin'),
        OwnedHttpResource.account,
      ),
      throwsFormatException,
    );
    for (final path in [
      '/v1/admin/users',
      '/v1/web/admin',
      '/v1/ops',
      '/public/v1/catalog?redirect=1',
    ]) {
      expect(
        () => ownedHttpRoutes(
          Uri.parse('https://api.droponevedimka.ru$path'),
          OwnedHttpResource.account,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ownedHttpRoutes(
        Uri.parse('https://api.droponevedimka.ru/v1/me'),
        OwnedHttpResource.account,
        method: 'POST',
      ),
      throwsFormatException,
    );
    expect(
      ownedAccountMirrorPathAllowed(
        '/v1/action-confirmations/test_12345/consume',
        'POST',
      ),
      isTrue,
    );
    expect(
      ownedAccountMirrorPathAllowed(
        '/v1/action-confirmations/test_12345/consume',
        'GET',
      ),
      isFalse,
    );
    expect(
      accountCredentialOrigin('https://api.droponevedimka.ru'),
      'https://dropo.fun',
    );
    expect(
      accountCredentialOrigin('https://ms-api.ordaflow.net'),
      'https://ms-api.ordaflow.net',
    );
  });

  test(
    'connect failure chooses pinned reserve before sending POST exactly once',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serving(),
      );
      final calls = <String>[], requests = <String>[];
      final router = OwnedHttpTransport(
        resource: OwnedHttpResource.account,
        dial: (uri, address) {
          calls.add('${uri.host}@${address.address}');
          if (address.address == '109.120.152.117') {
            throw const SocketException('unreachable');
          }
          expect(uri.host, 'ms-api.ordaflow.net');
          return createPinnedTlsConnection(
            uri.replace(port: server.port),
            InternetAddress.loopbackIPv4,
            context: trust(),
          );
        },
      );
      final api = createAccountTransportForTesting(
        'https://api.droponevedimka.ru',
        connectionTransport: router,
      );
      addTearDown(() async {
        api.close();
        await server.close(force: true);
      });
      server.listen((r) async {
        requests.add('${r.method} ${r.uri.path}');
        expect(r.headers.value(HttpHeaders.hostHeader), 'ms-api.ordaflow.net');
        if (r.method == 'POST') {
          expect(
            r.headers.value(HttpHeaders.authorizationHeader),
            'Bearer fixture-token',
          );
          expect(jsonDecode(await utf8.decoder.bind(r).join()), {
            'installationSecret': 'fixture-secret',
          });
        }
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"ok":true}');
        await r.response.close();
      });
      expect(
        await api.request(
          'POST',
          '/v1/auth/guest',
          token: 'fixture-token',
          body: {'installationSecret': 'fixture-secret'},
        ),
        {'ok': true},
      );
      expect(await api.request('GET', '/v1/me'), {'ok': true});
      expect(requests, [
        'POST /dropo-api/v1/auth/guest',
        'GET /dropo-api/v1/me',
      ]);
      expect(calls, [
        'api.droponevedimka.ru@109.120.152.117',
        'ms-api.ordaflow.net@91.229.239.99',
        'ms-api.ordaflow.net@91.229.239.99',
      ]);
    },
  );

  test(
    'HTTP error and uncertain POST response never replay on reserve',
    () async {
      for (final loseReply in [false, true]) {
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serving(),
        );
        final calls = <String>[];
        var received = 0;
        final router = OwnedHttpTransport(
          resource: OwnedHttpResource.account,
          dial: (uri, address) {
            calls.add(uri.host);
            return createPinnedTlsConnection(
              uri.replace(port: server.port),
              InternetAddress.loopbackIPv4,
              context: trust(),
            );
          },
        );
        final api = createAccountTransportForTesting(
          'https://api.droponevedimka.ru',
          connectionTransport: router,
        );
        server.listen((r) async {
          await utf8.decoder.bind(r).join();
          received++;
          if (loseReply) {
            final socket = await r.response.detachSocket(writeHeaders: false);
            socket.destroy();
            return;
          }
          r.response.statusCode = 503;
          r.response.write('{"error":{"code":"unavailable"}}');
          await r.response.close();
        });
        try {
          await expectLater(
            api.request(
              'POST',
              '/v1/auth/guest',
              body: {'installationSecret': 'fixture-secret'},
            ),
            throwsA(anything),
          );
          expect(received, 1);
          expect(calls, ['api.droponevedimka.ru']);
        } finally {
          api.close();
          await server.close(force: true);
        }
      }
    },
  );

  test(
    'invalid TLS on both routes sends no HTTP and preserves failure',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serving(),
      );
      var received = 0;
      final calls = <String>[];
      server.listen((r) async {
        received++;
        await r.response.close();
      });
      final router = OwnedHttpTransport(
        resource: OwnedHttpResource.account,
        dial: (uri, address) {
          calls.add(uri.host);
          return createPinnedTlsConnection(
            uri.replace(host: 'wrong.invalid', port: server.port),
            InternetAddress.loopbackIPv4,
            context: trust(),
          );
        },
      );
      addTearDown(() async {
        router.close();
        await server.close(force: true);
      });
      await expectLater(
        router.open(
          'POST',
          Uri.parse('https://api.droponevedimka.ru/v1/auth/guest'),
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(received, 0);
      expect(calls, ['api.droponevedimka.ru', 'ms-api.ordaflow.net']);
    },
  );

  test('reserve affinity expires and primary is preferred again', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serving(),
    );
    var now = DateTime.utc(2026, 1, 1), primaryFailed = true;
    final calls = <String>[];
    server.listen((r) async {
      r.response.write('{}');
      await r.response.close();
    });
    final router = OwnedHttpTransport(
      resource: OwnedHttpResource.account,
      clock: () => now,
      dial: (uri, address) {
        calls.add(uri.host);
        if (primaryFailed && address.address == '109.120.152.117') {
          throw const SocketException('unreachable');
        }
        return createPinnedTlsConnection(
          uri.replace(port: server.port),
          InternetAddress.loopbackIPv4,
          context: trust(),
        );
      },
    );
    addTearDown(() async {
      router.close();
      await server.close(force: true);
    });
    Future<void> check() async {
      final acquired = await router.open(
        'GET',
        Uri.parse('https://api.droponevedimka.ru/v1/me'),
      );
      try {
        await (await acquired.request.close()).drain<void>();
      } finally {
        acquired.close();
      }
    }

    await check();
    primaryFailed = false;
    await check();
    now = now.add(const Duration(minutes: 6));
    await check();
    expect(calls, [
      'api.droponevedimka.ru',
      'ms-api.ordaflow.net',
      'ms-api.ordaflow.net',
      'api.droponevedimka.ru',
    ]);
  });

  test(
    'closing transport during connection cannot start the reserve',
    () async {
      final pending = Completer<ConnectionTask<Socket>>();
      var calls = 0;
      final router = OwnedHttpTransport(
        resource: OwnedHttpResource.account,
        connectTimeout: const Duration(milliseconds: 200),
        dial: (uri, address) {
          calls++;
          return pending.future;
        },
      );
      final opened = router.open(
        'POST',
        Uri.parse('https://api.droponevedimka.ru/v1/auth/guest'),
      );
      final expectation = expectLater(opened, throwsA(isA<SocketException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      router.close();
      pending.completeError(const SocketException('cancelled'));
      await expectation;
      expect(calls, 1);
    },
  );
}
