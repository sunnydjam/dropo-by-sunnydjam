part of 'main.dart';

// Home-only presentation tokens. Network state stays in the shared core bridge.
const _homeSurface = Color(0xFF172421);
const _homeBorder = Color(0xFF30453D);
const _homeText = Color(0xFFE8F3EF);
const _homeMuted = Color(0xFFA8BAB5);
const _homeAccent = Color(0xFF75E3AD);

class _HomeBrand extends StatelessWidget {
  const _HomeBrand();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Dropo',
    excludeSemantics: true,
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Dr',
          style: TextStyle(
            color: _homeText,
            fontSize: 36,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          'opo',
          style: TextStyle(
            color: _homeAccent,
            fontSize: 36,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _HomePanel extends StatelessWidget {
  const _HomePanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: _homeSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _homeBorder),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: _homeText, fontSize: 14, height: 1.4),
      child: child,
    ),
  );
}

// Shared by connection/source panels: avoid truncating the primary action at
// 200% text scaling or on a narrow native window.
class _HomeAdaptiveAction extends StatelessWidget {
  const _HomeAdaptiveAction({required this.content, required this.action});
  final Widget content;
  final Widget action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 470 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [content, const SizedBox(height: 16), action],
        );
      }
      return Row(
        children: [
          Expanded(child: content),
          const SizedBox(width: 24),
          action,
        ],
      );
    },
  );
}

class _HomeConnectionPanel extends StatelessWidget {
  const _HomeConnectionPanel({
    required this.status,
    required this.online,
    required this.booting,
    required this.busy,
    required this.disconnecting,
    required this.routingMode,
    required this.enabled,
    required this.onPressed,
    this.onDisabledPressed,
    this.atlas = false,
  });
  final CoreStatus status;
  final bool online, booting, busy, disconnecting, enabled;
  final String routingMode;
  final VoidCallback onPressed;
  final VoidCallback? onDisabledPressed;
  final bool atlas;

  @override
  Widget build(BuildContext context) {
    final danger = !booting && (!online || status.hasError);
    final connected = online && status.connected && !danger;
    final stopping = disconnecting || status.disconnecting;
    final title = booting
        ? 'Запуск приложения'
        : !online
        ? 'Нет связи с ядром'
        : status.hasError
        ? 'Требуется внимание'
        : stopping
        ? 'Отключение'
        : status.connecting
        ? 'Подключение'
        : connected
        ? 'Подключено'
        : 'Отключено';
    final accent = danger
        ? const Color(0xFFFFB4AB)
        : busy
        ? const Color(0xFFFFD38B)
        : connected
        ? _homeAccent
        : _homeMuted;
    final description = danger
        ? 'Состояние подключения не подтверждено. Проверьте сообщение ниже.'
        : busy
        ? 'Подождите, пока приложение завершит текущую операцию.'
        : connected
        ? 'Подключение активно. Доступность сервисов проверяется отдельно.'
        : 'Выберите режим и нажмите «Подключить».';
    final mode = routingMode == 'all_traffic' ? 'Всё через VPN' : 'По сервисам';
    if (atlas) {
      return _AtlasConnectionPanel(
        title: title,
        accent: accent,
        connected: connected,
        sessionActive: status.connected,
        busy: busy,
        stopping: stopping,
        enabled: enabled,
        onPressed: onPressed,
        onDisabledPressed: onDisabledPressed,
      );
    }
    return _HomePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HomeAdaptiveAction(
            content: Row(
              children: [
                Icon(
                  danger
                      ? Icons.error_outline
                      : connected
                      ? Icons.check_circle_outline
                      : Icons.power_settings_new,
                  size: 42,
                  color: accent,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          title,
                          key: const ValueKey('home-connection-state'),
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        connected ? mode : 'Выбран режим: $mode',
                        style: const TextStyle(color: _homeMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            action: FilledButton.icon(
              key: const ValueKey('home-connect'),
              onPressed: enabled ? onPressed : onDisabledPressed,
              style: FilledButton.styleFrom(
                backgroundColor: _homeAccent,
                foregroundColor: const Color(0xFF08140F),
                disabledBackgroundColor: const Color(0xFF30433B),
                disabledForegroundColor: _homeMuted,
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                textStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.power_settings_new, size: 20),
              label: Text(
                busy
                    ? 'Подождите'
                    : status.connected
                    ? 'Отключить'
                    : 'Подключить',
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1, color: _homeBorder),
          ),
          Text(
            description,
            style: const TextStyle(color: _homeMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _HomeSourcePanel extends StatelessWidget {
  const _HomeSourcePanel({
    required this.sources,
    required this.loaded,
    required this.failed,
    required this.connected,
    required this.online,
    required this.hasSubscription,
    required this.onManage,
    this.atlas = false,
  });
  final List<VpnSourceInfo> sources;
  final bool loaded, failed, connected, online, hasSubscription;
  final VoidCallback? onManage;
  final bool atlas;

  @override
  Widget build(BuildContext context) {
    VpnSourceInfo? source;
    final available = sources
        .where((source) => !source.disabled)
        .toList(growable: false);
    for (final candidate in available) {
      if (connected && candidate.active && loaded) {
        source = candidate;
        break;
      }
    }
    final active = source != null;
    if (!connected && loaded && available.isNotEmpty) source = available.first;
    String title;
    String detail;
    if (!online || failed) {
      title = 'Источник не подтверждён';
      detail =
          'Нет актуальных данных от ядра. Сохранённые источники доступны в настройках.';
    } else if (!loaded) {
      title = 'Получаем источники…';
      detail = 'Это не задерживает подключение.';
    } else if (source != null) {
      title = source.name;
      final node = source.selectedNode;
      final nodeName = node >= 0 && node < source.nodeNames.length
          ? source.nodeNames[node]
          : 'Первый поддерживаемый сервер';
      detail =
          '$nodeName · ${active ? 'используется сейчас' : 'первый по приоритету'}';
    } else if (connected && available.isNotEmpty) {
      title = 'VPN-источник не подтверждён';
      detail =
          'Ядро не сообщило активный источник. Подключение не подтверждает использование VPN.';
    } else if (sources.isNotEmpty) {
      title = 'Источники выключены';
      detail = 'Включите нужный источник для подключения через VPN.';
    } else if (hasSubscription) {
      title = 'Подписка добавлена';
      detail = 'Данные об активном сервере ещё не получены.';
    } else {
      title = 'Добавьте источник VPN';
      detail =
          'Своя подписка или бесплатный резерв. Обход без VPN настраивается в сервисах.';
    }
    if (atlas) {
      final known = source != null && loaded && online && !failed;
      final node = known ? source.selectedNode : -1;
      return _AtlasSourceTile(
        title: known
            ? (node >= 0 && node < source.nodeNames.length
                  ? source.nodeNames[node]
                  : 'Первый поддерживаемый сервер')
            : title,
        detail: known
            ? '${source.name} · ${active ? 'используется сейчас' : 'первый по приоритету'}'
            : detail,
        publicNotice: known && source.isPublic
            ? (active
                  ? 'Используется бесплатный резерв'
                  : 'Бесплатный резерв · после личных подписок')
            : null,
        onPressed: onManage,
      );
    }
    return _HomePanel(
      child: _HomeAdaptiveAction(
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Источник VPN',
              style: TextStyle(color: _homeMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              key: const ValueKey('home-source-title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              key: const ValueKey('home-source-detail'),
              style: const TextStyle(color: _homeMuted, fontSize: 13),
            ),
            if (source != null && loaded && online && source.isPublic) ...[
              const SizedBox(height: 8),
              Text(
                active
                    ? 'Используется бесплатный резерв'
                    : 'Бесплатный резерв · после личных подписок',
                style: const TextStyle(color: Color(0xFFFFD38B), fontSize: 13),
              ),
            ],
          ],
        ),
        action: OutlinedButton(
          key: const ValueKey('home-manage-sources'),
          onPressed: onManage,
          style: OutlinedButton.styleFrom(
            foregroundColor: _homeText,
            side: const BorderSide(color: Color(0xFF587068)),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: Text(
            loaded && sources.isEmpty && !hasSubscription
                ? 'Добавить'
                : 'Изменить',
          ),
        ),
      ),
    );
  }
}

class _HomeRouteControls extends StatelessWidget {
  const _HomeRouteControls({
    required this.services,
    required this.enabled,
    required this.expanded,
    required this.routingMode,
    required this.hasSubscription,
    required this.connected,
    required this.onExpandedChanged,
    required this.onRoutingModeChanged,
    required this.onPolicyChanged,
    required this.onZapretStrategyChanged,
    required this.onAdd,
    required this.onRemove,
    this.atlas = false,
    this.onAllServices,
    this.summaryOnly = false,
  });

  final List<RouteService> services;
  final bool enabled;
  final bool expanded;
  final String routingMode;
  final bool hasSubscription;
  final bool connected;
  final ValueChanged<bool> onExpandedChanged;
  final ValueChanged<String> onRoutingModeChanged;
  final void Function(RouteService service, String policy) onPolicyChanged;
  final void Function(RouteService service, String mode, String strategyTag)
  onZapretStrategyChanged;
  final VoidCallback? onAdd;
  final void Function(RouteService service, bool visible) onRemove;
  final bool atlas;
  final VoidCallback? onAllServices;
  final bool summaryOnly;

  @override
  Widget build(BuildContext context) {
    final ordered = List<RouteService>.from(services);
    const primaryOrder = <String>['youtube', 'discord', 'meta', 'openai'];
    ordered.sort((left, right) {
      final leftIndex = primaryOrder.indexOf(left.tag);
      final rightIndex = primaryOrder.indexOf(right.tag);
      if (leftIndex >= 0 || rightIndex >= 0) {
        if (leftIndex < 0) return 1;
        if (rightIndex < 0) return -1;
        return leftIndex.compareTo(rightIndex);
      }
      return left.name.compareTo(right.name);
    });

    if (atlas) return _AtlasRouteControls(controls: this, services: ordered);
    return Container(
      key: const ValueKey('home-route-controls'),
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _homeSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _homeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Режим подключения',
            style: TextStyle(
              color: Color(0xFFE8F3EF),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Flex(
            direction: MediaQuery.textScalerOf(context).scale(14) > 21
                ? Axis.vertical
                : Axis.horizontal,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: _HomeRoutingModeButton(
                  key: const ValueKey('home-routing-selected'),
                  icon: Icons.account_tree_outlined,
                  label: 'По сервисам',
                  selected: routingMode != 'all_traffic',
                  enabled: enabled,
                  onPressed: () => onRoutingModeChanged('blocked_only'),
                ),
              ),
              const SizedBox(width: 8, height: 8),
              Flexible(
                fit: FlexFit.loose,
                child: Tooltip(
                  message: hasSubscription
                      ? 'Направить весь трафик через VPN'
                      : 'Сначала добавьте VPN-подписку',
                  child: _HomeRoutingModeButton(
                    key: const ValueKey('home-routing-all-vpn'),
                    icon: Icons.shield_outlined,
                    label: 'Всё через VPN',
                    selected: routingMode == 'all_traffic',
                    enabled: enabled,
                    onPressed: () => onRoutingModeChanged('all_traffic'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            routingMode == 'all_traffic'
                ? 'Общий трафик — через VPN. Локальные и рабочие сети сохраняют исключения.'
                : 'Маршруты сервисов и каталоги блокировок. Остальное — напрямую.',
            style: const TextStyle(
              color: _homeMuted,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: _homeBorder),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.alt_route, size: 16, color: Color(0xFF75E3AD)),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'Маршруты сервисов',
                  style: TextStyle(
                    color: Color(0xFFE8F3EF),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('toggle-home-route-services'),
                onPressed: () => onExpandedChanged(!expanded),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(expanded ? 'Скрыть' : 'Показать'),
                    const SizedBox(width: 3),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (expanded) ...[
            if (routingMode == 'all_traffic')
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 5, 4, 2),
                child: Text(
                  'Политики ниже сохранены для режима «По сервисам».',
                  style: TextStyle(color: Color(0xFFA8BAB5), fontSize: 11),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('add-home-route-service'),
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Добавить сервис'),
              ),
            ),
            ...ordered.map(
              (service) => _HomeRouteServiceRow(
                service: service,
                connected: connected,
                allTraffic: routingMode == 'all_traffic',
                enabled: enabled,
                onPolicyChanged: (policy) => onPolicyChanged(service, policy),
                onZapretStrategyChanged: (mode, strategyTag) =>
                    onZapretStrategyChanged(service, mode, strategyTag),
                onRemove: isPrimaryHomeRouteService(service.tag)
                    ? null
                    : () => onRemove(service, false),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeRoutingModeButton extends StatelessWidget {
  const _HomeRoutingModeButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 16),
      label: Text(label, textAlign: TextAlign.center),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
        foregroundColor: selected
            ? const Color(0xFF08140F)
            : const Color(0xFFD8E4E0),
        backgroundColor: selected
            ? const Color(0xFF75E3AD)
            : Colors.transparent,
        side: BorderSide(
          color: selected ? const Color(0xFF75E3AD) : const Color(0xFF3C554E),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _HomeRouteServiceRow extends StatelessWidget {
  const _HomeRouteServiceRow({
    required this.service,
    required this.connected,
    required this.allTraffic,
    required this.enabled,
    required this.onPolicyChanged,
    required this.onZapretStrategyChanged,
    required this.onRemove,
    this.keyPrefix = 'home',
    this.headerAction,
    this.statusKnown = true,
  });

  final RouteService service;
  final bool connected, allTraffic;
  final bool enabled;
  final ValueChanged<String> onPolicyChanged;
  final void Function(String mode, String strategyTag) onZapretStrategyChanged;
  final VoidCallback? onRemove;
  final String keyPrefix;
  final Widget? headerAction;
  final bool statusKnown;

  @override
  Widget build(BuildContext context) {
    final selected = _normalizedHomeRoutePolicy(service);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 8, 7, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF172824),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF314B43)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _homeRouteName(service),
                    style: const TextStyle(
                      color: Color(0xFFE8F3EF),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                ?headerAction,
                if (onRemove != null)
                  IconButton(
                    key: ValueKey('remove-home-route-${service.tag}'),
                    tooltip: 'Убрать из быстрого списка',
                    onPressed: enabled ? onRemove : null,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close, size: 15),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (_isMobileShell)
                  _homeRouteButton(service, 'auto', 'Авто', selected),
                _homeRouteButton(service, 'direct', 'Напрямую', selected),
                _homeRouteButton(service, 'vpn', 'VPN', selected),
                if (!_isMobileShell)
                  Tooltip(
                    message: service.zapretSupported
                        ? service.tag == 'discord'
                              ? 'Эксперимент: web/API могут работать, voice/video не гарантируются'
                              : 'Встроенный обход блокировки'
                        : 'Zapret недоступен для этого сервиса',
                    child: _homeRouteButton(
                      service,
                      'zapret',
                      service.tag == 'discord' ? 'Zapret (эксп.)' : 'Zapret',
                      selected,
                      supported: service.zapretSupported,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !statusKnown
                  ? 'Актуальный маршрут пока неизвестен'
                  : !connected
                  ? 'Сохранённая настройка · подключение выключено'
                  : allTraffic
                  ? 'Сейчас действует режим «Всё через VPN»'
                  : 'Маршрут по данным ядра: ${service.method}',
              style: const TextStyle(
                color: _homeMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            if (selected == 'zapret' &&
                service.zapretStrategyOptions.isNotEmpty) ...[
              Material(
                color: Colors.transparent,
                child: ExpansionTile(
                  key: ValueKey('$keyPrefix-route-details-${service.tag}'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: const Text(
                    'Стратегия и ограничения',
                    style: TextStyle(color: _homeText, fontSize: 13),
                  ),
                  children: [
                    _HomeZapretStrategyControls(
                      service: service,
                      enabled: enabled,
                      onChanged: onZapretStrategyChanged,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _homeRouteButton(
    RouteService service,
    String policy,
    String label,
    String selected, {
    bool supported = true,
  }) {
    return _ServiceRoutePolicyButton(
      key: ValueKey('$keyPrefix-route-${service.tag}-$policy'),
      comfortable: true,
      label: label,
      selected: selected == policy,
      enabled: enabled && supported,
      onPressed: () => onPolicyChanged(policy),
    );
  }
}

class _HomeZapretStrategyControls extends StatelessWidget {
  const _HomeZapretStrategyControls({
    required this.service,
    required this.enabled,
    required this.onChanged,
  });

  final RouteService service;
  final bool enabled;
  final void Function(String mode, String strategyTag) onChanged;

  @override
  Widget build(BuildContext context) {
    final manual = service.zapretStrategyMode == 'manual';
    final experimentalAuto = service.tag == 'discord';
    final options = service.zapretStrategyOptions;
    final selectedTag =
        options.any((option) => option.tag == service.zapretSelectedStrategy)
        ? service.zapretSelectedStrategy
        : options.first.tag;
    final effective = service.zapretEffectiveStrategyLabel.isEmpty
        ? 'ещё не определена'
        : service.zapretEffectiveStrategyLabel;

    return Container(
      key: ValueKey('home-zapret-strategy-${service.tag}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1D19),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFF2A493F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Стратегия Zapret',
                  style: TextStyle(
                    color: Color(0xFFDDEBE6),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: TextButton.icon(
                  key: ValueKey('zapret-auto-${service.tag}'),
                  onPressed: enabled ? () => onChanged('auto', '') : null,
                  icon: const Icon(Icons.auto_fix_high, size: 15),
                  label: Text(
                    experimentalAuto
                        ? manual
                              ? 'Авто (эксп.)'
                              : 'Повторить (эксп.)'
                        : manual
                        ? 'Авто'
                        : 'Подобрать заново',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          Text(
            manual
                ? 'Выбрана вручную: $effective'
                : service.zapretStrategyNotFound
                ? 'Результат: подходящая стратегия не найдена'
                : experimentalAuto
                ? 'Авто (эксперимент): проверяется $effective'
                : 'Стратегия по данным ядра: $effective',
            style: TextStyle(
              color: !manual && service.zapretStrategyNotFound
                  ? const Color(0xFFFF9C92)
                  : const Color(0xFFA8BAB5),
              fontSize: 13,
            ),
          ),
          if (experimentalAuto) ...[
            const SizedBox(height: 3),
            const Text(
              'Discord Zapret экспериментален: web/API могут открыться, но voice/video не гарантируются. Для голосового чата рекомендуется VPN.',
              style: TextStyle(
                color: Color(0xFFFFC979),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 5),
          DropdownButtonFormField<String>(
            key: ValueKey('zapret-manual-${service.tag}'),
            initialValue: manual ? selectedTag : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Выбрать вручную',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            ),
            items: options
                .map(
                  (option) => DropdownMenuItem<String>(
                    value: option.tag,
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                )
                .toList(growable: false),
            onChanged: enabled
                ? (value) {
                    if (value != null) onChanged('manual', value);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _AddHomeRouteServiceSheet extends StatelessWidget {
  const _AddHomeRouteServiceSheet({required this.services});

  final List<RouteService> services;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 4, 18, 12),
              child: Text(
                'Добавить сервис',
                style: TextStyle(
                  color: Color(0xFFE8F3EF),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                itemCount: services.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final service = services[index];
                  return ListTile(
                    key: ValueKey('add-home-route-${service.tag}'),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    tileColor: const Color(0xFF172824),
                    title: Text(
                      _homeRouteName(service),
                      style: const TextStyle(color: Color(0xFFE8F3EF)),
                    ),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: () => Navigator.of(context).pop(service),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
