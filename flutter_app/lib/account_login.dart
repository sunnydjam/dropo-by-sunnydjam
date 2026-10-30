part of 'main.dart';

// Only server-issued bearer tokens enter the existing secure session vault.
// Passwords are transient form values, never build constants or saved settings.
class _PasswordSignInDialog extends StatefulWidget {
  const _PasswordSignInDialog({required this.api, required this.deviceName});
  final AccountTransport api;
  final String deviceName;

  @override
  State<_PasswordSignInDialog> createState() => _PasswordSignInDialogState();
}

class _PasswordSignInDialogState extends State<_PasswordSignInDialog> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _working = false;
  String _message = '';
  int _generation = 0;

  @override
  void dispose() {
    ++_generation;
    _username.clear();
    _password.clear();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_working) return;
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _message = 'Введите логин и пароль аккаунта Dropo.');
      return;
    }
    final generation = ++_generation;
    setState(() {
      _working = true;
      _message = '';
    });
    _password.clear();
    try {
      final response = await widget.api.request(
        'POST',
        '/v1/auth/password',
        body: {
          'username': username,
          'password': password,
          'deviceName': widget.deviceName,
        },
      );
      final token = response['accessToken'];
      if (!mounted || generation != _generation) {
        if (token is String && token.isNotEmpty) {
          await _discardUnclaimedAccountSession(widget.api, token);
        }
        return;
      }
      final account = _asMap(response['account']);
      if (token is! String ||
          token.isEmpty ||
          token.length > 256 ||
          account['id'] is! String ||
          (account['id'] as String).isEmpty ||
          account['authMethod'] != 'password') {
        if (token is String && token.isNotEmpty && token.length <= 256) {
          await _discardUnclaimedAccountSession(widget.api, token);
        }
        throw const AccountApiException('Сервис не подтвердил вход в аккаунт.');
      }
      if (!mounted || generation != _generation) return;
      Navigator.pop(context, response);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _working = false;
          _message = _accountError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AlertDialog(
      title: const Text('Вход по логину и паролю'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Введите выданные данные аккаунта Dropo. Это вход на сервер; '
              'пароль Telegram не нужен. Бесплатное подключение доступно без аккаунта.',
              style: TextStyle(height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('account-password-username'),
              controller: _username,
              enabled: !_working,
              maxLength: 64,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Логин / Username'),
            ),
            _AccountPasswordField(
              fieldKey: const ValueKey('account-password-value'),
              controller: _password,
              enabled: !_working,
              onSubmitted: _submit,
            ),
            const SizedBox(height: 12),
            const Text(
              'Сервер проверит пароль и создаст сессию устройства. '
              'На устройстве сохраняется защищённый токен сессии, а не пароль. '
              'Данные аккаунта можно удалить в его настройках.',
              key: ValueKey('account-password-disclosure'),
              style: TextStyle(color: _atlasMuted, height: 1.45),
            ),
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
              const Text('Выполняем вход…'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('account-password-cancel'),
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey('account-password-submit'),
          onPressed: _working ? null : _submit,
          child: const Text('Войти / Sign in'),
        ),
      ],
    ),
  );
}

Future<void> _discardUnclaimedAccountSession(
  AccountTransport api,
  String token,
) async {
  try {
    await api.request('DELETE', '/v1/sessions/current', token: token);
  } catch (_) {
    // A disposed/closed transport cannot always revoke a newly issued session.
    // It is never persisted by the abandoned UI and remains subject to server TTL.
  }
}

String _approvedPasswordConfirmation(Map<String, dynamic> response) {
  final token = response['confirmationToken'];
  final rawExpiry = response['expiresAt'];
  final expiry = rawExpiry is String ? DateTime.tryParse(rawExpiry) : null;
  if (token is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(token) ||
      response['status'] != 'approved' ||
      expiry == null ||
      !expiry.isAfter(DateTime.now())) {
    throw const AccountApiException(
      'Сервер не подтвердил действие. Повторите попытку.',
    );
  }
  return token;
}

class _AccountPasswordField extends StatefulWidget {
  const _AccountPasswordField({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    this.onSubmitted,
  });
  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  State<_AccountPasswordField> createState() => _AccountPasswordFieldState();
}

class _AccountPasswordFieldState extends State<_AccountPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: !_visible,
    maxLength: 128,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => widget.enabled ? widget.onSubmitted?.call() : null,
    decoration: InputDecoration(
      labelText: 'Пароль Dropo / Password',
      suffixIcon: Semantics(
        label: _visible ? 'Скрыть пароль' : 'Показать пароль',
        child: IconButton(
          onPressed: widget.enabled
              ? () => setState(() => _visible = !_visible)
              : null,
          icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
        ),
      ),
    ),
  );
}
