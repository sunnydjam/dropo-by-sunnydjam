part of 'main.dart';

// Adaptive presentation only. Policy changes still go through the existing
// session-aware callbacks; no traffic decisions belong in these widgets.
const _atlasBackground = Color(0xFF071F17);
const _atlasSurface = Color(0xFF10271F);
const _atlasBorder = Color(0xFF29483C);
const _atlasText = Color(0xFFEDF5EF);
const _atlasMuted = Color(0xFFADC2B7);
const _atlasMint = Color(0xFF5CF0B0);

class _AtlasHomeLayout extends StatelessWidget {
  const _AtlasHomeLayout({
    required this.connection,
    required this.source,
    required this.routes,
    required this.notices,
  });
  final Widget connection, source, routes, notices;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('home'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Errors and active probes stay visible even on the simple screen.
            notices,
            connection,
            const SizedBox(height: 8),
            source,
            const SizedBox(height: 8),
            routes,
          ],
        ),
      ),
    ),
  );
}

class _AtlasConnectionPanel extends StatelessWidget {
  const _AtlasConnectionPanel({
    required this.title,
    required this.accent,
    required this.connected,
    required this.sessionActive,
    required this.busy,
    required this.stopping,
    required this.enabled,
    required this.onPressed,
    this.onDisabledPressed,
  });
  final String title;
  final Color accent;
  final bool connected, sessionActive, busy, stopping, enabled;
  final VoidCallback onPressed;
  final VoidCallback? onDisabledPressed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(17) > 23;
      final planetSize = math.min(
        constraints.maxWidth,
        math.min(
          280.0,
          math.max(
            largeText ? 280.0 : 190.0,
            MediaQuery.sizeOf(context).height - 310,
          ),
        ),
      );
      final actionIcon = busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.power_settings_new, size: 24);
      final actionLabel = Text(
        busy
            ? (stopping ? 'Отключаем…' : 'Подождите')
            : sessionActive
            ? 'Отключить'
            : 'Подключить',
        textAlign: TextAlign.center,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Доступность сервисов проверяется отдельно.',
            child: Semantics(
              liveRegion: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      title,
                      key: const ValueKey('home-connection-state'),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox.square(
            dimension: planetSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                IgnorePointer(
                  child: _AtlasAnimatedPlanet(
                    connected: connected,
                    size: planetSize,
                  ),
                ),
                SizedBox(
                  width: largeText
                      ? planetSize
                      : math.min(216.0, planetSize * 0.82),
                  child: FilledButton(
                    key: const ValueKey('home-connect'),
                    onPressed: enabled ? onPressed : onDisabledPressed,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 52),
                      backgroundColor: connected
                          ? _atlasBackground.withValues(alpha: 0.94)
                          : _atlasMint,
                      foregroundColor: connected
                          ? _atlasText
                          : _atlasBackground,
                      disabledBackgroundColor: _atlasSurface,
                      disabledForegroundColor: _atlasMuted,
                      side: BorderSide(
                        color: enabled ? _atlasMint : _atlasBorder,
                        width: 1.5,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 14,
                      ),
                      textStyle: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                      shape: const StadiumBorder(),
                    ),
                    child: largeText
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              actionIcon,
                              const SizedBox(height: 8),
                              actionLabel,
                            ],
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              actionIcon,
                              const SizedBox(width: 8),
                              Flexible(child: actionLabel),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _AtlasSourceTile extends StatelessWidget {
  const _AtlasSourceTile({
    required this.title,
    required this.detail,
    required this.onPressed,
    this.publicNotice,
  });
  final String title, detail;
  final String? publicNotice;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: const ValueKey('home-manage-sources'),
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: _atlasText,
      backgroundColor: _atlasSurface,
      side: const BorderSide(color: _atlasBorder),
      padding: const EdgeInsets.all(10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    child: Row(
      children: [
        const Icon(Icons.dns_outlined, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                key: const ValueKey('home-source-title'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                detail,
                key: const ValueKey('home-source-detail'),
                style: const TextStyle(
                  color: _atlasMuted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (publicNotice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    publicNotice!,
                    style: const TextStyle(
                      color: Color(0xFFFFD38B),
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right, size: 20),
      ],
    ),
  );
}

class _AtlasRouteControls extends StatelessWidget {
  const _AtlasRouteControls({required this.controls, required this.services});
  final _HomeRouteControls controls;
  final List<RouteService> services;

  @override
  Widget build(BuildContext context) {
    final c = controls;
    final allTraffic = c.routingMode == 'all_traffic';
    return Column(
      key: const ValueKey('home-route-controls'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!c.summaryOnly)
          const Text(
            'Как подключаться',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
        if (!c.summaryOnly) const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final buttons = [
              _mode(
                'selected',
                'По сервисам',
                !allTraffic,
                () => c.onRoutingModeChanged('blocked_only'),
              ),
              Tooltip(
                message: c.hasSubscription
                    ? 'Направить общий трафик через VPN; исключения рабочих сетей сохраняются'
                    : 'Сначала добавьте VPN-подписку',
                child: _mode(
                  'all-vpn',
                  'Всё через VPN',
                  allTraffic,
                  () => c.onRoutingModeChanged('all_traffic'),
                ),
              ),
            ];
            if (constraints.maxWidth < 275 ||
                MediaQuery.textScalerOf(context).scale(14) > 19) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [buttons[0], const SizedBox(height: 10), buttons[1]],
              );
            }
            return Row(
              children: [
                Expanded(child: buttons[0]),
                const SizedBox(width: 8),
                Expanded(child: buttons[1]),
              ],
            );
          },
        ),
        if (!c.summaryOnly) ...[
          const SizedBox(height: 6),
          Text(
            allTraffic
                ? 'Общий трафик — через VPN. Локальные и рабочие сети сохраняют исключения.'
                : 'Только выбранные сервисы. Остальное — напрямую.',
            style: const TextStyle(
              color: _atlasMuted,
              fontSize: 12,
              height: 1.3,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              const Text(
                'Сервисы',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                ),
              ),
              IconButton(
                key: const ValueKey('toggle-home-route-services'),
                onPressed: () => c.onExpandedChanged(!c.expanded),
                icon: Icon(c.expanded ? Icons.expand_less : Icons.expand_more),
                tooltip: c.expanded ? 'Свернуть сервисы' : 'Развернуть сервисы',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (c.expanded)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: _atlasBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (allTraffic)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Политики ниже сохранены для режима «По сервисам».',
                        style: TextStyle(color: _atlasMuted, fontSize: 13),
                      ),
                    ),
                  for (final service in services) ...[
                    _AtlasServiceRow(service: service, controls: c),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Divider(height: 0, color: _atlasBorder),
                    ),
                  ],
                  Padding(
                    padding: EdgeInsets.zero,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('add-home-route-service'),
                          onPressed: c.onAdd,
                          icon: const Icon(Icons.add, size: 20),
                          label: const Text('Добавить сервис'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ] else ...[
          const SizedBox(height: 8),
          _SettingsLink(
            section: 'service-settings',
            title: 'Настроить сервисы',
            icon: Icons.grid_view_rounded,
            trailing: Text(
              '${services.length}',
              style: const TextStyle(color: _atlasMuted),
            ),
            onPressed: c.onAllServices,
          ),
        ],
      ],
    );
  }

  Widget _mode(String key, String label, bool selected, VoidCallback action) =>
      Semantics(
        selected: selected,
        child: OutlinedButton.icon(
          key: ValueKey('home-routing-$key'),
          onPressed: controls.enabled ? action : null,
          icon: Icon(
            key == 'selected' ? Icons.grid_view_rounded : Icons.public,
            size: 18,
          ),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: selected ? _atlasBackground : _atlasText,
            backgroundColor: selected ? _atlasMint : _atlasSurface,
            side: BorderSide(color: selected ? _atlasMint : _atlasBorder),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );
}

class _AtlasServiceRow extends StatelessWidget {
  const _AtlasServiceRow({required this.service, required this.controls});
  final RouteService service;
  final _HomeRouteControls controls;

  @override
  Widget build(BuildContext context) {
    final policy = _normalizedHomeRoutePolicy(service);
    final allTraffic = controls.routingMode == 'all_traffic';
    String label(String value) => switch (value) {
      'direct' => 'Напрямую',
      'vpn' => 'Через VPN',
      'zapret' =>
        service.tag == 'discord' ? 'Zapret (эксп.)' : 'Обход · Zapret',
      _ => 'Авто',
    };
    final options = [
      if (_isMobileShell) 'auto',
      'direct',
      'vpn',
      if (!_isMobileShell && service.zapretSupported) 'zapret',
    ];
    final dropdown = Semantics(
      label: 'Способ подключения: ${_homeRouteName(service)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: _atlasSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: _atlasBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: ValueKey('home-route-policy-${service.tag}-$policy'),
            value: options.contains(policy) ? policy : 'direct',
            isExpanded: true,
            isDense: false,
            itemHeight: null,
            menuMaxHeight: 360,
            style: const TextStyle(
              color: _atlasText,
              fontSize: 13,
              fontFamily: 'Inter',
            ),
            icon: const Icon(Icons.expand_more, color: _atlasText),
            items: [
              for (final value in options)
                DropdownMenuItem(
                  value: value,
                  child: Text(
                    label(value),
                    key: ValueKey('home-route-${service.tag}-$value'),
                    maxLines: 2,
                  ),
                ),
            ],
            onChanged: controls.enabled && !allTraffic
                ? (value) {
                    if (value != null && value != policy) {
                      controls.onPolicyChanged(service, value);
                    }
                  }
                : null,
          ),
        ),
      ),
    );
    final identity = Row(
      children: [
        _AtlasServiceIcon(tag: service.tag),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: !controls.connected
                ? 'Сохранённая настройка · подключение выключено'
                : allTraffic
                ? 'Сейчас действует режим «Всё через VPN»'
                : 'Маршрут по данным ядра: ${service.method}',
            child: Text(
              _homeRouteName(service),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ),
        if (!isPrimaryHomeRouteService(service.tag))
          IconButton(
            key: ValueKey('remove-home-route-${service.tag}'),
            tooltip: 'Убрать из быстрого списка',
            onPressed: controls.enabled
                ? () => controls.onRemove(service, false)
                : null,
            icon: const Icon(Icons.close, size: 16),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 260 ||
                  MediaQuery.textScalerOf(context).scale(14) > 19 ||
                  (!isPrimaryHomeRouteService(service.tag) &&
                      constraints.maxWidth < 340)) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [identity, const SizedBox(height: 12), dropdown],
                );
              }
              return Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: constraints.maxWidth > 420 ? 180 : 142,
                    child: dropdown,
                  ),
                ],
              );
            },
          ),
          if (policy == 'zapret' && service.zapretStrategyOptions.isNotEmpty)
            ExpansionTile(
              key: ValueKey('home-route-details-${service.tag}'),
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'Стратегия и ограничения',
                style: TextStyle(color: _atlasMuted, fontSize: 12),
              ),
              children: [
                _HomeZapretStrategyControls(
                  service: service,
                  enabled: controls.enabled && !allTraffic,
                  onChanged: (mode, tag) =>
                      controls.onZapretStrategyChanged(service, mode, tag),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AtlasServiceIcon extends StatelessWidget {
  const _AtlasServiceIcon({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context) {
    final asset = switch (tag) {
      'youtube' => 'youtube',
      'discord' => 'discord',
      'meta' => 'instagram',
      'openai' => 'openai',
      _ => null,
    };
    return ExcludeSemantics(
      child: Container(
        width: 28,
        height: 28,
        padding: EdgeInsets.all(tag == 'openai' ? 0 : 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: switch (tag) {
            'youtube' => const Color(0xFFFF202C),
            'discord' => const Color(0xFF5865F2),
            'openai' => Colors.transparent,
            _ => _atlasSurface,
          },
          gradient: tag == 'meta'
              ? const LinearGradient(
                  begin: Alignment.bottomLeft,
                  end: Alignment.topRight,
                  colors: [
                    Color(0xFFFFCE52),
                    Color(0xFFFF285B),
                    Color(0xFF983ADD),
                  ],
                )
              : null,
        ),
        child: asset == null
            ? const Icon(Icons.language, color: _atlasMint, size: 24)
            : SvgPicture.asset(
                'assets/service-$asset.svg',
                colorFilter: const ColorFilter.mode(
                  _atlasText,
                  BlendMode.srcIn,
                ),
              ),
      ),
    );
  }
}
