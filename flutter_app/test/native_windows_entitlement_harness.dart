// Explicitly built lab entry point; never part of the production app target.
import 'dart:convert';
import 'dart:io';
import 'package:dropo/account_session_store.dart';
import 'package:dropo/main.dart';
import 'package:dropo/pinned_tls.dart';
import 'package:flutter/widgets.dart';

class _API implements AccountTransport {
  final HttpClient client = HttpClient();
  _API() {
    client.connectionTimeout = const Duration(seconds: 8);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != 'api.droponevedimka.ru' || proxyHost != null) {
        throw const FormatException('Unexpected fixture transport');
      }
      return createPinnedTlsConnection(uri, InternetAddress('193.233.88.97'));
    };
  }
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('https://api.droponevedimka.ru$path'),
    );
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    if (method != 'GET') request.write(jsonEncode(body ?? <String, dynamic>{}));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) {
        throw const FormatException('Fixture response bounds');
      }
    }
    if (response.statusCode != 200) {
      throw HttpException('Fixture HTTP ${response.statusCode}');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  @override
  void close() => client.close(force: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const root = r'C:\DropoLab';
  final result = <String, dynamic>{'passed': false, 'guestOnly': true};
  _API? api;
  try {
    if (!Platform.isWindows ||
        Platform.environment['COMPUTERNAME'] != 'DROPO-LAB') {
      throw StateError('Owned Windows guest required');
    }
    final marker =
        jsonDecode(
              await File(
                r'C:\ProgramData\DropoLab\isolation.json',
              ).readAsString(),
            )
            as Map;
    final model = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-CimInstance Win32_ComputerSystem).Model',
    ]);
    if (marker['guestOnly'] != true ||
        marker['platform'] != 'hyper-v' ||
        model.stdout.toString().trim() != 'Virtual Machine') {
      throw StateError('Isolated guest proof failed');
    }
    final request = Map<String, dynamic>.from(
      jsonDecode(
            await File('$root/entitlement-request.private.json').readAsString(),
          )
          as Map,
    );
    final action = request['action'];
    if (!const ['free', 'register', 'sync'].contains(action)) {
      throw StateError('Unknown fixture action');
    }
    final bridge = HttpCoreBridge('http://127.0.0.1:17890');
    if ((await bridge.status()).connected) {
      throw StateError('Existing VPN session retained');
    }
    final client = OwnedVPNClient(endpoint: 'https://api.droponevedimka.ru');
    final identity = ProtectedAccountIdentityStore(
      endpoint: 'https://api.droponevedimka.ru',
    );
    api = _API();
    if (action == 'free') {
      if ((await identity.read())['token'] != null) {
        throw StateError('Existing account retained');
      }
      final enrolled = await client.enroll(
        api,
        (id, name, key, consent) => bridge.callMap(
          'AddManagedVPNSource',
          args: [id, name, key, consent],
        ),
        (raw, minimum) =>
            bridge.callMap('ValidateManagedCatalog', args: [raw, minimum]),
      );
      if (enrolled['success'] != true) {
        throw StateError('Free enrollment failed');
      }
      final encoded = await NativeAccountSessionStore(
        null,
        'managed-vpn-v1',
      ).read();
      final record =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(encoded!))),
              )
              as Map;
      await File('$root/windows-installation.private.json').writeAsString(
        jsonEncode({
          'installationId': record['installationId'],
          'installationSecret': record['secret'],
          'token': record['guestToken'],
        }),
        flush: true,
      );
      await bridge.callMap('SetRoutingMode', args: ['all_traffic']);
    } else {
      final stored = await identity.read();
      final token = action == 'register'
          ? request['token'] as String
          : stored['token'] as String;
      final me = await api.request('GET', '/v1/me', token: token);
      final account = Map<String, dynamic>.from(me['account'] as Map);
      if (me['administrator'] == true ||
          account['id'] != request['fixtureAccountId'] ||
          !(account['displayName'] as String).startsWith(
            'Dropo isolated client acceptance ',
          )) {
        throw StateError('Owned synthetic account required');
      }
      if (action == 'register') {
        await identity.update((record) {
          record['token'] = token;
          record['accountKind'] = 'registered';
          record['installationId'] = request['installationId'];
          record['expiresAt'] = request['expiresAt'];
        });
      } else {
        final refreshed = await client.synchronizeEntitlement(
          bridge,
          token,
          DateTime.tryParse(account['speedBoostUntil']?.toString() ?? ''),
          transport: api,
        );
        if (refreshed['success'] != true) {
          throw StateError('Entitlement synchronization failed');
        }
        await client.restore(bridge);
        result['turboActive'] =
            DateTime.tryParse(account['speedBoostUntil']?.toString() ?? '')
                ?.isAfter(DateTime.now()) ??
            false;
      }
    }
    final sources = await bridge.callMap('GetVPNSources');
    result['managedReferences'] = [
      for (final value in sources['sources'] as List? ?? const [])
        (value as Map)['public_catalog_id'],
    ];
    result['action'] = action;
    result['passed'] = true;
  } catch (error) {
    result['errorType'] = error.runtimeType.toString();
    if (error is OwnedVPNOperationFailure) result['stage'] = error.code;
  } finally {
    api?.close();
    result['timeUTC'] = DateTime.now().toUtc().toIso8601String();
    await File(
      '$root/entitlement-result.json',
    ).writeAsString(jsonEncode(result), flush: true);
  }
  exit(result['passed'] == true ? 0 : 1);
}
