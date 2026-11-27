part of 'main.dart';

class _SettingsBreadcrumbs extends StatelessWidget {
  const _SettingsBreadcrumbs({
    required this.sections,
    required this.labels,
    required this.onSelect,
  });

  final List<String> sections;
  final Map<String, String> labels;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontFamily: 'Inter',
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    const separator = Icon(Icons.chevron_right, size: 14, color: _atlasMuted);
    final titles = [
      for (final section in sections)
        _uiText(context, labels[section] ?? section),
    ];
    final widths = [
      for (final title in titles)
        (TextPainter(
              text: TextSpan(text: title, style: style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
            )..layout()).width.ceilToDouble() +
            12,
    ];
    Widget item(int index) {
      final current = index == sections.length - 1;
      return TextButton(
        key: ValueKey('breadcrumb-${sections[index]}'),
        style: TextButton.styleFrom(
          textStyle: style,
          disabledForegroundColor: current ? _atlasText : _atlasMuted,
          foregroundColor: _atlasMuted,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: current || onSelect == null
            ? null
            : () => onSelect!(sections[index]),
        child: Text(
          titles[index],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const menuWidth = 40.0;
        const chevronWidth = 14.0;
        if (widths.reduce((a, b) => a + b) +
                chevronWidth * (widths.length - 1) <=
            constraints.maxWidth) {
          return Row(
            children: [
              for (var index = 0; index < sections.length; index++) ...[
                if (index > 0) separator,
                SizedBox(width: widths[index], child: item(index)),
              ],
            ],
          );
        }
        var shownFrom = sections.length;
        var used = widths.first + chevronWidth + menuWidth;
        while (shownFrom > 2 &&
            used + chevronWidth + widths[shownFrom - 1] <=
                constraints.maxWidth) {
          shownFrom--;
          used += chevronWidth + widths[shownFrom];
        }
        return Row(
          children: [
            Flexible(child: item(0)),
            separator,
            SizedBox(
              width: menuWidth,
              child: PopupMenuButton<String>(
                key: const ValueKey('breadcrumb-overflow'),
                tooltip: _tr(
                  context,
                  'Другие разделы пути',
                  'More sections in the path',
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz, size: 20),
                enabled: onSelect != null,
                onSelected: onSelect,
                itemBuilder: (context) => [
                  for (var index = 1; index < shownFrom; index++)
                    PopupMenuItem(
                      value: sections[index],
                      enabled: index != sections.length - 1,
                      child: Text(titles[index]),
                    ),
                ],
              ),
            ),
            for (var index = shownFrom; index < sections.length; index++) ...[
              separator,
              SizedBox(width: widths[index], child: item(index)),
            ],
          ],
        );
      },
    );
  }
}

/// One navigation row, shared by the connection screen and settings hubs.
/// Navigating never changes a saved route or starts a network operation.
class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.section,
    required this.title,
    required this.icon,
    required this.onPressed,
    this.detail,
  });
  final String section, title;
  final String? detail;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: ListTile(
      key: ValueKey('link-$section'),
      enabled: onPressed != null,
      mouseCursor: onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onTap: onPressed,
      minTileHeight: 48,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(icon, size: 24, color: _atlasMuted),
      title: Text(
        _uiText(context, title),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      subtitle: detail == null
          ? null
          : Text(
              _uiText(context, detail!),
              style: const TextStyle(
                fontSize: 13,
                color: _atlasMuted,
                height: 1.4,
              ),
            ),
      trailing: const Icon(Icons.chevron_right, size: 20, color: _atlasMuted),
    ),
  );
}

class _MinimalSettingsPage extends StatelessWidget {
  const _MinimalSettingsPage({
    required this.section,
    required this.disabled,
    required this.onSelect,
    required this.onWorkNetworks,
  });
  final String section;
  final bool disabled;
  final ValueChanged<String> onSelect;
  final VoidCallback? onWorkNetworks;

  @override
  Widget build(BuildContext context) {
    final entries = switch (section) {
      'advanced' => <(String, String, String, IconData)>[
        if (!_isMobileShell)
          (
            'profiles',
            'Профили',
            'Сохранённые конфигурации подключения',
            Icons.layers_outlined,
          ),
        if (!_isMobileShell)
          (
            'work',
            'Рабочие сети',
            'Защищённый доступ к частным сетям',
            Icons.hub_outlined,
          ),
        (
          'technical-settings',
          'Сеть и диагностика',
          'Логирование, проверка сервисов и компоненты',
          Icons.tune,
        ),
        if (_isMobileShell)
          (
            'dropo_space',
            'Dropo Space',
            'Совместимость приложений на Android',
            Icons.workspaces_outline,
          ),
      ],
      'help' => <(String, String, String, IconData)>[
        (
          'guided-help',
          'Решить проблему',
          'Нет интернета, не открывается сервис или не получается обновиться',
          Icons.help_outline,
        ),
        (
          'logs',
          'Диагностика',
          'Журнал и данные для решения проблем',
          Icons.monitor_heart_outlined,
        ),
        (
          'stats',
          'Статистика',
          'Трафик текущего подключения',
          Icons.bar_chart_rounded,
        ),
        (
          'about',
          'О приложении',
          'Версия, проект и лицензии',
          Icons.info_outline,
        ),
      ],
      _ => <(String, String, String, IconData)>[
        (
          'app-settings',
          'Приложение',
          _isMobileShell
              ? 'Оформление и обновления'
              : 'Автозапуск и обновления',
          Icons.settings_outlined,
        ),
        (
          'advanced',
          'Дополнительно',
          _isMobileShell
              ? 'Маршруты, диагностика и совместимость'
              : 'Обход, профили и рабочие сети',
          Icons.shield_outlined,
        ),
        (
          'manual-routing',
          'Списки маршрутизации',
          'Приложения, защита от блокировок, домены и IP-адреса',
          Icons.tune,
        ),
        ('help', 'Помощь', 'Решение проблем и диагностика', Icons.help_outline),
      ],
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView.separated(
          key: ValueKey('$section-section'),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final (target, title, detail, icon) = entries[index];
            return _SettingsLink(
              section: target,
              title: title,
              detail: detail,
              icon: icon,
              onPressed: disabled
                  ? null
                  : switch (target) {
                      'work' => onWorkNetworks,
                      _ => () => onSelect(target),
                    },
            );
          },
        ),
      ),
    );
  }
}

class _VPNOnlyServicesPage extends StatefulWidget {
  const _VPNOnlyServicesPage({required this.bridge, this.inline = false});
  final bool inline;
  final CoreBridge bridge;

  @override
  State<_VPNOnlyServicesPage> createState() => _VPNOnlyServicesPageState();
}

class _VPNOnlyServicesPageState extends State<_VPNOnlyServicesPage> {
  late Future<List<RouteService>> catalog = widget.bridge.routes();
  late Future<Map<String, dynamic>> protection = widget.bridge.appConfig();
  bool savingProtection = false;
  String protectionError = '';
  String serviceError = '';
  String? expandedService;

  Future<void> _editCustomService([_CustomVPNService? service]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CustomVPNServiceDialog(
        service: service,
        onSave: (name, domains) async {
          final result = await widget.bridge.callMap(
            'SetCustomVPNService',
            args: [service?.id ?? '', name, domains, false],
          );
          if (result['success'] != true) {
            throw StateError(
              result['error']?.toString() ?? 'Ошибка сохранения',
            );
          }
        },
      ),
    );
    if (changed == true && mounted) {
      setState(() {
        serviceError = '';
        protection = widget.bridge.appConfig();
      });
    }
  }

  Future<void> _removeCustomService(_CustomVPNService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Удалить сервис?', 'Remove service?')),
        content: Text(service.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_uiText(context, 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_uiText(context, 'Удалить')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await widget.bridge.callMap(
        'SetCustomVPNService',
        args: [service.id, '', '', true],
      );
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Ошибка сохранения');
      }
      if (mounted) {
        setState(() {
          serviceError = '';
          protection = widget.bridge.appConfig();
        });
      }
    } catch (error) {
      if (mounted) setState(() => serviceError = _cleanError(error));
    }
  }

  Future<void> _setProtection(bool enabled) async {
    setState(() {
      savingProtection = true;
      protectionError = '';
    });
    try {
      final result = await widget.bridge.callMap(
        'SetProtectedRouting',
        args: [enabled],
      );
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Ошибка сохранения');
      }
      if (mounted) {
        setState(() {
          protection = widget.bridge.appConfig();
        });
      }
    } catch (error) {
      if (mounted) setState(() => protectionError = _cleanError(error));
    } finally {
      if (mounted) setState(() => savingProtection = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final add = _CatalogAddButton(
      buttonKey: const ValueKey('add-custom-vpn-service'),
      label: 'Добавить сервис',
      onPressed: _editCustomService,
    );
    final content = FutureBuilder<List<RouteService>>(
      future: catalog,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return TextButton(
            onPressed: () => setState(() {
              catalog = widget.bridge.routes();
            }),
            child: Text(_uiText(context, 'Повторить загрузку')),
          );
        }
        final services = (snapshot.data ?? []).where((s) => s.vpnOnly).toList()
          ..sort((a, b) => _homeRouteName(a).compareTo(_homeRouteName(b)));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _uiText(
                  context,
                  'Пассивная защита от блокировок при потере соединения с VPN.',
                ),
                style: const TextStyle(
                  color: _atlasMuted,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.windows)
              FutureBuilder<Map<String, dynamic>>(
                future: protection,
                builder: (context, protectionSnapshot) {
                  final settings = protectionSnapshot.data;
                  final enabled = settings?['protectedRoutingEnabled'] != false;
                  final ready = settings?['protectedRoutingReady'] == true;
                  final message = protectionError.isNotEmpty
                      ? protectionError
                      : settings?['protectedRoutingError']?.toString() ?? '';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile.adaptive(
                        key: const ValueKey('protect-vpn-only-when-off'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Защищать сервисы при выключенном VPN',
                        ),
                        subtitle: Text(
                          enabled && settings != null && !ready
                              ? 'Локальный маршрутизатор недоступен'
                              : 'Обычные сайты открываются напрямую',
                        ),
                        value: enabled,
                        onChanged: savingProtection || settings == null
                            ? null
                            : _setProtection,
                      ),
                      if (message.isNotEmpty) Text(message),
                      const Divider(height: 1, color: _atlasBorder),
                    ],
                  );
                },
              ),
            FutureBuilder<Map<String, dynamic>>(
              future: protection,
              builder: (context, snapshot) {
                final raw = snapshot.data?['customVPNServices'];
                final custom = raw is List
                    ? raw.whereType<Map>().map(_CustomVPNService.fromJson)
                    : const <_CustomVPNService>[];
                return Column(
                  children: [
                    if (serviceError.isNotEmpty) Text(serviceError),
                    for (final service in custom)
                      _CatalogRow(
                        key: ValueKey('custom-vpn-${service.id}'),
                        icon: const Icon(
                          Icons.shield_outlined,
                          color: _atlasMint,
                        ),
                        title: service.name,
                        subtitle: service.domains.join(', '),
                        actions: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: _tr(context, 'Редактировать', 'Edit'),
                              onPressed: () => _editCustomService(service),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: _uiText(context, 'Удалить'),
                              onPressed: () => _removeCustomService(service),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            for (final service in services)
              _CatalogRow(
                rowKey: ValueKey('vpn-only-${service.tag}'),
                title: _homeRouteName(service),
                icon: _ServiceBrandIcon(tag: service.tag),
                expanded: expandedService == service.tag,
                badge: 'VPN',
                accentBadge: true,
                onTap: () => setState(
                  () => expandedService = expandedService == service.tag
                      ? null
                      : service.tag,
                ),
                detail: expandedService == service.tag
                    ? Padding(
                        padding: const EdgeInsets.only(left: 46, bottom: 12),
                        child: SelectableText(
                          [
                            ...service.domainSuffixes,
                            ...service.processNames,
                          ].join(', '),
                          style: const TextStyle(
                            color: _atlasMuted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      )
                    : null,
              ),
          ],
        );
      },
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [content, add],
    );
    return widget.inline
        ? body
        : _FeaturePage(
            title: _uiText(context, 'Защита от блокировок'),
            icon: Icons.public_outlined,
            child: body,
          );
  }
}

class _CustomVPNService {
  const _CustomVPNService(this.id, this.name, this.domains);

  factory _CustomVPNService.fromJson(Map json) => _CustomVPNService(
    json['id']?.toString() ?? '',
    json['name']?.toString() ?? '',
    (json['domains'] as List? ?? const []).whereType<String>().toList(),
  );

  final String id, name;
  final List<String> domains;
}

class _CustomVPNServiceDialog extends StatefulWidget {
  const _CustomVPNServiceDialog({required this.service, required this.onSave});

  final _CustomVPNService? service;
  final Future<void> Function(String name, String domains) onSave;

  @override
  State<_CustomVPNServiceDialog> createState() =>
      _CustomVPNServiceDialogState();
}

class _CustomVPNServiceDialogState extends State<_CustomVPNServiceDialog> {
  late final name = TextEditingController(text: widget.service?.name);
  late final domains = TextEditingController(
    text: widget.service?.domains.join('\n'),
  );
  bool saving = false;
  String error = '';

  @override
  void dispose() {
    name.dispose();
    domains.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      await widget.onSave(name.text, domains.text);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          saving = false;
          error = _cleanError(failure);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.service == null
          ? _tr(context, 'Добавить сервис', 'Add service')
          : _tr(context, 'Редактировать сервис', 'Edit service'),
    ),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('custom-vpn-name'),
            controller: name,
            autofocus: true,
            enabled: !saving,
            decoration: InputDecoration(
              labelText: _tr(context, 'Название', 'Name'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('custom-vpn-domains'),
            controller: domains,
            enabled: !saving,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: _tr(context, 'Домены сервиса', 'Service domains'),
              hintText: 'example.org',
              helperText: _tr(
                context,
                'С новой строки или через запятую',
                'One per line or comma-separated',
              ),
              helperMaxLines: 2,
            ),
          ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: Text(_uiText(context, 'Отмена')),
      ),
      FilledButton(
        key: const ValueKey('save-custom-vpn-service'),
        onPressed: saving ? null : _save,
        child: Text(_uiText(context, 'Сохранить')),
      ),
    ],
  );
}
