part of 'main.dart';

class VpnSourcesSnapshot {
  const VpnSourcesSnapshot({
    required this.sources,
    this.autoSelect,
    this.running,
    this.autoSelectSupported = true,
    this.fallbackSupported = true,
  });
  final List<VpnSourceInfo> sources;
  final bool? autoSelect;
  final bool? running;
  final bool autoSelectSupported;
  final bool fallbackSupported;

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
        autoSelectSupported: json['autoSelectSupported'] != false,
        fallbackSupported: json['fallbackSupported'] != false,
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
    this.onApplyChange,
    this.connected,
  });

  final CoreBridge bridge;
  final SubscriptionInfo subscription;
  final bool embedded, enabled;
  final VoidCallback? onChanged;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onReadyToConnect;
  final VpnSourcesSnapshot? sourceSnapshot;
  final bool? connected;
  final Future<Map<String, dynamic>> Function(
    Future<Map<String, dynamic>> Function() operation,
  )?
  onApplyChange;

  @override
  State<VpnSourcesDialog> createState() => _VpnSourcesDialogState();
}

class _VpnSourcesDialogState extends State<VpnSourcesDialog> {
  final controller = TextEditingController();
  final nameController = TextEditingController();
  final nameFocus = FocusNode(debugLabel: 'personal-vpn-name');
  final personalFormAnchor = GlobalKey();
  final addFlowAnchor = GlobalKey();
  final orderAnchor = GlobalKey();
  String statusText = '';
  String statusKind = '';
  String catalogError = '';
  bool busy = false;
  bool loading = true;
  bool sourcesFresh = false;
  bool? autoSelect;
  bool? running;
  bool autoSelectSupported = true;
  bool fallbackSupported = true;
  bool showPersonalForm = false;
  bool showAddOptions = false;
  bool showOrder = false;
  bool showReadyAction = false;
  bool showOptionalName = false;
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
    nameFocus.dispose();
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
      autoSelectSupported = widget.sourceSnapshot!.autoSelectSupported;
      fallbackSupported = widget.sourceSnapshot!.fallbackSupported;
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
          autoSelectSupported = snapshot.autoSelectSupported;
          fallbackSupported = snapshot.fallbackSupported;
          sourcesFresh = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          statusKind = 'error';
          sourcesFresh = false;
          statusText = _friendlyVpnSourceError(error);
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
          catalogError = catalog.isEmpty
              ? 'Dropo Free сейчас недоступен. Вашу подписку можно добавить вручную.'
              : '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => catalogError =
              'Dropo Free сейчас недоступен. Вашу подписку можно добавить вручную.',
        );
      }
    }
  }

  Future<bool> _changeSource(
    Future<Map<String, dynamic>> Function() operation,
    String progress, {
    String success = 'Настройки источников сохранены.',
    String Function(Map<String, dynamic> result)? successText,
    bool metadataOnly = false,
    String confirmationTitle = 'Применить изменение?',
    bool leavesDisconnected = false,
  }) async {
    if (busy || loading || !widget.enabled || !sourcesFresh) return false;
    if (!metadataOnly && (widget.connected ?? running) == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(confirmationTitle),
          content: Text(
            leavesDisconnected
                ? 'После изменения не останется включённых подписок. VPN отключится и останется выключенным. Для подключения потребуется добавить или включить подписку.'
                : 'VPN ненадолго отключится и подключится с выбранными настройками. Режим и правила сервисов сохранятся.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const ValueKey('source-reconnect-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                leavesDisconnected ? 'Отключить VPN' : 'Переподключить',
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return false;
    }
    if (!mounted || busy || !widget.enabled || !sourcesFresh) return false;
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = !metadataOnly && (widget.connected ?? running) == true
          ? leavesDisconnected
                ? 'Отключаем VPN…'
                : 'Переподключаем с новым выбором…'
          : progress;
      showReadyAction = false;
    });
    var completed = false;
    try {
      final result = !metadataOnly && widget.onApplyChange != null
          ? await widget.onApplyChange!(operation)
          : await operation();
      if (!mounted) return false;
      if (result['success'] != true) {
        if (!metadataOnly) {
          // The saved selection can change even if restarting the tunnel fails.
          await _load(refreshCatalog: false);
          widget.onChanged?.call();
          if (!mounted) return false;
        }
        setState(() {
          statusKind = 'error';
          statusText =
              _applyUserMessage(result, metadataOnly) ??
              _friendlyVpnSourceError(result['error']);
        });
        return false;
      }
      await _load(refreshCatalog: false);
      widget.onChanged?.call();
      if (!mounted) return false;
      setState(() {
        statusKind = 'success';
        statusText =
            _applyUserMessage(result, metadataOnly) ??
            successText?.call(result) ??
            success;
      });
      completed = true;
    } catch (error) {
      if (!metadataOnly && mounted) {
        await _load(refreshCatalog: false);
        widget.onChanged?.call();
      }
      if (mounted) {
        setState(() {
          statusKind = 'error';
          statusText = _friendlyVpnSourceError(error);
        });
      }
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => busy = false);
    }
    return completed;
  }

  String? _applyUserMessage(Map<String, dynamic> result, bool metadataOnly) {
    final message = !metadataOnly && widget.onApplyChange != null
        ? result['userMessage']
        : null;
    return message is String &&
            message.length <= 500 &&
            !RegExp(
              r'[a-z][a-z0-9+.-]*://',
              caseSensitive: false,
            ).hasMatch(message)
        ? message
        : null;
  }

  bool _removesLastEnabled(VpnSourceInfo source) =>
      _isAndroidPlatform &&
      !source.disabled &&
      sources.where((item) => !item.disabled).length == 1;

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
    FocusManager.instance.primaryFocus?.unfocus();
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
            '${provider.name} — бесплатная подписка, предоставляемая через сервис Dropo. '
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
      'Проверяем доступность Dropo Free…',
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
      leavesDisconnected: _removesLastEnabled(source),
    );
  }

  void _toggleAddOptions() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      showAddOptions = !showAddOptions;
      showPersonalForm = showAddOptions;
      showReadyAction = false;
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

  Future<void> _rename(VpnSourceInfo source) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _RenameVpnSourceDialog(initialName: source.name),
    );
    if (result == null || result == source.name || !mounted) return;
    await _changeSource(
      () => widget.bridge.callMap('RenameVPNSource', args: [source.id, result]),
      'Сохраняем название…',
      success: 'Название сохранено.',
      metadataOnly: true,
    );
  }

  Future<bool> _favorite(VpnSourceInfo source, String nodeId, bool favorite) =>
      _changeSource(
        () => widget.bridge.callMap(
          'SetVPNSourceNodeFavorite',
          args: [source.id, nodeId, favorite],
        ),
        'Сохраняем избранное…',
        success: favorite
            ? 'Сервер добавлен в избранное.'
            : 'Сервер удалён из избранного.',
        metadataOnly: true,
      );

  Future<void> _refreshSources() => _changeSource(
    widget.bridge.refreshVpnSources,
    'Обновляем списки серверов…',
    success: 'Списки подписок обновлены.',
  );

  Future<void> _selectNode(VpnSourceInfo source, int node) async {
    final nodeId = node >= 0 && node < source.nodeIds.length
        ? source.nodeIds[node]
        : '';
    if (nodeId.isEmpty) {
      setState(() {
        statusKind = 'error';
        statusText =
            'Обновите список подписок перед выбором сервера. Если это не помогает, обновите Dropo.';
      });
      return;
    }
    final name = node < source.nodeNames.length
        ? source.nodeNames[node]
        : 'сервер ${node + 1}';
    await _changeSource(
      () => widget.bridge.callMap(
        'SetVPNSourceNodeByID',
        args: [source.id, nodeId],
        // Windows waits for subscription refresh and atomic reconnection,
        // matching the existing SetVPNSourceNode transaction timeout.
        timeout: const Duration(minutes: 3),
      ),
      'Сохраняем сервер…',
      confirmationTitle: 'Выбрать «$name»?',
      success:
          'Сервер сохранён для «${source.name}». Выбор подписки не изменён.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final disabled = busy || loading || !widget.enabled;
    final controlsDisabled = disabled || !sourcesFresh;
    final firstEnabled = sources
        .where((source) => !source.disabled)
        .firstOrNull;
    final free = providers
        .where(
          (provider) =>
              !sources.any((source) => source.publicCatalogId == provider.id),
        )
        .firstOrNull;
    final addButton = FilledButton.icon(
      key: const ValueKey('add-personal-vpn'),
      onPressed: disabled ? null : _toggleAddOptions,
      icon: Icon(showPersonalForm ? Icons.close : Icons.add, size: 18),
      label: Text(showPersonalForm ? 'Закрыть' : 'Добавить'),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
          Align(alignment: Alignment.centerRight, child: addButton),
        if (busy || loading) const LinearProgressIndicator(),
        if (!widget.enabled && !busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Изменения сейчас недоступны. Дождитесь завершения подключения или повторите загрузку.',
              style: TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
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
        if (sources.isEmpty && sourcesFresh && !showPersonalForm) ...[
          const SizedBox(height: 12),
          const Text(
            'Добавьте свою подписку',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Вставьте ссылку от вашего провайдера или используйте Dropo Free.',
            style: TextStyle(color: _atlasMuted, height: 1.4),
          ),
          const SizedBox(height: 16),
        ],
        if (showPersonalForm) ...[
          const SizedBox(height: 16),
          Column(
            key: addFlowAnchor,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ссылка подписки или VPN-ключ',
                key: personalFormAnchor,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('personal-vpn-uri'),
                controller: controller,
                enabled: !controlsDisabled,
                minLines: 1,
                maxLines: 3,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!controlsDisabled) unawaited(_addPersonal());
                },
                onChanged: (_) => _clearPersonalInputError(),
                decoration: _fieldDecoration(
                  hint: 'https://… или VPN-ключ',
                  suffixIcon: _AccessibleIconButton(
                    tooltip: 'Вставить ссылку',
                    icon: const Icon(Icons.content_paste),
                    onPressed: controlsDisabled
                        ? null
                        : () async {
                            final data = await Clipboard.getData(
                              Clipboard.kTextPlain,
                            );
                            if (mounted &&
                                data?.text != null &&
                                !busy &&
                                widget.enabled &&
                                sourcesFresh) {
                              controller.text = data!.text!;
                              _clearPersonalInputError();
                            }
                          },
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('source-optional-name'),
                  onPressed: controlsDisabled
                      ? null
                      : () => setState(
                          () => showOptionalName = !showOptionalName,
                        ),
                  child: Text(
                    showOptionalName
                        ? 'Скрыть название'
                        : 'Название · необязательно',
                  ),
                ),
              ),
              if (showOptionalName) ...[
                TextField(
                  key: const ValueKey('personal-vpn-name'),
                  controller: nameController,
                  focusNode: nameFocus,
                  enabled: !controlsDisabled,
                  maxLength: 80,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!controlsDisabled) unawaited(_addPersonal());
                  },
                  decoration: _fieldDecoration(
                    hint: 'Например, «Моя подписка»',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                key: const ValueKey('submit-personal-vpn'),
                onPressed: controlsDisabled ? null : _addPersonal,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Проверить и добавить'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ],
        if (statusText.isNotEmpty) ...[
          const SizedBox(height: 8),
          _StatusBox(kind: statusKind, text: statusText),
          const SizedBox(height: 8),
        ],
        if (showReadyAction && widget.onReadyToConnect != null)
          FilledButton.icon(
            key: const ValueKey('onboarding-ready-connect'),
            onPressed: disabled ? null : widget.onReadyToConnect,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Перейти к подключению'),
          ),
        if (recentlyAddedId.isNotEmpty &&
            sources.length > 1 &&
            sources.first.id != recentlyAddedId)
          TextButton(
            key: const ValueKey('new-source-make-primary'),
            onPressed: controlsDisabled
                ? null
                : () => _changeSource(
                    () => widget.bridge.moveVpnSource(recentlyAddedId, 0),
                    'Выбираем подписку…',
                  ),
            child: const Text('Использовать новую подписку'),
          ),
        if (autoSelectSupported && sources.isNotEmpty) ...[
          Semantics(
            checked: sourcesFresh && autoSelect == true,
            inMutuallyExclusiveGroup: true,
            child: ListTile(
              key: const ValueKey('source-auto-select'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                sourcesFresh && autoSelect == true
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: sourcesFresh && autoSelect == true
                    ? _atlasMint
                    : _atlasMuted,
              ),
              title: const Text(
                'Автоматически',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'По отклику между подписками',
                style: TextStyle(color: _atlasMuted, fontSize: 12),
              ),
              onTap: controlsDisabled || autoSelect == true
                  ? null
                  : () => _changeSource(
                      widget.bridge.enableVpnSourceAutoSelect,
                      'Включаем автовыбор…',
                      success:
                          'Автовыбор включён. Сервер внутри подписки сохраняется.',
                      confirmationTitle: 'Включить автовыбор?',
                    ),
            ),
          ),
          const Divider(height: 1, color: _atlasBorder),
        ],
        for (final source in sources)
          _VpnSourceTile(
            key: ValueKey('vpn-source-${source.id}'),
            source: source,
            statusKnown: sourcesFresh && !loading && widget.enabled,
            fallbackSupported: fallbackSupported,
            running: widget.connected ?? running,
            autoSelect: autoSelect,
            primary: source.id == firstEnabled?.id,
            busy: controlsDisabled,
            onEnabled: (value) => _changeSource(
              () => widget.bridge.setVpnSourceEnabled(source.id, value),
              'Сохраняем подписку…',
              leavesDisconnected: !value && _removesLastEnabled(source),
            ),
            onNode: (node) => _selectNode(source, node),
            onSelect: () => _changeSource(
              () => widget.bridge.moveVpnSource(source.id, 0),
              'Выбираем подписку…',
              confirmationTitle: 'Подключиться через «${source.name}»?',
            ),
            onRemove: () => _remove(source),
            onRename: () => _rename(source),
            onRefresh: _refreshSources,
            onFavorite: (nodeId, value) => _favorite(source, nodeId, value),
            favoriteError: () => statusKind == 'error' ? statusText : '',
            onOrder:
                sources.length > 1 &&
                    autoSelect == false &&
                    source.id == firstEnabled?.id
                ? () async {
                    setState(() => showOrder = !showOrder);
                    await WidgetsBinding.instance.endOfFrame;
                    if (mounted &&
                        showOrder &&
                        orderAnchor.currentContext != null) {
                      await Scrollable.ensureVisible(
                        orderAnchor.currentContext!,
                        duration: const Duration(milliseconds: 200),
                      );
                    }
                  }
                : null,
          ),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Отклик — время проверки через VPN, не скорость загрузки.',
            style: TextStyle(color: _atlasMuted, fontSize: 11),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              TextButton.icon(
                key: const ValueKey('refresh-source-lists'),
                onPressed: controlsDisabled ? null : _refreshSources,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить все подписки'),
              ),
            ],
          ),
          if (sources.length > 1 && autoSelect == false && showOrder) ...[
            Text(
              key: orderAnchor,
              fallbackSupported
                  ? 'Первый включённый — основной. Остальные используются при сбое.'
                  : 'Первый включённый используется при подключении.',
              style: const TextStyle(color: _atlasMuted, fontSize: 12),
            ),
            for (var i = 0; i < sources.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      '${i + 1}. ${sources[i].name}${sources[i].disabled ? ' · Выключен' : ''}',
                    ),
                    TextButton(
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
                      child: const Text('Выше'),
                    ),
                    TextButton(
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
                      child: const Text('Ниже'),
                    ),
                  ],
                ),
              ),
          ],
        ],
        if ((sources.isEmpty || showPersonalForm) && free != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: ValueKey('add-public-vpn-${free.id}'),
            onPressed: controlsDisabled ? null : () => _addPublic(free),
            icon: const Icon(Icons.public_outlined),
            label: const Text('Добавить Dropo Free'),
          ),
        ],
        if ((sources.isEmpty || showPersonalForm) && catalogError.isNotEmpty)
          TextButton(
            onPressed: busy ? null : _loadCatalog,
            child: const Text('Dropo Free недоступен · повторить'),
          ),
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
    'Dropo Free временно недоступен' => 'Dropo Free временно недоступен',
    'Используйте название до 80 символов без ссылок и переносов строк.' ||
    'используйте название до 80 символов без ссылок и переносов строк' =>
      'Используйте название до 80 символов без ссылок и переносов строк.',
    'В одном источнике можно сохранить до 64 избранных серверов.' ||
    'в одном источнике можно сохранить до 64 избранных серверов' =>
      'Можно сохранить до 64 избранных серверов в одной подписке. Уберите ненужный сервер и повторите попытку.',
    'VPN key is invalid or unsupported on Android' =>
      'VPN-ключ повреждён или не поддерживается на Android.',
    'VPN subscription could not be downloaded or contains no supported Android servers' =>
      'Не удалось загрузить подписку или в ней нет поддерживаемых серверов для Android.',
    'Could not save Android VPN subscription' =>
      'Не удалось сохранить VPN-подписку на устройстве.',
    'VPN subscription is empty' =>
      'Вставьте HTTPS-ссылку подписки или VPN-ключ.',
    'Выбранный сервер больше недоступен. Обновите список и выберите сервер снова.' ||
    'Сервер не найден. Обновите список.' ||
    'сервер не найден в этом источнике; обновите список' ||
    'Неверный идентификатор сервера. Обновите список.' =>
      'Выбранный сервер больше недоступен. Обновите список и выберите сервер снова.',
    _ when message.isEmpty => 'Не удалось сохранить источник.',
    _ when message.toLowerCase().contains('исчез') =>
      'Выбранного сервера больше нет. Выберите другой.',
    _
        when message.toLowerCase().contains('истек') ||
            message.toLowerCase().contains('истёк') =>
      'Срок подписки истёк. Обновите её у провайдера и повторите проверку.',
    _ =>
      'Не удалось обновить подписку. Проверьте подключение и повторите попытку.',
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

class _VpnSourceTile extends StatefulWidget {
  const _VpnSourceTile({
    super.key,
    required this.source,
    required this.statusKnown,
    required this.fallbackSupported,
    required this.running,
    required this.autoSelect,
    required this.primary,
    required this.busy,
    required this.onEnabled,
    required this.onNode,
    required this.onSelect,
    required this.onRemove,
    required this.onRename,
    required this.onRefresh,
    required this.onFavorite,
    required this.favoriteError,
    this.onOrder,
  });
  final VpnSourceInfo source;
  final bool statusKnown, fallbackSupported, primary, busy;
  final bool? running, autoSelect;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<int> onNode;
  final VoidCallback onSelect, onRemove, onRename, onRefresh;
  final VoidCallback? onOrder;
  final Future<bool> Function(String nodeId, bool favorite) onFavorite;
  final String Function() favoriteError;

  @override
  State<_VpnSourceTile> createState() => _VpnSourceTileState();
}

class _VpnSourceTileState extends State<_VpnSourceTile> {
  bool expanded = false;

  Future<void> _chooseNode() async {
    if (widget.busy || !widget.statusKnown || widget.source.nodeCount < 1) {
      return;
    }
    final before = widget.source;
    // A subscription with one supported server needs no empty selection step.
    if (before.nodeCount == 1) {
      if (before.selectedNode != 0) widget.onNode(0);
      return;
    }
    final result = await showDialog<int>(
      context: context,
      builder: (_) => VpnNodePicker(
        source: before,
        onFavorite: widget.onFavorite,
        favoriteError: widget.favoriteError,
      ),
    );
    if (!mounted || widget.busy || !widget.statusKnown || result == null) {
      return;
    }
    final stableId = result < before.nodeIds.length
        ? before.nodeIds[result]
        : null;
    final currentIndex = stableId == null
        ? result
        : widget.source.nodeIds.indexOf(stableId);
    if (currentIndex < 0 ||
        currentIndex >= widget.source.nodeCount ||
        currentIndex == widget.source.selectedNode) {
      return;
    }
    if (stableId == null &&
        (currentIndex >= before.nodeNames.length ||
            currentIndex >= widget.source.nodeNames.length ||
            before.nodeNames[currentIndex] !=
                widget.source.nodeNames[currentIndex])) {
      return;
    }
    widget.onNode(currentIndex);
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
    final missing =
        source.selectedNode < 0 || source.selectedNode >= source.nodeCount;
    final node =
        source.selectedNode >= 0 &&
            source.selectedNode < source.nodeNames.length
        ? source.nodeNames[source.selectedNode]
        : source.nodeCount == 0
        ? 'Серверы не загружены'
        : 'Выберите доступный сервер';
    final state = !widget.statusKnown
        ? 'Статус уточняется'
        : source.disabled
        ? 'Выключен'
        : active
        ? 'Подключён сейчас'
        : selected
        ? widget.running == true
              ? 'Выбран для следующего подключения'
              : 'Выбран для подключения'
        : widget.autoSelect == true
        ? 'Доступен для автовыбора'
        : widget.fallbackSupported
        ? 'Резервный'
        : 'Доступен для выбора';
    final response = !widget.statusKnown || widget.running == null
        ? 'Нет данных'
        : source.disabled
        ? 'Выключен'
        : widget.running != true
        ? 'После подключения'
        : source.response.label;
    final problem = source.lastError.isNotEmpty
        ? missing && source.nodeCount > 0
              ? 'Выбранного сервера больше нет. Выберите другой.'
              : source.usingCache
              ? 'Не удалось обновить список. Сохранённые серверы остаются доступны.'
              : _friendlyVpnSourceError(source.lastError)
        : missing && source.nodeCount > 0
        ? 'Выберите доступный сервер.'
        : '';
    return Container(
      key: ValueKey('source-row-surface-${source.id}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _atlasBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  checked: selected,
                  inMutuallyExclusiveGroup: true,
                  child: TextButton(
                    key: ValueKey('vpn-source-first-${source.id}'),
                    onPressed: widget.busy || source.disabled || selected
                        ? null
                        : widget.onSelect,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      alignment: Alignment.centerLeft,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: selected ? _atlasMint : _atlasMuted,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                source.name,
                                style: const TextStyle(
                                  color: _atlasText,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                state,
                                style: TextStyle(
                                  color: active ? _atlasMint : _atlasMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(
                key: PageStorageKey('source-details-${source.id}'),
                onPressed: () => setState(() => expanded = !expanded),
                style: TextButton.styleFrom(
                  foregroundColor: _atlasMuted,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                child: const Text('Ещё'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 34),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (source.nodeCount > 1 || missing && source.nodeCount > 0)
                  TextButton.icon(
                    key: ValueKey('choose-vpn-node-${source.id}'),
                    onPressed: widget.busy ? null : _chooseNode,
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      minimumSize: const Size(48, 44),
                    ),
                    icon: const Icon(Icons.public_outlined, size: 16),
                    label: Text(
                      node,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      source.nodeCount == 1
                          ? '$node · единственный сервер'
                          : node,
                      style: const TextStyle(color: _atlasMuted, fontSize: 12),
                    ),
                  ),
                Text(
                  'Отклик · $response',
                  key: ValueKey('source-response-${source.id}'),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: source.response.current ? 'monospace' : 'Inter',
                    color: active && source.response.current
                        ? _atlasMint
                        : _atlasMuted,
                  ),
                ),
              ],
            ),
          ),
          if (source.publicCatalogId == 'vpn-checker-ru-part9')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Старый публичный список больше не предлагается. Сохранённый источник можно удалить через «Ещё».',
                style: TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
              ),
            ),
          if (problem.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              problem,
              key: ValueKey('source-problem-${source.id}'),
              style: const TextStyle(color: Color(0xFFFFD38B), fontSize: 12),
            ),
            TextButton(
              key: ValueKey('source-recover-${source.id}'),
              onPressed: widget.busy
                  ? null
                  : missing && source.nodeCount > 0
                  ? _chooseNode
                  : widget.onRefresh,
              child: Text(
                missing && source.nodeCount > 0
                    ? 'Выбрать сервер'
                    : 'Обновить все подписки',
              ),
            ),
          ],
          if (expanded) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  key: ValueKey('rename-source-${source.id}'),
                  onPressed: widget.busy ? null : widget.onRename,
                  child: const Text('Переименовать'),
                ),
                TextButton(
                  onPressed: widget.busy ? null : widget.onRefresh,
                  child: const Text('Обновить все подписки'),
                ),
                TextButton(
                  key: ValueKey('remove-source-${source.id}'),
                  onPressed: widget.busy ? null : widget.onRemove,
                  child: const Text('Удалить'),
                ),
                if (widget.onOrder != null)
                  TextButton.icon(
                    key: const ValueKey('source-order'),
                    onPressed: widget.busy ? null : widget.onOrder,
                    icon: const Icon(Icons.reorder, size: 18),
                    label: const Text('Порядок резерва'),
                  ),
              ],
            ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Использовать подписку',
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
              '${_vpnServerCountLabel(source.nodeCount)}. Сервер внутри подписки выбираете вы; резерв — другие подписки.',
              style: const TextStyle(color: _atlasMuted, fontSize: 12),
            ),
            if (source.lastUpdated.isNotEmpty)
              Text(
                'Список обновлён: ${source.lastUpdated}',
                style: const TextStyle(color: _atlasMuted, fontSize: 11),
              ),
          ],
        ],
      ),
    );
  }
}

/// Source-local stable IDs back favorites and the committed server choice.
class VpnNodePicker extends StatefulWidget {
  const VpnNodePicker({
    super.key,
    required this.source,
    this.onFavorite,
    this.favoriteError,
  });
  final VpnSourceInfo source;
  final Future<bool> Function(String nodeId, bool favorite)? onFavorite;
  final String Function()? favoriteError;

  @override
  State<VpnNodePicker> createState() => _VpnNodePickerState();
}

class _VpnNodePickerState extends State<VpnNodePicker> {
  String query = '', error = '';
  late final Set<String> favorites = widget.source.favoriteNodeIds.toSet();
  final Set<String> pending = {};

  String name(int index) => index < widget.source.nodeNames.length
      ? widget.source.nodeNames[index]
      : 'Сервер ${index + 1}';
  String? nodeId(int index) =>
      index < widget.source.nodeIds.length &&
          widget.source.nodeIds[index].isNotEmpty
      ? widget.source.nodeIds[index]
      : null;

  Future<void> _favorite(int index) async {
    final id = nodeId(index);
    if (id == null || pending.isNotEmpty || widget.onFavorite == null) return;
    final next = !favorites.contains(id);
    setState(() {
      pending.add(id);
      error = '';
    });
    try {
      final saved = await widget.onFavorite!(id, next);
      if (!mounted) return;
      setState(() {
        if (saved) {
          if (next) {
            favorites.add(id);
          } else {
            favorites.remove(id);
          }
        } else {
          final message = widget.favoriteError?.call() ?? '';
          error = message.contains('64 избранных')
              ? message
              : 'Не удалось сохранить избранное. Повторите попытку.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось сохранить избранное. Повторите попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => pending.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = [
      for (var i = 0; i < widget.source.nodeCount; i++)
        if (query.isEmpty ||
            name(i).toLowerCase().contains(query.toLowerCase()))
          i,
    ];
    final current = matches
        .where((index) => index == widget.source.selectedNode)
        .toList();
    final favorite = matches
        .where(
          (index) =>
              index != widget.source.selectedNode &&
              favorites.contains(nodeId(index)),
        )
        .toList();
    final others = matches
        .where(
          (index) =>
              index != widget.source.selectedNode &&
              !favorites.contains(nodeId(index)),
        )
        .toList();
    final rows = <({String? title, int? node})>[
      if (query.isEmpty && current.isNotEmpty)
        (title: 'Выбранный сервер', node: null),
      for (final node in current) (title: null, node: node),
      if (query.isEmpty && favorite.isNotEmpty)
        (title: 'Избранное', node: null),
      for (final node in favorite) (title: null, node: node),
      if (query.isEmpty && others.isNotEmpty)
        (title: 'Все серверы', node: null),
      for (final node in others) (title: null, node: node),
    ];
    final size = MediaQuery.sizeOf(context);
    final mobile = _isMobileShell || size.width < 600;
    return Dialog(
      backgroundColor: const Color(0xFF101815),
      insetPadding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 32,
        vertical: 20,
      ),
      child: SizedBox(
        width: mobile ? double.infinity : 540,
        height: (size.height - MediaQuery.viewInsetsOf(context).bottom - 48)
            .clamp(180, mobile ? 720 : 640)
            .toDouble(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _atlasText,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Semantics(
                    label: 'Закрыть выбор сервера',
                    button: true,
                    child: IconButton(
                      key: const ValueKey('vpn-node-close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('vpn-node-search'),
                autofocus: false,
                decoration: const InputDecoration(
                  labelText: 'Поиск сервера или страны',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => query = value.trim()),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('vpn-node-list'),
                  itemCount: rows.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            matches.isEmpty
                                ? 'Серверы не найдены'
                                : 'Найдено: ${matches.length}',
                            style: const TextStyle(
                              color: _atlasMuted,
                              fontSize: 12,
                            ),
                          ),
                          if (error.isNotEmpty)
                            Text(
                              error,
                              style: const TextStyle(
                                color: Color(0xFFFFD38B),
                                fontSize: 12,
                              ),
                            ),
                        ],
                      );
                    }
                    if (index == rows.length + 1) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'Названия указаны провайдером. Значения в названиях — не замер Dropo.',
                          style: TextStyle(color: _atlasMuted, fontSize: 11),
                        ),
                      );
                    }
                    final item = rows[index - 1];
                    if (item.node == null) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 4),
                        child: Text(
                          item.title!,
                          style: const TextStyle(
                            color: _atlasMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    }
                    final node = item.node!;
                    final selected = node == widget.source.selectedNode;
                    final id = nodeId(node);
                    return ListTile(
                      key: ValueKey('vpn-node-$node'),
                      contentPadding: EdgeInsets.zero,
                      selected: selected,
                      leading: Icon(
                        selected
                            ? Icons.check_circle_outline
                            : Icons.public_outlined,
                        size: 20,
                        color: selected ? _atlasMint : _atlasMuted,
                      ),
                      title: Text(
                        name(node),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _atlasText, fontSize: 14),
                      ),
                      trailing: id == null || widget.onFavorite == null
                          ? null
                          : Semantics(
                              label: favorites.contains(id)
                                  ? 'Убрать ${name(node)} из избранного'
                                  : 'Добавить ${name(node)} в избранное',
                              button: true,
                              child: IconButton(
                                key: ValueKey('vpn-node-favorite-$id'),
                                onPressed: pending.isEmpty
                                    ? () => _favorite(node)
                                    : null,
                                icon: Icon(
                                  favorites.contains(id)
                                      ? Icons.star
                                      : Icons.star_border,
                                  color: favorites.contains(id)
                                      ? _atlasMint
                                      : _atlasMuted,
                                ),
                              ),
                            ),
                      onTap: pending.isNotEmpty
                          ? null
                          : () => Navigator.pop(context, node),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameVpnSourceDialog extends StatefulWidget {
  const _RenameVpnSourceDialog({required this.initialName});
  final String initialName;
  @override
  State<_RenameVpnSourceDialog> createState() => _RenameVpnSourceDialogState();
}

class _RenameVpnSourceDialogState extends State<_RenameVpnSourceDialog> {
  late final name = TextEditingController(text: widget.initialName);
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void save() {
    final value = name.text.trim();
    if (value.isEmpty) {
      setState(() => error = 'Введите название');
      return;
    }
    if (RegExp(
      r'[a-z][a-z0-9+.-]*://|[\x00-\x1f\x7f]',
      caseSensitive: false,
    ).hasMatch(value)) {
      setState(() => error = 'Введите название без ссылок и переносов строк');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Название подписки'),
    scrollable: true,
    content: TextField(
      key: const ValueKey('source-rename-input'),
      controller: name,
      autofocus: true,
      maxLength: 80,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(labelText: 'Название', errorText: error),
      onSubmitted: (_) => save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const ValueKey('source-rename-save'),
        onPressed: save,
        child: const Text('Сохранить'),
      ),
    ],
  );
}
