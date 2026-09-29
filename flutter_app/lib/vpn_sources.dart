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
  final addFlowAnchor = GlobalKey();
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
  bool showAddOptions = false;
  bool showOrder = false;
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
      showAddOptions = false;
      showFreeCatalog = false;
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
      showAddOptions = true;
      showFreeCatalog = false;
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

  void _toggleAddOptions() {
    setState(() {
      showAddOptions = !showAddOptions;
      if (!showAddOptions) {
        showPersonalForm = false;
        showFreeCatalog = false;
      }
    });
    if (showAddOptions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !showAddOptions) return;
        final target = addFlowAnchor.currentContext;
        if (target != null) {
          unawaited(
            Scrollable.ensureVisible(
              target,
              alignment: 0,
              duration: const Duration(milliseconds: 200),
            ),
          );
        }
      });
    }
  }

  Future<void> _selectManualMode() async {
    final first = sources.where((source) => !source.disabled).firstOrNull;
    if (first == null) return;
    await _changeSource(
      () => widget.bridge.moveVpnSource(first.id, 0),
      'Включаем ручной выбор…',
      success: 'Ручной выбор включён. Основной источник — «${first.name}».',
    );
  }

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobileShell;
    final disabled = busy || loading || !widget.enabled;
    final controlsDisabled = disabled || !sourcesFresh;
    final hasPersonalSource = _hasPersonalSource(sources);
    final firstEnabled = sources
        .where((source) => !source.disabled)
        .firstOrNull;
    final adding = showAddOptions || (sourcesFresh && sources.isEmpty);
    final addButton = FilledButton.icon(
      key: const ValueKey('add-personal-vpn'),
      style: FilledButton.styleFrom(
        foregroundColor: const Color(0xFF06251B),
        backgroundColor: _atlasMint,
        disabledBackgroundColor: _atlasSurface,
        disabledForegroundColor: _atlasMuted,
      ),
      onPressed: disabled ? null : _toggleAddOptions,
      icon: Icon(showAddOptions ? Icons.close : Icons.add, size: 18),
      label: Text(showAddOptions ? 'Закрыть добавление' : 'Добавить'),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
          Align(alignment: Alignment.centerRight, child: addButton),
        if (mobile)
          const Text(
            'На Android используется одна активная подписка.',
            style: TextStyle(color: _atlasMuted, fontSize: 13),
          ),
        if (!mobile && sources.isNotEmpty) ...[
          Wrap(
            key: const ValueKey('source-selection-mode'),
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('source-auto-select'),
                label: const Text('Автоматически'),
                selected: sourcesFresh && autoSelect == true,
                onSelected: controlsDisabled
                    ? null
                    : (_) => autoSelect == true
                          ? null
                          : _changeSource(
                              widget.bridge.enableVpnSourceAutoSelect,
                              'Включаем автовыбор…',
                              success:
                                  'Автовыбор включён. При подключении сравнивается отклик отдельных источников; сервер внутри подписки не меняется.',
                            ),
              ),
              ChoiceChip(
                key: const ValueKey('source-manual-select'),
                label: const Text('Вручную'),
                selected: sourcesFresh && autoSelect == false,
                onSelected: controlsDisabled || firstEnabled == null
                    ? null
                    : (_) => autoSelect == false ? null : _selectManualMode(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            !sourcesFresh || autoSelect == null
                ? 'Уточняем способ выбора источника…'
                : autoSelect!
                ? 'При подключении выбираем источник с минимальным откликом. Работающее соединение не переключаем.'
                : 'Первый включённый источник — основной. Остальные подстрахуют при сбое.',
            style: const TextStyle(
              color: _atlasMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (busy || loading) const LinearProgressIndicator(),
        if (!widget.enabled)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              mobile
                  ? 'Отключите VPN и дождитесь связи с ядром, чтобы изменить подписку.'
                  : 'Управление временно недоступно. Дождитесь связи с ядром и завершения подключения.',
              style: const TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
            ),
          ),
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
        if (showReadyAction && widget.onReadyToConnect != null)
          FilledButton.icon(
            key: const ValueKey('onboarding-ready-connect'),
            onPressed: disabled ? null : widget.onReadyToConnect,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Перейти к подключению'),
          ),
        if (!mobile &&
            recentlyAddedId.isNotEmpty &&
            sources.any(
              (source) => source.id == recentlyAddedId && !source.disabled,
            ) &&
            sources.length > 1 &&
            sources.first.id != recentlyAddedId)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('new-source-make-primary'),
              onPressed: controlsDisabled
                  ? null
                  : () => _changeSource(
                      () => widget.bridge.moveVpnSource(recentlyAddedId, 0),
                      'Сохраняем приоритет…',
                    ),
              icon: const Icon(Icons.vertical_align_top),
              label: const Text('Выбрать новый источник вручную'),
            ),
          ),
        if (adding) ...[
          const SizedBox(height: 12),
          Column(
            key: addFlowAnchor,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sources.isEmpty) ...[
                const Text(
                  'Добавьте первый источник',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Используйте свою подписку или выберите сторонний бесплатный источник.',
                  style: TextStyle(color: _atlasMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('choose-personal-source'),
                    onPressed: disabled ? null : _togglePersonalForm,
                    icon: const Icon(Icons.vpn_key_outlined, size: 18),
                    label: Text(
                      showPersonalForm
                          ? 'Скрыть форму'
                          : mobile && hasPersonalSource
                          ? 'Заменить подписку'
                          : 'Своя подписка',
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('toggle-free-catalog'),
                    onPressed: disabled
                        ? null
                        : () => setState(() {
                            showFreeCatalog = !showFreeCatalog;
                            showPersonalForm = false;
                            showAddOptions = true;
                          }),
                    icon: const Icon(Icons.public_outlined, size: 18),
                    label: const Text('Бесплатные источники'),
                  ),
                ],
              ),
              if (showPersonalForm) ...[
                const SizedBox(height: 12),
                Text(
                  'Ссылка подписки или VPN-ключ',
                  key: personalFormAnchor,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
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
                    decoration: _fieldDecoration(
                      hint: 'Например, «Моя подписка»',
                    ),
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

              if (showFreeCatalog) ...[
                const SizedBox(height: 20),
                const _VpnSectionTitle('Бесплатный VPN · по желанию'),
                const Text(
                  'Нет подписки? Можно использовать публичный список. '
                  'Это сторонние серверы с переменной доступностью, а не гарантия обхода блокировок.',
                  style: TextStyle(color: Color(0xFFB4C9C1), fontSize: 12),
                ),
                const SizedBox(height: 10),
                if (catalogError.isNotEmpty) ...[
                  Text(catalogError),
                  TextButton(
                    onPressed: _loadCatalog,
                    child: const Text('Повторить загрузку каталога'),
                  ),
                ],
                if (providers.isEmpty && catalogError.isEmpty)
                  const Text(
                    'Загружаем каталог…',
                    style: TextStyle(color: _atlasMuted),
                  ),
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

              if (!mobile)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Dropo Boost · скоро',
                    key: ValueKey('boost-preview'),
                    style: TextStyle(color: _atlasMuted, fontSize: 12),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (sources.isNotEmpty && !mobile && running == true)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Смена источника или сервера переподключит VPN. Маршруты сервисов сохранятся.',
              style: TextStyle(color: _atlasMuted, fontSize: 11),
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
            primary: sources[i].id == firstEnabled?.id,
            busy: controlsDisabled,
            onEnabled: (enabled) => _changeSource(
              () => widget.bridge.setVpnSourceEnabled(sources[i].id, enabled),
              'Сохраняем состояние источника…',
            ),
            onNode: (node) => _changeSource(
              () => widget.bridge.setVpnSourceNode(sources[i].id, node),
              'Сохраняем выбранный сервер…',
            ),
            onSelect: () => _changeSource(
              () => widget.bridge.moveVpnSource(sources[i].id, 0),
              'Выбираем источник вручную…',
            ),
            onRemove: () => _remove(sources[i]),
          ),
        if (!mobile && sources.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'Отклик — HTTP-проверка, не игровой пинг и не скорость скачивания.',
            style: TextStyle(color: _atlasMuted, fontSize: 11),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (sources.length > 1 && autoSelect == false)
                TextButton.icon(
                  key: const ValueKey('source-order'),
                  onPressed: () => setState(() => showOrder = !showOrder),
                  icon: Icon(
                    showOrder ? Icons.expand_less : Icons.reorder,
                    size: 18,
                  ),
                  label: const Text('Порядок резервных источников'),
                ),
              TextButton.icon(
                key: const ValueKey('refresh-source-lists'),
                onPressed: controlsDisabled
                    ? null
                    : () => _changeSource(
                        widget.bridge.refreshVpnSources,
                        'Обновляем списки серверов…',
                      ),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить списки'),
              ),
            ],
          ),
          if (sources.length > 1 && autoSelect == false && showOrder) ...[
            const Text(
              'Первый включённый — основной. Выключенные пропускаются.',
              style: TextStyle(color: _atlasMuted, fontSize: 12),
            ),
            for (var i = 0; i < sources.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${i + 1}. ${sources[i].name}${sources[i].disabled ? ' · Выключен' : ''}',
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          key: ValueKey('vpn-source-up-${sources[i].id}'),
                          onPressed: controlsDisabled || i == 0
                              ? null
                              : () => _changeSource(
                                  () => widget.bridge.moveVpnSource(
                                    sources[i].id,
                                    i - 1,
                                  ),
                                  'Сохраняем порядок…',
                                ),
                          icon: const Icon(Icons.arrow_upward, size: 16),
                          label: const Text('Выше'),
                        ),
                        TextButton.icon(
                          key: ValueKey('vpn-source-down-${sources[i].id}'),
                          onPressed: controlsDisabled || i == sources.length - 1
                              ? null
                              : () => _changeSource(
                                  () => widget.bridge.moveVpnSource(
                                    sources[i].id,
                                    i + 1,
                                  ),
                                  'Сохраняем порядок…',
                                ),
                          icon: const Icon(Icons.arrow_downward, size: 16),
                          label: const Text('Ниже'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ],
        if (!widget.embedded)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, true),
              child: const Text('Готово'),
            ),
          ),
      ],
    );
    if (widget.embedded) {
      return _FeaturePage(
        title: 'Источники VPN',
        icon: Icons.vpn_key_outlined,
        headerAction: addButton,
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
    required this.primary,
    required this.busy,
    required this.onEnabled,
    required this.onNode,
    required this.onSelect,
    required this.onRemove,
  });

  final VpnSourceInfo source;
  final bool statusKnown, singleSource, primary, busy;
  final bool? running, autoSelect;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<int> onNode;
  final VoidCallback onSelect, onRemove;

  @override
  State<_VpnSourceTile> createState() => _VpnSourceTileState();
}

class _VpnSourceTileState extends State<_VpnSourceTile> {
  bool expanded = false;

  Future<void> _chooseNode() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => VpnNodePicker(source: widget.source),
    );
    if (!mounted ||
        widget.busy ||
        result == null ||
        result == widget.source.selectedNode) {
      return;
    }
    widget.onNode(result);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final active =
        widget.statusKnown &&
        widget.running == true &&
        source.active &&
        !source.disabled;
    final selected =
        widget.statusKnown &&
        widget.autoSelect == false &&
        widget.primary &&
        !source.disabled;
    final node =
        source.selectedNode >= 0 &&
            source.selectedNode < source.nodeNames.length
        ? source.nodeNames[source.selectedNode]
        : 'Список серверов ещё не загружен';
    final state = !widget.statusKnown
        ? 'Статус уточняется'
        : widget.singleSource
        ? 'Сохранена'
        : source.disabled
        ? 'Выключен'
        : active
        ? 'Подключён сейчас'
        : selected
        ? 'Выбран для подключения'
        : widget.autoSelect == false
        ? 'Резервный'
        : widget.autoSelect == true
        ? 'Участвует в автовыборе'
        : 'Способ выбора уточняется';
    final response = Text(
      !widget.statusKnown || widget.running == null
          ? 'Отклик · Нет данных'
          : source.disabled
          ? 'Отклик · Выключен'
          : widget.running != true
          ? 'Отклик · После подключения'
          : 'Отклик · ${source.response.label}',
      key: ValueKey('source-response-${source.id}'),
      style: TextStyle(
        fontFamily: source.response.current ? 'Consolas' : 'Inter',
        fontFamilyFallback: const ['Inter'],
        fontSize: 12,
        color:
            widget.statusKnown &&
                widget.running == true &&
                !source.disabled &&
                source.response.current
            ? _atlasMint
            : _atlasMuted,
      ),
    );
    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!widget.singleSource)
          TextButton.icon(
            key: ValueKey('vpn-source-first-${source.id}'),
            onPressed: widget.busy || source.disabled || selected
                ? null
                : widget.onSelect,
            icon: Icon(selected ? Icons.check : Icons.arrow_forward, size: 16),
            label: Text(
              selected
                  ? 'Выбран'
                  : widget.autoSelect == false
                  ? 'Выбрать'
                  : 'Выбрать вручную',
            ),
          ),
        TextButton.icon(
          key: PageStorageKey('source-details-${source.id}'),
          onPressed: () => setState(() => expanded = !expanded),
          icon: Icon(expanded ? Icons.expand_less : Icons.more_horiz, size: 18),
          label: const Text('Ещё'),
          style: TextButton.styleFrom(foregroundColor: _atlasMuted),
        ),
      ],
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              source.isPublic ? Icons.public_outlined : Icons.vpn_key_outlined,
              color: active ? _atlasMint : _atlasMuted,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                source.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.singleSource
              ? '$state · ${_vpnServerCountLabel(source.nodeCount)}'
              : '${source.isPublic ? 'Бесплатный' : 'Своя подписка'} · $state',
          style: TextStyle(
            color: active ? _atlasMint : _atlasMuted,
            fontSize: 12,
          ),
        ),
        if (!widget.singleSource) ...[
          const SizedBox(height: 4),
          Text(
            node,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _atlasMuted, fontSize: 12),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('choose-vpn-node-${source.id}'),
              onPressed: widget.busy || source.nodeCount < 1
                  ? null
                  : _chooseNode,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                minimumSize: const Size(48, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Сменить сервер',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
    return Container(
      key: ValueKey('source-row-surface-${source.id}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _atlasBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 480 &&
                  MediaQuery.textScalerOf(context).scale(1) <= 1.3;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identity,
                    if (!widget.singleSource) response,
                    actions,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!widget.singleSource) response,
                      const SizedBox(height: 8),
                      actions,
                    ],
                  ),
                ],
              );
            },
          ),
          if (!expanded && source.lastError.isNotEmpty)
            const Text(
              'Есть проблема с источником. Подробности — в «Ещё».',
              style: TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
            ),
          if (expanded) ...[
            if (!widget.singleSource)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Использовать источник',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  Switch.adaptive(
                    key: ValueKey('source-enabled-${source.id}'),
                    value: !source.disabled,
                    onChanged: widget.busy ? null : widget.onEnabled,
                  ),
                ],
              ),
            Text(
              widget.singleSource
                  ? 'На Android доступный сервер выбирается VPN-ядром при подключении.'
                  : '${_vpnServerCountLabel(source.nodeCount)}. Используется выбранный сервер; автоматического перебора внутри подписки нет.',
              style: const TextStyle(color: _atlasMuted, fontSize: 12),
            ),
            if (source.lastUpdated.isNotEmpty)
              Text(
                'Список обновлён: ${source.lastUpdated}',
                style: const TextStyle(color: _atlasMuted, fontSize: 11),
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
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('remove-source-${source.id}'),
                onPressed: widget.busy ? null : widget.onRemove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Удалить источник'),
              ),
            ),
          ],
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
