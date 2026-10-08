import 'dart:async';
import 'dart:io';

import 'package:dropo/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late AccountTransport transport;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = createAccountTransportForTesting(
      'http://127.0.0.1:${server.port}',
      responseTimeout: const Duration(milliseconds: 300),
    );
  });
  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  test('valid bounded response decodes normally', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"registrationAvailable":true}');
      await request.response.close();
    });
    expect(await transport.request('GET', '/v1/capabilities'), {
      'registrationAvailable': true,
    });
  });

  test('stalled response body times out instead of hanging loading', () async {
    final responses = <HttpResponse>[];
    server.listen((request) async {
      responses.add(request.response);
      request.response.headers.contentType = ContentType.json;
      request.response.write('{');
      await request.response.flush();
      // Deliberately never close the body; production must abort this request.
    });
    final started = DateTime.now();
    await expectLater(
      transport.request('GET', '/v1/capabilities'),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 3)),
    );
    for (final response in responses) {
      try {
        await response.close();
      } catch (_) {
        /* Client aborted. */
      }
    }
  });

  test('oversized fixed-length response is rejected', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('x' * (256 * 1024 + 1));
      try {
        await request.response.close();
      } catch (_) {
        /* Client aborted. */
      }
    });
    await expectLater(
      transport.request('GET', '/v1/capabilities'),
      throwsA(isA<AccountApiException>()),
    );
  });

  test('oversized chunked response is rejected', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = -1;
      request.response.write('x' * (256 * 1024 + 1));
      try {
        await request.response.close();
      } catch (_) {
        /* Client aborted. */
      }
    });
    await expectLater(
      transport.request('GET', '/v1/capabilities'),
      throwsA(isA<AccountApiException>()),
    );
  });

  test('redirect cannot forward an account credential', () async {
    var followed = false;
    server.listen((request) async {
      if (request.uri.path == '/v1/elsewhere') followed = true;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/v1/elsewhere');
      await request.response.close();
    });
    await expectLater(
      transport.request('GET', '/v1/me', token: 'test-session'),
      throwsA(isA<AccountApiException>()),
    );
    expect(followed, isFalse);
  });

  test('absolute external target is rejected before network request', () async {
    await expectLater(
      transport.request(
        'GET',
        'https://other.example/v1/me',
        token: 'test-session',
      ),
      throwsA(isA<AccountApiException>()),
    );
  });
}
