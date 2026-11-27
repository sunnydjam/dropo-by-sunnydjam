part of 'main.dart';

// The home anchor reserves the tabs’ height in both routing modes;
// hiding services therefore never rescales the Earth or the mode selector.
double _homeServicesHeaderExtent(BuildContext context) => math.max(
  _compactDesktopHome(context) ? 48 : 56,
  MediaQuery.textScalerOf(context).scale(17) * 1.2 +
      (_compactDesktopHome(context) ? 16 : 24),
);

enum _RoutingTab {
  apps('Приложения'),
  protected('Защита от блокировок'),
  domains('Домены и IP-адреса');

  const _RoutingTab(this.label);
  final String label;
}

/// Home owns the scroll position; neither the catalog nor a service detail
/// creates a nested scrollable or an independent tinted surface.
class _HomeRoutingCatalog extends StatefulWidget {
  const _HomeRoutingCatalog({
    super.key,
    required this.bridge,
    required this.connected,
    required this.enabled,
    required this.routingMode,
    required this.onBusyChanged,
    this.onChanged,
    this.routeSnapshot,
  });

  final CoreBridge bridge;
  final bool connected, enabled;
  final String routingMode;
  final ValueChanged<bool> onBusyChanged;
  final VoidCallback? onChanged;
  final List<RouteService>? routeSnapshot;

  @override
  State<_HomeRoutingCatalog> createState() => _HomeRoutingCatalogState();
}

class _HomeRoutingCatalogState extends State<_HomeRoutingCatalog>
    with SingleTickerProviderStateMixin {
  late final tabs = TabController(
    length: _RoutingTab.values.length,
    vsync: this,
  );

  final search = TextEditingController();
  List<RouteService> services = const [];
  bool loading = false, busy = false, pinnedOnly = true;
  String loadError = '', feedback = '';
  String? openServiceTag;
  int loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.routeSnapshot != null) {
      services = widget.routeSnapshot!.where((s) => !s.vpnOnly).toList();
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    ++loadGeneration;
    tabs.dispose();
    search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HomeRoutingCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!busy &&
        widget.routeSnapshot != null &&
        !identical(oldWidget.routeSnapshot, widget.routeSnapshot)) {
      ++loadGeneration;
      services = widget.routeSnapshot!.where((s) => !s.vpnOnly).toList();
      loading = false;
      loadError = '';
    } else if (!busy &&
        (oldWidget.connected != widget.connected ||
            (!oldWidget.enabled && widget.enabled))) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++loadGeneration;
    final connected = widget.connected;
    setState(() {
      loading = true;
      loadError = '';
    });
    try {
      final result = await widget.bridge
          .routes(live: connected)
          .timeout(const Duration(seconds: 10));
      if (mounted && generation == loadGeneration) {
        setState(() => services = result.where((s) => !s.vpnOnly).toList());
      }
    } catch (error) {
      if (mounted && generation == loadGeneration) {
        setState(() => loadError = _cleanError(error));
      }
    } finally {
      if (mounted && generation == loadGeneration) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _change(
    Future<Map<String, dynamic>> Function() action, {
    bool routeChange = true,
  }) async {
    if (busy || loading || !widget.enabled || loadError.isNotEmpty) return;
    setState(() {
      busy = true;
      feedback = 'Сохраняем…';
    });
    final onBusyChanged = widget.onBusyChanged;
    onBusyChanged(true);
    try {
      final result = await action();
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Не удалось сохранить');
      }
      if (!mounted) return;
      widget.onChanged?.call();
      setState(
        () => feedback = !routeChange
            ? 'Список сохранён.'
            : widget.routingMode == 'all_traffic'
            ? 'Сохранено. Применится в режиме «Ручное».'
            : result['applied'] == true
            ? 'Маршрут применён.'
            : result['restarted'] == true
            ? 'Сохранено. VPN переподключён.'
            : 'Сохранено. Применится при подключении.',
      );
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => feedback = 'Не удалось сохранить: ${_cleanError(error)}',
        );
      }
    } finally {
      onBusyChanged(false);
      if (mounted) setState(() => busy = false);
    }
  }

  bool _pinned(RouteService service) =>
      service.homeVisible || isPrimaryHomeRouteService(service.tag);

  List<RouteService> get _filtered {
    final query = search.text.trim().toLowerCase();
    // Search addresses the full catalog, even when its quick tab was selected.
    // Otherwise a domain search can misleadingly hide an unpinned service.
    final filtered = services.where((service) {
      if (query.isEmpty && pinnedOnly && !_pinned(service)) return false;
      return '${_homeRouteName(service)} ${service.tag} ${service.domainSuffixes.join(' ')}'
          .toLowerCase()
          .contains(query);
    }).toList();
    final primaryOrder = primaryHomeRouteServiceTags.toList();
    filtered.sort((a, b) {
      final aIndex = primaryOrder.indexOf(a.tag);
      final bIndex = primaryOrder.indexOf(b.tag);
      final order =
          (aIndex < 0 ? primaryOrder.length : aIndex) -
          (bIndex < 0 ? primaryOrder.length : bIndex);
      return order != 0
          ? order
          : _homeRouteName(a).compareTo(_homeRouteName(b));
    });
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, bounds) {
              final scroll =
                  bounds.maxWidth < MediaQuery.textScalerOf(context).scale(290);
              return TabBar(
                controller: tabs,
                isScrollable: scroll,
                tabAlignment: scroll ? TabAlignment.start : TabAlignment.fill,
                indicatorColor: _atlasMint,
                labelColor: _atlasMint,
                unselectedLabelColor: _atlasMuted,
                dividerColor: _atlasBorder,
                labelPadding: EdgeInsets.symmetric(horizontal: scroll ? 12 : 4),
                tabs: [
                  for (final tab in _RoutingTab.values)
                    Tab(
                      key: ValueKey('routing-tab-${tab.name}'),
                      child: Text(
                        _uiText(context, tab.label),
                        textAlign: TextAlign.center,
                        maxLines: scroll ? 1 : 2,
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: tabs,
            builder: (context, _) {
              final tab = _RoutingTab.values[tabs.index];
              return switch (tab) {
                _RoutingTab.apps => _applications(),
                _RoutingTab.protected => _VPNOnlyServicesPage(
                  bridge: widget.bridge,
                  inline: true,
                ),
                _RoutingTab.domains => _BlockedCatalogPage(
                  bridge: widget.bridge,
                  inline: true,
                ),
              };
            },
          ),
        ],
      ),
    );
  }

  Widget _applications() {
    final pinnedCount = services.where(_pinned).length;
    final available = widget.enabled && !busy && !loading && loadError.isEmpty;
    final filtered = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('service-search'),
          controller: search,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: _atlasText, fontSize: 14),
          decoration: _catalogSearchDecoration(
            'Найти приложение или домен',
            onClear: search.text.isEmpty ? null : () => setState(search.clear),
          ),
        ),
        Row(
          children: [
            _tab('services-pinned', 'Закреплённые $pinnedCount', true),
            const SizedBox(width: 12),
            _tab('services-all', 'Все ${services.length}', false),
          ],
        ),
        if (loading || busy) const LinearProgressIndicator(minHeight: 2),
        if (!widget.enabled)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Настройки временно недоступны. Проверьте состояние подключения.',
              style: TextStyle(color: _atlasMuted, fontSize: 12, height: 1.4),
            ),
          ),
        if (loadError.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Не удалось обновить каталог: $loadError. Показанные данные могут быть устаревшими.',
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('retry-home-services'),
              onPressed: busy ? null : _load,
              child: const Text('Повторить загрузку'),
            ),
          ),
        ],
        if (!loading && loadError.isEmpty && filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              search.text.trim().isEmpty && pinnedOnly
                  ? 'Нет закреплённых приложений. Откройте «Все», чтобы добавить их.'
                  : 'Приложения не найдены. Измените поиск или добавьте приложение.',
              style: const TextStyle(color: _atlasMuted, height: 1.4),
            ),
          ),
        for (final service in filtered) _service(service, available: available),
        if (!_isMobileShell && widget.connected)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'При изменении настроек VPN переподключится. Связь ненадолго прервётся.',
              key: ValueKey('home-services-reconnect-note'),
              style: TextStyle(color: _atlasMuted, fontSize: 12, height: 1.4),
            ),
          ),
        if (feedback.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              feedback,
              key: const ValueKey('service-feedback'),
              style: const TextStyle(
                color: _atlasText,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        _ApplicationBindingsEditor(
          bridge: widget.bridge,
          enabled: available,
          onBusyChanged: widget.onBusyChanged,
        ),
      ],
    );
  }

  Widget _tab(String key, String label, bool quick) {
    final selected = pinnedOnly == quick;
    return Flexible(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: ValueKey(key),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => setState(() => pinnedOnly = quick),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? _atlasMint : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? _atlasMint : _atlasMuted,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _service(RouteService service, {required bool available}) {
    final expanded = openServiceTag == service.tag;
    final primary = isPrimaryHomeRouteService(service.tag);
    final policy = _normalizedHomeRoutePolicy(service);
    final label = switch (policy) {
      'direct' => 'Напрямую',
      'vpn' => 'VPN',
      'zapret' => 'Zapret',
      _ => 'Авто',
    };
    return _CatalogRow(
      rowKey: ValueKey('home-service-row-${service.tag}'),
      icon: _ServiceBrandIcon(tag: service.tag, size: 32),
      title: _homeRouteName(service),
      expanded: expanded,
      onTap: () =>
          setState(() => openServiceTag = expanded ? null : service.tag),
      badge: label,
      accentBadge: policy == 'vpn',
      detail: expanded
          ? Column(
              key: ValueKey('home-service-details-${service.tag}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HomeRouteServiceRow(
                  service: service,
                  keyPrefix: 'service',
                  connected: widget.connected && available,
                  allTraffic: widget.routingMode == 'all_traffic',
                  enabled: available,
                  statusKnown: widget.enabled && !loading && loadError.isEmpty,
                  onRemove: null,
                  headerAction: _AccessibleIconButton(
                    key: ValueKey('pin-service-${service.tag}'),
                    tooltip: primary
                        ? 'Основной сервис'
                        : _pinned(service)
                        ? 'Открепить сервис'
                        : 'Закрепить сервис',
                    onPressed: available && !primary
                        ? () => unawaited(
                            _change(
                              () => widget.bridge.setHomeRouteServiceVisible(
                                service.tag,
                                !service.homeVisible,
                              ),
                              routeChange: false,
                            ),
                          )
                        : null,
                    icon: Icon(
                      _pinned(service) ? Icons.star : Icons.star_border,
                      color: _pinned(service) ? _atlasMint : _atlasMuted,
                    ),
                  ),
                  onPolicyChanged: (value) => unawaited(
                    _change(
                      () => widget.bridge.setFreeAccessServiceMethod(
                        service.tag,
                        value,
                      ),
                    ),
                  ),
                  onZapretStrategyChanged: (mode, tag) => unawaited(
                    _change(
                      () => widget.bridge.setZapretServiceStrategy(
                        service.tag,
                        mode,
                        tag,
                      ),
                    ),
                  ),
                ),
                if (service.tag == 'discord' && !_isMobileShell)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Для звонков Discord рекомендуем VPN. Обход работает в экспериментальном режиме.',
                      style: TextStyle(
                        color: _atlasMuted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (service.domainSuffixes.isNotEmpty)
                  ExpansionTile(
                    key: ValueKey('service-domains-${service.tag}'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Домены сервиса',
                      style: TextStyle(color: _atlasMuted, fontSize: 12),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          service.domainSuffixes.join(', '),
                          style: const TextStyle(
                            color: _atlasMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
              ],
            )
          : null,
    );
  }
}
