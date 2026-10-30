part of 'main.dart';

/// App-scoped identity. Network/storage work never participates in VPN readiness.
/// Credentials and private state stay in the endpoint-bound native vault.
class GuestIdentityCoordinator extends ChangeNotifier {
  GuestIdentityCoordinator({
    required this.endpoint,
    required this.available,
    this.persistSession = true,
    AccountTransport? transport,
    ProtectedAccountIdentityStore? store,
    String? initialToken,
    String? platform,
    String? appVersion,
    DateTime Function()? now,
  }) : _api = transport ?? _AccountApi(endpoint),
       _ownsApi = transport == null,
       store = store ?? ProtectedAccountIdentityStore(endpoint: endpoint),
       _platform =
           platform ??
           (Platform.isAndroid
               ? 'android'
               : Platform.isWindows
               ? 'windows'
               : 'other'),
       _appVersion = appVersion ?? _bundledAppVersion,
       _now = now ?? DateTime.now,
       _record = initialToken == null
           ? {}
           : {'token': initialToken, 'accountKind': 'registered'};

  final String endpoint;
  final bool available, persistSession;
  final ProtectedAccountIdentityStore store;
  final AccountTransport _api;
  final bool _ownsApi;
  final String _platform, _appVersion;
  final DateTime Function() _now;
  Map<String, dynamic> _record;
  Map<String, dynamic>? _account;
  Future<void>? _restoring;
  Timer? _renewal;
  DateTime? _lastAttempt;
  int _epoch = 0;
  bool _disposed = false, _foreground = true;
  bool _locallySuppressed = false, _changingIdentity = false;
  bool guestAvailable = false, incidentsAvailable = false;
  String state = 'idle';

  String? get token =>
      suppressed || _changingIdentity ? null : _record['token'] as String?;
  String? get installationId =>
      suppressed ? null : _record['installationId'] as String?;
  String get accountKind => token == null
      ? 'none'
      : _record['accountKind'] == 'guest'
      ? 'guest'
      : 'registered';
  bool get suppressed => _locallySuppressed || _record['suppressed'] == true;
  int get identityEpoch => _epoch;
  Map<String, dynamic>? get account =>
      _account == null ? null : Map.unmodifiable(_account!);
  bool get deletionPending => _record['pendingDeletion'] is Map;

  Future<Map<String, dynamic>?> readPrivateState(String namespace) async {
    if (persistSession) return store.readPrivateState(namespace);
    final values = _record['privateState'];
    final value = values is Map ? values[namespace] : null;
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> writePrivateState(
    String namespace,
    Map<String, dynamic>? value,
  ) async {
    final epoch = _epoch;
    bool canWrite() =>
        !_disposed &&
        epoch == _epoch &&
        (value == null || (!suppressed && !_changingIdentity));
    if (persistSession) {
      return store.writePrivateState(namespace, value, canWrite: canWrite);
    }
    if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(namespace) ||
        (value != null && utf8.encode(jsonEncode(value)).length > 8 * 1024)) {
      throw const FormatException('Invalid private state.');
    }
    final frozen = value == null ? null : jsonDecode(jsonEncode(value));
    await _save((record) {
      if (!canWrite()) throw const AccountIdentityChanged();
      final values = Map<String, dynamic>.from(
        record['privateState'] as Map? ?? const {},
      );
      if (frozen == null) {
        values.remove(namespace);
      } else {
        values[namespace] = frozen;
      }
      record['privateState'] = values;
    }, expectedEpoch: epoch);
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _save(
    void Function(Map<String, dynamic>) change, {
    int? expectedEpoch,
  }) async {
    final epoch = expectedEpoch ?? _epoch;
    void guardedChange(Map<String, dynamic> record) {
      if (_disposed || epoch != _epoch) throw StateError('Identity changed.');
      change(record);
    }

    late final Map<String, dynamic> next;
    if (persistSession) {
      next = await store.update(guardedChange);
    } else {
      next = Map<String, dynamic>.from(_record);
      guardedChange(next);
    }
    if (_disposed || epoch != _epoch) throw StateError('Identity changed.');
    _record = next;
  }

  Future<void> restore() {
    if (_disposed || !available || _changingIdentity) {
      return Future<void>.value();
    }
    if (_restoring != null) return _restoring!;
    final pending = _restore().catchError((Object _) {
      if (_disposed) return;
      state = 'storage_error';
      _publish();
    });
    _restoring = pending;
    return pending.whenComplete(() {
      if (identical(_restoring, pending)) _restoring = null;
    });
  }

  Future<void> resume() async {
    if (_disposed || !_foreground || !available) return;
    final last = _lastAttempt;
    if (last != null && _now().difference(last) < const Duration(seconds: 30)) {
      return;
    }
    await restore();
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) {
      _renewal?.cancel();
      return;
    }
    unawaited(resume());
    _scheduleRenewal();
  }

  Future<void> _restore() async {
    final epoch = _epoch;
    _lastAttempt = _now();
    try {
      if (persistSession) {
        final record = await store.read();
        if (_disposed || epoch != _epoch) return;
        _record = record;
      }
    } catch (_) {
      state = 'storage_error';
      _publish();
      return; // Missing and unreadable credentials are deliberately different.
    }
    if (_disposed || epoch != _epoch) return;
    try {
      final capabilities = await _api.request('GET', '/v1/capabilities');
      if (_disposed || epoch != _epoch) return;
      guestAvailable =
          capabilities['guestAvailable'] == true &&
          persistSession &&
          (_platform == 'android' || _platform == 'windows');
      incidentsAvailable = capabilities['incidentsAvailable'] == true;
    } catch (_) {
      guestAvailable = false;
      incidentsAvailable = false;
    }
    if (_disposed || epoch != _epoch) return;
    if (suppressed) {
      if (deletionPending) await _retryDeletion();
      state = deletionPending ? 'deletion_pending' : 'signed_out';
      _publish();
      return;
    }
    final existing = token;
    if (existing != null && existing.isNotEmpty) {
      final expiry = DateTime.tryParse(_record['expiresAt']?.toString() ?? '');
      final renewalDue =
          accountKind == 'guest' &&
          expiry != null &&
          expiry.difference(_now()) <= const Duration(minutes: 5);
      if (!renewalDue || !guestAvailable) {
        try {
          final response = await _api.request('GET', '/v1/me', token: existing);
          if (_disposed || epoch != _epoch) return;
          _account = _asMap(response['account']);
          if (accountKind == 'registered') {
            await _bindRegisteredInstallation(epoch);
          }
          if (_disposed || epoch != _epoch) return;
          state = 'ready';
          _scheduleRenewal();
          _publish();
          return;
        } on AccountApiException catch (error) {
          if (_disposed || epoch != _epoch) return;
          if (error.status != 401 && error.code != 'invalid_session') {
            state = 'offline';
            _publish();
            return;
          }
          if (accountKind != 'guest') {
            await _suppress(preserveBinding: true);
            return; // Never replace a registered account with a new guest.
          }
        } catch (_) {
          state = 'offline';
          _publish();
          return;
        }
      }
    }
    if (!guestAvailable) {
      state = existing == null ? 'signed_out' : 'offline';
      _publish();
      return;
    }
    try {
      var secret = _record['installationSecret'] as String?;
      if (secret == null) {
        // Commit recovery material BEFORE the first request, including retries.
        final random = math.Random.secure();
        secret = base64UrlEncode(
          List<int>.generate(32, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
        final created = secret;
        await _save((record) {
          if (_disposed || epoch != _epoch) {
            throw StateError('Identity changed.');
          }
          record['installationSecret'] = created;
        });
      }
      if (_disposed || epoch != _epoch || suppressed) return;
      final response = await _api.request(
        'POST',
        '/v1/auth/guest',
        body: {
          'installationSecret': secret,
          if (_record['installationId'] is String)
            'installationId': _record['installationId'],
          'platform': _platform,
          'appVersion': _appVersion,
        },
      );
      if (_disposed || epoch != _epoch || suppressed) return;
      final issued = response['sessionToken'];
      final installation = response['installationId'];
      final resultAccount = _asMap(response['account']);
      final expires = DateTime.tryParse(
        response['expiresAt']?.toString() ?? '',
      );
      if (issued is! String ||
          !_validSessionToken(issued) ||
          installation is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(installation) ||
          resultAccount['authMethod'] != 'guest' ||
          resultAccount['demoAccount'] == true ||
          resultAccount['id'] is! String ||
          expires == null ||
          !expires.isAfter(_now()) ||
          expires.difference(_now()) > const Duration(hours: 2)) {
        throw const FormatException('Invalid guest profile response.');
      }
      await _save((record) {
        if (_disposed || epoch != _epoch) throw StateError('Identity changed.');
        record.addAll({
          'token': issued,
          'accountKind': 'guest',
          'installationId': installation,
          'expiresAt': expires.toUtc().toIso8601String(),
        });
      });
      if (_disposed || epoch != _epoch) return;
      _account = resultAccount;
      state = 'ready';
      _scheduleRenewal();
    } on AccountApiException catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (const {
        'requires_login',
        'installation_revoked',
        'installation_blocked',
      }.contains(error.code)) {
        await _suppress(preserveBinding: error.code == 'requires_login');
        return;
      }
      state = 'offline';
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      state = 'offline';
    }
    _publish();
  }

  static bool _validSessionToken(String value) =>
      value.isNotEmpty &&
      value.length <= 256 &&
      value.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

  Future<void> _bindRegisteredInstallation(
    int epoch, {
    bool force = false,
  }) async {
    if (!guestAvailable ||
        !persistSession ||
        _account?['demoAccount'] == true ||
        (_record['installationId'] != null && !force) ||
        _record['accountKind'] != 'registered') {
      return;
    }
    try {
      var secret = _record['installationSecret'] as String?;
      if (secret == null) {
        final random = math.Random.secure();
        secret = base64UrlEncode(
          List<int>.generate(32, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
        final created = secret;
        await _save((record) {
          record['installationSecret'] = created;
          record['boundAccountId'] = _account?['id'];
        }, expectedEpoch: epoch);
      }
      if (_disposed || epoch != _epoch || suppressed) return;
      final response = await _api.request(
        'POST',
        '/v1/installations/bind',
        token: _record['token'] as String?,
        body: {
          'installationSecret': secret,
          'platform': _platform,
          'appVersion': _appVersion,
        },
      );
      final installation = response['installationId'];
      if (installation is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(installation)) {
        return;
      }
      await _save((record) {
        record['installationId'] = installation;
        record['boundAccountId'] = _account?['id'];
      }, expectedEpoch: epoch);
    } catch (_) {
      // Diagnostics binding must never invalidate a working registered session.
    }
  }

  void _scheduleRenewal() {
    _renewal?.cancel();
    if (_disposed || !_foreground || accountKind != 'guest') return;
    final expires = DateTime.tryParse(_record['expiresAt']?.toString() ?? '');
    if (expires == null) return;
    final remaining = expires.difference(_now()) - const Duration(minutes: 5);
    _renewal = Timer(
      remaining < const Duration(minutes: 1)
          ? const Duration(minutes: 1)
          : remaining,
      () => unawaited(resume()),
    );
  }

  Future<void> _suppress({bool preserveBinding = false}) async {
    final keepBinding = preserveBinding && _record['boundAccountId'] is String;
    ++_epoch;
    _renewal?.cancel();
    _account = null;
    _locallySuppressed = true;
    _publish();
    await _save((record) {
      record['suppressed'] = true;
      for (final key in ['token', 'accountKind', 'expiresAt', 'privateState']) {
        record.remove(key);
      }
      if (!keepBinding) {
        for (final key in [
          'installationSecret',
          'installationId',
          'boundAccountId',
        ]) {
          record.remove(key);
        }
      }
    });
    state = 'signed_out';
    _publish();
  }

  Future<void> acceptRegisteredSession(
    String registeredToken,
    Map<String, dynamic> registeredAccount,
  ) async {
    if (deletionPending) {
      throw const AccountApiException(
        'Сначала завершите удаление бесплатного профиля.',
      );
    }
    if (!_validSessionToken(registeredToken) ||
        registeredAccount['authMethod'] == 'guest' ||
        registeredAccount['id'] is! String) {
      throw const FormatException('Invalid account session.');
    }
    final guestToken = accountKind == 'guest' ? token : null;
    final guestInstallation = installationId;
    final linksGuest =
        guestToken != null && registeredAccount['demoAccount'] != true;
    final reusesBinding =
        !linksGuest &&
        registeredAccount['demoAccount'] != true &&
        _record['boundAccountId'] == registeredAccount['id'] &&
        _record['installationSecret'] is String;
    ++_epoch; // Fence any pending enrollment/renewal before linking.
    final epoch = _epoch;
    _renewal?.cancel();
    _changingIdentity = true;
    _publish();
    try {
      if (linksGuest) {
        // Preserve the candidate owner before linking. If every response is
        // lost, a later proven login can bind the SAME installation; its secret
        // alone can never authenticate as that registered account.
        await _save(
          (record) => record['boundAccountId'] = registeredAccount['id'],
          expectedEpoch: epoch,
        );
        Map<String, dynamic> linked;
        try {
          linked = await _api.request(
            'POST',
            '/v1/guest/link',
            token: guestToken,
            body: {'accountToken': registeredToken},
          );
        } catch (_) {
          if (_disposed || epoch != _epoch) rethrow;
          // Linking revokes the guest bearer. The backend confirms a committed
          // link with the proven target bearer and original installation secret.
          final rebound = await _api.request(
            'POST',
            '/v1/installations/bind',
            token: registeredToken,
            body: {
              'installationSecret': _record['installationSecret'],
              'platform': _platform,
              'appVersion': _appVersion,
            },
          );
          linked = {
            'linked': true,
            'installationId': rebound['installationId'],
            'account': registeredAccount,
          };
        }
        if (linked['linked'] != true ||
            linked['installationId'] != guestInstallation ||
            _asMap(linked['account'])['id'] != registeredAccount['id']) {
          throw const FormatException('Account link was not confirmed.');
        }
      }
      if (_disposed || epoch != _epoch) throw StateError('Identity changed.');
      await _save((record) {
        if (!linksGuest && !reusesBinding) {
          record.remove('installationId');
          record.remove('installationSecret');
        }
        record.addAll({
          'token': registeredToken,
          'accountKind': 'registered',
          'suppressed': false,
          'boundAccountId': registeredAccount['id'],
        });
        for (final key in ['expiresAt', 'pendingDeletion', 'privateState']) {
          record.remove(key);
        }
      }, expectedEpoch: epoch);
      _locallySuppressed = false;
      _account = Map<String, dynamic>.from(registeredAccount);
      if (guestToken != null && !linksGuest) {
        try {
          await _api.request(
            'DELETE',
            '/v1/sessions/current',
            token: guestToken,
          );
        } catch (_) {}
      }
      await _bindRegisteredInstallation(epoch, force: reusesBinding);
      if (_disposed || epoch != _epoch) return;
      state = 'ready';
    } finally {
      _changingIdentity = false;
      _publish();
    }
  }

  Future<void> logout({bool forgetInstallation = false}) async {
    final oldToken = _record['token'] as String?;
    await _suppress(
      preserveBinding:
          !forgetInstallation && _record['accountKind'] == 'registered',
    ); // Suppression precedes revocation.
    if (oldToken != null) {
      try {
        await _api.request('DELETE', '/v1/sessions/current', token: oldToken);
      } catch (_) {}
    }
  }

  Future<void> deleteGuest() async {
    // Keep a failed local suppression write retryable without exposing its
    // credential again to account display or incident reporting.
    if (_record['accountKind'] != 'guest' || _record['token'] is! String) {
      return;
    }
    final pending = {
      'token': _record['token'],
      'installationSecret': _record['installationSecret'],
      'installationId': _record['installationId'],
    };
    ++_epoch;
    _renewal?.cancel();
    _account = null;
    _locallySuppressed = true;
    _publish();
    // The retained credential is usable only by this deletion retry path, never
    // as an active identity. This handles an offline request or lost response.
    await _save((record) {
      record['suppressed'] = true;
      record['pendingDeletion'] = pending;
      for (final key in [
        'token',
        'accountKind',
        'expiresAt',
        'installationSecret',
        'installationId',
        'boundAccountId',
        'privateState',
      ]) {
        record.remove(key);
      }
    });
    state = 'deletion_pending';
    _publish();
    await _retryDeletion();
    state = deletionPending ? 'deletion_pending' : 'signed_out';
    _publish();
  }

  Future<void> _retryDeletion() async {
    final epoch = _epoch;
    final pending = _record['pendingDeletion'];
    if (pending is! Map || _disposed) return;
    try {
      var deletionToken = pending['token'] as String?;
      try {
        final result = await _api.request(
          'DELETE',
          '/v1/guest/account',
          token: deletionToken,
          body: {'confirm': true},
        );
        if (result['deleted'] != true || result['sessionsRevoked'] != true) {
          return;
        }
      } on AccountApiException catch (error) {
        if (error.status != 401 || pending['installationSecret'] is! String) {
          rethrow;
        }
        if (_disposed || epoch != _epoch) return;
        final response = await _api.request(
          'POST',
          '/v1/auth/guest',
          body: {
            'installationSecret': pending['installationSecret'],
            if (pending['installationId'] is String)
              'installationId': pending['installationId'],
            'platform': _platform,
            'appVersion': _appVersion,
          },
        );
        deletionToken = response['sessionToken'] as String?;
        if (deletionToken == null || !_validSessionToken(deletionToken)) return;
        if (_disposed || epoch != _epoch) return;
        final result = await _api.request(
          'DELETE',
          '/v1/guest/account',
          token: deletionToken,
          body: {'confirm': true},
        );
        if (result['deleted'] != true || result['sessionsRevoked'] != true) {
          return;
        }
      }
      await _save(
        (record) => record.remove('pendingDeletion'),
        expectedEpoch: epoch,
      );
    } on AccountApiException catch (error) {
      if (error.code == 'installation_revoked' &&
          !_disposed &&
          epoch == _epoch) {
        await _save(
          (record) => record.remove('pendingDeletion'),
          expectedEpoch: epoch,
        );
      }
    } catch (_) {
      /* Keep the durable deletion intent for a bounded later retry. */
    }
  }

  Future<void> createNewGuest() async {
    if (deletionPending || !persistSession) return;
    ++_epoch;
    await _save((record) {
      for (final key in [
        'token',
        'accountKind',
        'expiresAt',
        'installationSecret',
        'installationId',
        'boundAccountId',
        'privateState',
      ]) {
        record.remove(key);
      }
      record['suppressed'] = false;
    });
    _locallySuppressed = false;
    await _restoring;
    await restore();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _renewal?.cancel();
    if (_ownsApi) _api.close();
    super.dispose();
  }
}
