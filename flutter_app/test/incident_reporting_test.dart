import 'dart:async';
import 'dart:convert';
import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements AccountTransport {
  final List<Map<String, dynamic>> requests = [];
  Object? error;
  Completer<Map<String, dynamic>>? pending;
  bool closed = false;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    expect(method, 'POST');
    expect(path, '/v1/incidents');
    requests.add({'token': token, 'body': body});
    if (error != null) throw error!;
    return pending == null ? {'accepted': 1} : await pending!.future;
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late IncidentReporter reporter;
  late _Transport transport;
  late DateTime time;
  late IncidentIdentity identity;
  Map<String, dynamic>? stored;
  bool storageFails = false;

  Future<void> initialize() async {
    reporter = IncidentReporter(
      readState: () async => stored,
      writeState: (value) async {
        if (storageFails) throw StateError('keystore unavailable');
        stored = jsonDecode(jsonEncode(value)) as Map<String, dynamic>?;
      },
      identity: () => identity,
      openTransport: () => transport,
      platform: 'android',
      now: () => time,
      scheduleUploads: false,
    );
    await reporter.initialize();
  }

  void record({
    String service = 'telegram',
    String kind = 'service_probe',
    bool success = false,
  }) => reporter.record(
    kind: kind,
    service: service,
    success: success,
    category: success ? 'none' : 'timeout',
    version: '3.0.52',
    mode: 'blocked_only',
  );

  setUp(() {
    transport = _Transport();
    time = DateTime.utc(2026, 10, 31);
    identity = const IncidentIdentity(
      owner: 'account-one',
      epoch: 1,
      token: 'test-only-token',
      available: true,
    );
    stored = null;
    storageFails = false;
  });
  tearDown(() => reporter.dispose());

  testWidgets('mobile consent is explicit, scrollable and can be declined', (
    tester,
  ) async {
    await initialize();
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IncidentScope(
        reporter: reporter,
        child: MaterialApp(
          home: Scaffold(
            body: const SingleChildScrollView(child: IncidentPrivacySetting()),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Технические сведения о подключении'), findsOneWidget);
    expect(reporter.enabled, false);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Не сейчас'));
    await tester.pumpAndSettle();
    expect(reporter.enabled, false);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить'));
    await tester.pumpAndSettle();
    expect(reporter.enabled, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('no collection or requests before explicit opt in', () async {
    await initialize();
    record();
    await reporter.flush();
    expect(reporter.enabled, false);
    expect(reporter.queuedCount, 0);
    expect(transport.requests, isEmpty);
  });
  test('source probe failure is distinct from a connection failure', () async {
    await initialize();
    await reporter.setEnabled(true);
    reporter.observeConnection(
      CoreStatus.fromJson({
        'connected': true,
        'version': {'version': '3.0.52'},
        'vpnResponse': {
          'state': 'failed',
          'checkedAt': time.toIso8601String(),
          'sessionGeneration': 7,
          'sourceId': 'private-source',
          'target': 'https://private-target.invalid',
        },
      }),
      'blocked_only',
    );
    await reporter.flush();
    final events = (transport.requests.single['body'] as Map)['events'] as List;
    expect(events.any((dynamic e) => e['kind'] == 'connection_failure'), false);
    expect(
      events.any(
        (dynamic e) => e['kind'] == 'service_probe' && e['result'] == 'failure',
      ),
      true,
    );
    expect(jsonEncode(events), isNot(contains('private')));
  });
  test(
    'failure category is bounded and never returns the source text',
    () async {
      await initialize();
      expect(
        incidentFailureCategory(
          'dial https://private.invalid context deadline exceeded',
        ),
        'timeout',
      );
      expect(
        incidentFailureCategory('lookup private.invalid: no such host'),
        'dns',
      );
      expect(incidentFailureCategory('private credential'), 'unknown');
      expect(incidentFailureCategory('tls handshake failed'), 'tls');
    },
  );
  test('uploads only allowlisted schema, with consent and auth', () async {
    await initialize();
    expect(await reporter.setEnabled(true), true);
    record();
    await reporter.flush();
    expect(transport.requests.single['token'], 'test-only-token');
    final body = transport.requests.single['body'] as Map;
    expect(body['consentVersion'], 1);
    final event = (body['events'] as List).single as Map;
    expect(event.keys.toSet(), IncidentEvent.fields);
    expect(event['service'], 'telegram');
    expect(event['routeVerified'], false);
    expect(reporter.queuedCount, 0);
    expect(jsonEncode(stored), isNot(contains('test-only-token')));
  });
  test(
    'raw URLs errors and custom services never enter event stream',
    () async {
      await initialize();
      await reporter.setEnabled(true);
      record(service: 'private-site.example');
      final report = ConnectionHealthReport.fromJson({
        'success': false,
        'sessionValid': true,
        'checkedAt': time.toIso8601String(),
        'error': 'private logs https://secret.example/sub/key',
        'services': [
          {
            'serviceTag': 'telegram',
            'name': 'private name',
            'url': 'https://secret.example/sub/key',
            'success': false,
            'error': 'vless://private-credential@example.com',
            'routeVerified': false,
          },
        ],
      });
      reporter.observeReport(report, 'private-version', 'blocked_only');
      await reporter.flush();
      final body = jsonEncode(transport.requests.single['body']);
      expect(body, isNot(contains('private')));
      expect(body, isNot(contains('example')));
      expect(body, contains('unknown'));
      expect(reporter.queuedCount, 0);
    },
  );
  test('deduplicates observations and bounds offline queue', () async {
    await initialize();
    await reporter.setEnabled(true);
    record();
    record();
    expect(reporter.queuedCount, 1);
    for (var i = 0; i < 30; i++) {
      time = time.add(const Duration(minutes: 6));
      record();
    }
    expect(reporter.queuedCount, IncidentReporter.maxEvents);
    await Future<void>.delayed(Duration.zero);
    expect(
      utf8.encode(jsonEncode(stored!['events'])).length,
      lessThanOrEqualTo(IncidentReporter.maxQueueBytes),
    );
  });
  test('opt out cancels upload and purges queued records', () async {
    await initialize();
    await reporter.setEnabled(true);
    record();
    transport.pending = Completer();
    final upload = reporter.flush();
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests.length, 1);
    await reporter.setEnabled(false);
    expect(transport.closed, true);
    expect(reporter.queuedCount, 0);
    transport.pending!.complete({'accepted': 1});
    await upload;
    expect(reporter.enabled, false);
    expect(stored!['events'], isEmpty);
    record();
    expect(reporter.queuedCount, 0);
  });
  test(
    'account switch cannot upload old records with new credential',
    () async {
      await initialize();
      await reporter.setEnabled(true);
      record();
      identity = const IncidentIdentity(
        owner: 'account-two',
        epoch: 2,
        token: 'different-token',
        available: true,
      );
      reporter.synchronizeIdentity();
      await reporter.flush();
      expect(reporter.enabled, false);
      expect(reporter.queuedCount, 0);
      expect(transport.requests, isEmpty);
    },
  );
  test('offline retry preserves event ID and applies backoff', () async {
    await initialize();
    await reporter.setEnabled(true);
    record();
    transport.error = const AccountApiException('offline');
    await reporter.flush();
    await reporter.flush();
    expect(transport.requests.length, 1);
    expect(reporter.queuedCount, 1);
    final first = jsonEncode(transport.requests.single['body']);
    time = time.add(const Duration(hours: 2));
    transport.error = null;
    await reporter.flush();
    expect(jsonEncode(transport.requests.last['body']), first);
    expect(reporter.queuedCount, 0);
  });
  test(
    'storage failure disables upload instead of plaintext fallback',
    () async {
      await initialize();
      storageFails = true;
      expect(await reporter.setEnabled(true), false);
      record();
      await reporter.flush();
      expect(reporter.enabled, false);
      expect(reporter.storageFailed, true);
      expect(transport.requests, isEmpty);
    },
  );
  test('queue expires after seven days and stale checks are ignored', () async {
    await initialize();
    await reporter.setEnabled(true);
    record();
    time = time.add(const Duration(days: 8));
    await reporter.flush();
    expect(reporter.queuedCount, 0);
    expect(transport.requests, isEmpty);
    expect(stored!['events'], isEmpty);
  });
  test('startup removes expired events from protected storage too', () async {
    await initialize();
    await reporter.setEnabled(true);
    record();
    await Future<void>.delayed(Duration.zero);
    expect(stored!['events'], isNotEmpty);
    reporter.dispose();
    time = time.add(const Duration(days: 8));
    await initialize();
    expect(reporter.queuedCount, 0);
    expect(stored!['events'], isEmpty);
  });
  test(
    'mixed targets cannot claim service recovery within one report',
    () async {
      await initialize();
      await reporter.setEnabled(true);
      ConnectionHealthReport report(bool allPass) =>
          ConnectionHealthReport.fromJson({
            'success': allPass,
            'sessionValid': true,
            'checkedAt': time.toIso8601String(),
            'services': [
              {
                'serviceTag': 'telegram',
                'success': allPass,
                'routeVerified': false,
                'error': 'timeout',
              },
              {
                'serviceTag': 'telegram',
                'success': true,
                'routeVerified': true,
              },
            ],
          });
      reporter.observeReport(report(false), '3.0.52', 'blocked_only');
      time = time.add(const Duration(minutes: 6));
      reporter.observeReport(report(false), '3.0.52', 'blocked_only');
      await reporter.flush();
      final first =
          (transport.requests.single['body'] as Map)['events'] as List;
      expect(first.length, 2);
      expect(
        first.every(
          (dynamic e) =>
              e['result'] == 'failure' && e['kind'] == 'service_probe',
        ),
        true,
      );
      time = time.add(const Duration(minutes: 6));
      reporter.observeReport(report(true), '3.0.52', 'blocked_only');
      await reporter.flush();
      final recovered =
          ((transport.requests.last['body'] as Map)['events'] as List).single
              as Map;
      expect(recovered['kind'], 'recovery');
      expect(recovered['routeVerified'], false);
    },
  );
  test(
    'restored record rejects injected fields even in protected storage',
    () async {
      await initialize();
      await reporter.setEnabled(true);
      record();
      await Future<void>.delayed(Duration.zero);
      reporter.dispose();
      (stored!['events'] as List).first['url'] = 'https://sensitive.invalid';
      await initialize();
      expect(reporter.queuedCount, 0);
    },
  );
}
