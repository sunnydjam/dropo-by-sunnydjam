part of 'main.dart';

class PublicVpnProviderInfo {
  const PublicVpnProviderInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.website,
  });

  final String id;
  final String name;
  final String description;
  final String website;

  factory PublicVpnProviderInfo.fromJson(Map<String, dynamic> json) =>
      PublicVpnProviderInfo(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? 'Бесплатный источник',
        description: json['description']?.toString() ?? '',
        website: json['website']?.toString() ?? '',
      );
}

/// The source editor is separate from the home screen and the routing controls.
/// Public sources require explicit consent and never change service policies.
class VpnSourcesDialog extends StatefulWidget {
  const VpnSourcesDialog({
    super.key,
    required this.bridge,
    required this.subscription,
    this.embedded = false,
    this.enabled = true,
    this.onChanged,
    this.onBusyChanged,
    this.onReadyToConnect,
    this.sourceSnapshot,
  });

  final CoreBridge bridge;
  final SubscriptionInfo subscription;
  final bool embedded, enabled;
  final VoidCallback? onChanged;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onReadyToConnect;
  final List<VpnSourceInfo>? sourceSnapshot;

  @override
  State<VpnSourcesDialog> createState() => _VpnSourcesDialogState();
}

class _VpnSourcesDialogState extends State<VpnSourcesDialog> {
  final controller = TextEditingController();
  final nameController = TextEditingController();
  String statusText = '';
  String statusKind = '';
  String catalogError = '';
  bool busy = false;
  bool loading = true;
  bool sourcesFresh = false;
  bool showPersonalForm = false;
  bool personalFormDismissed = false;
  bool showReadyAction = false;
  List<VpnSourceInfo> sources = const [];
  List<PublicVpnProviderInfo> providers = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    controller.dispose();
    nameController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VpnSourcesDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!busy &&
        !loading &&
        widget.sourceSnapshot != null &&
        !identical(widget.sourceSnapshot, oldWidget.sourceSnapshot)) {
      sources = widget.sourceSnapshot!;
      sourcesFresh = true;
      if (!_hasPersonalSource(sources) && !personalFormDismissed) {
        showPersonalForm = true;
      }
    }
  }

  bool _hasPersonalSource(List<VpnSourceInfo> value) =>
      value.any((source) => !source.isPublic);

  Future<void> _load({bool refreshCatalog = true}) async {
    if (refreshCatalog) {
      // The public catalog is optional. Its network latency must never hold the
      // personal-subscription form or a completed source mutation disabled.
      unawaited(_loadCatalog());
    }
    try {
      final loaded = await widget.bridge.vpnSources().timeout(
        const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() {
          sources = loaded;
          sourcesFresh = true;
          if (!_hasPersonalSource(loaded) && !personalFormDismissed) {
            showPersonalForm = true;
          }
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          statusKind = 'error';
          sourcesFresh = false;
          statusText = _cleanError(error);
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _loadCatalog() async {
    try {
      final catalog = await widget.bridge.publicVpnProviders().timeout(
        const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() {
          providers = catalog;
          catalogError = '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => catalogError =
              'Каталог недоступен. Ваши подписки по-прежнему можно добавить вручную.',
        );
      }
    }
  }

  Future<bool> _changeSource(
    Future<Map<String, dynamic>> Function() operation,
    String progress, {
    String success = 'Настройки источников сохранены.',
    String Function(Map<String, dynamic> result)? successText,
  }) async {
    if (busy || !widget.enabled) return false;
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = progress;
      showReadyAction = false;
    });
    var completed = false;
    try {
      final result = await operation();
      if (!mounted) return false;
      if (result['success'] != true) {
        setState(() {
          statusKind = 'error';
          statusText = _friendlyVpnSourceError(result['error']);
        });
        return false;
      }
      await _load(refreshCatalog: false);
      widget.onChanged?.call();
      if (!mounted) return false;
      setState(() {
        statusKind = 'success';
        statusText = successText?.call(result) ?? success;
      });
      completed = true;
    } catch (error) {
      if (mounted) {
        setState(() {
          statusKind = 'error';
          statusText = _cleanError(error);
        });
      }
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => busy = false);
    }
    return completed;
  }

  Future<void> _addPersonal() async {
    final uri = controller.text.trim();
    final validationError = _personalVpnSourceInputError(uri);
    if (validationError != null) {
      setState(() {
        statusKind = 'error';
        statusText = validationError;
        showReadyAction = false;
      });
      return;
    }
    final name = nameController.text.trim();
    final wasFirstPersonalSource = !_hasPersonalSource(sources);
    var verifiedCount = 0;
    final added = await _changeSource(
      () async {
        final check = await widget.bridge.testSubscription(uri);
        if (check['success'] != true) return check;
        verifiedCount = _asInt(check['count']);
        return widget.bridge.addVpnSource(
          name.isEmpty
              ? 'Мой VPN ${sources.where((s) => !s.isPublic).length + 1}'
              : name,
          uri,
        );
      },
      'Проверяем и добавляем вашу подписку…',
      successText: (_) => verifiedCount > 0
          ? '${_vpnServerCountLabel(verifiedCount)} добавлено. Можно подключаться.'
          : 'Подписка добавлена. Можно подключаться.',
    );
    if (!mounted || !added) return;
    controller.clear();
    nameController.clear();
    setState(() {
      showPersonalForm = false;
      personalFormDismissed = true;
      showReadyAction =
          wasFirstPersonalSource && widget.onReadyToConnect != null;
    });
  }

  void _togglePersonalForm() {
    setState(() {
      showPersonalForm = !showPersonalForm;
      personalFormDismissed = !showPersonalForm;
      showReadyAction = false;
      if (showPersonalForm && statusKind == 'error') {
        statusText = '';
        statusKind = '';
      }
    });
  }

  void _clearPersonalInputError() {
    if (statusKind != 'error') return;
    setState(() {
      statusKind = '';
      statusText = '';
    });
  }

  Future<void> _addPublic(PublicVpnProviderInfo provider) async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Использовать бесплатные серверы?'),
        content: SingleChildScrollView(
          child: Text(
            '${provider.name} — сторонний публичный список, не серверы Dropo. '
            'Оператор VPN может видеть адреса соединений и незашифрованный трафик. '
            'Скорость, конфиденциальность и доступность не гарантируются.\n\n'
            'Источник будет включён последним резервом. Без личной подписки он станет единственным VPN-источником. '
            'Маршруты сервисов и режим подключения не изменятся.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('public-vpn-consent'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Понимаю, добавить'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await _changeSource(
      () => widget.bridge.addPublicVpnSource(provider.id, true),
      'Загружаем бесплатный список…',
      success:
          'Бесплатный резерв добавлен. Выбран первый поддерживаемый сервер; доступность проверяется при подключении.',
    );
  }

  Future<void> _remove(VpnSourceInfo source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить «${source.name}»?'),
        content: const Text(
          'Источник исчезнет из этого профиля. Остальные источники и маршруты сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _changeSource(
      () => widget.bridge.removeVpnSource(source.id),
      'Удаляем источник…',
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobileShell;
    final disabled = busy || loading || !widget.enabled;
    final hasPersonalSource = _hasPersonalSource(sources);
    final needsFirstPersonalSource = sourcesFresh
        ? !hasPersonalSource
        : !widget.subscription.hasSubscription;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          needsFirstPersonalSource
              ? 'Первое подключение'
              : mobile
              ? 'VPN-подписка'
              : 'Своя подписка или бесплатный резерв',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          needsFirstPersonalSource
              ? 'Вставьте HTTPS-ссылку подписки или поддерживаемый VPN-ключ. '
                    'Dropo проверит доступные серверы до сохранения.'
              : mobile
              ? 'На Android используется одна активная подписка. Новая ссылка заменит сохранённую после проверки.'
              : 'Сначала используются ваши подписки, затем — включённый бесплатный источник. '
                    'Переключение происходит только при недоступности текущего источника.',
          style: const TextStyle(
            color: Color(0xFFB4C9C1),
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          mobile
              ? 'Чтобы заменить подписку, сначала отключите VPN. Настройки маршрутов сервисов сохранятся.'
              : 'Изменения источников переподключат активный VPN. '
                    'Выбранные маршруты сервисов не меняются.',
          style: const TextStyle(
            color: Color(0xFF9CAEA8),
            fontSize: 12,
            height: 1.35,
          ),
        ),
        if (busy || loading) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (!widget.enabled) ...[
          const SizedBox(height: 10),
          Text(
            mobile
                ? 'Отключите VPN и дождитесь связи с ядром, чтобы изменить подписку.'
                : 'Управление временно недоступно. Дождитесь связи с ядром и завершения подключения.',
            style: const TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
          ),
        ],
        if (!loading && !sourcesFresh)
          TextButton(
            onPressed: busy
                ? null
                : () {
                    setState(() => loading = true);
                    unawaited(_load());
                  },
            child: const Text('Повторить загрузку источников'),
          ),
        if (statusText.isNotEmpty) ...[
          const SizedBox(height: 12),
          _StatusBox(kind: statusKind, text: statusText),
        ],
        if (showReadyAction && widget.onReadyToConnect != null) ...[
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('onboarding-ready-connect'),
            onPressed: disabled ? null : widget.onReadyToConnect,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Перейти к подключению'),
          ),
        ],
        const SizedBox(height: 18),
        _VpnSectionTitle(
          mobile ? 'Моя VPN-подписка' : 'Мои источники · в порядке приоритета',
        ),
        if (!loading && sourcesFresh && sources.isEmpty && !showPersonalForm)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'VPN-подписка пока не добавлена.',
              style: TextStyle(color: Color(0xFFB4C9C1)),
            ),
          ),
        for (var i = 0; i < sources.length; i++)
          _VpnSourceTile(
            key: ValueKey('vpn-source-${sources[i].id}'),
            source: sources[i],
            statusKnown: widget.enabled && sourcesFresh && !loading,
            singleSource: mobile,
            index: i,
            busy: disabled,
            canMoveUp: i > 0 && sources[i].isPublic == sources[i - 1].isPublic,
            canMoveDown:
                i + 1 < sources.length &&
                sources[i].isPublic == sources[i + 1].isPublic,
            onEnabled: (enabled) => _changeSource(
              () => widget.bridge.setVpnSourceEnabled(sources[i].id, enabled),
              'Сохраняем состояние источника…',
            ),
            onNode: (node) => _changeSource(
              () => widget.bridge.setVpnSourceNode(sources[i].id, node),
              'Сохраняем выбранный сервер…',
            ),
            onMove: (index) => _changeSource(
              () => widget.bridge.moveVpnSource(sources[i].id, index),
              'Сохраняем приоритет…',
            ),
            onRemove: () => _remove(sources[i]),
          ),
        if (hasPersonalSource || !showPersonalForm)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('add-personal-vpn'),
                onPressed: disabled ? null : _togglePersonalForm,
                icon: Icon(
                  showPersonalForm ? Icons.expand_less : Icons.add_link,
                ),
                label: Text(
                  showPersonalForm
                      ? 'Скрыть форму'
                      : mobile && hasPersonalSource
                      ? 'Заменить подписку'
                      : 'Добавить свою подписку',
                ),
              ),
              if (!mobile && sources.isNotEmpty)
                TextButton.icon(
                  onPressed: disabled
                      ? null
                      : () => _changeSource(
                          widget.bridge.refreshVpnSources,
                          'Обновляем списки серверов…',
                        ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Обновить списки'),
                ),
            ],
          ),
        if (showPersonalForm) ...[
          if (hasPersonalSource || !needsFirstPersonalSource)
            const SizedBox(height: 12),
          const Text(
            'Ссылка подписки или VPN-ключ',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('personal-vpn-uri'),
            controller: controller,
            enabled: !disabled,
            minLines: 1,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            onChanged: (_) => _clearPersonalInputError(),
            decoration: _fieldDecoration(
              hint: 'https://… или vless://…',
              suffixIcon: IconButton(
                tooltip: 'Вставить ссылку',
                icon: const Icon(Icons.content_paste),
                onPressed: disabled
                    ? null
                    : () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (mounted && data?.text != null) {
                          controller.text = data!.text!;
                          _clearPersonalInputError();
                        }
                      },
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Поддерживаются безопасные HTTPS-подписки и ключи VLESS, Trojan, Shadowsocks, VMess, Hysteria2 и TUIC.',
            style: TextStyle(color: Color(0xFF9CAEA8), fontSize: 11),
          ),
          if (!mobile) ...[
            const SizedBox(height: 10),
            const Text(
              'Название (необязательно)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('personal-vpn-name'),
              controller: nameController,
              enabled: !disabled,
              onChanged: (_) => _clearPersonalInputError(),
              decoration: _fieldDecoration(hint: 'Например, «Моя подписка»'),
            ),
          ],
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const ValueKey('submit-personal-vpn'),
            onPressed: disabled ? null : _addPersonal,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(
              mobile && hasPersonalSource
                  ? 'Проверить и заменить'
                  : 'Проверить и добавить',
            ),
          ),
        ],
        if (providers.isNotEmpty || catalogError.isNotEmpty) ...[
          const SizedBox(height: 20),
          const _VpnSectionTitle('Бесплатный VPN · по желанию'),
          const Text(
            'Нет подписки? Можно использовать публичный список. '
            'Это сторонние серверы с переменной доступностью, а не гарантия обхода блокировок.',
            style: TextStyle(color: Color(0xFFB4C9C1), fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (catalogError.isNotEmpty) Text(catalogError),
          for (final provider in providers)
            _PublicVpnProviderCard(
              provider: provider,
              busy: disabled,
              added: sources.any((s) => s.publicCatalogId == provider.id),
              onAdd: () => _addPublic(provider),
              onWebsite: () async {
                try {
                  await widget.bridge.openExternal(provider.website);
                } catch (error) {
                  if (mounted) {
                    setState(() {
                      statusKind = 'error';
                      statusText = _cleanError(error);
                    });
                  }
                }
              },
            ),
        ],
        const SizedBox(height: 12),
        Text(
          mobile
              ? 'На Android VPN-ядро выбирает доступный сервер из подписки при подключении.'
              : 'Внутри источника используется один выбранный сервер. '
                    'Если он не работает, выберите другой вручную. Автоперебора серверов нет.',
          style: const TextStyle(color: Color(0xFF9CAEA8), fontSize: 12),
        ),
        if (!widget.embedded) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, true),
              child: const Text('Готово'),
            ),
          ),
        ],
      ],
    );
    if (widget.embedded) {
      return _FeaturePage(
        title: 'Источники VPN',
        icon: Icons.vpn_key_outlined,
        child: content,
      );
    }
    return _AppDialog(
      title: 'Источники VPN',
      icon: Icons.vpn_key_outlined,
      width: 680,
      centered: true,
      child: content,
    );
  }
}

String? _personalVpnSourceInputError(String value) {
  final input = value.trim();
  if (input.isEmpty) {
    return 'Вставьте HTTPS-ссылку подписки или VPN-ключ.';
  }
  const directSchemes = <String>[
    'vless://',
    'trojan://',
    'ss://',
    'vmess://',
    'hysteria2://',
    'hy2://',
    'tuic://',
  ];
  if (directSchemes.any(input.startsWith)) return null;

  final uri = Uri.tryParse(input);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return 'Для подписки нужна корректная HTTPS-ссылка. HTTP и локальные файлы не поддерживаются.';
  }
  if (uri.userInfo.isNotEmpty) {
    return 'Логин и пароль нельзя помещать в адрес подписки.';
  }
  return null;
}

String _friendlyVpnSourceError(Object? error) {
  final message = _cleanError(
    error ?? 'Не удалось сохранить источник',
  ).replaceFirst('Bad state: ', '').trim();
  return switch (message) {
    'VPN key is invalid or unsupported on Android' =>
      'VPN-ключ повреждён или не поддерживается на Android.',
    'VPN subscription could not be downloaded or contains no supported Android servers' =>
      'Не удалось загрузить подписку или в ней нет поддерживаемых серверов для Android.',
    'Could not save Android VPN subscription' =>
      'Не удалось сохранить VPN-подписку на устройстве.',
    'VPN subscription is empty' =>
      'Вставьте HTTPS-ссылку подписки или VPN-ключ.',
    _ when message.isEmpty => 'Не удалось сохранить источник.',
    _ => message,
  };
}

String _vpnServerCountLabel(int count) {
  final value = count < 0 ? 0 : count;
  final mod100 = value % 100;
  final mod10 = value % 10;
  final suffix = mod100 >= 11 && mod100 <= 14
      ? 'серверов'
      : mod10 == 1
      ? 'сервер'
      : mod10 >= 2 && mod10 <= 4
      ? 'сервера'
      : 'серверов';
  return '$value $suffix';
}

class _VpnSectionTitle extends StatelessWidget {
  const _VpnSectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFFA9C7BC),
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _PublicVpnProviderCard extends StatelessWidget {
  const _PublicVpnProviderCard({
    required this.provider,
    required this.busy,
    required this.added,
    required this.onAdd,
    required this.onWebsite,
  });

  final PublicVpnProviderInfo provider;
  final bool busy;
  final bool added;
  final VoidCallback onAdd;
  final VoidCallback onWebsite;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF183128),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF3B6653)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          provider.name,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        const SizedBox(height: 6),
        Text(
          provider.description,
          style: const TextStyle(color: Color(0xFFB4C9C1), fontSize: 12),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: ValueKey('add-public-vpn-${provider.id}'),
              onPressed: busy || added ? null : onAdd,
              icon: Icon(added ? Icons.check : Icons.add),
              label: Text(
                added ? 'Уже добавлен' : 'Добавить бесплатный резерв',
              ),
            ),
            TextButton.icon(
              onPressed: busy ? null : onWebsite,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Об источнике'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _VpnSourceTile extends StatelessWidget {
  const _VpnSourceTile({
    super.key,
    required this.source,
    required this.statusKnown,
    required this.singleSource,
    required this.index,
    required this.busy,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onEnabled,
    required this.onNode,
    required this.onMove,
    required this.onRemove,
  });

  final VpnSourceInfo source;
  final bool statusKnown;
  final bool singleSource;
  final int index;
  final bool busy;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<int> onNode;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final selected = source.selectedNode;
    final node = selected >= 0 && selected < source.nodeNames.length
        ? source.nodeNames[selected]
        : 'Список серверов ещё не загружен';
    final state = singleSource
        ? 'Сохранена'
        : !statusKnown
        ? 'Статус уточняется'
        : source.disabled
        ? 'Выключен'
        : source.active
        ? 'Используется сейчас'
        : 'Включён';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: source.active && statusKnown
              ? const Color(0xFF5DC693)
              : Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                source.isPublic
                    ? Icons.public_outlined
                    : Icons.vpn_key_outlined,
                color: const Color(0xFF86EFAC),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (!singleSource)
                Tooltip(
                  message: source.disabled
                      ? 'Включить источник'
                      : 'Выключить источник',
                  child: Switch.adaptive(
                    value: !source.disabled,
                    onChanged: busy ? null : onEnabled,
                  ),
                ),
            ],
          ),
          Text(
            singleSource
                ? '$state · ${_vpnServerCountLabel(source.nodeCount)}'
                : '${source.isPublic ? 'Бесплатный · последний резерв' : 'Приоритет ${index + 1} · личный источник'} · $state',
            style: const TextStyle(color: Color(0xFFB4C9C1), fontSize: 12),
          ),
          if (singleSource) ...[
            const SizedBox(height: 8),
            const Text(
              'Доступный сервер выбирается VPN-ядром автоматически при подключении.',
              style: TextStyle(color: Color(0xFF9CAEA8), fontSize: 11),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Material(
              color: Colors.transparent,
              child: ListTile(
                key: ValueKey('choose-vpn-node-${source.id}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(node, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${source.nodeCount} серверов · выбрать вручную',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy || source.nodeCount < 1
                    ? null
                    : () async {
                        final result = await showDialog<int>(
                          context: context,
                          builder: (context) => VpnNodePicker(source: source),
                        );
                        if (result != null && result != selected) {
                          onNode(result);
                        }
                      },
              ),
            ),
          ],
          if (source.lastUpdated.isNotEmpty)
            Text(
              'Список обновлён: ${source.lastUpdated}',
              style: const TextStyle(color: Color(0xFF9CAEA8), fontSize: 11),
            ),
          if (source.lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                source.lastError,
                style: TextStyle(
                  color: source.usingCache
                      ? const Color(0xFFFCD34D)
                      : const Color(0xFFFCA5A5),
                  fontSize: 12,
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!singleSource && !source.isPublic) ...[
                IconButton(
                  tooltip: 'Выше по приоритету',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: busy || !canMoveUp
                      ? null
                      : () => onMove(index - 1),
                ),
                IconButton(
                  tooltip: 'Ниже по приоритету',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: busy || !canMoveDown
                      ? null
                      : () => onMove(index + 1),
                ),
              ],
              IconButton(
                tooltip: 'Удалить источник',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: busy ? null : onRemove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Lazy, searchable list instead of a several-hundred-item dropdown menu.
class VpnNodePicker extends StatefulWidget {
  const VpnNodePicker({super.key, required this.source});
  final VpnSourceInfo source;

  @override
  State<VpnNodePicker> createState() => _VpnNodePickerState();
}

class _VpnNodePickerState extends State<VpnNodePicker> {
  String query = '';

  String name(int index) => index < widget.source.nodeNames.length
      ? widget.source.nodeNames[index]
      : 'Сервер ${index + 1}';

  @override
  Widget build(BuildContext context) {
    final matches = [
      for (var i = 0; i < widget.source.nodeCount; i++)
        if (query.isEmpty ||
            name(i).toLowerCase().contains(query.toLowerCase()))
          i,
    ];
    return AlertDialog(
      title: const Text('Выбрать сервер'),
      content: SizedBox(
        width: 540,
        height: MediaQuery.sizeOf(context).height * 0.48,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('vpn-node-search'),
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Поиск по названию или стране',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => query = value.trim()),
            ),
            const SizedBox(height: 8),
            Text(
              'Найдено: ${matches.length}. Названия и задержки указаны поставщиком; это не замер Dropo.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? const Center(child: Text('Серверы не найдены'))
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final node = matches[index];
                        final selected = node == widget.source.selectedNode;
                        return ListTile(
                          key: ValueKey('vpn-node-$node'),
                          selected: selected,
                          title: Text(name(node)),
                          trailing: selected
                              ? const Icon(Icons.check_circle_outline)
                              : null,
                          onTap: () => Navigator.pop(context, node),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
