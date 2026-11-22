import 'dart:convert';
import 'package:dropo/main.dart';
import 'package:dropo/account_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends MockCoreBridge {
  final removed = <String>[];
  List<Map<String, dynamic>>? references;
  bool failCleanup = false;
  int stops = 0;
  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    expect(value, false);
    stops++;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<dynamic> args = const [],
    Duration? timeout,
  }) async {
    expect(method, 'GetVPNSources');
    return {
      'sources':
          references ??
          [
            {'id': 'manual', 'public_catalog_id': ''},
            {'id': 'free', 'public_catalog_id': 'dropo-individual-free'},
            {
              'id': 'free-reserve',
              'public_catalog_id': 'dropo-individual-free-reserve',
            },
            {'id': 'boost', 'public_catalog_id': 'dropo-individual-boost'},
            {
              'id': 'boost-reserve',
              'public_catalog_id': 'dropo-individual-boost-reserve',
            },
            {'id': 'legacy', 'public_catalog_id': 'dropo-free'},
          ],
    };
  }

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) async {
    removed.add(id);
    return {'success': !failCleanup};
  }
}

class _RestoreBridge implements CoreBridge {
  _RestoreBridge(this.references);
  final List<Map<String, dynamic>> references;
  final added = <String>[];
  final restoreReferences = <String>[];
  final restoreNodeIDs = <String>[];
  bool deleteAfterSnapshot = false;
  bool replaceNodeAfterSnapshot = false;
  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<dynamic> args = const [],
    Duration? timeout,
  }) async {
    if (method == 'GetVPNSources') {
      final snapshot = references.map((source) => {...source}).toList();
      if (deleteAfterSnapshot) references.clear();
      if (replaceNodeAfterSnapshot) {
        references.first['node_ids'] = ['new-primary'];
        references.first['selected_node'] = 0;
      }
      return {'sources': snapshot};
    }
    if (method == 'RestoreManagedVPNSource') {
      expect(args, hasLength(4));
      restoreReferences.add(args[2] as String);
      restoreNodeIDs.add(args[3] as String);
      final current = references
          .where((source) => source['id'] == args[2])
          .firstOrNull;
      if (current == null) {
        return {'success': false, 'error': 'Expected reference was removed'};
      }
      final nodes = current['node_ids'] as List? ?? const [];
      final index = (current['selected_node'] as num?)?.toInt() ?? 0;
      final selectedID = nodes.isEmpty ? '' : nodes[index];
      if (selectedID != args[3]) {
        return {'success': false, 'error': 'Expected reference was replaced'};
      }
      added.add(args.first as String);
      return {'success': true};
    }
    throw StateError('Unexpected restore method');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _API implements AccountTransport {
  final calls = <String>[];
  bool loseDeleteReply = false;
  bool deleted = false;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    if (path == '/v1/guest/deletion-status') {
      expect(token, isNull);
      return {'deleted': deleted};
    }
    if (path == '/v1/auth/guest') {
      return {'sessionToken': 'recovered-guest-token'};
    }
    expect(token, isNotEmpty);
    if (path == '/v1/guest/deletion-key') return {'ready': true};
    if (path == '/v1/guest/account') {
      deleted = true;
      if (loseDeleteReply) {
        throw const AccountApiException('private detail must not reach UI');
      }
      return {'deleted': true};
    }
    throw StateError('Unexpected request');
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dropo/account_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? protected;
  Map<String, dynamic> record() => Map<String, dynamic>.from(
    jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(protected!))))
        as Map,
  );
  void seed(Map<String, dynamic> extra) {
    protected = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'format': 1,
          'origin': accountCredentialOrigin('https://api.droponevedimka.ru'),
          'secret': 'fixture-installation-secret',
          'guestToken': 'fixture-guest-token',
          ...extra,
        }),
      ),
    );
  }

  OwnedVPNClient client() => OwnedVPNClient(
    endpoint: 'https://api.droponevedimka.ru',
    store: NativeAccountSessionStore(channel, 'managed-vpn-v1'),
  );
  setUp(() {
    seed({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect((call.arguments as Map)['scope'], 'managed-vpn-v1');
      if (call.method == 'read') return protected;
      if (call.method == 'write') {
        protected = (call.arguments as Map)['token'] as String;
        return null;
      }
      if (call.method == 'clear') {
        protected = null;
        return null;
      }
      throw StateError('Unexpected vault method');
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'delete removes only owned references after confirmed server erasure',
    () async {
      final bridge = _Bridge(), api = _API();
      expect(
        (await client().deleteGuest(bridge, transport: api))['success'],
        true,
      );
      expect(api.deleted, true);
      expect(bridge.removed, ['free', 'boost']);
      expect(protected, isNull);
    },
  );
  test(
    'orphan reserve references are cleaned once per managed family',
    () async {
      final bridge = _Bridge()
        ..references = [
          {'id': 'manual', 'public_catalog_id': ''},
          {
            'id': 'free-reserve',
            'public_catalog_id': 'dropo-individual-free-reserve',
          },
          {
            'id': 'boost-reserve',
            'public_catalog_id': 'dropo-individual-boost-reserve',
          },
        ];
      expect((await client().forgetLocalProfile(bridge))['success'], true);
      expect(bridge.removed, ['free-reserve', 'boost-reserve']);
    },
  );
  test(
    'offline restore expands a retained reserve reference through its primary key',
    () async {
      seed({
        'freeKey': 'cached-free',
        'boostKey': 'cached-boost',
        'boostUntil': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
      });
      final bridge = _RestoreBridge([
        {
          'id': 'free-reserve',
          'public_catalog_id': 'dropo-individual-free-reserve',
          'disabled': true,
        },
        {'id': 'boost', 'public_catalog_id': 'dropo-individual-boost'},
        {
          'id': 'boost-reserve',
          'public_catalog_id': 'dropo-individual-boost-reserve',
        },
      ]);
      await client().restore(bridge);
      expect(bridge.added, ['dropo-individual-free', 'dropo-individual-boost']);
      expect(bridge.restoreNodeIDs, ['', '']);
    },
  );
  test(
    'offline restore never recreates a removed family or pending deletion',
    () async {
      seed({
        'freeKey': 'cached-free',
        'boostKey': 'cached-boost',
        'boostUntil': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
      });
      final removed = _RestoreBridge([
        {'id': 'personal', 'public_catalog_id': ''},
      ]);
      await client().restore(removed);
      expect(removed.added, isEmpty);
      seed({'freeKey': 'cached-free', 'deletionPending': true});
      final pending = _RestoreBridge([
        {
          'id': 'free-reserve',
          'public_catalog_id': 'dropo-individual-free-reserve',
        },
      ]);
      await client().restore(pending);
      expect(pending.added, isEmpty);
    },
  );
  test(
    'deletion between source snapshot and restore never falls back to explicit add',
    () async {
      seed({'freeKey': 'cached-free'});
      final bridge = _RestoreBridge([
        {'id': 'existing-free', 'public_catalog_id': 'dropo-individual-free'},
      ])..deleteAfterSnapshot = true;
      await client().restore(bridge);
      expect(bridge.restoreReferences, ['existing-free']);
      expect(bridge.references, isEmpty);
      expect(bridge.added, isEmpty);
    },
  );
  test(
    'restore pins the selected fingerprint and rejects a newer reference',
    () async {
      seed({'freeKey': 'cached-free'});
      final bridge = _RestoreBridge([
        {
          'id': 'existing-free',
          'public_catalog_id': 'dropo-individual-free',
          'node_ids': ['other-node', 'old-primary'],
          'selected_node': 1,
        },
      ])..replaceNodeAfterSnapshot = true;
      await client().restore(bridge);
      expect(bridge.restoreReferences, ['existing-free']);
      expect(bridge.restoreNodeIDs, ['old-primary']);
      expect(bridge.added, isEmpty);
    },
  );
  test(
    'lost deletion response survives restart and uses anonymous receipt',
    () async {
      final bridge = _Bridge(), api = _API()..loseDeleteReply = true;
      expect(
        (await client().deleteGuest(bridge, transport: api))['success'],
        false,
      );
      expect(record()['deletionPending'], true);
      expect(bridge.removed, isEmpty);
      expect(
        (await client().deleteGuest(bridge, transport: api))['success'],
        true,
      );
      expect(
        api.calls.where((c) => c == 'DELETE /v1/guest/account'),
        hasLength(1),
      );
      expect(api.calls.last, 'POST /v1/guest/deletion-status');
      expect(protected, isNull);
    },
  );
  test(
    'failed local cleanup does not repeat server mutation after restart',
    () async {
      final bridge = _Bridge()..failCleanup = true, api = _API();
      expect(
        (await client().deleteGuest(bridge, transport: api))['success'],
        false,
      );
      expect(record()['serverDeleted'], true);
      final before = api.calls.length;
      bridge.failCleanup = false;
      expect(
        (await client().deleteGuest(bridge, transport: api))['success'],
        true,
      );
      expect(api.calls.length, before);
      expect(protected, isNull);
    },
  );
  test('linked account cannot be deleted by the guest action', () async {
    seed({'linked': true});
    final bridge = _Bridge(), api = _API();
    expect(
      (await client().deleteGuest(bridge, transport: api))['success'],
      false,
    );
    expect(api.calls, isEmpty);
    expect(bridge.stops, 0);
    expect(protected, isNotNull);
  });
  test(
    'confirmed account deletion clears managed keys and keeps personal sources',
    () async {
      seed({
        'linked': true,
        'freeKey': 'cached-free',
        'boostKey': 'cached-boost',
      });
      final bridge = _Bridge();
      expect((await client().forgetLocalProfile(bridge))['success'], true);
      expect(bridge.removed, ['free', 'boost']);
      expect(bridge.stops, 0);
      expect(protected, isNull);
    },
  );
  test(
    'failed managed cleanup remains durable and can be retried after restart',
    () async {
      seed({'linked': true, 'freeKey': 'cached-free'});
      final bridge = _Bridge()..failCleanup = true;
      expect((await client().forgetLocalProfile(bridge))['success'], false);
      expect(record()['deletionPending'], true);
      bridge.failCleanup = false;
      expect((await client().forgetLocalProfile(bridge))['success'], true);
      expect(protected, isNull);
    },
  );
  test(
    'lost enrollment reply recovers the same installation before deletion',
    () async {
      seed({'enrollmentAttempted': true});
      final value = record()..remove('guestToken');
      protected = base64Url.encode(utf8.encode(jsonEncode(value)));
      final api = _API();
      expect(
        (await client().deleteGuest(_Bridge(), transport: api))['success'],
        true,
      );
      expect(api.calls.first, 'POST /v1/auth/guest');
      expect(api.deleted, true);
    },
  );
}
