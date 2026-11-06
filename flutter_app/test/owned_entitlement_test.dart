import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dropo/main.dart';
import 'package:dropo/account_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends NativeAccountSessionStore {
  _Vault(Map<String, dynamic> record) : super(null, 'managed-vpn-v1') {
    value = base64UrlEncode(utf8.encode(jsonEncode(record)));
  }
  late String value;
  Map<String, dynamic> get record =>
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(value))))
          as Map<String, dynamic>;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async {
    value = token;
  }
}

class _Bridge extends MockCoreBridge {
  bool connected = false;
  final added = <String>[];
  final removed = <String>[];
  @override
  Future<CoreStatus> status() async =>
      CoreStatus.fromJson({'connected': connected});
  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<dynamic> args = const [],
    Duration? timeout,
  }) async {
    if (method == 'ValidateManagedCatalog') {
      return {'success': true, 'revision': 1};
    }
    if (method == 'AddManagedVPNSource') {
      added.add(args[0] as String);
      return {'success': true};
    }
    if (method == 'GetVPNSources') {
      return {
        'sources': [
          {'id': 'manual', 'public_catalog_id': ''},
          {'id': 'free', 'public_catalog_id': 'dropo-individual-free'},
          {'id': 'boost', 'public_catalog_id': 'dropo-individual-boost'},
        ],
      };
    }
    throw StateError('Unexpected bridge method $method');
  }

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) async {
    removed.add(id);
    return {'success': true};
  }
}

class _API implements AccountTransport {
  _API(this.until);
  final int until;
  final calls = <String>[];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    if (fail) throw const AccountApiException('offline');
    if (path == '/public/v1/catalog') return {};
    expect(token, 'registered-fixture');
    if (path == '/v1/installations/bind') {
      return {'installationId': 'fixture-installation'};
    }
    if (path == '/v1/vpn/profile') {
      return {
        'status': 'ready',
        'id': 'fixture-installation',
        'boostUntilUnix': until,
        'freeSubscriptionUrl':
            'https://app.droponevedimka.ru/managed/v1/subscription/free',
        'boostSubscriptionUrl':
            'https://app.droponevedimka.ru/managed/v1/subscription/boost',
      };
    }
    throw StateError('Unexpected API path');
  }

  @override
  void close() {}
}

class _HTTP extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client();
}

class _Client implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _Request(url.pathSegments.last);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.pool);
  final String pool;
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => _Response(pool);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.pool);
  final String pool;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(
    utf8.encode(
      base64Encode(
        utf8.encode(
          'vless://00000000-0000-0000-0000-000000000001@cdn.droponevedimka.ru:443?security=tls#$pool',
        ),
      ),
    ),
  ).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Vault vault;
  late _Bridge bridge;
  late _API api;
  late OwnedVPNClient client;
  late DateTime until;
  setUp(() {
    until = DateTime.fromMillisecondsSinceEpoch(
      (DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400) * 1000,
    );
    vault = _Vault({
      'format': 1,
      'origin': 'https://dropo.fun',
      'secret': 'fixture-secret',
      'installationId': 'fixture-installation',
      'linked': true,
      'freeKey': 'protected-original-free',
      'boostUntil': 0,
    });
    bridge = _Bridge();
    api = _API(until.millisecondsSinceEpoch ~/ 1000);
    client = OwnedVPNClient(
      endpoint: 'https://api.droponevedimka.ru',
      store: vault,
    );
  });
  test(
    'web gift replaces cached Free with both current managed profiles',
    () async {
      final result = await HttpOverrides.runWithHttpOverrides(
        () => client.synchronizeEntitlement(
          bridge,
          'registered-fixture',
          until,
          transport: api,
        ),
        _HTTP(),
      );
      expect(result['success'], true);
      expect(bridge.added, ['dropo-individual-free', 'dropo-individual-boost']);
      expect(vault.record['boostKey'], contains('#boost'));
      expect(vault.record['boostUntil'], api.until);
      expect(api.calls.where((x) => x == 'POST /v1/vpn/profile'), hasLength(1));
      expect(api.calls.any((x) => x.contains('/v1/guest/link')), false);
    },
  );
  test('unchanged entitlement does not query or reissue profiles', () async {
    vault.value = base64UrlEncode(
      utf8.encode(
        jsonEncode({
          ...vault.record,
          'boostKey': 'cached-boost',
          'boostUntil': api.until,
        }),
      ),
    );
    expect(
      (await client.synchronizeEntitlement(
        bridge,
        'registered-fixture',
        until,
        transport: api,
      ))['unchanged'],
      true,
    );
    expect(api.calls, isEmpty);
    expect(bridge.added, isEmpty);
  });
  test(
    'revocation removes only managed Boost and preserves Free and manual sources',
    () async {
      vault.value = base64UrlEncode(
        utf8.encode(
          jsonEncode({
            ...vault.record,
            'boostKey': 'cached-boost',
            'boostUntil': api.until,
          }),
        ),
      );
      expect(
        (await client.synchronizeEntitlement(
          bridge,
          'registered-fixture',
          null,
          transport: api,
        ))['turboRemoved'],
        true,
      );
      expect(bridge.removed, ['boost']);
      expect(vault.record['freeKey'], 'protected-original-free');
      expect(vault.record['boostKey'], isNull);
      expect(api.calls, isEmpty);
    },
  );
  test(
    'active session defers a changed entitlement without interrupting traffic',
    () async {
      bridge.connected = true;
      final before = vault.value;
      expect(
        (await client.synchronizeEntitlement(
          bridge,
          'registered-fixture',
          until,
          transport: api,
        ))['deferred'],
        true,
      );
      expect(vault.value, before);
      expect(bridge.added, isEmpty);
      expect(api.calls, isEmpty);
    },
  );
  test(
    'offline refresh preserves the usable protected Free credential',
    () async {
      api.fail = true;
      expect(
        (await client.synchronizeEntitlement(
          bridge,
          'registered-fixture',
          until,
          transport: api,
        ))['success'],
        false,
      );
      expect(vault.record['freeKey'], 'protected-original-free');
      expect(bridge.added, isEmpty);
      expect(bridge.removed, isEmpty);
    },
  );
}
