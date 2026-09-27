part of 'main.dart';

class VpnSourcesSnapshot {
  const VpnSourcesSnapshot({
    required this.sources,
    this.autoSelect,
    this.running,
  });
  final List<VpnSourceInfo> sources;
  final bool? autoSelect;
  final bool? running;

  factory VpnSourcesSnapshot.fromJson(Map<String, dynamic> json) =>
      VpnSourcesSnapshot(
        sources: (json['sources'] as List? ?? const [])
            .map(_asMap)
            .map(VpnSourceInfo.fromJson)
            .toList(growable: false),
        autoSelect: json['autoSelect'] is bool
            ? json['autoSelect'] as bool
            : null,
        running: json['running'] is bool ? json['running'] as bool : null,
      );
}

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
  final VpnSourcesSnapshot? sourceSnapshot;

  @override
  State<VpnSourcesDialog> createState() => _VpnSourcesDialogState();
}

class _VpnSourcesDialogState extends State<VpnSourcesDialog> {
  final controller = TextEditingController();
  final nameController = TextEditingController();
  final personalFormAnchor = GlobalKey();
  String statusText = '';
  String statusKind = '';
  String catalogError = '';
  bool busy = false;
  bool loading = true;
  bool sourcesFresh = false;
  bool? autoSelect;
  bool? running;
  bool showFreeCatalog = false;
  bool showPersonalForm = false;
  bool personalFormDismissed = false;
  bool showReadyAction = false;
  String recentlyAddedId = '';
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
    if (oldWidget.sourceSnapshot != null && widget.sourceSnapshot == null) {
      sourcesFresh = false;
    }
    if (!busy &&
        !loading &&
        widget.sourceSnapshot != null &&
        !identical(widget.sourceSnapshot, oldWidget.sourceSnapshot)) {
      sources = widget.sourceSnapshot!.sources;
      autoSelect = widget.sourceSnapshot!.autoSelect;
      running = widget.sourceSnapshot!.running;
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
      final snapshot = await widget.bridge.vpnSourcesSnapshot().timeout(
        const Duration(seconds: 10),
      );
      final loaded = snapshot.sources;
      if (mounted) {
        setState(() {
          sources = loaded;
          autoSelect = snapshot.autoSelect;
          running = snapshot.running;
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
    final previousIds = sources.map((source) => source.id).toSet();
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
      recentlyAddedId =
          sources
              .where((source) => !previousIds.contains(source.id))
              .firstOrNull
              ?.id ??
          '';
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
    if (showPersonalForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !showPersonalForm) return;
        final anchorContext = personalFormAnchor.currentContext;
        if (anchorContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              anchorContext,
              alignment: 0.1,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ),
          );
        }
      });
    }
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
            'Источник будет добавлен в конец списка. Вы сможете изменить его приоритет. '
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
    final added = await _changeSource(
      () => widget.bridge.addPublicVpnSource(provider.id, true),
      'Загружаем бесплатный список…',
      success:
          'Бесплатный источник добавлен. Выбран первый поддерживаемый сервер; доступность проверяется при подключении.',
    );
    if (mounted && added) {
      setState(
        () => recentlyAddedId =
            sources
                .where((source) => source.publicCatalogId == provider.id)
                .firstOrNull
                ?.id ??
            '',
      );
    }
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
        if (mobile) ...[
          Text(
            needsFirstPersonalSource
                ? 'Добавьте подписку или выберите бесплатный источник ниже.'
                : 'На Android используется одна активная подписка.',
            style: const TextStyle(color: _atlasMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
        ] else if (sources.isNotEmpty) ...[
          Text(
            !sourcesFresh || autoSelect == null
                ? 'Выбор источника'
                : autoSelect!
                ? 'Автоматически · по отклику'
                : 'Вручную · по вашему порядку',
            key: const ValueKey('source-selection-mode'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            autoSelect == false
                ? 'Первый включённый источник — основной. Остальные подстрахуют при сбое.'
                : 'Dropo сравнит отклик источников при подключении. Выбор вручную отключает автовыбор.',
            style: const TextStyle(
              color: _atlasMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
        ],
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
        if (!mobile &&
            recentlyAddedId.isNotEmpty &&
            sources.length > 1 &&
            sources.first.id != recentlyAddedId)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('new-source-make-primary'),
              onPressed: disabled
                  ? null
                  : () => _changeSource(
                      () => widget.bridge.moveVpnSource(recentlyAddedId, 0),
                      'Сохраняем приоритет…',
                    ),
              icon: const Icon(Icons.vertical_align_top),
              label: const Text('Сделать новый источник основным'),
            ),
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
            running: running,
            autoSelect: autoSelect,
            index: i,
            busy: disabled,
            canMoveUp: i > 0,
            canMoveDown: i + 1 < sources.length,
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
        if (!mobile && sources.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                key: const ValueKey('source-auto-select'),
                onPressed: disabled || autoSelect == true
                    ? null
                    : () => _changeSource(
                        widget.bridge.enableVpnSourceAutoSelect,
                        'Включаем автовыбор…',
                        success:
                            'Автовыбор включён. При подключении сравнивается отклик отдельных источников; сервер внутри подписки не меняется.',
                      ),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  autoSelect == true
                      ? 'Автовыбор включён'
                      : 'Автовыбор по пингу',
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
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('add-personal-vpn'),
            onPressed: disabled ? null : _togglePersonalForm,
            icon: Icon(showPersonalForm ? Icons.expand_less : Icons.add_link),
            label: Text(
              showPersonalForm
                  ? 'Скрыть форму'
                  : mobile && hasPersonalSource
                  ? 'Заменить подписку'
                  : 'Добавить свою подписку',
            ),
          ),
        ),

        if (showPersonalForm) ...[
          if (hasPersonalSource || !needsFirstPersonalSource)
            const SizedBox(height: 12),
          Text(
            'Ссылка подписки или VPN-ключ',
            key: personalFormAnchor,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
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
              suffixIcon: _AccessibleIconButton(
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
        const SizedBox(height: 16),
        Text(
          mobile
              ? 'Чтобы изменить подписку, отключите VPN. Маршруты сервисов сохранятся.'
              : 'Изменение источника переподключит активный VPN. Маршруты сервисов сохранятся.',
          style: const TextStyle(color: _atlasMuted, fontSize: 11, height: 1.4),
        ),
        if (hasPersonalSource &&
            (providers.isNotEmpty || catalogError.isNotEmpty))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('toggle-free-catalog'),
              onPressed: () =>
                  setState(() => showFreeCatalog = !showFreeCatalog),
              icon: Icon(
                showFreeCatalog ? Icons.expand_less : Icons.expand_more,
              ),
              label: const Text('Бесплатные источники'),
            ),
          ),
        if ((!hasPersonalSource || showFreeCatalog) &&
            (providers.isNotEmpty || catalogError.isNotEmpty)) ...[
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
        if (!mobile) ...[const SizedBox(height: 20), const _BoostPreview()],
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

class _BoostPreview extends StatelessWidget {
  const _BoostPreview();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('boost-preview'),
    padding: const EdgeInsets.symmetric(vertical: 16),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _atlasBorder)),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dropo Boost · скоро',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 6),
        Text(
          'VPN-подписки внутри приложения. Покупка пока недоступна.',
          style: TextStyle(fontSize: 13, color: Color(0xFFB4C9C1), height: 1.4),
        ),
      ],
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
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _atlasBorder)),
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
                added ? 'Уже добавлен' : 'Подключить бесплатный источник',
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

class _VpnSourceTile extends StatefulWidget {
  const _VpnSourceTile({
    super.key,
    required this.source,
    required this.statusKnown,
    required this.singleSource,
    required this.running,
    required this.autoSelect,
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
  final bool? running, autoSelect;
  final int index;
  final bool busy;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<int> onNode;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  State<_VpnSourceTile> createState() => _VpnSourceTileState();
}

class _VpnSourceTileState extends State<_VpnSourceTile> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final statusKnown = widget.statusKnown;
    final singleSource = widget.singleSource;
    final running = widget.running;
    final autoSelect = widget.autoSelect;
    final index = widget.index;
    final busy = widget.busy;
    final canMoveUp = widget.canMoveUp;
    final canMoveDown = widget.canMoveDown;
    final onEnabled = widget.onEnabled;
    final onNode = widget.onNode;
    final onMove = widget.onMove;
    final onRemove = widget.onRemove;
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
        : index == 0 && autoSelect == false
        ? 'Основной'
        : 'Готов к выбору';
    return Container(
      key: ValueKey('source-row-surface-${source.id}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _atlasBorder)),
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
                color: source.active && statusKnown ? _atlasMint : _atlasMuted,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Text(
            singleSource
                ? '$state · ${_vpnServerCountLabel(source.nodeCount)}'
                : '${source.isPublic ? 'Бесплатный' : 'Своя подписка'} · $state',
            style: TextStyle(
              color: source.active && statusKnown ? _atlasMint : _atlasMuted,
              fontSize: 12,
            ),
          ),
          if (!singleSource) ...[
            const SizedBox(height: 6),
            Text(
              node,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _atlasMuted, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  !statusKnown
                      ? 'Отклик · Нет данных'
                      : source.disabled
                      ? 'Отклик · Выключен'
                      : running == false
                      ? 'Отклик · После подключения'
                      : 'HTTP · ${source.response.label}',
                  key: ValueKey('source-response-${source.id}'),
                  style: TextStyle(
                    fontFamily: source.response.current ? 'Consolas' : 'Inter',
                    fontFamilyFallback: const ['Inter'],
                    fontSize: 12,
                    color:
                        statusKnown &&
                            running != false &&
                            !source.disabled &&
                            source.response.current
                        ? _atlasMint
                        : _atlasMuted,
                  ),
                ),
              ],
            ),
          ],
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: PageStorageKey('source-details-${source.id}'),
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: const Text('Настройки', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(foregroundColor: _atlasMuted),
              ),
              if (!singleSource)
                TextButton.icon(
                  key: ValueKey('vpn-source-first-${source.id}'),
                  onPressed:
                      busy ||
                          source.disabled ||
                          (autoSelect == false && index == 0)
                      ? null
                      : () => onMove(0),
                  icon: Icon(
                    autoSelect == false && index == 0
                        ? Icons.check
                        : Icons.arrow_forward,
                    size: 16,
                  ),
                  label: Text(
                    autoSelect == false && index == 0 ? 'Выбран' : 'Выбрать',
                  ),
                ),
            ],
          ),
          if (expanded)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!singleSource)
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Использовать источник',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      _AccessibleDescription(
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
                if (!singleSource)
                  Text(
                    'Приоритет ${index + 1} · ${_vpnServerCountLabel(source.nodeCount)}',
                    style: const TextStyle(color: _atlasMuted, fontSize: 12),
                  ),
                if (!singleSource)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'HTTP-отклик — не игровой пинг и не скорость скачивания.',
                      style: TextStyle(color: _atlasMuted, fontSize: 11),
                    ),
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
                      title: Text(
                        node,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_vpnServerCountLabel(source.nodeCount)} · выбрать вручную',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy || source.nodeCount < 1
                          ? null
                          : () async {
                              final result = await showDialog<int>(
                                context: context,
                                builder: (context) =>
                                    VpnNodePicker(source: source),
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
                    style: const TextStyle(
                      color: Color(0xFF9CAEA8),
                      fontSize: 11,
                    ),
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
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if (!singleSource) ...[
                      _AccessibleIconButton(
                        key: ValueKey('vpn-source-up-${source.id}'),
                        tooltip: 'Выше по приоритету',
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        onPressed: busy || !canMoveUp
                            ? null
                            : () => onMove(index - 1),
                      ),
                      _AccessibleIconButton(
                        key: ValueKey('vpn-source-down-${source.id}'),
                        tooltip: 'Ниже по приоритету',
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        onPressed: busy || !canMoveDown
                            ? null
                            : () => onMove(index + 1),
                      ),
                    ],
                    _AccessibleIconButton(
                      tooltip: 'Удалить источник',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: busy ? null : onRemove,
                    ),
                  ],
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
