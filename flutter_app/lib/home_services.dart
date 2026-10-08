part of 'main.dart';

/// Home owns the scroll position; neither the catalog nor a service detail
/// creates a nested scrollable or an independent tinted surface.
class _HomeServicesAccordion extends StatefulWidget {
  const _HomeServicesAccordion({
    super.key,
    required this.bridge,
    required this.connected,
    required this.enabled,
    required this.routingMode,
    required this.onBusyChanged,
    required this.expanded,
    required this.onExpandedChanged,
    this.onChanged,
    this.routeSnapshot,
  });

  final CoreBridge bridge;
  final bool connected, enabled, expanded;
  final String routingMode;
  final ValueChanged<bool> onBusyChanged, onExpandedChanged;
  final VoidCallback? onChanged;
  final List<RouteService>? routeSnapshot;

  @override
  State<_HomeServicesAccordion> createState() => _HomeServicesAccordionState();
}

class _HomeServicesAccordionState extends State<_HomeServicesAccordion> {
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
      services = widget.routeSnapshot!;
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    ++loadGeneration;
    search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HomeServicesAccordion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!busy &&
        widget.routeSnapshot != null &&
        !identical(oldWidget.routeSnapshot, widget.routeSnapshot)) {
      ++loadGeneration;
      services = widget.routeSnapshot!;
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
        setState(() => services = result);
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
    // Reading an active Android session is safe; editing its routes is not.
    // The user, never the disclosure control, decides when to disconnect.
    if (routeChange && _isMobileShell && widget.connected) return;
    setState(() {
      busy = true;
      feedback = 'Сохраняем…';
    });
    widget.onBusyChanged(true);
    try {
      final result = await action();
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Не удалось сохранить');
      }
      widget.onChanged?.call();
      if (!mounted) return;
      setState(
        () => feedback = !routeChange
            ? 'Быстрый список сохранён.'
            : result['restarted'] == true
            ? 'Маршрут сохранён, VPN автоматически переподключён.'
            : 'Маршрут сохранён. Настройка применяется ядром при следующем подключении.',
      );
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => feedback = 'Не удалось сохранить: ${_cleanError(error)}',
        );
      }
    } finally {
      widget.onBusyChanged(false);
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
    if (widget.routingMode != 'blocked_only') return const SizedBox.shrink();
    final pinnedCount = services.where(_pinned).length;
    final available = widget.enabled && !busy && !loading && loadError.isEmpty;
    final editing = available && (!_isMobileShell || !widget.connected);
    final filtered = _filtered;
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: _atlasBorder),
                bottom: BorderSide(color: _atlasBorder),
              ),
            ),
            child: Semantics(
              button: true,
              expanded: widget.expanded,
              child: InkWell(
                key: const ValueKey('toggle-home-route-services'),
                mouseCursor: SystemMouseCursors.click,
                onTap: () => widget.onExpandedChanged(!widget.expanded),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.grid_view_rounded,
                          size: 20,
                          color: _atlasText,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Сервисы',
                            style: TextStyle(
                              color: _atlasText,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Flexible(
                          child: Text(
                            widget.expanded
                                ? '$pinnedCount'
                                : '$pinnedCount в быстром списке',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: _atlasMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          widget.expanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          color: _atlasText,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.expanded) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('service-search'),
              controller: search,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: _atlasText, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Найти сервис или домен',
                hintStyle: const TextStyle(color: _atlasMuted, fontSize: 14),
                prefixIcon: const Icon(Icons.search, size: 22),
                filled: true,
                fillColor: _atlasSurface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _atlasBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _atlasBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _atlasMint),
                ),
                suffixIcon: search.text.isEmpty
                    ? null
                    : _AccessibleIconButton(
                        tooltip: 'Очистить поиск',
                        onPressed: () => setState(search.clear),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            Row(
              children: [
                _tab('services-pinned', 'Быстрые $pinnedCount', true),
                const SizedBox(width: 12),
                _tab('services-all', 'Все ${services.length}', false),
              ],
            ),
            if (loading || busy) const LinearProgressIndicator(minHeight: 2),
            if (!widget.enabled)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  'Управление временно недоступно. Дождитесь связи с ядром и завершения подключения.',
                  style: TextStyle(
                    color: _atlasMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
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
                      ? 'В быстром списке пока нет сервисов. Откройте «Все», чтобы добавить их.'
                      : 'Сервисы не найдены. Измените поиск или предложите новый сервис.',
                  style: const TextStyle(color: _atlasMuted, height: 1.4),
                ),
              ),
            for (final service in filtered)
              _service(service, available: available, editing: editing),
            if (_isMobileShell && widget.connected)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Для изменения маршрутов отключите VPN',
                  key: ValueKey('home-services-read-only'),
                  style: TextStyle(
                    color: _atlasMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            if (!_isMobileShell && widget.connected)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'При смене маршрута dropo безопасно переподключит VPN автоматически. Связь может кратковременно прерваться.',
                  key: ValueKey('home-services-reconnect-note'),
                  style: TextStyle(
                    color: _atlasMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
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
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('request-home-service'),
                onPressed: busy
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            _RequestServiceDialog(bridge: widget.bridge),
                      ),
                icon: const Icon(
                  Icons.add_circle_outline,
                  color: _atlasMuted,
                  size: 25,
                ),
                label: const Text(
                  'Предложить сервис',
                  style: TextStyle(color: _atlasText, fontSize: 14),
                ),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ),
          ],
        ],
      ),
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

  Widget _service(
    RouteService service, {
    required bool available,
    required bool editing,
  }) {
    final expanded = openServiceTag == service.tag;
    final primary = isPrimaryHomeRouteService(service.tag);
    final policy = _normalizedHomeRoutePolicy(service);
    final label = switch (policy) {
      'direct' => 'Напрямую',
      'vpn' => 'VPN',
      'zapret' => 'Zapret',
      _ => 'Авто',
    };
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _atlasBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              key: ValueKey('home-service-row-${service.tag}'),
              mouseCursor: SystemMouseCursors.click,
              onTap: () => setState(
                () => openServiceTag = expanded ? null : service.tag,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      _ServiceBrandIcon(tag: service.tag, size: 32),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          _homeRouteName(service),
                          style: const TextStyle(
                            color: _atlasText,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          label,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: _atlasMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        expanded ? Icons.expand_less : Icons.chevron_right,
                        color: _atlasMuted,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expanded)
            Column(
              key: ValueKey('home-service-details-${service.tag}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HomeRouteServiceRow(
                  service: service,
                  keyPrefix: 'service',
                  connected: widget.connected && available,
                  allTraffic: false,
                  enabled: editing,
                  statusKnown: widget.enabled && !loading && loadError.isEmpty,
                  onRemove: null,
                  headerAction: _AccessibleIconButton(
                    key: ValueKey('pin-service-${service.tag}'),
                    tooltip: primary
                        ? 'Основной сервис'
                        : _pinned(service)
                        ? 'Убрать из быстрого списка'
                        : 'Добавить в быстрый список',
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
                      'Discord: для стабильного voice/video рекомендуется VPN. Zapret — экспериментальный метод, работа голоса не гарантируется.',
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
            ),
        ],
      ),
    );
  }
}
