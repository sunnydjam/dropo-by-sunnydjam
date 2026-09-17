part of 'main.dart';

/// Scrollable native section; long catalogs are built lazily.
class _FeaturePage extends StatefulWidget {
  const _FeaturePage({
    required this.title,
    required this.icon,
    this.child,
    this.slivers = const [],
  });
  final String title;
  final IconData icon;
  final Widget? child;
  final List<Widget> slivers;

  @override
  State<_FeaturePage> createState() => _FeaturePageState();
}

class _FeaturePageState extends State<_FeaturePage> {
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _homeSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _homeBorder),
    ),
    child: Material(
      color: Colors.transparent,
      child: Scrollbar(
        controller: scroll,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(20),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Icon(widget.icon, color: _homeAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: _homeText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.child != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverToBoxAdapter(child: widget.child),
              ),
            ...widget.slivers,
          ],
        ),
      ),
    ),
  );
}

class ServiceRoutesPage extends StatefulWidget {
  const ServiceRoutesPage({
    super.key,
    required this.bridge,
    required this.connected,
    required this.enabled,
    required this.routingMode,
    this.onChanged,
    this.onBusyChanged,
    this.routeSnapshot,
  });
  final CoreBridge bridge;
  final bool connected, enabled;
  final String routingMode;
  final VoidCallback? onChanged;
  final ValueChanged<bool>? onBusyChanged;
  final List<RouteService>? routeSnapshot;
  @override
  State<ServiceRoutesPage> createState() => _ServiceRoutesPageState();
}

class _ServiceRoutesPageState extends State<ServiceRoutesPage> {
  final search = TextEditingController();
  List<RouteService> services = const [];
  bool loading = true, busy = false, pinnedOnly = false;
  String loadError = '', feedback = '';
  int loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ServiceRoutesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!busy &&
        !loading &&
        widget.routeSnapshot != null &&
        !identical(oldWidget.routeSnapshot, widget.routeSnapshot)) {
      services = widget.routeSnapshot!;
      loadError = '';
    }
    if (!busy &&
        (oldWidget.connected != widget.connected ||
            (!oldWidget.enabled && widget.enabled))) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++loadGeneration;
    setState(() {
      loading = true;
      loadError = '';
    });
    try {
      final result = await widget.bridge
          .routes(live: widget.connected)
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
    widget.onBusyChanged?.call(true);
    setState(() {
      busy = true;
      feedback = 'Сохраняем…';
    });
    try {
      final result = await action();
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Не удалось сохранить');
      }
      widget.onChanged?.call();
      if (!mounted) return;
      setState(
        () => feedback = !routeChange
            ? 'Список на главной сохранён.'
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
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => busy = false);
    }
  }

  bool _pinned(RouteService service) =>
      service.homeVisible || isPrimaryHomeRouteService(service.tag);

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final filtered =
        services
            .where(
              (s) =>
                  (!pinnedOnly || _pinned(s)) &&
                  '${_homeRouteName(s)} ${s.tag} ${s.domainSuffixes.join(' ')}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort((a, b) {
            final order = primaryHomeRouteServiceTags.toList();
            final aIndex = order.indexOf(a.tag);
            final bIndex = order.indexOf(b.tag);
            final primary =
                (aIndex < 0 ? order.length : aIndex) -
                (bIndex < 0 ? order.length : bIndex);
            return primary != 0
                ? primary
                : _homeRouteName(a).compareTo(_homeRouteName(b));
          });
    final enabled = widget.enabled && !busy && !loading && loadError.isEmpty;
    final editing = enabled && (!_isMobileShell || !widget.connected);
    return _FeaturePage(
      title: 'Сервисы',
      icon: Icons.apps_outlined,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Выберите маршрут для сервиса. Звёздочка закрепляет его на главной.',
                  style: TextStyle(color: _homeMuted, height: 1.5),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.routingMode == 'all_traffic'
                      ? 'Сейчас выбран режим «Всё через VPN». Индивидуальные маршруты сохраняются для режима выбранных сервисов.'
                      : 'В режиме выбранных сервисов остальные сайты и игры идут напрямую, если не заданы дополнительные правила.',
                  style: const TextStyle(color: _homeText, height: 1.5),
                ),
                const SizedBox(height: 8),
                Text(
                  _isMobileShell
                      ? 'На Android доступны Авто, Напрямую и VPN. Перед изменением маршрута отключите VPN.'
                      : 'При смене маршрута dropo безопасно переподключит VPN автоматически. Связь может кратковременно прерваться.',
                  style: const TextStyle(color: _homeMuted, height: 1.5),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('service-search'),
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Поиск сервиса или домена',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            onPressed: () => setState(search.clear),
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      key: const ValueKey('services-pinned'),
                      label: const Text('На главной'),
                      selected: pinnedOnly,
                      onSelected: (value) => setState(() => pinnedOnly = value),
                    ),
                    Text(
                      'Найдено: ${filtered.length}',
                      style: const TextStyle(color: _homeMuted),
                    ),
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  _RequestServiceDialog(bridge: widget.bridge),
                            ),
                      icon: const Icon(Icons.add),
                      label: const Text('Предложить сервис'),
                    ),
                  ],
                ),
                if (loading || busy) const LinearProgressIndicator(),
                if (!widget.enabled)
                  const Text(
                    'Управление временно недоступно. Дождитесь связи с ядром и завершения подключения.',
                    style: TextStyle(color: _homeMuted),
                  ),
                if (feedback.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      feedback,
                      key: const ValueKey('service-feedback'),
                      style: const TextStyle(color: _homeText),
                    ),
                  ),
                if (loadError.isNotEmpty) ...[
                  Text(
                    'Не удалось обновить каталог: $loadError. Показанные данные могут быть устаревшими.',
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                  TextButton(
                    onPressed: busy ? null : _load,
                    child: const Text('Повторить загрузку'),
                  ),
                ],
                if (!loading && loadError.isEmpty && filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'Сервисы не найдены. Измените поиск или предложите новый сервис.',
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          sliver: SliverList.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final service = filtered[index];
              final primary = isPrimaryHomeRouteService(service.tag);
              return Column(
                key: ValueKey('service-card-${service.tag}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HomeRouteServiceRow(
                    service: service,
                    keyPrefix: 'service',
                    statusKnown:
                        widget.enabled && loadError.isEmpty && !loading,
                    connected:
                        widget.connected &&
                        widget.enabled &&
                        loadError.isEmpty &&
                        !loading,
                    allTraffic: widget.routingMode == 'all_traffic',
                    enabled: editing,
                    onRemove: null,
                    headerAction: IconButton(
                      key: ValueKey('pin-service-${service.tag}'),
                      tooltip: primary
                          ? 'Всегда на главной'
                          : _pinned(service)
                          ? 'Убрать с главной'
                          : 'Закрепить на главной',
                      onPressed: enabled && !primary
                          ? () => _change(
                              () => widget.bridge.setHomeRouteServiceVisible(
                                service.tag,
                                !service.homeVisible,
                              ),
                              routeChange: false,
                            )
                          : null,
                      icon: Icon(
                        _pinned(service) ? Icons.star : Icons.star_border,
                        color: _pinned(service) ? _homeAccent : _homeMuted,
                      ),
                    ),
                    onPolicyChanged: (policy) => unawaited(
                      _change(
                        () => widget.bridge.setFreeAccessServiceMethod(
                          service.tag,
                          policy,
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
                          color: _homeMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  if (service.domainSuffixes.isNotEmpty)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'Домены сервиса',
                        style: TextStyle(color: _homeMuted, fontSize: 12),
                      ),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            service.domainSuffixes.join(', '),
                            style: const TextStyle(
                              color: _homeMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
