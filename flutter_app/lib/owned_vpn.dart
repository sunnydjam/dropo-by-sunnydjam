part of 'main.dart';

typedef OwnedVPNSave =
    Future<Map<String, dynamic>> Function(String, String, String, bool);

class OwnedVPNOperationFailure implements Exception {
  const OwnedVPNOperationFailure(this.code);
  final String code;
}

Future<T> _ownedStep<T>(String code, Future<T> Function() operation) async {
  try {
    return await operation();
  } catch (_) {
    throw OwnedVPNOperationFailure(code);
  }
}

final _ownedVPNClients = <String, OwnedVPNClient>{};
OwnedVPNClient _ownedVPNForEndpoint(String endpoint) =>
    _ownedVPNClients.putIfAbsent(
      accountCredentialOrigin(endpoint),
      () => OwnedVPNClient(endpoint: endpoint),
    );
final _ownedVPNClient = _ownedVPNForEndpoint(_accountEndpoint);

/// Only the native vault persists installation/session secrets and cached keys.
/// Restore is local and does not query the account service during connection.
class OwnedVPNClient {
  OwnedVPNClient({
    required this.endpoint,
    NativeAccountSessionStore? store,
    ProtectedAccountIdentityStore? identityStore,
    this.subscriptionTimeout = const Duration(seconds: 10),
  }) : _store = store ?? NativeAccountSessionStore(null, 'managed-vpn-v1'),
       _identityStore =
           identityStore ?? ProtectedAccountIdentityStore(endpoint: endpoint);
  final String endpoint;
  final Duration subscriptionTimeout;
  final NativeAccountSessionStore _store;
  final ProtectedAccountIdentityStore _identityStore;
  Future<void> _operations = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// Upgrade the preview's separate VPN vault before the shared guest
  /// coordinator starts. Reuse only proven local recovery material; an existing
  /// different identity or a deletion/suppression intent is never overwritten.
  Future<void> prepareAccountIdentity({bool Function()? canWrite}) =>
      _serialize(() async {
        await _load().timeout(const Duration(seconds: 3));
        if (canWrite?.call() == false) {
          return;
        }
        final source = _record;
        if (source == null ||
            source['deletionPending'] == true ||
            source['secret'] is! String) {
          return;
        }
        final secret = source['secret'] as String;
        if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(secret)) {
          return;
        }
        if (source['installationId'] != null &&
            (source['installationId'] is! String ||
                !RegExp(
                  r'^[A-Za-z0-9_-]{8,128}$',
                ).hasMatch(source['installationId'] as String))) {
          throw const FormatException(
            'Invalid protected installation identity.',
          );
        }
        final existing = await _identityStore.read().timeout(
          const Duration(seconds: 3),
        );
        if (existing['installationSecret'] != null ||
            existing['suppressed'] == true ||
            existing['pendingDeletion'] != null) {
          return;
        }
        await _identityStore
            .update((identity) {
              if (canWrite?.call() == false) {
                throw const AccountIdentityChanged();
              }
              if (identity['installationSecret'] != null ||
                  identity['suppressed'] == true ||
                  identity['pendingDeletion'] != null) {
                return;
              }
              identity['installationSecret'] = secret;
              if (source['installationId'] is String &&
                  (source['linked'] == true ||
                      identity['accountKind'] != 'registered')) {
                identity['installationId'] = source['installationId'];
              }
              if (source['linked'] == true && identity['token'] == null) {
                identity['suppressed'] = true;
              }
            })
            .timeout(const Duration(seconds: 3));
      });

  Future<Map<String, dynamic>> _adoptAccountIdentity() async {
    final candidate = _newSecret();
    final primary = await _identityStore.update((identity) {
      if (identity['suppressed'] == true ||
          identity['pendingDeletion'] != null) {
        throw const AccountIdentityChanged();
      }
      identity.putIfAbsent('installationSecret', () => candidate);
    });
    return {
      'format': 1,
      'origin': accountCredentialOrigin(endpoint),
      'secret': primary['installationSecret'],
      if (primary['installationId'] is String)
        'installationId': primary['installationId'],
      if (primary['accountKind'] == 'guest' && primary['token'] is String)
        'guestToken': primary['token'],
      if (primary['accountKind'] == 'registered' &&
          primary['installationId'] is String)
        'linked': true,
    };
  }

  Map<String, dynamic>? _record;
  Future<void>? _loading;
  Future<void> _load() => _loading ??=
      () async {
        final raw = await _store.read();
        if (raw == null) return;
        final value = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(raw))),
        );
        if (value is! Map ||
            value['format'] != 1 ||
            value['origin'] != accountCredentialOrigin(endpoint)) {
          throw const FormatException('Invalid protected VPN profile.');
        }
        _record = Map<String, dynamic>.from(value);
      }().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _persist() async {
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(_record)))
        .replaceAll('=', '');
    await _store.write(encoded);
  }

  String _newSecret() => base64Url
      .encode(List<int>.generate(32, (_) => math.Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<Map<String, dynamic>> enroll(
    AccountTransport api,
    OwnedVPNSave save,
    Future<Map<String, dynamic>> Function(String, int) verify, {
    String? registeredToken,
  }) => _serialize(
    () => _enroll(api, save, verify, registeredToken: registeredToken),
  );

  Future<Map<String, dynamic>> _enroll(
    AccountTransport api,
    OwnedVPNSave save,
    Future<Map<String, dynamic>> Function(String, int) verify, {
    String? registeredToken,
  }) async {
    await _ownedStep('protected_storage_read', _load);
    if (_record?['deletionPending'] == true) {
      throw const AccountApiException(
        'Сначала завершите удаление гостевого профиля в разделе аккаунта.',
      );
    }
    final envelope = await _ownedStep(
      'catalog_download',
      () => api.request('GET', '/public/v1/catalog'),
    );
    final valid = await _ownedStep(
      'catalog_native_bridge',
      () => verify(
        jsonEncode(envelope),
        (_record?['catalogRevision'] as num?)?.toInt() ?? 0,
      ),
    );
    if (valid['success'] != true) {
      throw const OwnedVPNOperationFailure('catalog_signature');
    }
    _record ??= await _adoptAccountIdentity();
    _record!['catalogRevision'] = valid['revision'];
    // Save the installation credential before the first request, so a lost
    // response/restart reuses the same installation rather than creating one.
    await _ownedStep('protected_storage_write', _persist);
    final accountToken =
        registeredToken ??
        await _AccountTokenVault(endpoint: endpoint).read(registeredOnly: true);
    String token = '';
    if (_record!['linked'] == true) {
      token = accountToken ?? '';
      if (token.isEmpty) {
        throw const AccountApiException(
          'Для обновления профиля войдите в привязанный аккаунт. Сохранённый Free продолжает работать.',
        );
      }
      // A new Telegram session is not automatically bound to this device.
      // The installation secret proves continuity; the server checks its owner.
      final bound = await api.request(
        'POST',
        '/v1/installations/bind',
        token: token,
        body: {
          'installationSecret': _record!['secret'],
          'platform': Platform.isAndroid ? 'android' : 'windows',
          'appVersion': _bundledAppVersion,
        },
      );
      if (bound['installationId'] != _record!['installationId']) {
        throw const FormatException('Installation binding changed.');
      }
    } else if (_record!['guestToken'] is String) {
      token = _record!['guestToken'] as String;
    } else if (accountToken != null && accountToken.isNotEmpty) {
      final bound = await api.request(
        'POST',
        '/v1/installations/bind',
        token: accountToken,
        body: {
          'installationSecret': _record!['secret'],
          'platform': Platform.isAndroid ? 'android' : 'windows',
          'appVersion': _bundledAppVersion,
        },
      );
      _record!['installationId'] = bound['installationId'];
      _record!['linked'] = true;
      token = accountToken;
      await _persist();
    }
    Future<String> guestLogin() async {
      _record!['enrollmentAttempted'] = true;
      await _persist();
      final result = await api.request(
        'POST',
        '/v1/auth/guest',
        body: {
          'installationSecret': _record!['secret'],
          if (_record!['installationId'] != null)
            'installationId': _record!['installationId'],
          'platform': Platform.isAndroid ? 'android' : 'windows',
          'appVersion': _bundledAppVersion,
        },
      );
      final next = result['sessionToken'];
      final iid = result['installationId'];
      if (next is! String ||
          next.length < 16 ||
          iid is! String ||
          iid.length < 8) {
        throw const FormatException('Incomplete guest enrollment.');
      }
      _record!['guestToken'] = next;
      _record!['installationId'] = iid;
      await _persist();
      return next;
    }

    if (token.isEmpty) token = await guestLogin();
    Map<String, dynamic> profile;
    try {
      profile = await api.request('POST', '/v1/vpn/profile', token: token);
    } on AccountApiException catch (e) {
      if (e.status != 401 || _record!['linked'] == true) rethrow;
      token = await guestLogin();
      profile = await api.request('POST', '/v1/vpn/profile', token: token);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (profile['status'] == 'pending' &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      profile = await api.request('GET', '/v1/vpn/profile', token: token);
    }
    if (profile['status'] != 'ready' ||
        profile['id'] != _record!['installationId']) {
      throw const AccountApiException(
        'Профиль ещё готовится. Повторите добавление немного позже.',
      );
    }
    final free = await _downloadKey(profile['freeSubscriptionUrl'], 0);
    String? boost;
    final until = (profile['boostUntilUnix'] as num?)?.toInt() ?? 0;
    if (profile['boostSubscriptionUrl'] is String &&
        until > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      boost = await _downloadKey(profile['boostSubscriptionUrl'], until);
    }
    if (registeredToken != null) {
      final identity = await _identityStore.read();
      if (identity['suppressed'] == true ||
          identity['pendingDeletion'] != null ||
          identity['token'] != registeredToken ||
          identity['accountKind'] != 'registered' ||
          identity['installationSecret'] != _record!['secret']) {
        throw const AccountIdentityChanged();
      }
    }
    _record!['freeKey'] = free;
    _record!['boostKey'] = boost;
    _record!['boostUntil'] = until;
    await _persist();
    return _apply(save);
  }

  Future<String> _downloadKey(Object? value, int until) async {
    if (value is! String) {
      throw const FormatException('Missing owned subscription.');
    }
    final u = Uri.parse(value);
    if (u.scheme != 'https' ||
        u.host != 'app.droponevedimka.ru' ||
        u.port != 443 ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        !u.path.startsWith('/managed/v1/subscription/')) {
      throw const FormatException('Untrusted subscription origin.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.host != 'app.droponevedimka.ru' ||
          uri.port != 443 ||
          proxyHost != null) {
        throw const FormatException('Untrusted profile transport.');
      }
      return createPinnedTlsConnection(uri, InternetAddress('193.233.88.97'));
    };
    try {
      return await (() async {
        final request = await client.getUrl(u);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode != 200) {
          throw const FormatException('Subscription unavailable.');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8192) {
            throw const FormatException('Subscription exceeds bounds.');
          }
        }
        final text = utf8
            .decode(base64.decode(base64.normalize(utf8.decode(bytes).trim())))
            .trim();
        if (text.contains('\n') || text.length > 4096) {
          throw const FormatException('Unexpected managed nodes.');
        }
        final key = Uri.parse(text);
        if (key.scheme != 'vless' ||
            (key.host != 'cdn.droponevedimka.ru' &&
                key.host != '193.233.88.97') ||
            key.port != 443) {
          throw const FormatException('Untrusted ingress.');
        }
        return key
            .replace(
              host: '193.233.88.97',
              queryParameters: {
                ...key.queryParameters,
                'dropo_expiry': '$until',
              },
            )
            .toString();
      })().timeout(subscriptionTimeout);
    } finally {
      client.close(force: true);
    }
  }

  /// Forget only Dropo-managed local credentials after an explicit deletion.
  /// Mark the vault first so a failed native cleanup cannot restore revoked keys
  /// on the next launch. User subscriptions are never part of this cleanup.
  Future<Map<String, dynamic>> forgetLocalProfile(
    CoreBridge bridge,
  ) => _serialize(() async {
    try {
      await _load();
      final view = await bridge.callMap('GetVPNSources');
      final sources = (view['sources'] as List? ?? const [])
          .map(_asMap)
          .where(
            (source) => const {
              'dropo-individual-free',
              'dropo-individual-boost',
            }.contains(source['public_catalog_id']),
          )
          .toList();
      if (_record == null && sources.isEmpty) return {'success': true};
      if (_record != null) {
        _record!['deletionPending'] = true;
        await _persist();
      }
      if (sources.isNotEmpty) {
        final stopped = await bridge.setConnected(false);
        if (stopped['success'] != true) {
          throw const FormatException('VPN stop unconfirmed.');
        }
        for (final source in sources) {
          final removed = await bridge.removeVpnSource(source['id'].toString());
          if (removed['success'] != true) {
            throw const FormatException('Local cleanup pending.');
          }
        }
      }
      await _store.clear();
      _record = null;
      return {'success': true};
    } catch (_) {
      return {
        'success': false,
        'error':
            'Не удалось удалить ключи Dropo с устройства. Повторите очистку; свои подписки сохранятся.',
      };
    }
  });

  Future<Map<String, dynamic>> _apply(OwnedVPNSave save) async {
    final free = _record?['freeKey'];
    if (free is! String) {
      return {
        'success': false,
        'error': 'Защищённый профиль Free ещё не получен.',
      };
    }
    final first = await save('dropo-individual-free', 'Dropo Free', free, true);
    if (first['success'] != true) {
      return {
        'success': false,
        'error':
            'Профиль сохранён защищённо. Отключите VPN и повторите подключение для применения.',
      };
    }
    final boost = _record?['boostKey'];
    final until = (_record?['boostUntil'] as num?)?.toInt() ?? 0;
    if (boost is String &&
        until > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      final result = await save(
        'dropo-individual-boost',
        'Dropo Boost',
        boost,
        true,
      );
      if (result['success'] != true) {
        return {
          'success': false,
          'error': 'Free готов; отключите VPN для применения Boost.',
        };
      }
    }
    return {'success': true, 'individual': true};
  }

  Future<void> restore(CoreBridge bridge) {
    if (!accountEndpointAvailable(endpoint, allowLocalDevelopment: false) ||
        bridge is MockCoreBridge) {
      return Future<void>.value();
    }
    return _serialize(() => _restore(bridge));
  }

  Future<void> _restore(CoreBridge bridge) async {
    try {
      await _load().timeout(const Duration(seconds: 3));
      if (_record?['deletionPending'] == true) return;
      if (_record?['freeKey'] is! String) return;
      final view = await bridge.callMap('GetVPNSources');
      final references = <Object?>{};
      for (final value in (view['sources'] as List? ?? const [])) {
        final s = _asMap(value);
        references.add(s['public_catalog_id']);
      }
      for (final pool in ['free', 'boost']) {
        final id = 'dropo-individual-$pool';
        final key = _record?['${pool}Key'];
        if (!references.contains(id) || key is! String) continue;
        if (pool == 'boost' &&
            ((_record?['boostUntil'] as num?)?.toInt() ?? 0) <=
                DateTime.now().millisecondsSinceEpoch ~/ 1000) {
          continue;
        }
        await bridge.callMap(
          'AddManagedVPNSource',
          args: [id, pool == 'free' ? 'Dropo Free' : 'Dropo Boost', key, true],
          timeout: const Duration(seconds: 8),
        );
      }
    } catch (_) {
      /* Never erase credentials or fall back to plaintext on a read error. */
    }
  }

  Future<Map<String, dynamic>> linkAccount(
    CoreBridge bridge,
    String token,
    bool consent, {
    AccountTransport? transport,
  }) => _serialize(
    () => _linkAccount(bridge, token, consent, transport: transport),
  );

  /// Account entitlements can change on the web while this local profile stays
  /// cached. Refresh only changed entitlements, before starting a VPN session.
  Future<Map<String, dynamic>> synchronizeEntitlement(
    CoreBridge bridge,
    String token,
    DateTime? turboUntil, {
    AccountTransport? transport,
  }) => _serialize(() async {
    await _load();
    if (_record?['deletionPending'] == true || _record?['freeKey'] is! String) {
      return {'success': true, 'unchanged': true};
    }
    final active = turboUntil?.isAfter(DateTime.now()) ?? false;
    final until = active ? turboUntil!.millisecondsSinceEpoch ~/ 1000 : 0;
    final cachedUntil = (_record?['boostUntil'] as num?)?.toInt() ?? 0;
    if (active && _record?['boostKey'] is String && cachedUntil == until) {
      return {'success': true, 'unchanged': true};
    }
    if (!active && _record?['boostKey'] == null && cachedUntil == 0) {
      return {'success': true, 'unchanged': true};
    }
    if ((await bridge.status()).connected) {
      return {'success': true, 'deferred': true};
    }
    if (active) {
      // An authenticated account is already bound by the identity coordinator.
      // Never silently consent to merging another guest installation here.
      return _linkAccount(bridge, token, false, transport: transport);
    }
    final view = await bridge.callMap('GetVPNSources');
    for (final raw in view['sources'] as List? ?? const []) {
      final source = _asMap(raw);
      if (source['public_catalog_id'] != 'dropo-individual-boost') continue;
      final result = await bridge.removeVpnSource(source['id'].toString());
      if (result['success'] != true) return result;
    }
    _record!.remove('boostKey');
    _record!['boostUntil'] = 0;
    await _persist();
    return {'success': true, 'turboRemoved': true};
  });

  Future<Map<String, dynamic>> _linkAccount(
    CoreBridge bridge,
    String token,
    bool consent, {
    AccountTransport? transport,
  }) async {
    final api = transport ?? _AccountApi(endpoint);
    try {
      await _load();
      final identity = await _identityStore.read();
      if (identity['suppressed'] == true ||
          identity['pendingDeletion'] != null ||
          identity['token'] != token ||
          identity['accountKind'] != 'registered') {
        throw const AccountIdentityChanged();
      }
      if (identity['accountKind'] == 'registered' &&
          identity['installationSecret'] is String &&
          _record != null &&
          identity['installationSecret'] != _record!['secret']) {
        // A new authenticated account has its own installation. Never try to
        // bind the previous owner's cached installation to the new account.
        _record = await _adoptAccountIdentity();
        await _persist();
      }
      if (_record?['deletionPending'] == true) {
        return {
          'success': false,
          'error': 'Сначала завершите удаление гостевого профиля.',
        };
      }
      if (_record?['secret'] is String && _record?['linked'] != true) {
        try {
          // Also recovers a lost successful guest/link reply. A bootstrap
          // secret can bind only the already authenticated canonical owner.
          final bound = await api.request(
            'POST',
            '/v1/installations/bind',
            token: token,
            body: {
              'installationSecret': _record!['secret'],
              'platform': Platform.isAndroid ? 'android' : 'windows',
              'appVersion': _bundledAppVersion,
            },
          );
          _record!['installationId'] = bound['installationId'];
        } on AccountApiException catch (error) {
          if (error.code != 'guest_link_required') rethrow;
          if (!consent) return {'success': false, 'requiresLink': true};
          final guest = await api.request(
            'POST',
            '/v1/auth/guest',
            body: {
              'installationSecret': _record!['secret'],
              'installationId': _record!['installationId'],
              'platform': Platform.isAndroid ? 'android' : 'windows',
              'appVersion': _bundledAppVersion,
            },
          );
          final guestToken = guest['sessionToken'];
          if (guestToken is! String || guestToken.length < 16) {
            throw const FormatException('Guest session unavailable.');
          }
          await api.request(
            'POST',
            '/v1/guest/link',
            token: guestToken,
            body: {'accountToken': token},
          );
        }
        _record!['linked'] = true;
        _record!.remove('guestToken');
        await _persist();
      }
      return await _enroll(
        api,
        (id, name, key, ok) =>
            bridge.callMap('AddManagedVPNSource', args: [id, name, key, ok]),
        (raw, min) =>
            bridge.callMap('ValidateManagedCatalog', args: [raw, min]),
        registeredToken: token,
      );
    } catch (_) {
      return {
        'success': false,
        'error':
            'Не удалось обновить профиль VPN. Сохранённые источники доступны; повторите позже.',
      };
    } finally {
      api.close();
    }
  }

  Future<Map<String, dynamic>> deleteGuest(
    CoreBridge bridge, {
    AccountTransport? transport,
  }) => _serialize(() => _deleteGuest(bridge, transport: transport));
  Future<Map<String, dynamic>> _deleteGuest(
    CoreBridge bridge, {
    AccountTransport? transport,
  }) async {
    final api = transport ?? _AccountApi(endpoint);
    try {
      await _load();
      if (_record == null) return {'success': true};
      if (_record!['linked'] == true) {
        return {
          'success': false,
          'error':
              'Профиль привязан к аккаунту. Управляйте им после входа через Telegram.',
        };
      }
      final stopped = await bridge.setConnected(false);
      if (stopped['success'] != true) {
        return {
          'success': false,
          'error': 'Сначала отключите VPN и повторите удаление.',
        };
      }
      var token = _record!['guestToken'];
      if (token is! String &&
          _record!['enrollmentAttempted'] == true &&
          _record!['serverDeleted'] != true) {
        final recovered = await api.request(
          'POST',
          '/v1/auth/guest',
          body: {
            'installationSecret': _record!['secret'],
            if (_record!['installationId'] != null)
              'installationId': _record!['installationId'],
            'platform': Platform.isAndroid ? 'android' : 'windows',
            'appVersion': _bundledAppVersion,
          },
        );
        token = recovered['sessionToken'];
        if (token is! String) {
          throw const FormatException('Guest recovery unconfirmed.');
        }
        _record!['guestToken'] = token;
        await _persist();
      }
      if (token is String && _record!['serverDeleted'] != true) {
        _record!['deletionSecret'] ??= _newSecret();
        _record!['deletionPending'] = true;
        await _persist();
        final secret = _record!['deletionSecret'];
        var confirmed = false;
        if (_record!['deletionKeyReady'] == true) {
          final receipt = await api.request(
            'POST',
            '/v1/guest/deletion-status',
            body: {'code': 'dg1.$secret'},
          );
          confirmed = receipt['deleted'] == true;
        }
        if (!confirmed) {
          await api.request(
            'PUT',
            '/v1/guest/deletion-key',
            token: token,
            body: {'deletionSecret': secret},
          );
          _record!['deletionKeyReady'] = true;
          await _persist();
          final result = await api.request(
            'DELETE',
            '/v1/guest/account',
            token: token,
            body: {'confirm': true},
          );
          if (result['deleted'] != true) {
            throw const FormatException('Deletion unconfirmed.');
          }
        }
      }
      _record!['serverDeleted'] = true;
      _record!['deletionPending'] = true;
      await _persist();
      final sources = await bridge.callMap('GetVPNSources');
      for (final value in (sources['sources'] as List? ?? const [])) {
        final source = _asMap(value);
        if (![
          'dropo-individual-free',
          'dropo-individual-boost',
        ].contains(source['public_catalog_id'])) {
          continue;
        }
        final removed = await bridge.removeVpnSource(source['id'].toString());
        if (removed['success'] != true) {
          throw const FormatException('Local cleanup pending.');
        }
      }
      await _store.clear();
      _record = null;
      return {'success': true};
    } catch (_) {
      return {
        'success': false,
        'error':
            'Удаление пока не завершено. Сохранён защищённый запрос; повторите удаление при доступном интернете.',
      };
    } finally {
      if (transport == null) api.close();
    }
  }
}
