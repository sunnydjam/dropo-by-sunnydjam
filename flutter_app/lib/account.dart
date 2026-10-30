part of 'main.dart';

enum _AccountPhase {
  loading,
  signedOut,
  pendingAuth,
  signedIn,
  offline,
  deletionCleanup,
}

/// Server expiry is authoritative, but a broken/missing response cannot keep
/// the client waiting forever. These are UI bounds, not a server TTL change.
@visibleForTesting
Duration accountAuthWaitDuration(Object? expiresAt, {required DateTime now}) {
  final expiry = expiresAt is String ? DateTime.tryParse(expiresAt) : null;
  if (expiry == null) return const Duration(minutes: 5);
  final remaining = expiry.difference(now);
  if (remaining <= Duration.zero) return Duration.zero;
  return remaining > const Duration(minutes: 10)
      ? const Duration(minutes: 10)
      : remaining;
}

/// Real account sessions never use a local server mock or plain HTTP in release.
bool accountEndpointAvailable(
  String endpoint, {
  bool allowLocalDevelopment = kDebugMode,
}) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return false;
  }
  final host = uri.host.toLowerCase();
  final local =
      host == 'localhost' ||
      (InternetAddress.tryParse(host)?.isLoopback ?? false);
  return uri.scheme == 'https' && !local ||
      allowLocalDevelopment && local && uri.scheme == 'http';
}

// Purchases require a separate, explicit build AND server opt-in. They remain
// off while no real premium VPN provisioning is available.
const _accountPurchasesEnabled = bool.fromEnvironment(
  'DROPO_PURCHASES_ENABLED',
  defaultValue: false,
);

@visibleForTesting
AccountTransport? debugAccountTransport;

@visibleForTesting
String? debugAccountSessionToken;

class _AccountRecord {
  const _AccountRecord({
    required this.id,
    required this.displayName,
    required this.maskedPhone,
    required this.plan,
    required this.telegramUsername,
    this.authMethod = 'telegram',
    this.demoAccount = false,
    this.username = '',
    this.speedBoostUntil,
  });

  factory _AccountRecord.fromJson(Map<String, dynamic> json) => _AccountRecord(
    id: json['id']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? 'Пользователь Dropo',
    maskedPhone: json['maskedPhone']?.toString() ?? '',
    plan: json['plan']?.toString() ?? 'Dropo Free',
    telegramUsername: json['telegramUsername']?.toString() ?? '',
    authMethod: json['authMethod'] == 'password' ? 'password' : 'telegram',
    demoAccount: json['demoAccount'] == true,
    username: json['username']?.toString() ?? '',
    speedBoostUntil: DateTime.tryParse(
      json['speedBoostUntil']?.toString() ?? '',
    ),
  );

  final String id, displayName, maskedPhone, plan, telegramUsername;
  final String authMethod, username;
  final bool demoAccount;
  bool get passwordAccount => authMethod == 'password';
  final DateTime? speedBoostUntil;
}

/// Presentation-only public account details. Credentials and private profile
/// fields never enter the shell, semantics, logs, or avatar image requests.
class AccountDisplaySnapshot {
  const AccountDisplaySnapshot({
    required this.displayName,
    this.telegramUsername = '',
  });

  factory AccountDisplaySnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['displayName']?.toString() ?? '';
    final clean = raw
        .replaceAll(
          RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
          '',
        )
        .trim();
    final name = String.fromCharCodes(clean.runes.take(80));
    final username = json['telegramUsername']?.toString() ?? '';
    return AccountDisplaySnapshot(
      displayName: name.isEmpty ? 'Аккаунт' : name,
      telegramUsername: RegExp(r'^[A-Za-z0-9_]{1,32}$').hasMatch(username)
          ? username
          : '',
    );
  }

  final String displayName, telegramUsername;
}

/// A bounded background read of an already stored session, never an automatic
/// sign-in. It is independent of the VPN ready gate and cannot clear a token.
class _AccountDisplayController extends ValueNotifier<AccountDisplaySnapshot?> {
  _AccountDisplayController({
    required this.endpoint,
    required this.available,
    required bool persistSession,
    this.transport,
    String? initialToken,
  }) : _vault = _AccountTokenVault(
         endpoint: endpoint,
         enabled: persistSession,
         initialToken: initialToken,
       ),
       super(null);

  final String endpoint;
  final bool available;
  final AccountTransport? transport;
  final _AccountTokenVault _vault;
  AccountTransport? _ownedApi;
  int _generation = 0;
  bool _disposed = false;

  void publish(AccountDisplaySnapshot? snapshot) {
    if (_disposed) return;
    ++_generation;
    value = snapshot;
  }

  Future<void> restore() async {
    if (!available || _disposed) return;
    final generation = ++_generation;
    try {
      final token = await _vault.read().timeout(const Duration(seconds: 3));
      if (_disposed ||
          generation != _generation ||
          token == null ||
          token.isEmpty) {
        return;
      }
      // A saved account remains identifiable when the server is offline. The
      // actual public name replaces this neutral label only after validation.
      value = const AccountDisplaySnapshot(displayName: 'Аккаунт');
      final api = transport ?? (_ownedApi = _AccountApi(endpoint));
      final response = await api
          .request('GET', '/v1/me', token: token)
          .timeout(const Duration(seconds: 8));
      if (_disposed || generation != _generation) return;
      value = AccountDisplaySnapshot.fromJson(_asMap(response['account']));
    } catch (_) {
      // AccountPage alone owns authentication, expiry and local sign-out.
      // An offline backend must not interrupt VPN or remove a stored session.
    } finally {
      _ownedApi?.close();
      _ownedApi = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _ownedApi?.close();
    _ownedApi = null;
    super.dispose();
  }
}

class _AccountProduct {
  const _AccountProduct({
    required this.id,
    required this.name,
    required this.description,
    required this.stars,
    required this.durationDays,
  });

  factory _AccountProduct.fromJson(Map<String, dynamic> json) =>
      _AccountProduct(
        id: json['id']?.toString() ?? 'speed_30d',
        name: json['name']?.toString() ?? 'Ускорение VPN',
        description:
            json['description']?.toString() ??
            'Приоритетные быстрые маршруты Dropo на 30 дней.',
        stars: (json['stars'] as num?)?.toInt() ?? 150,
        durationDays: (json['durationDays'] as num?)?.toInt() ?? 30,
      );

  final String id, name, description;
  final int stars, durationDays;
}

class _AccountSession {
  const _AccountSession({
    required this.deviceName,
    required this.lastSeenAt,
    required this.current,
  });

  factory _AccountSession.fromJson(Map<String, dynamic> json) =>
      _AccountSession(
        deviceName: json['deviceName']?.toString() ?? 'Dropo',
        lastSeenAt: DateTime.tryParse(json['lastSeenAt']?.toString() ?? ''),
        current: json['current'] == true,
      );

  final String deviceName;
  final DateTime? lastSeenAt;
  final bool current;
}

class AccountApiException implements Exception {
  const AccountApiException(this.message, {this.code = '', this.status = 0});
  final String message, code;
  final int status;
  @override
  String toString() => message;
}

abstract class AccountTransport {
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  });

  void close();
}

@visibleForTesting
AccountTransport createAccountTransportForTesting(
  String endpoint, {
  Duration responseTimeout = const Duration(seconds: 8),
}) => _AccountApi(endpoint, responseTimeout: responseTimeout);

class _AccountApi implements AccountTransport {
  _AccountApi(
    this.endpoint, {
    this.responseTimeout = const Duration(seconds: 8),
  });

  final String endpoint;
  final Duration responseTimeout;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    if (!accountEndpointAvailable(endpoint)) {
      throw const AccountApiException('Сервис аккаунтов пока не настроен.');
    }
    final base = Uri.parse(endpoint);
    final target = base.resolve(path);
    if (!path.startsWith('/v1/') || target.origin != base.origin) {
      throw const AccountApiException('Некорректный запрос аккаунта.');
    }
    final request = await _client
        .openUrl(method, target)
        .timeout(const Duration(seconds: 6));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    late final HttpClientResponse response;
    late final String raw;
    try {
      response = await request.close().timeout(responseTimeout);
      raw = await _readBody(response).timeout(responseTimeout);
    } catch (_) {
      request.abort();
      rethrow;
    }
    Map<String, dynamic> decoded = const {};
    if (raw.trim().isNotEmpty) {
      final value = jsonDecode(raw);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _asMap(decoded['error']);
      throw AccountApiException(
        error['message']?.toString() ?? 'Сервис аккаунтов временно недоступен.',
        code: error['code']?.toString() ?? '',
        status: response.statusCode,
      );
    }
    return decoded;
  }

  Future<String> _readBody(HttpClientResponse response) async {
    const maxBytes = 256 * 1024;
    if (response.contentLength > maxBytes) {
      throw const AccountApiException('Сервис вернул слишком большой ответ.');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const AccountApiException('Сервис вернул слишком большой ответ.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  @override
  void close() => _client.close(force: true);
}

class _AccountTokenVault {
  _AccountTokenVault({
    required this.endpoint,
    this.enabled = true,
    String? initialToken,
  }) : _memoryFallback = initialToken;

  static final _volatileSessions = <String, String>{};
  final String endpoint;
  final bool enabled;
  final _store = NativeAccountSessionStore();
  String? _memoryFallback;
  bool previousCredentialMayRemain = false;

  Future<String?> read() async {
    if (!enabled) return _memoryFallback;
    if (_volatileSessions.containsKey(endpoint)) {
      return _volatileSessions[endpoint];
    }
    try {
      final stored = await _store.read();
      if (stored == null) return _memoryFallback;
      final record = jsonDecode(stored);
      if (record is! Map ||
          record['endpoint'] != endpoint ||
          record['token'] is! String) {
        return _memoryFallback;
      }
      final token = record['token'] as String;
      return token.isEmpty ? _memoryFallback : token;
    } catch (_) {
      return _memoryFallback;
    }
  }

  Future<bool> write(String token) async {
    previousCredentialMayRemain = false;
    _memoryFallback = token;
    if (!enabled) return true;
    _volatileSessions[endpoint] = token;
    try {
      // Bind a credential to its issuing backend; a differently configured
      // client must never send the previous server's token to a new origin.
      await _store.write(jsonEncode({'endpoint': endpoint, 'token': token}));
      _volatileSessions.remove(endpoint);
      return true;
    } catch (_) {
      // Never fall back to a plaintext file. Explain the memory-only login.
      try {
        await _store.clear();
      } catch (_) {
        previousCredentialMayRemain = true;
      }
      return false;
    }
  }

  Future<bool> clear() async {
    _memoryFallback = null;
    if (!enabled) return true;
    try {
      await _store.clear();
      _volatileSessions.remove(endpoint);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.endpoint,
    required this.onOpenExternal,
    this.available = true,
    this.persistSession = true,
    this.transport,
    this.initialToken,
    this.onDisplayChanged,
  });

  final String endpoint;
  final Future<void> Function(String url) onOpenExternal;
  final bool persistSession;
  final bool available;
  final AccountTransport? transport;
  final String? initialToken;
  final ValueChanged<AccountDisplaySnapshot?>? onDisplayChanged;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> with WidgetsBindingObserver {
  late final AccountTransport _api =
      widget.transport ?? _AccountApi(widget.endpoint);
  late final _vault = _AccountTokenVault(
    endpoint: widget.endpoint,
    enabled: widget.persistSession,
    initialToken: widget.initialToken,
  );
  Timer? _authPoll;
  Timer? _authDeadlineTimer;
  DateTime? _authDeadline;
  _AccountPhase _phase = _AccountPhase.loading;
  _AccountRecord? _account;
  _AccountProduct _product = const _AccountProduct(
    id: 'speed_30d',
    name: 'Ускорение VPN',
    description: 'Приоритетные быстрые маршруты Dropo на 30 дней.',
    stars: 150,
    durationDays: 30,
  );
  String? _token, _challengeToken, _telegramUrl;
  String _authPurpose = 'login';
  String _message = '';
  bool _busy = false;
  bool _registrationAvailable = false;
  bool _passwordLoginAvailable = false;
  bool _passwordDialogOpen = false;
  bool _purchasingAvailable = false;
  bool _accountDeletionAvailable = false;
  bool _development = false;
  int? _pollingGeneration;
  bool _openingTelegram = false;
  bool _authOpenFailed = false;
  bool _authCheckFailed = false;
  bool _authRetryAvailable = false;
  int _authGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAuthTimers();
    _authGeneration++;
    if (widget.transport == null) _api.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _phase == _AccountPhase.pendingAuth &&
        !_expireAuthIfNeeded()) {
      unawaited(_pollAuth());
    }
  }

  Future<void> _restore() async {
    if (!widget.available) {
      setState(() => _phase = _AccountPhase.signedOut);
      widget.onDisplayChanged?.call(null);
      return;
    }
    await _loadCapabilities();
    if (!mounted) return;
    final token = await _vault.read();
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _phase = _AccountPhase.signedOut);
      if (mounted) widget.onDisplayChanged?.call(null);
      return;
    }
    _token = token;
    try {
      await _refreshAccount();
    } catch (error) {
      final invalid =
          error is AccountApiException &&
          (error.status == 401 || error.code == 'invalid_session');
      if (invalid) {
        await _vault.clear();
        _token = null;
        if (mounted) widget.onDisplayChanged?.call(null);
      }
      if (mounted) {
        setState(() {
          _phase = invalid ? _AccountPhase.signedOut : _AccountPhase.offline;
          _message = invalid
              ? 'Сессия завершена. Войдите в аккаунт снова.'
              : 'Сервис аккаунтов временно недоступен. Сохранённая сессия не удалена; VPN продолжает работать независимо от аккаунта.';
        });
      }
    }
  }

  Future<void> _loadCapabilities() async {
    _message = '';
    _registrationAvailable = false;
    _passwordLoginAvailable = false;
    _purchasingAvailable = false;
    _accountDeletionAvailable = false;
    _development = false;
    try {
      final response = await _api.request('GET', '/v1/capabilities');
      _development = response['development'] == true;
      _registrationAvailable =
          response['registrationAvailable'] == true &&
          response['phoneRequired'] == false &&
          response['authMode'] == 'telegram_bot';
      _purchasingAvailable =
          _accountPurchasesEnabled && response['purchasingAvailable'] == true;
      _accountDeletionAvailable = response['accountDeletionAvailable'] == true;
      _passwordLoginAvailable = response['passwordLoginAvailable'] == true;
      if (!_registrationAvailable && !_passwordLoginAvailable) {
        _message = 'Вход через Telegram пока не настроен на сервере.';
      }
      if (_purchasingAvailable) await _loadProduct();
    } catch (error) {
      _message = _accountError(error);
    }
  }

  Future<void> _loadProduct() async {
    try {
      final response = await _api.request('GET', '/v1/products');
      final products = response['products'];
      if (products is List && products.isNotEmpty && products.first is Map) {
        _product = _AccountProduct.fromJson(
          Map<String, dynamic>.from(products.first as Map),
        );
      }
    } catch (_) {
      // The catalog has a safe built-in rendering fallback while offline.
    }
  }

  Future<void> _refreshAccount() async {
    final response = await _api.request('GET', '/v1/me', token: _token);
    if (!mounted) return;
    setState(() {
      _account = _AccountRecord.fromJson(_asMap(response['account']));
      _phase = _AccountPhase.signedIn;
      _message = '';
    });
    widget.onDisplayChanged?.call(
      AccountDisplaySnapshot.fromJson(_asMap(response['account'])),
    );
  }

  Future<void> _startPasswordSignIn() async {
    if (_busy || !_passwordLoginAvailable) return;
    _stopAuthTimers();
    final generation = ++_authGeneration;
    setState(() {
      _busy = true;
      _passwordDialogOpen = true;
      _message = '';
    });
    try {
      final response = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _PasswordSignInDialog(api: _api, deviceName: _deviceName()),
      );
      if (response == null) return;
      final token = response['accessToken'] as String;
      if (!mounted || generation != _authGeneration) {
        await _discardUnclaimedAccountSession(_api, token);
        return;
      }
      // A native secure write cannot be cancelled once started. Fence it before
      // entry and keep all competing authentication actions disabled until done.
      final persisted = await _vault.write(token);
      _token = token;
      if (!mounted || generation != _authGeneration) return;
      setState(() {
        _account = _AccountRecord.fromJson(_asMap(response['account']));
        _phase = _AccountPhase.signedIn;
        _authRetryAvailable = false;
        _message = persisted
            ? ''
            : _vault.previousCredentialMayRemain
            ? 'Вход сохранён только до закрытия приложения. Не удалось очистить прежнюю защищённую сессию. Повторите выход из аккаунта.'
            : 'Вход выполнен, но защищённое хранилище недоступно. Сессия сохранена только до закрытия приложения.';
      });
      widget.onDisplayChanged?.call(
        AccountDisplaySnapshot.fromJson(_asMap(response['account'])),
      );
    } catch (error) {
      if (mounted && generation == _authGeneration) {
        setState(() => _message = _accountError(error));
      }
    } finally {
      if (mounted && generation == _authGeneration) {
        setState(() {
          _busy = false;
          _passwordDialogOpen = false;
        });
      }
    }
  }

  Future<void> _startAuth({String purpose = 'login'}) async {
    if (_busy || !_registrationAvailable) return;
    _stopAuthTimers();
    final generation = ++_authGeneration;
    setState(() {
      _busy = true;
      _message = '';
      _authPurpose = purpose;
      _authRetryAvailable = false;
      _authOpenFailed = false;
      _authCheckFailed = false;
      _openingTelegram = false;
    });
    try {
      final response = await _api.request(
        'POST',
        '/v1/auth/challenges',
        body: {'purpose': purpose},
      );
      if (!mounted || generation != _authGeneration) return;
      _challengeToken = response['challengeToken']?.toString();
      _telegramUrl = response['telegramUrl']?.toString();
      if (_challengeToken == null ||
          !RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(_challengeToken!) ||
          !_validAuthLink(_telegramUrl, _challengeToken!, purpose)) {
        throw const AccountApiException('Сервис вернул неполную заявку входа.');
      }
      final now = DateTime.now();
      final wait = accountAuthWaitDuration(response['expiresAt'], now: now);
      if (wait == Duration.zero) {
        _finishAuthAttempt('Время подтверждения истекло. Повторите вход.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _phase = _AccountPhase.pendingAuth;
        _busy = false;
      });
      _setAuthDeadline(now.add(wait), generation);
      _scheduleAuthPoll();
      await _openAuthLink();
    } catch (error) {
      if (!mounted || generation != _authGeneration) return;
      _finishAuthAttempt(_accountError(error));
    }
  }

  bool _validAuthLink(String? value, String challenge, String purpose) {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return false;
    if (uri.scheme == 'https' &&
        uri.host == 't.me' &&
        (!uri.hasPort || uri.port == 443) &&
        uri.pathSegments.length == 1 &&
        RegExp(
          r'^[A-Za-z][A-Za-z0-9_]{4,31}$',
        ).hasMatch(uri.pathSegments.first)) {
      final prefix = purpose == 'recovery' ? 'recover_' : 'login_';
      return '$prefix$challenge'.length <= 64 &&
          uri.queryParametersAll.length == 1 &&
          uri.queryParametersAll['start']?.length == 1 &&
          uri.queryParameters['start'] == '$prefix$challenge';
    }
    final endpoint = Uri.tryParse(widget.endpoint);
    return _development &&
        kDebugMode &&
        endpoint != null &&
        accountEndpointAvailable(widget.endpoint) &&
        endpoint.scheme == 'http' &&
        uri.scheme == 'http' &&
        uri.origin == endpoint.origin &&
        !uri.hasQuery &&
        uri.path == '/dev/telegram/$challenge';
  }

  void _cancelAuth() {
    _finishAuthAttempt('', retry: false);
  }

  void _stopAuthTimers() {
    _authPoll?.cancel();
    _authPoll = null;
    _authDeadlineTimer?.cancel();
    _authDeadlineTimer = null;
    _authDeadline = null;
  }

  void _setAuthDeadline(DateTime deadline, int generation) {
    _authDeadline = deadline;
    _authDeadlineTimer?.cancel();
    _authDeadlineTimer = Timer(deadline.difference(DateTime.now()), () {
      if (mounted &&
          generation == _authGeneration &&
          _phase == _AccountPhase.pendingAuth) {
        _finishAuthAttempt('Время подтверждения истекло. Повторите вход.');
      }
    });
  }

  bool _expireAuthIfNeeded() {
    final deadline = _authDeadline;
    if (deadline == null || DateTime.now().isBefore(deadline)) return false;
    _finishAuthAttempt('Время подтверждения истекло. Повторите вход.');
    return true;
  }

  void _finishAuthAttempt(String message, {bool retry = true}) {
    _authGeneration++;
    _stopAuthTimers();
    _challengeToken = null;
    _telegramUrl = null;
    if (!mounted) return;
    setState(() {
      _phase = _account == null
          ? _AccountPhase.signedOut
          : _AccountPhase.signedIn;
      _busy = false;
      _openingTelegram = false;
      _authOpenFailed = false;
      _authCheckFailed = false;
      _authRetryAvailable = retry;
      _message = message;
    });
  }

  Future<void> _openAuthLink() async {
    final url = _telegramUrl;
    final generation = _authGeneration;
    if (_openingTelegram ||
        _busy ||
        url == null ||
        _phase != _AccountPhase.pendingAuth ||
        _expireAuthIfNeeded()) {
      return;
    }
    setState(() => _openingTelegram = true);
    try {
      await widget.onOpenExternal(url).timeout(const Duration(seconds: 6));
      if (!mounted ||
          generation != _authGeneration ||
          _phase != _AccountPhase.pendingAuth) {
        return;
      }
      setState(() {
        _authOpenFailed = false;
        if (!_authCheckFailed) _message = '';
      });
    } catch (_) {
      if (mounted &&
          generation == _authGeneration &&
          _phase == _AccountPhase.pendingAuth) {
        setState(() {
          _authOpenFailed = true;
          _message = _development
              ? 'Не удалось открыть тестовую страницу. Повторите открытие или отмените вход.'
              : 'Не удалось открыть Telegram. Повторите открытие или отмените вход. Проверьте, что Telegram установлен.';
        });
      }
    } finally {
      if (mounted &&
          generation == _authGeneration &&
          _phase == _AccountPhase.pendingAuth) {
        setState(() => _openingTelegram = false);
      }
    }
  }

  void _scheduleAuthPoll() {
    _authPoll?.cancel();
    _authPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollAuth()),
    );
    unawaited(_pollAuth());
  }

  Future<void> _pollAuth() async {
    final challenge = _challengeToken;
    final generation = _authGeneration;
    if (challenge == null ||
        _busy ||
        _pollingGeneration == generation ||
        !mounted ||
        _phase != _AccountPhase.pendingAuth) {
      return;
    }
    if (_expireAuthIfNeeded()) return;
    _pollingGeneration = generation;
    try {
      final response = await _api.request(
        'GET',
        '/v1/auth/challenges/$challenge',
      );
      if (!mounted ||
          generation != _authGeneration ||
          _phase != _AccountPhase.pendingAuth) {
        return;
      }
      final serverExpiry = response['expiresAt'];
      final parsedExpiry = serverExpiry is String
          ? DateTime.tryParse(serverExpiry)
          : null;
      if (parsedExpiry != null &&
          _authDeadline != null &&
          parsedExpiry.isBefore(_authDeadline!)) {
        _setAuthDeadline(parsedExpiry, generation);
      }
      if (_expireAuthIfNeeded()) return;
      if (_authCheckFailed) {
        setState(() {
          _authCheckFailed = false;
          if (!_authOpenFailed) _message = '';
        });
      }
      final status = response['status']?.toString();
      if (status == 'approved') {
        _authPoll?.cancel();
        await _exchangeAuth(challenge, generation);
      } else if (status == 'denied' || status == 'expired') {
        _finishAuthAttempt(
          status == 'expired'
              ? 'Время подтверждения истекло. Повторите вход.'
              : 'Вход отклонён в Telegram. Можно повторить вход.',
        );
      }
    } catch (error) {
      if (mounted &&
          generation == _authGeneration &&
          _phase == _AccountPhase.pendingAuth) {
        if (error is AccountApiException &&
            (error.status == 404 || error.status == 410)) {
          _finishAuthAttempt('Заявка входа больше недоступна. Повторите вход.');
        } else {
          setState(() {
            _authCheckFailed = true;
            if (!_authOpenFailed) {
              _message =
                  'Нет связи с сервером аккаунтов. Проверьте интернет. Проверка повторится автоматически; вход можно отменить.';
            }
          });
        }
      }
    } finally {
      if (_pollingGeneration == generation) _pollingGeneration = null;
    }
  }

  Future<void> _exchangeAuth(String challenge, int generation) async {
    setState(() => _busy = true);
    try {
      final response = await _api.request(
        'POST',
        '/v1/auth/challenges/$challenge/exchange',
        body: {'deviceName': _deviceName()},
      );
      if (!mounted ||
          generation != _authGeneration ||
          _phase != _AccountPhase.pendingAuth ||
          _expireAuthIfNeeded()) {
        return;
      }
      final token = response['accessToken']?.toString() ?? '';
      if (token.isEmpty) {
        throw const AccountApiException('Не удалось получить сессию Dropo.');
      }
      // A started native secure write cannot be cancelled. The approved
      // exchange is fenced before it starts; the UI remains busy until done.
      _stopAuthTimers();
      final persisted = await _vault.write(token);
      _token = token;
      if (!mounted || generation != _authGeneration) return;
      setState(() {
        _account = _AccountRecord.fromJson(_asMap(response['account']));
        _phase = _AccountPhase.signedIn;
        _busy = false;
        _authRetryAvailable = false;
        _message = !persisted
            ? _vault.previousCredentialMayRemain
                  ? 'Новый вход сохранён только до закрытия приложения. Не удалось очистить прежнюю защищённую сессию: после перезапуска может восстановиться предыдущий аккаунт. Повторите выход из аккаунта.'
                  : 'Вход выполнен, но защищённое хранилище недоступно. Сессия сохранена только до закрытия приложения.'
            : _authPurpose == 'recovery'
            ? 'Доступ восстановлен. Остальные сессии завершены.'
            : '';
      });
      widget.onDisplayChanged?.call(
        AccountDisplaySnapshot.fromJson(_asMap(response['account'])),
      );
    } catch (error) {
      if (!mounted || generation != _authGeneration) return;
      _finishAuthAttempt(_accountError(error));
    }
  }

  String _deviceName() {
    if (Platform.isAndroid) return 'Dropo · Android';
    if (Platform.isWindows) return 'Dropo · Windows';
    if (Platform.isMacOS) return 'Dropo · macOS';
    return 'Dropo · ${Platform.operatingSystem}';
  }

  Future<void> _logout() async {
    _stopAuthTimers();
    _authGeneration++;
    final token = _token;
    setState(() => _busy = true);
    try {
      if (token != null) {
        await _api.request('DELETE', '/v1/sessions/current', token: token);
      }
    } catch (_) {
      // Local sign-out still removes the credential when the backend is down.
    }
    final cleared = await _vault.clear();
    _authPoll?.cancel();
    if (!mounted) return;
    if (!cleared) {
      setState(() {
        _busy = false;
        _phase = _AccountPhase.offline;
        _message =
            'Не удалось очистить защищённое хранилище. Повторите выход из аккаунта.';
      });
      return;
    }
    setState(() {
      _token = null;
      _account = null;
      _phase = _AccountPhase.signedOut;
      _busy = false;
      _message = '';
    });
    widget.onDisplayChanged?.call(null);
  }

  Future<void> _deleteAccount() async {
    final token = _token;
    if (_busy || token == null || !_accountDeletionAvailable) return;
    setState(() => _busy = true);
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeleteAccountDialog(
        api: _api,
        token: token,
        endpoint: widget.endpoint,
        development: _development,
        passwordAccount: _account?.passwordAccount == true,
        demoAccount: _account?.demoAccount == true,
        onOpenExternal: widget.onOpenExternal,
      ),
    );
    if (deleted == true) {
      // Erasure has already revoked every server session. Even if navigation
      // disposes this page, still attempt to remove the local credential.
      _stopAuthTimers();
      _authGeneration++;
      _account = null;
      widget.onDisplayChanged?.call(null);
      await _finishDeletionCleanup();
    } else if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _finishDeletionCleanup() async {
    if (mounted) setState(() => _busy = true);
    final cleared = await _vault.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _phase = cleared
          ? _AccountPhase.signedOut
          : _AccountPhase.deletionCleanup;
      if (cleared) _token = null;
      _message = cleared
          ? 'Аккаунт удалён, все сессии завершены. Личные VPN-источники и настройки на устройстве сохранены.'
          : 'Аккаунт на сервере удалён, все сессии завершены. Не удалось удалить сохранённый токен из защищённого хранилища. Повторите очистку на этом устройстве.';
    });
  }

  Future<void> _openPurchase() async {
    if (!_purchasingAvailable || !_accountPurchasesEnabled) return;
    final token = _token;
    if (token == null) return;
    final paid = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SpeedBoostPurchaseDialog(
        api: _api,
        token: token,
        product: _product,
        onOpenExternal: widget.onOpenExternal,
      ),
    );
    if (paid == true) await _refreshAccount();
  }

  Future<void> _startRecoveryDialog() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить доступ'),
        content: const Text(
          'Подтвердите тот же Telegram-аккаунт. После восстановления другие сессии Dropo будут завершены. Номер телефона, пароль и коды Telegram не нужны.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Продолжить в Telegram'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await _startAuth(purpose: 'recovery');
  }

  Future<void> _showSessions() async {
    final token = _token;
    if (_busy || token == null) return;
    final generation = _authGeneration;
    setState(() => _busy = true);
    try {
      final response = await _api.request('GET', '/v1/sessions', token: token);
      final raw = response['sessions'];
      final sessions = raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (item) =>
                      _AccountSession.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : <_AccountSession>[];
      if (!mounted || generation != _authGeneration || _token != token) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SessionsDialog(
          sessions: sessions,
          api: _api,
          token: token,
          passwordAccount: _account?.passwordAccount == true,
          onOpenExternal: widget.onOpenExternal,
        ),
      );
    } catch (error) {
      if (mounted && generation == _authGeneration) {
        setState(() => _message = _accountError(error));
      }
    } finally {
      if (mounted && generation == _authGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _retryAccount() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _phase = _AccountPhase.loading;
    });
    try {
      await _restore();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _offlineAccount() => _page(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Аккаунт временно недоступен',
          style: TextStyle(
            color: _atlasText,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        _AccountNotice(message: _message),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const ValueKey('account-retry'),
              onPressed: _busy ? null : _retryAccount,
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
            TextButton(
              onPressed: _busy ? null : _logout,
              child: const Text('Выйти на этом устройстве'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _PrivacyActions(onOpenExternal: widget.onOpenExternal),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.available) {
      return _page(
        const Column(
          key: ValueKey('account-unavailable'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.person_outline_rounded, size: 40, color: _atlasMint),
            SizedBox(height: 20),
            Text(
              'Вход пока недоступен',
              style: TextStyle(
                color: _atlasText,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'Для подключения VPN аккаунт не нужен. Используйте свою подписку или бесплатный VPN.',
              style: TextStyle(color: _atlasMuted, fontSize: 15, height: 1.5),
            ),
            SizedBox(height: 28),
            Text(
              'Dropo Boost · скоро',
              style: TextStyle(color: _atlasText, fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              'Здесь появятся подписки Dropo и управление покупками.',
              style: TextStyle(color: _atlasMuted, fontSize: 14, height: 1.5),
            ),
          ],
        ),
      );
    }
    return switch (_phase) {
      _AccountPhase.loading => const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      _AccountPhase.signedOut => TickerMode(
        enabled: !_passwordDialogOpen,
        child: _signedOut(),
      ),
      _AccountPhase.pendingAuth => _pendingAuth(),
      _AccountPhase.signedIn => _signedIn(),
      _AccountPhase.offline => _offlineAccount(),
      _AccountPhase.deletionCleanup => _page(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Завершите очистку устройства',
              style: TextStyle(color: _atlasText, fontSize: 24),
            ),
            const SizedBox(height: 16),
            _AccountNotice(message: _message),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('account-delete-cleanup-retry'),
              onPressed: _busy ? null : _finishDeletionCleanup,
              icon: const Icon(Icons.delete_outline),
              label: Text(_busy ? 'Удаляем токен…' : 'Повторить очистку'),
            ),
            const SizedBox(height: 16),
            _PrivacyActions(onOpenExternal: widget.onOpenExternal),
          ],
        ),
      ),
    };
  }

  Widget _page(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: child,
      ),
    ),
  );

  Widget _signedOut() => _page(
    LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        final form = _AuthForm(
          busy: _busy,
          available: _registrationAvailable,
          development: _development,
          recovery: _authPurpose == 'recovery',
          retry: _authRetryAvailable,
          message: _message,
          onOpenExternal: widget.onOpenExternal,
          onSubmit: () => _startAuth(purpose: _authPurpose),
          onToggleRecovery: () => setState(() {
            _authPurpose = _authPurpose == 'login' ? 'recovery' : 'login';
            _message = '';
            _authRetryAvailable = false;
          }),
        );
        const steps = _TelegramAuthSteps();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Войти в Dropo',
              style: TextStyle(
                color: _atlasText,
                fontSize: 32,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _passwordLoginAvailable
                  ? 'Выберите способ входа: Telegram или выданный логин и пароль. Бесплатный VPN работает и без входа.'
                  : 'Войдите через Telegram. При первом подтверждении аккаунт создаётся автоматически. Бесплатный VPN работает и без входа.',
              style: const TextStyle(color: _atlasMuted, fontSize: 15),
            ),
            const SizedBox(height: 28),
            if (_passwordLoginAvailable) ...[
              OutlinedButton.icon(
                key: const ValueKey('account-password-open'),
                onPressed: _busy ? null : _startPasswordSignIn,
                icon: const Icon(Icons.password_outlined),
                label: const Text('Войти по логину и паролю'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Для аккаунтов с выданными данными входа. Telegram не требуется.',
                style: TextStyle(color: _atlasMuted, height: 1.4),
              ),
              const SizedBox(height: 28),
            ],
            if (_development) ...[
              const _AccountNotice(
                message:
                    'Локальная проверка: подтверждение имитируется в браузере. Это не настоящий вход через Telegram.',
              ),
              const SizedBox(height: 20),
            ],
            if (!_registrationAvailable) ...[
              TextButton.icon(
                key: const ValueKey('account-retry'),
                onPressed: _busy ? null : _retryAccount,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить проверку сервиса'),
              ),
              const SizedBox(height: 16),
            ],
            if (compact) ...[
              form,
              const SizedBox(height: 28),
              steps,
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: form),
                  const SizedBox(width: 48),
                  const Expanded(flex: 5, child: _TelegramAuthSteps()),
                ],
              ),
          ],
        );
      },
    ),
  );

  Widget _pendingAuth() => _page(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _authPurpose == 'recovery'
              ? 'Восстановление доступа'
              : 'Подтвердите вход',
          style: const TextStyle(
            color: _atlasText,
            fontSize: 30,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _atlasSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _atlasBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: _authOpenFailed || _authCheckFailed
                        ? const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.orangeAccent,
                          )
                        : const CircularProgressIndicator(strokeWidth: 2.7),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _authOpenFailed
                          ? 'Не удалось открыть ${_development ? 'страницу' : 'Telegram'}'
                          : _authCheckFailed
                          ? 'Не удалось проверить подтверждение'
                          : _development
                          ? 'Ожидаем локальное подтверждение'
                          : 'Ожидаем подтверждение в Telegram',
                      style: const TextStyle(
                        color: _atlasText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'После подтверждения вернитесь в Dropo. Если время заявки истечёт, можно повторить вход.',
                style: TextStyle(color: _atlasMuted, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text(
                _development
                    ? 'Подтвердите тестовый вход на локальной странице в браузере. Это имитация: настоящий Telegram-бот не используется.'
                    : 'Откройте бота и подтвердите вход. Передавать контакт или вводить коды Telegram не нужно. Статус обновится автоматически.',
                style: const TextStyle(color: _atlasMuted, height: 1.5),
              ),
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _message,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ],
              const SizedBox(height: 22),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('account-reopen-telegram'),
                    onPressed: _telegramUrl == null || _busy || _openingTelegram
                        ? null
                        : () => unawaited(_openAuthLink()),
                    icon: const Icon(Icons.send_outlined),
                    label: Text(
                      _development
                          ? 'Открыть тестовую страницу'
                          : 'Открыть Telegram снова',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _cancelAuth,
                    child: const Text('Отменить'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _signedIn() {
    final account = _account!;
    return _page(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_development && !account.passwordAccount) ...[
            const _AccountNotice(
              message:
                  'Локальный тестовый аккаунт. Это имитация регистрации; настоящий Telegram не подключён.',
            ),
            const SizedBox(height: 20),
          ],
          if (account.demoAccount) ...[
            const _AccountNotice(
              message:
                  'Тестовый аккаунт на сервере. Подключение и действия с сессиями настоящие. '
                  'Удаление стирает профиль и завершает все сессии. Следующий вход выданными '
                  'данными создаст новый пустой тестовый профиль без восстановления удалённых данных.',
            ),
            const SizedBox(height: 20),
          ],
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _atlasMint.withValues(alpha: 0.12),
                  border: Border.all(color: _atlasMint.withValues(alpha: 0.45)),
                ),
                child: Icon(
                  account.passwordAccount
                      ? Icons.person_outline
                      : Icons.send_rounded,
                  color: _atlasMint,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName,
                      style: const TextStyle(
                        color: _atlasText,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      account.passwordAccount
                          ? account.username.isEmpty
                                ? 'Вход по паролю'
                                : account.username
                          : _development
                          ? 'Telegram не подключён'
                          : account.telegramUsername.isNotEmpty
                          ? '@${account.telegramUsername}'
                          : 'Telegram подключён',
                      style: const TextStyle(color: _atlasMuted),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _logout,
                child: const Text('Выйти'),
              ),
            ],
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 16),
            _AccountNotice(message: _message),
          ],
          const SizedBox(height: 26),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final plan = _PlanPanel(account: account);
              final boost = _BoostPanel(
                product: _product,
                available: _purchasingAvailable,
                enabled: !_busy,
                onBuy: _openPurchase,
                onTerms: () => _showTextDialog(
                  context,
                  'Условия покупки',
                  'Оплата цифровой услуги проводится в Telegram Stars. Ускорение активируется только после успешного платежа и действует ${_product.durationDays} дней. По вопросам оплаты используйте /paysupport в боте.',
                ),
              );
              if (compact) {
                return Column(
                  children: [plan, const SizedBox(height: 16), boost],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: plan),
                  const SizedBox(width: 16),
                  Expanded(child: boost),
                ],
              );
            },
          ),
          const SizedBox(height: 28),
          const Text(
            'Безопасность аккаунта',
            style: TextStyle(
              color: _atlasText,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: _atlasSurface.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _atlasBorder),
            ),
            child: Column(
              children: [
                _AccountActionRow(
                  icon: Icons.shield_outlined,
                  title: 'Подтверждение действий',
                  detail: account.passwordAccount
                      ? 'Чувствительные действия подтверждаются паролем Dropo'
                      : _development
                      ? 'Подтверждения имитируются на локальной странице'
                      : 'Вход и завершение сессий подтверждаются в Telegram',
                  onTap: () => _showTextDialog(
                    context,
                    'Подтверждение действий',
                    account.passwordAccount
                        ? 'Повторный ввод пароля Dropo подтверждает удаление аккаунта и завершение других сессий. Пароль Telegram не требуется.'
                        : _development
                        ? 'Это локальная проверка интерфейса, а не реальная авторизация. Для настоящего входа нужно настроить Telegram-бота и HTTPS backend.'
                        : 'Dropo никогда не запрашивает код входа или пароль Telegram. Подтверждайте действие только в официальном боте после запуска из приложения.',
                  ),
                ),
                if (!account.passwordAccount) ...[
                  const Divider(height: 1),
                  _AccountActionRow(
                    icon: Icons.key_outlined,
                    title: 'Восстановить доступ',
                    detail: 'Подтвердить Telegram и завершить другие сессии',
                    onTap: _busy ? null : _startRecoveryDialog,
                  ),
                ],
                const Divider(height: 1),
                _AccountActionRow(
                  icon: Icons.devices_outlined,
                  title: 'Управление сессиями',
                  detail: 'Просмотр устройств и безопасный выход',
                  onTap: _busy ? null : _showSessions,
                ),
                const Divider(height: 1),
                _AccountActionRow(
                  key: const ValueKey('account-delete'),
                  icon: Icons.delete_outline,
                  title: 'Удалить аккаунт',
                  detail: _accountDeletionAvailable
                      ? 'Безвозвратно удалить данные аккаунта и завершить все сессии'
                      : 'Удаление через приложение временно недоступно — откройте страницу ниже',
                  onTap: _busy || !_accountDeletionAvailable
                      ? null
                      : _deleteAccount,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '«Выйти» завершает сессию только на этом устройстве и не удаляет аккаунт.',
            style: TextStyle(color: _atlasMuted, height: 1.4),
          ),
          const SizedBox(height: 8),
          _PrivacyActions(onOpenExternal: widget.onOpenExternal),
        ],
      ),
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({
    required this.api,
    required this.token,
    required this.endpoint,
    required this.development,
    required this.onOpenExternal,
    this.passwordAccount = false,
    this.demoAccount = false,
  });

  final AccountTransport api;
  final String token, endpoint;
  final bool development;
  final bool passwordAccount, demoAccount;
  final Future<void> Function(String) onOpenExternal;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  String? _confirmation, _telegramUrl;
  DateTime? _deadline;
  String _message = '';
  Timer? _poll, _expiry;
  bool _working = false, _checking = false, _openingTelegram = false;
  bool _uncertainResult = false;
  bool _expired = false;
  int _generation = 0;

  @override
  void dispose() {
    ++_generation;
    _stopTimers();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  void _stopTimers() {
    _poll?.cancel();
    _poll = null;
    _expiry?.cancel();
    _expiry = null;
  }

  bool _validConfirmationLink(String value, String confirmation) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment) return false;
    if (uri.scheme == 'https' &&
        uri.host == 't.me' &&
        (!uri.hasPort || uri.port == 443) &&
        !uri.hasQuery &&
        uri.pathSegments.length == 1 &&
        RegExp(
          r'^[A-Za-z][A-Za-z0-9_]{4,31}$',
        ).hasMatch(uri.pathSegments.first)) {
      return true;
    }
    final endpoint = Uri.tryParse(widget.endpoint);
    return widget.development &&
        kDebugMode &&
        endpoint != null &&
        endpoint.scheme == 'http' &&
        accountEndpointAvailable(widget.endpoint) &&
        uri.scheme == 'http' &&
        uri.origin == endpoint.origin &&
        !uri.hasQuery &&
        uri.path == '/dev/action/$confirmation';
  }

  Future<void> _createConfirmation() async {
    if (_working) return;
    final password = _password.text;
    if (widget.passwordAccount && password.isEmpty) {
      setState(
        () => _message = 'Введите пароль Dropo для подтверждения удаления.',
      );
      return;
    }
    _password.clear();
    _stopTimers();
    final generation = ++_generation;
    setState(() {
      _working = true;
      _message = '';
      _expired = false;
    });
    try {
      final response = await widget.api
          .request(
            'POST',
            widget.passwordAccount
                ? '/v1/action-confirmations/password'
                : '/v1/action-confirmations',
            token: widget.token,
            body: {
              'action': 'account.delete',
              if (widget.passwordAccount) 'password': password,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      if (widget.passwordAccount) {
        final confirmation = _approvedPasswordConfirmation(response);
        setState(() {
          _confirmation = confirmation;
          _deadline = DateTime.tryParse(response['expiresAt'] as String);
        });
        await _consumeConfirmation(confirmation, generation);
        return;
      }
      final confirmation = response['confirmationToken'];
      final link = response['telegramUrl'];
      final rawExpiry = response['expiresAt'];
      final expiry = rawExpiry is String ? DateTime.tryParse(rawExpiry) : null;
      if (confirmation is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(confirmation) ||
          link is! String ||
          !_validConfirmationLink(link, confirmation) ||
          response['status'] != 'pending' ||
          expiry == null ||
          !expiry.isAfter(DateTime.now())) {
        throw const AccountApiException(
          'Сервер вернул некорректное подтверждение удаления. Аккаунт не удалён.',
        );
      }
      final wait = accountAuthWaitDuration(rawExpiry, now: DateTime.now());
      setState(() {
        _confirmation = confirmation;
        _telegramUrl = link;
        _deadline = DateTime.now().add(wait);
        _working = false;
      });
      _expiry = Timer(wait, () {
        if (!mounted || generation != _generation || _working) return;
        _stopTimers();
        setState(() {
          _expired = true;
          _message =
              'Время подтверждения истекло. Закройте окно и начните заново. Удаление аккаунта не подтверждено.';
        });
      });
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_checkConfirmation()),
      );
      await _openTelegram();
      if (mounted && generation == _generation) {
        unawaited(_checkConfirmation());
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _working = false;
        _message = _accountError(error);
      });
    }
  }

  Future<void> _openTelegram() async {
    final link = _telegramUrl;
    if (_openingTelegram || link == null) return;
    final generation = _generation;
    setState(() => _openingTelegram = true);
    try {
      await widget.onOpenExternal(link).timeout(const Duration(seconds: 6));
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _message = widget.development
              ? 'Не удалось открыть тестовую страницу. Повторите открытие или отмените удаление.'
              : 'Не удалось открыть Telegram. Повторите открытие или отмените удаление.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _openingTelegram = false);
      }
    }
  }

  Future<void> _checkConfirmation() async {
    final confirmation = _confirmation;
    if (_checking || _working || confirmation == null) return;
    // A lost consume response can be checked through its deletion receipt even
    // after the original Telegram challenge expires. Never create a new action
    // while the result of a previously submitted deletion is unknown.
    if (!_uncertainResult &&
        (_expired ||
            _deadline != null && !DateTime.now().isBefore(_deadline!))) {
      return;
    }
    final generation = _generation;
    _checking = true;
    try {
      final response = await widget.api
          .request(
            'GET',
            '/v1/action-confirmations/$confirmation',
            token: widget.token,
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      final status = response['status'];
      if (status == 'approved' ||
          status == 'exchanged' &&
              response['deleted'] == true &&
              response['sessionsRevoked'] == true) {
        if (!_uncertainResult &&
            (_expired ||
                _deadline != null && !DateTime.now().isBefore(_deadline!))) {
          return;
        }
        await _consumeConfirmation(confirmation, generation);
      } else if (status == 'denied' || status == 'expired') {
        _stopTimers();
        setState(() {
          _message = status == 'denied'
              ? 'Удаление отклонено в Telegram. Аккаунт сохранён.'
              : 'Подтверждение истекло. Начните удаление заново.';
        });
      } else if (status != 'pending') {
        throw const AccountApiException(
          'Не удалось подтвердить статус удаления. Повторите проверку.',
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _message = _accountError(error));
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _consumeConfirmation(String confirmation, int generation) async {
    _stopTimers();
    setState(() {
      _working = true;
      _message = '';
      _uncertainResult = true;
    });
    try {
      final response = await widget.api
          .request(
            'POST',
            '/v1/action-confirmations/$confirmation/consume',
            token: widget.token,
            body: const {},
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      if (response['success'] != true ||
          response['deleted'] != true ||
          response['sessionsRevoked'] != true) {
        throw const AccountApiException(
          'Сервер не подтвердил полное удаление аккаунта и завершение сессий.',
        );
      }
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _working = false;
          final detail = error is AccountApiException ? error.message : '';
          const resultMessage =
              'Не удалось подтвердить результат удаления. Сохранённый токен пока не удалён. Нажмите «Проверить результат»; не начинайте новое удаление.';
          _message = detail.isEmpty ? resultMessage : '$detail\n$resultMessage';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AlertDialog(
      title: const Text('Удалить аккаунт Dropo?'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.passwordAccount
                  ? 'Будут безвозвратно удалены профиль, сессии устройств и связанные данные аккаунта. Все устройства выйдут из аккаунта. Это не обычный выход из приложения.'
                  : 'Будут безвозвратно удалены Telegram-привязка, профиль, сессии устройств и связанные данные аккаунта. Все устройства выйдут из аккаунта. Это не обычный выход из приложения.',
              style: const TextStyle(height: 1.45),
            ),
            if (widget.demoAccount) ...[
              const SizedBox(height: 12),
              const Text(
                'Выданные тестовые данные входа останутся действительными. Следующий вход создаст новый пустой профиль; удалённые данные не восстановятся.',
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Личные VPN-источники, подписки, настройки и локальные журналы на устройствах останутся. Их можно удалить отдельно в приложении или очистить его хранилище.',
              style: TextStyle(color: _atlasMuted, height: 1.45),
            ),
            const SizedBox(height: 12),
            _PrivacyActions(onOpenExternal: widget.onOpenExternal),
            if (widget.passwordAccount && _confirmation == null) ...[
              const SizedBox(height: 16),
              _AccountPasswordField(
                fieldKey: const ValueKey('account-delete-password'),
                controller: _password,
                enabled: !_working,
                onSubmitted: _createConfirmation,
              ),
            ],
            if (_confirmation != null && !widget.passwordAccount) ...[
              const SizedBox(height: 12),
              Text(
                widget.development
                    ? 'Локальная имитация: подтвердите удаление на тестовой странице. Настоящий Telegram не используется.'
                    : 'Подтвердите именно удаление аккаунта в боте Dropo и вернитесь сюда. После подтверждения приложение завершит удаление.',
                style: const TextStyle(height: 1.45),
              ),
            ],
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _message,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ],
            if (_working) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                _uncertainResult
                    ? 'Удаляем аккаунт и завершаем сессии…'
                    : 'Создаём подтверждение…',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('account-delete-cancel'),
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('Закрыть'),
        ),
        if (_confirmation == null)
          FilledButton(
            key: const ValueKey('account-delete-confirm'),
            onPressed: _working ? null : _createConfirmation,
            child: Text(
              widget.passwordAccount
                  ? 'Удалить аккаунт'
                  : widget.development
                  ? 'Подтвердить в локальном тесте'
                  : 'Подтвердить удаление в Telegram',
            ),
          )
        else ...[
          if (!_uncertainResult && !widget.passwordAccount)
            OutlinedButton(
              key: const ValueKey('account-delete-open-telegram'),
              onPressed: _working || _openingTelegram ? null : _openTelegram,
              child: Text(
                widget.development
                    ? 'Открыть тестовую страницу'
                    : 'Открыть Telegram',
              ),
            ),
          FilledButton(
            key: const ValueKey('account-delete-check'),
            onPressed: _working ? null : _checkConfirmation,
            child: Text(
              _uncertainResult
                  ? 'Проверить результат'
                  : 'Проверить подтверждение',
            ),
          ),
        ],
      ],
    ),
  );
}

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.busy,
    required this.available,
    required this.development,
    required this.recovery,
    required this.retry,
    required this.message,
    required this.onSubmit,
    required this.onToggleRecovery,
    required this.onOpenExternal,
  });
  final bool busy, recovery, available, development, retry;
  final String message;
  final VoidCallback onSubmit, onToggleRecovery;
  final Future<void> Function(String) onOpenExternal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        recovery
            ? 'Восстановите доступ через привязанный Telegram.'
            : 'Без номера телефона и пароля. Нажмите кнопку и подтвердите вход в боте Dropo.',
        style: const TextStyle(color: _atlasMuted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 20),
      const Text(
        'При входе через Telegram сервер Dropo получает Telegram ID аккаунта и чата, имя и имя пользователя (если указаны). После подтверждения хранит профиль, сессии устройств и события действий с аккаунтом. Эти данные нужны для входа и безопасности. VPN-трафик и личные подписки в сервис аккаунтов не отправляются. Вход необязателен; аккаунт можно удалить.',
        key: ValueKey('account-auth-disclosure'),
        style: TextStyle(color: _atlasMuted, height: 1.45),
      ),
      const SizedBox(height: 4),
      _PrivacyActions(onOpenExternal: onOpenExternal),
      const SizedBox(height: 12),
      if (message.isNotEmpty) _AccountNotice(message: message),
      const SizedBox(height: 14),
      FilledButton.icon(
        key: const ValueKey('account-submit'),
        onPressed: busy || !available ? null : onSubmit,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_outlined),
        label: Text(
          development
              ? 'Проверить локальный вход'
              : retry
              ? 'Повторить ${recovery ? 'восстановление' : 'вход'} через Telegram'
              : recovery
              ? 'Восстановить через Telegram'
              : 'Войти через Telegram',
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: _atlasMint,
          foregroundColor: _atlasBackground,
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: busy ? null : onToggleRecovery,
        child: Text(recovery ? 'Вернуться ко входу' : 'Восстановить доступ'),
      ),
      const SizedBox(height: 18),
      const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: _atlasMuted, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Dropo никогда не запрашивает коды или пароль Telegram.',
              style: TextStyle(color: _atlasMuted, fontSize: 13, height: 1.45),
            ),
          ),
        ],
      ),
    ],
  );
}

class _TelegramAuthSteps extends StatelessWidget {
  const _TelegramAuthSteps();
  static const _steps = [
    ('Откройте Telegram', 'Нажмите «Войти через Telegram» в приложении.'),
    (
      'Подтвердите вход',
      'В боте нажмите «Подтвердить». Контакт и коды не нужны.',
    ),
    (
      'Вернитесь в Dropo',
      'Аккаунт появится автоматически после подтверждения.',
    ),
  ];
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var index = 0; index < _steps.length; index++)
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _atlasBorder),
                ),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(color: _atlasText),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _steps[index].$1,
                      style: const TextStyle(
                        color: _atlasText,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _steps[index].$2,
                      style: const TextStyle(color: _atlasMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class _PlanPanel extends StatelessWidget {
  const _PlanPanel({required this.account});
  final _AccountRecord account;
  @override
  Widget build(BuildContext context) => _AccountPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Текущий тариф', style: TextStyle(color: _atlasMuted)),
        const SizedBox(height: 12),
        Text(
          account.plan,
          style: const TextStyle(
            color: _atlasText,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          account.speedBoostUntil == null
              ? 'Бесплатный доступ'
              : 'Активно до ${_dateLabel(account.speedBoostUntil!)}',
          style: TextStyle(
            color: account.speedBoostUntil == null ? _atlasMuted : _atlasMint,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 14),
        const Text(
          'Основные функции VPN остаются доступными независимо от тарифа.',
          style: TextStyle(color: _atlasMuted, height: 1.45),
        ),
      ],
    ),
  );
}

class _BoostPanel extends StatelessWidget {
  const _BoostPanel({
    required this.product,
    required this.available,
    required this.enabled,
    required this.onBuy,
    required this.onTerms,
  });
  final _AccountProduct product;
  final bool enabled, available;
  final VoidCallback onBuy, onTerms;
  @override
  Widget build(BuildContext context) => _AccountPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          available ? product.name : 'Dropo Boost · скоро',
          style: const TextStyle(
            color: _atlasText,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          available
              ? product.description
              : 'Платный VPN появится позже. Сейчас доступна регистрация для проверки; оплаты и продажи не подключены.',
          style: const TextStyle(color: _atlasMuted, height: 1.45),
        ),
        const SizedBox(height: 18),
        if (available) _StarsAmount(amount: product.stars, fontSize: 26),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('account-buy-speed'),
          onPressed: available && enabled ? onBuy : null,
          icon: const Icon(Icons.send_outlined),
          label: Text(
            available ? 'Оплатить в Telegram' : 'Покупки пока недоступны',
          ),
          style: FilledButton.styleFrom(
            backgroundColor: _atlasMint,
            foregroundColor: _atlasBackground,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        if (available)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onTerms,
              child: const Text('Условия покупки'),
            ),
          ),
      ],
    ),
  );
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 280),
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: _atlasSurface.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _atlasBorder),
    ),
    child: child,
  );
}

class _AccountActionRow extends StatelessWidget {
  const _AccountActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });
  final IconData icon;
  final String title, detail;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: ListTile(
      minTileHeight: 68,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      leading: Icon(icon, color: _atlasText),
      title: Text(
        title,
        style: const TextStyle(color: _atlasText, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(detail, style: const TextStyle(color: _atlasMuted)),
      trailing: const Icon(Icons.chevron_right, color: _atlasMuted),
      onTap: onTap,
    ),
  );
}

class _AccountNotice extends StatelessWidget {
  const _AccountNotice({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: _atlasMint.withValues(alpha: 0.08),
      border: Border.all(color: _atlasMint.withValues(alpha: 0.3)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(message, style: const TextStyle(color: _atlasText)),
  );
}

class _SpeedBoostPurchaseDialog extends StatefulWidget {
  const _SpeedBoostPurchaseDialog({
    required this.api,
    required this.token,
    required this.product,
    required this.onOpenExternal,
  });
  final AccountTransport api;
  final String token;
  final _AccountProduct product;
  final Future<void> Function(String) onOpenExternal;
  @override
  State<_SpeedBoostPurchaseDialog> createState() =>
      _SpeedBoostPurchaseDialogState();
}

class _SpeedBoostPurchaseDialogState extends State<_SpeedBoostPurchaseDialog> {
  bool accepted = false, busy = false, pending = false;
  String message = '', orderId = '', invoiceUrl = '';
  Timer? poll;

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    if (!accepted || busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final response = await widget.api.request(
        'POST',
        '/v1/orders',
        token: widget.token,
        body: {'productId': widget.product.id, 'termsAccepted': true},
      );
      orderId = response['orderId']?.toString() ?? '';
      invoiceUrl = response['invoiceUrl']?.toString() ?? '';
      if (orderId.isEmpty || invoiceUrl.isEmpty) {
        throw const AccountApiException('Счёт Telegram не создан.');
      }
      if (!mounted) return;
      setState(() {
        busy = false;
        pending = true;
      });
      await widget.onOpenExternal(invoiceUrl);
      poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
      unawaited(_poll());
    } catch (error) {
      if (mounted) {
        setState(() {
          busy = false;
          message = _accountError(error);
        });
      }
    }
  }

  Future<void> _poll() async {
    if (busy || orderId.isEmpty) return;
    try {
      final response = await widget.api.request(
        'GET',
        '/v1/orders/$orderId',
        token: widget.token,
      );
      if (response['status']?.toString() == 'paid') {
        poll?.cancel();
        if (mounted) Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) setState(() => message = _accountError(error));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      pending ? 'Ждём подтверждение Telegram' : 'Подтвердите покупку',
    ),
    content: SizedBox(
      width: 410,
      child: pending
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 46,
                  height: 46,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Не закрывайте это окно. Статус обновится автоматически.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _atlasMuted, height: 1.45),
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    message,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ],
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: _atlasBorder),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bolt_rounded,
                        color: _atlasMint,
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.product.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${widget.product.durationDays} дней',
                              style: const TextStyle(color: _atlasMuted),
                            ),
                          ],
                        ),
                      ),
                      _StarsAmount(amount: widget.product.stars, fontSize: 18),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Оплата откроется в Telegram-боте. Доступ активируется только после успешного платежа.',
                  style: TextStyle(color: _atlasMuted, height: 1.45),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: accepted,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => accepted = value == true),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Я принимаю условия покупки'),
                ),
                if (message.isNotEmpty)
                  Text(
                    message,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
              ],
            ),
    ),
    actions: [
      if (pending)
        OutlinedButton(
          onPressed: invoiceUrl.isEmpty
              ? null
              : () => widget.onOpenExternal(invoiceUrl),
          child: const Text('Открыть счёт снова'),
        ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('Отмена'),
      ),
      if (!pending)
        FilledButton(
          key: const ValueKey('purchase-confirm'),
          onPressed: accepted && !busy ? _createOrder : null,
          child: Text(busy ? 'Создаём счёт…' : 'Перейти к оплате'),
        ),
    ],
  );
}

class _StarsAmount extends StatelessWidget {
  const _StarsAmount({required this.amount, required this.fontSize});

  final int amount;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '$amount',
        style: TextStyle(
          color: _atlasText,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(width: 5),
      const Icon(Icons.star_rounded, color: Color(0xFFFFC857), size: 22),
    ],
  );
}

class _SessionsDialog extends StatefulWidget {
  const _SessionsDialog({
    required this.sessions,
    required this.api,
    required this.token,
    required this.onOpenExternal,
    this.passwordAccount = false,
  });
  final List<_AccountSession> sessions;
  final AccountTransport api;
  final String token;
  final bool passwordAccount;
  final Future<void> Function(String) onOpenExternal;
  @override
  State<_SessionsDialog> createState() => _SessionsDialogState();
}

class _SessionsDialogState extends State<_SessionsDialog> {
  final _password = TextEditingController();
  int _generation = 0;
  bool busy = false;
  String message = '';
  Timer? poll;

  @override
  void dispose() {
    ++_generation;
    poll?.cancel();
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _revokeOthers() async {
    if (busy) return;
    final password = _password.text;
    if (widget.passwordAccount && password.isEmpty) {
      setState(
        () => message = 'Введите пароль Dropo для завершения других сессий.',
      );
      return;
    }
    _password.clear();
    final generation = ++_generation;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final response = await widget.api.request(
        'POST',
        widget.passwordAccount
            ? '/v1/action-confirmations/password'
            : '/v1/action-confirmations',
        token: widget.token,
        body: {
          'action': 'sessions.revoke_others',
          if (widget.passwordAccount) 'password': password,
        },
      );
      if (!mounted || generation != _generation) return;
      if (widget.passwordAccount) {
        final confirmation = _approvedPasswordConfirmation(response);
        final result = await widget.api.request(
          'POST',
          '/v1/action-confirmations/$confirmation/consume',
          token: widget.token,
          body: const {},
        );
        if (!mounted || generation != _generation) return;
        if (result['success'] != true) {
          throw const AccountApiException(
            'Сервер не подтвердил завершение сессий. Обновите список устройств.',
          );
        }
        Navigator.pop(context);
        return;
      }
      final confirmation = response['confirmationToken']?.toString() ?? '';
      final url = response['telegramUrl']?.toString() ?? '';
      if (confirmation.isEmpty) {
        throw const AccountApiException('Подтверждение не создано.');
      }
      if (url.isNotEmpty) await widget.onOpenExternal(url);
      if (!mounted || generation != _generation) return;
      poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final status = await widget.api.request(
            'GET',
            '/v1/action-confirmations/$confirmation',
            token: widget.token,
          );
          if (status['status']?.toString() == 'approved') {
            poll?.cancel();
            await widget.api.request(
              'POST',
              '/v1/action-confirmations/$confirmation/consume',
              token: widget.token,
              body: const {},
            );
            if (mounted) Navigator.pop(context);
          }
        } catch (error) {
          if (mounted) setState(() => message = _accountError(error));
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          busy = false;
          message = _accountError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Активные сессии'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final session in widget.sessions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  session.current
                      ? Icons.laptop_windows
                      : Icons.devices_outlined,
                  color: session.current ? _atlasMint : _atlasMuted,
                ),
                title: Text(session.deviceName),
                subtitle: Text(
                  session.lastSeenAt == null
                      ? 'Время неизвестно'
                      : 'Активность: ${_dateTimeLabel(session.lastSeenAt!)}',
                ),
                trailing: session.current
                    ? const Text('Текущая', style: TextStyle(color: _atlasMint))
                    : null,
              ),
            if (message.isNotEmpty)
              Text(message, style: const TextStyle(color: Colors.orangeAccent)),
            if (widget.passwordAccount &&
                widget.sessions.any((item) => !item.current)) ...[
              const SizedBox(height: 12),
              const Text(
                'Для завершения остальных сессий введите пароль Dropo.',
              ),
              const SizedBox(height: 8),
              _AccountPasswordField(
                fieldKey: const ValueKey('account-sessions-password'),
                controller: _password,
                enabled: !busy,
                onSubmitted: _revokeOthers,
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                widget.passwordAccount
                    ? 'Завершаем другие сессии…'
                    : 'Подтвердите действие в Telegram.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        if (widget.sessions.where((item) => !item.current).isNotEmpty)
          FilledButton(
            key: const ValueKey('account-sessions-revoke'),
            onPressed: busy ? null : _revokeOthers,
            child: const Text('Завершить остальные'),
          ),
      ],
    ),
  );
}

Future<void> _showTextDialog(BuildContext context, String title, String body) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(height: 1.5)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );

String _accountError(Object error) {
  if (error is AccountApiException) return error.message;
  if (error is SocketException || error is TimeoutException) {
    return 'Нет связи с сервером аккаунтов. Проверьте интернет и повторите попытку.';
  }
  return 'Не удалось выполнить действие. Повторите позже.';
}

String _dateLabel(DateTime value) {
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final local = value.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

String _dateTimeLabel(DateTime value) {
  final local = value.toLocal();
  String two(int item) => item.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}
