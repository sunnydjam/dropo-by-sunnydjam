part of 'main.dart';

enum _AccountPhase { loading, signedOut, pendingAuth, signedIn }

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
    this.speedBoostUntil,
  });

  factory _AccountRecord.fromJson(Map<String, dynamic> json) => _AccountRecord(
    id: json['id']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? 'Пользователь Dropo',
    maskedPhone: json['maskedPhone']?.toString() ?? '+• ••• •••-••-••',
    plan: json['plan']?.toString() ?? 'Dropo Free',
    telegramUsername: json['telegramUsername']?.toString() ?? '',
    speedBoostUntil: DateTime.tryParse(
      json['speedBoostUntil']?.toString() ?? '',
    ),
  );

  final String id, displayName, maskedPhone, plan, telegramUsername;
  final DateTime? speedBoostUntil;
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

class _AccountApiException implements Exception {
  const _AccountApiException(this.message, {this.code = ''});
  final String message, code;
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

class _AccountApi implements AccountTransport {
  _AccountApi(this.endpoint);

  final String endpoint;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final request = await _client
        .openUrl(method, Uri.parse(endpoint).resolve(path))
        .timeout(const Duration(seconds: 6));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 8));
    final raw = await utf8.decoder.bind(response).join();
    Map<String, dynamic> decoded = const {};
    if (raw.trim().isNotEmpty) {
      final value = jsonDecode(raw);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _asMap(decoded['error']);
      throw _AccountApiException(
        error['message']?.toString() ?? 'Сервис аккаунтов временно недоступен.',
        code: error['code']?.toString() ?? '',
      );
    }
    return decoded;
  }

  @override
  void close() => _client.close(force: true);
}

class _AccountTokenVault {
  _AccountTokenVault({this.enabled = true, String? initialToken})
    : _memoryFallback = initialToken;

  final bool enabled;
  String? _memoryFallback;

  File? get _file {
    if (!enabled) return null;
    try {
      if (Platform.isWindows) {
        final local = Platform.environment['LOCALAPPDATA'];
        if (local == null || local.isEmpty) return null;
        return File(
          '$local${Platform.pathSeparator}dropo${Platform.pathSeparator}account-session',
        );
      }
      if (Platform.isAndroid || Platform.isIOS) {
        return File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}dropo-account-session',
        );
      }
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      return File(
        '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share${Platform.pathSeparator}dropo${Platform.pathSeparator}account-session',
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> read() async {
    try {
      final file = _file;
      if (file == null || !await file.exists()) return _memoryFallback;
      final token = (await file.readAsString()).trim();
      return token.isEmpty ? _memoryFallback : token;
    } catch (_) {
      return _memoryFallback;
    }
  }

  Future<void> write(String token) async {
    _memoryFallback = token;
    try {
      final file = _file;
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsString(token, flush: true);
    } catch (_) {}
  }

  Future<void> clear() async {
    _memoryFallback = null;
    try {
      final file = _file;
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.endpoint,
    required this.onOpenExternal,
    this.persistSession = true,
    this.transport,
    this.initialToken,
  });

  final String endpoint;
  final Future<void> Function(String url) onOpenExternal;
  final bool persistSession;
  final AccountTransport? transport;
  final String? initialToken;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late final AccountTransport _api =
      widget.transport ?? _AccountApi(widget.endpoint);
  late final _vault = _AccountTokenVault(
    enabled: widget.persistSession,
    initialToken: widget.initialToken,
  );
  final _phone = TextEditingController();
  Timer? _authPoll;
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

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  @override
  void dispose() {
    _authPoll?.cancel();
    _phone.dispose();
    if (widget.transport == null) _api.close();
    super.dispose();
  }

  Future<void> _restore() async {
    await _loadProduct();
    final token = await _vault.read();
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _phase = _AccountPhase.signedOut);
      return;
    }
    _token = token;
    try {
      await _refreshAccount();
    } catch (_) {
      await _vault.clear();
      _token = null;
      if (mounted) {
        setState(() {
          _phase = _AccountPhase.signedOut;
          _message = 'Сессия завершена. Войдите через Telegram снова.';
        });
      }
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
  }

  Future<void> _startAuth({String purpose = 'login', String? phone}) async {
    final value = (phone ?? _phone.text).trim();
    if (value.isEmpty) {
      setState(() => _message = 'Введите номер телефона.');
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
      _authPurpose = purpose;
    });
    try {
      final response = await _api.request(
        'POST',
        '/v1/auth/challenges',
        body: {'phone': value, 'purpose': purpose},
      );
      _challengeToken = response['challengeToken']?.toString();
      _telegramUrl = response['telegramUrl']?.toString();
      if (_challengeToken == null || _telegramUrl == null) {
        throw const _AccountApiException(
          'Сервис вернул неполную заявку входа.',
        );
      }
      if (!mounted) return;
      setState(() {
        _phase = _AccountPhase.pendingAuth;
        _busy = false;
      });
      await widget.onOpenExternal(_telegramUrl!);
      _scheduleAuthPoll();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = _accountError(error);
      });
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
    if (challenge == null || _busy || !mounted) return;
    try {
      final response = await _api.request(
        'GET',
        '/v1/auth/challenges/$challenge',
      );
      final status = response['status']?.toString();
      if (status == 'approved') {
        _authPoll?.cancel();
        await _exchangeAuth(challenge);
      } else if (status == 'denied' || status == 'expired') {
        _authPoll?.cancel();
        if (!mounted) return;
        setState(() {
          _phase = _account == null
              ? _AccountPhase.signedOut
              : _AccountPhase.signedIn;
          _message = status == 'expired'
              ? 'Время подтверждения истекло. Создайте новую заявку.'
              : 'Вход отклонён в Telegram.';
        });
      }
    } catch (error) {
      if (mounted && _phase == _AccountPhase.pendingAuth) {
        setState(() => _message = _accountError(error));
      }
    }
  }

  Future<void> _exchangeAuth(String challenge) async {
    setState(() => _busy = true);
    try {
      final response = await _api.request(
        'POST',
        '/v1/auth/challenges/$challenge/exchange',
        body: {'deviceName': _deviceName()},
      );
      final token = response['accessToken']?.toString() ?? '';
      if (token.isEmpty) {
        throw const _AccountApiException('Не удалось получить сессию Dropo.');
      }
      await _vault.write(token);
      _token = token;
      if (!mounted) return;
      setState(() {
        _account = _AccountRecord.fromJson(_asMap(response['account']));
        _phase = _AccountPhase.signedIn;
        _busy = false;
        _message = _authPurpose == 'recovery'
            ? 'Доступ восстановлен. Остальные сессии завершены.'
            : '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _phase = _account == null
            ? _AccountPhase.signedOut
            : _AccountPhase.signedIn;
        _message = _accountError(error);
      });
    }
  }

  String _deviceName() {
    if (Platform.isAndroid) return 'Dropo · Android';
    if (Platform.isWindows) return 'Dropo · Windows';
    if (Platform.isMacOS) return 'Dropo · macOS';
    return 'Dropo · ${Platform.operatingSystem}';
  }

  Future<void> _logout() async {
    final token = _token;
    setState(() => _busy = true);
    try {
      if (token != null) {
        await _api.request('DELETE', '/v1/sessions/current', token: token);
      }
    } catch (_) {
      // Local sign-out still removes the credential when the backend is down.
    }
    await _vault.clear();
    _authPoll?.cancel();
    if (!mounted) return;
    setState(() {
      _token = null;
      _account = null;
      _phase = _AccountPhase.signedOut;
      _busy = false;
      _message = '';
    });
  }

  Future<void> _openPurchase() async {
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
    final controller = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить доступ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Введите привязанный номер. Telegram попросит передать контакт и подтвердить восстановление.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('recovery-phone'),
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Номер телефона',
                hintText: '+7 999 000-00-00',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (phone != null && phone.trim().isNotEmpty) {
      await _startAuth(purpose: 'recovery', phone: phone);
    }
  }

  Future<void> _showSessions() async {
    final token = _token;
    if (token == null) return;
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
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SessionsDialog(
          sessions: sessions,
          api: _api,
          token: token,
          onOpenExternal: widget.onOpenExternal,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _message = _accountError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _AccountPhase.loading => const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      _AccountPhase.signedOut => _signedOut(),
      _AccountPhase.pendingAuth => _pendingAuth(),
      _AccountPhase.signedIn => _signedIn(),
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
          phone: _phone,
          busy: _busy,
          recovery: _authPurpose == 'recovery',
          message: _message,
          onSubmit: () => _startAuth(purpose: _authPurpose),
          onToggleRecovery: () => setState(() {
            _authPurpose = _authPurpose == 'login' ? 'recovery' : 'login';
            _message = '';
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
            const Text(
              'Telegram защищает вход, восстановление и покупки.',
              style: TextStyle(color: _atlasMuted, fontSize: 15),
            ),
            const SizedBox(height: 28),
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
              const Row(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.7),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Ожидаем подтверждение в Telegram',
                      style: TextStyle(
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
                'Откройте бота, передайте свой контакт и подтвердите действие. Статус обновится автоматически.',
                style: TextStyle(color: _atlasMuted, height: 1.5),
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
                    onPressed: _telegramUrl == null
                        ? null
                        : () => widget.onOpenExternal(_telegramUrl!),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('Открыть Telegram снова'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      _authPoll?.cancel();
                      setState(() {
                        _phase = _account == null
                            ? _AccountPhase.signedOut
                            : _AccountPhase.signedIn;
                        _message = '';
                      });
                    },
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
                child: const Icon(Icons.send_rounded, color: _atlasMint),
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
                      account.maskedPhone,
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
                  detail: 'Вход, покупки и завершение сессий защищены Telegram',
                  onTap: () => _showTextDialog(
                    context,
                    'Подтверждение действий',
                    'Dropo никогда не запрашивает код входа или пароль Telegram. Подтверждайте действие только в официальном боте после запуска из приложения.',
                  ),
                ),
                const Divider(height: 1),
                _AccountActionRow(
                  icon: Icons.key_outlined,
                  title: 'Восстановить доступ',
                  detail: 'Перепривязать текущую сессию через контакт Telegram',
                  onTap: _busy ? null : _startRecoveryDialog,
                ),
                const Divider(height: 1),
                _AccountActionRow(
                  icon: Icons.devices_outlined,
                  title: 'Управление сессиями',
                  detail: 'Просмотр устройств и безопасный выход',
                  onTap: _busy ? null : _showSessions,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.phone,
    required this.busy,
    required this.recovery,
    required this.message,
    required this.onSubmit,
    required this.onToggleRecovery,
  });
  final TextEditingController phone;
  final bool busy, recovery;
  final String message;
  final VoidCallback onSubmit, onToggleRecovery;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        recovery
            ? 'Восстановите доступ через привязанный Telegram.'
            : 'Введите номер, привязанный к Telegram. Регистрация произойдёт при первом подтверждении.',
        style: const TextStyle(color: _atlasMuted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 20),
      TextField(
        key: const ValueKey('account-phone'),
        controller: phone,
        enabled: !busy,
        keyboardType: TextInputType.phone,
        autofillHints: const [AutofillHints.telephoneNumber],
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          labelText: 'Номер телефона',
          hintText: '+7 999 000-00-00',
          errorText: message.isEmpty ? null : message,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        key: const ValueKey('account-submit'),
        onPressed: busy ? null : onSubmit,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_outlined),
        label: Text(
          recovery ? 'Восстановить через Telegram' : 'Продолжить в Telegram',
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: _atlasMint,
          foregroundColor: _atlasBackground,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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
    ('Откройте бота', 'Приложение откроет официальный бот Dropo.'),
    ('Передайте свой контакт', 'Используйте кнопку бота, не вводите коды.'),
    ('Подтвердите вход', 'Вернитесь в Dropo после подтверждения.'),
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
    required this.enabled,
    required this.onBuy,
    required this.onTerms,
  });
  final _AccountProduct product;
  final bool enabled;
  final VoidCallback onBuy, onTerms;
  @override
  Widget build(BuildContext context) => _AccountPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          product.name,
          style: const TextStyle(
            color: _atlasText,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          product.description,
          style: const TextStyle(color: _atlasMuted, height: 1.45),
        ),
        const SizedBox(height: 18),
        _StarsAmount(amount: product.stars, fontSize: 26),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('account-buy-speed'),
          onPressed: enabled ? onBuy : null,
          icon: const Icon(Icons.send_outlined),
          label: const Text('Оплатить в Telegram'),
          style: FilledButton.styleFrom(
            backgroundColor: _atlasMint,
            foregroundColor: _atlasBackground,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
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
        throw const _AccountApiException('Счёт Telegram не создан.');
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
  });
  final List<_AccountSession> sessions;
  final AccountTransport api;
  final String token;
  final Future<void> Function(String) onOpenExternal;
  @override
  State<_SessionsDialog> createState() => _SessionsDialogState();
}

class _SessionsDialogState extends State<_SessionsDialog> {
  bool busy = false;
  String message = '';
  Timer? poll;

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _revokeOthers() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final response = await widget.api.request(
        'POST',
        '/v1/action-confirmations',
        token: widget.token,
        body: {'action': 'sessions.revoke_others'},
      );
      final confirmation = response['confirmationToken']?.toString() ?? '';
      final url = response['telegramUrl']?.toString() ?? '';
      if (confirmation.isEmpty) {
        throw const _AccountApiException('Подтверждение не создано.');
      }
      if (url.isNotEmpty) await widget.onOpenExternal(url);
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
      if (mounted) {
        setState(() {
          busy = false;
          message = _accountError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Активные сессии'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final session in widget.sessions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                session.current ? Icons.laptop_windows : Icons.devices_outlined,
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
          if (busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Подтвердите действие в Telegram.'),
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
          onPressed: busy ? null : _revokeOthers,
          child: const Text('Завершить остальные'),
        ),
    ],
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
  if (error is _AccountApiException) return error.message;
  if (error is SocketException || error is TimeoutException) {
    return 'Сервис аккаунтов недоступен. Запустите локальный DropoVPN-Backend или проверьте адрес сервиса.';
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
