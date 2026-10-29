part of 'main.dart';

// Public sample credentials, intentionally displayed to every user. These are
// not server credentials and must never authorize a real account or VPN plan.
const accountDemoUsername = 'demo.dropo';
const accountDemoPassword = 'DropoDemo2026!';

class _AccountDemoEntry extends StatelessWidget {
  const _AccountDemoEntry({required this.onOpenExternal});
  final Future<void> Function(String) onOpenExternal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        key: const ValueKey('account-demo-open'),
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => AccountDemoPage(onOpenExternal: onOpenExternal),
          ),
        ),
        icon: const Icon(Icons.preview_outlined),
        label: const Text('Вход по логину и паролю · демо'),
      ),
      const SizedBox(height: 8),
      const Text(
        'Познакомьтесь с разделом аккаунта без Telegram. '
        'Демонстрационные данные хранятся только до закрытия этого экрана.',
        style: TextStyle(color: _atlasMuted, height: 1.4),
      ),
    ],
  );
}

/// An explicitly labelled product tour, available to all users in every build.
/// It owns no AccountTransport, bearer token, secure vault, entitlement or VPN
/// configuration. Opening, logging out or resetting it cannot affect a real
/// Telegram account. Its public password is only a demonstration of the form.
class AccountDemoPage extends StatefulWidget {
  const AccountDemoPage({super.key, required this.onOpenExternal});
  final Future<void> Function(String) onOpenExternal;

  @override
  State<AccountDemoPage> createState() => _AccountDemoPageState();
}

class _AccountDemoPageState extends State<AccountDemoPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _signedIn = false;
  bool _otherSession = true;
  bool _showPassword = false;
  String _error = '';

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _signIn() {
    if (_username.text.trim() != accountDemoUsername ||
        _password.text != accountDemoPassword) {
      setState(
        () => _error =
            'Неверный демо-логин или пароль. '
            'Используйте учебные данные, указанные ниже.',
      );
      return;
    }
    _password.clear();
    setState(() {
      _signedIn = true;
      _otherSession = true;
      _error = '';
    });
  }

  void _signOut() {
    _username.clear();
    _password.clear();
    setState(() {
      _signedIn = false;
      _otherSession = true;
      _error = '';
      _showPassword = false;
    });
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить демоданные?'),
        content: const Text(
          'Будет завершён только этот учебный сеанс. Серверный аккаунт, '
          'сессии Telegram, VPN-источники и настройки не затрагиваются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('account-demo-reset-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить демоданные'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _signOut();
  }

  Future<void> _sessions() => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, updateDialog) => AlertDialog(
        scrollable: true,
        title: const Text('Демонстрационные сессии'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Это учебные записи, а не устройства на сервере.'),
              const ListTile(
                leading: Icon(Icons.phone_android),
                title: Text('Текущий демосеанс'),
                subtitle: Text('Только на этом экране'),
              ),
              if (_otherSession)
                const ListTile(
                  key: ValueKey('account-demo-other-session'),
                  leading: Icon(Icons.computer),
                  title: Text('Пример второго устройства'),
                  subtitle: Text('Вымышленная демосессия'),
                )
              else
                const Text('Другие демосессии завершены.'),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const ValueKey('account-demo-revoke'),
                onPressed: !_otherSession
                    ? null
                    : () {
                        setState(() => _otherSession = false);
                        updateDialog(() {});
                      },
                child: const Text('Завершить другие демосессии'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    ),
  );

  Widget _login() => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Учебный вход / Demo sign-in',
          style: TextStyle(color: _atlasText, fontSize: 22),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('account-demo-username'),
          controller: _username,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 80,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Логин / Username'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('account-demo-password'),
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 128,
          onSubmitted: (_) => _signIn(),
          decoration: InputDecoration(
            labelText: 'Пароль / Password',
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Скрыть пароль' : 'Показать пароль',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        if (_error.isNotEmpty)
          Text(_error, style: const TextStyle(color: Colors.orangeAccent)),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('account-demo-submit'),
          onPressed: _signIn,
          child: const Text('Войти в демо / Enter demo'),
        ),
        const SizedBox(height: 20),
        const SelectableText(
          'Публичные учебные данные / Public demo credentials\n'
          'Username: $accountDemoUsername\nPassword: $accountDemoPassword',
          style: TextStyle(color: _atlasText, height: 1.6),
        ),
        const SizedBox(height: 12),
        const Text(
          'Не вводите личный пароль. Демо-форма ничего не отправляет в сеть. '
          'Доступ многоразовый, без Telegram, одноразовых кодов и регистрации.',
          style: TextStyle(color: _atlasMuted, height: 1.5),
        ),
      ],
    ),
  );

  Widget _profile() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Dropo Demo',
        key: ValueKey('account-demo-profile'),
        style: TextStyle(
          color: _atlasText,
          fontSize: 26,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Telegram не подключён. Серверный аккаунт не создаётся.',
        style: TextStyle(color: _atlasMuted),
      ),
      const SizedBox(height: 20),
      const _PlanPanel(
        account: _AccountRecord(
          id: 'local-demo',
          displayName: 'Dropo Demo',
          maskedPhone: '',
          plan: 'Dropo Free',
          telegramUsername: '',
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Покупки недоступны. Демо не выдаёт VPN-подписку и не меняет '
        'тариф или маршруты. Настоящий VPN доступен на главном экране без входа.',
        style: TextStyle(color: _atlasMuted, height: 1.5),
      ),
      const SizedBox(height: 16),
      _AccountActionRow(
        key: const ValueKey('account-demo-sessions'),
        icon: Icons.devices_outlined,
        title: 'Управление демосессиями',
        detail: 'Посмотреть и завершить учебные сессии',
        onTap: _sessions,
      ),
      _AccountActionRow(
        key: const ValueKey('account-demo-reset'),
        icon: Icons.delete_outline,
        title: 'Удалить демоданные',
        detail: 'Очистить этот учебный сеанс',
        onTap: _reset,
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        key: const ValueKey('account-demo-logout'),
        onPressed: _signOut,
        child: const Text('Выйти из демо / Sign out'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _atlasBackground,
    appBar: AppBar(title: const Text('Демонстрационный аккаунт')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _AccountNotice(
                message:
                    'ДЕМО / DEMO — учебные данные только на этом экране. '
                    'Это не вход в серверный аккаунт. '
                    'Demo data only; no server account or real sessions.',
              ),
              const SizedBox(height: 24),
              if (_signedIn) _profile() else _login(),
              const SizedBox(height: 24),
              _PrivacyActions(onOpenExternal: widget.onOpenExternal),
            ],
          ),
        ),
      ),
    ),
  );
}
