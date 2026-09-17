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
    this.sourceSnapshot,
  });

  final CoreBridge bridge;
  final SubscriptionInfo subscription;
  final bool embedded, enabled;
  final VoidCallback? onChanged;
  final ValueChanged<bool>? onBusyChanged;
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
    }
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.bridge.vpnSources().timeout(
        const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() {
          sources = loaded;
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
    }
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
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _changeSource(
    Future<Map<String, dynamic>> Function() operation,
    String progress, {
    String success = 'Настройки источников сохранены.',
  }) async {
    if (busy || !widget.enabled) return;
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = progress;
    });
    try {
      final result = await operation();
      if (result['success'] == true) widget.onChanged?.call();
      if (!mounted) return;
      if (result['success'] != true) {
        throw StateError(
          result['error']?.toString() ?? 'Не удалось сохранить источник',
        );
      }
      setState(() {
        statusKind = 'success';
        statusText = success;
      });
      await _load();
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
  }

  Future<void> _addPersonal() async {
    final uri = controller.text.trim();
    if (uri.isEmpty) {
      setState(() {
        statusKind = 'error';
        statusText = 'Вставьте ссылку на подписку или VPN-ключ.';
      });
      return;
    }
    final name = nameController.text.trim();
    await _changeSource(
      () async {
        final check = await widget.bridge.testSubscription(uri);
        if (check['success'] != true) return check;
        final result = await widget.bridge.addVpnSource(
          name.isEmpty
              ? 'Мой VPN ${sources.where((s) => !s.isPublic).length + 1}'
              : name,
          uri,
        );
        if (mounted && result['success'] == true) {
          controller.clear();
          nameController.clear();
          setState(() => showPersonalForm = false);
        }
        return result;
      },
      'Проверяем и добавляем вашу подписку…',
      success: 'Подписка добавлена перед бесплатным резервом.',
    );
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
    final disabled = busy || loading || !widget.enabled;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Своя подписка или бесплатный резерв',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Сначала используются ваши подписки, затем — включённый бесплатный источник. '
          'Переключение происходит только при недоступности текущего источника.',
          style: TextStyle(color: Color(0xFFB4C9C1), fontSize: 13),
        ),
        const SizedBox(height: 8),
        const Text(
          'Изменения источников переподключат активный VPN. '
          'Выбранные маршруты сервисов не меняются.',
          style: TextStyle(color: Color(0xFF9CAEA8), fontSize: 12),
        ),
        if (busy || loading) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (!widget.enabled)
          const Text(
            'Управление временно недоступно. Дождитесь связи с ядром и завершения подключения.',
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
        const SizedBox(height: 18),
        const _VpnSectionTitle('Мои источники · в порядке приоритета'),
        if (!loading && sourcesFresh && sources.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Пока нет источников. Добавьте свою подписку или выберите бесплатный вариант ниже.',
              style: TextStyle(color: Color(0xFFB4C9C1)),
            ),
          ),
        for (var i = 0; i < sources.length; i++)
          _VpnSourceTile(
            key: ValueKey('vpn-source-${sources[i].id}'),
            source: sources[i],
            statusKnown: widget.enabled && sourcesFresh && !loading,
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
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('add-personal-vpn'),
              onPressed: disabled
                  ? null
                  : () => setState(() => showPersonalForm = !showPersonalForm),
              icon: Icon(showPersonalForm ? Icons.expand_less : Icons.add_link),
              label: Text(
                showPersonalForm ? 'Скрыть форму' : 'Добавить свою подписку',
              ),
            ),
            if (sources.isNotEmpty)
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
          const SizedBox(height: 10),
          TextField(
            controller: nameController,
            enabled: !disabled,
            decoration: _fieldDecoration(
              hint: 'Название, например «Моя подписка»',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            enabled: !disabled,
            minLines: 1,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
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
                        }
                      },
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: disabled ? null : _addPersonal,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Проверить и добавить'),
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
        const Text(
          'Внутри источника используется один выбранный сервер. '
          'Если он не работает, выберите другой вручную. Автоперебора серверов нет.',
          style: TextStyle(color: Color(0xFF9CAEA8), fontSize: 12),
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
    final state = !statusKnown
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
            '${source.isPublic ? 'Бесплатный · последний резерв' : 'Приоритет ${index + 1} · личный источник'} · $state',
            style: const TextStyle(color: Color(0xFFB4C9C1), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            child: ListTile(
              key: ValueKey('choose-vpn-node-${source.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(node, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${source.nodeCount} серверов · выбрать вручную'),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy || source.nodeCount < 1
                  ? null
                  : () async {
                      final result = await showDialog<int>(
                        context: context,
                        builder: (context) => VpnNodePicker(source: source),
                      );
                      if (result != null && result != selected) onNode(result);
                    },
            ),
          ),
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
              if (!source.isPublic) ...[
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
