import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dropo/pinned_tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final certificate = File(
    'test/fixtures/tls/bootstrap-test-cert.pem',
  ).readAsBytesSync();
  final key = File(
    'test/fixtures/tls/bootstrap-test-key.pem',
  ).readAsBytesSync();
  SecurityContext trust() =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(certificate);
  SecurityContext serving() => SecurityContext()
    ..useCertificateChainBytes(certificate)
    ..usePrivateKeyBytes(key);
  test(
    'numeric bootstrap uses TLS with original hostname and no DNS lookup',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serving(),
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });
      server.listen((r) async {
        expect(r.certificate, isNull); // no client certificate requested
        expect(
          r.headers.value(HttpHeaders.authorizationHeader),
          'Bearer fixture-secret',
        );
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"secure":true}');
        await r.response.close();
      });
      client.connectionFactory = (uri, _, _) => createPinnedTlsConnection(
        uri,
        InternetAddress.loopbackIPv4,
        context: trust(),
      );
      final r = await client.getUrl(
        Uri.parse('https://bootstrap.invalid:${server.port}/v1/me'),
      );
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer fixture-secret');
      final response = await r.close();
      expect(response.statusCode, 200);
      expect(await utf8.decoder.bind(response).join(), '{"secure":true}');
    },
  );
  test(
    'wrong hostname and untrusted CA fail before application data',
    () async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serving(),
      );
      var requests = 0;
      server.listen((r) async {
        requests++;
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));
      for (final host in ['wrong.invalid', 'bootstrap.invalid']) {
        final client = HttpClient();
        client.connectionFactory = (uri, _, _) => createPinnedTlsConnection(
          uri,
          InternetAddress.loopbackIPv4,
          context: host == 'wrong.invalid'
              ? trust()
              : SecurityContext(withTrustedRoots: false),
        );
        try {
          await expectLater(
            client.getUrl(Uri.parse('https://$host:${server.port}/v1/me')),
            throwsA(isA<HandshakeException>()),
          );
        } finally {
          client.close(force: true);
        }
      }
      expect(requests, 0);
    },
  );
  test('TLS failure sends no plaintext HTTP or bearer token', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final observed = Completer<List<int>>();
    server.listen((socket) {
      socket.listen((bytes) {
        if (!observed.isCompleted) observed.complete(bytes);
        socket.destroy();
      });
    });
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close();
    });
    client.connectionFactory = (uri, _, _) => createPinnedTlsConnection(
      uri,
      InternetAddress.loopbackIPv4,
      context: trust(),
    );
    await expectLater(
      client.getUrl(
        Uri.parse('https://bootstrap.invalid:${server.port}/v1/me'),
      ),
      throwsA(anything),
    );
    final bytes = await observed.future.timeout(const Duration(seconds: 3));
    expect(bytes.first, 22); // TLS handshake record
    expect(latin1.decode(bytes), isNot(contains('GET /')));
    expect(latin1.decode(bytes), isNot(contains('Authorization')));
  });
  test('cancellation rejects promptly while the SDK handshake is stalled', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen(sockets.add);
    addTearDown(() async {
      for (final s in sockets) {
        s.destroy();
      }
      await server.close();
    });
    final task = await createPinnedTlsConnection(
      Uri.parse('https://bootstrap.invalid:${server.port}/'),
      InternetAddress.loopbackIPv4,
      context: trust(),
    );
    final completed = expectLater(
      task.socket.timeout(const Duration(seconds: 3)),
      throwsA(isNot(isA<TimeoutException>())),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    task.cancel();
    await completed;
  });
}
