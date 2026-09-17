part of 'main.dart';

// Desktop presentation only. Policy changes still go through the existing
// session-aware callbacks; no traffic decisions belong in these widgets.
const _atlasBackground = Color(0xFF071F17);
const _atlasSurface = Color(0xFF10271F);
const _atlasBorder = Color(0xFF29483C);
const _atlasText = Color(0xFFEDF5EF);
const _atlasMuted = Color(0xFFADC2B7);
const _atlasMint = Color(0xFF5CF0B0);

class _AtlasDesktopShell extends StatelessWidget {
  const _AtlasDesktopShell({
    required this.activeSection,
    required this.disabled,
    required this.onSelect,
    required this.onWorkNetworks,
    required this.onExit,
    required this.version,
    required this.child,
    this.notice,
    this.overlay,
  });
  final String activeSection, version;
  final bool disabled;
  final ValueChanged<String> onSelect;
  final VoidCallback? onWorkNetworks, onExit;
  final Widget child;
  final Widget? notice, overlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The approved desktop theme is deliberately forest-dark, independent of
    // the system theme. Apply it locally so popups keep readable contrast too.
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: _atlasMint,
              brightness: Brightness.dark,
            ).copyWith(
              primary: _atlasMint,
              surface: _atlasSurface,
              onSurface: _atlasText,
            ),
        textTheme: ThemeData.dark().textTheme.apply(
          fontFamily: 'Inter',
          bodyColor: _atlasText,
          displayColor: _atlasText,
        ),
        dividerColor: _atlasBorder,
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(color: _atlasSurface),
      ),
      child: Scaffold(
        backgroundColor: _atlasBackground,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _header(),
                  if (notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: notice!,
                    ),
                  Expanded(
                    child: activeSection == 'home'
                        ? child
                        : Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1120),
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  children: [
                                    if (activeSection == 'settings')
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Wrap(
                                          spacing: 12,
                                          runSpacing: 8,
                                          children: [
                                            _shortcut(
                                              'Профили',
                                              Icons.layers_outlined,
                                              'profiles',
                                            ),
                                            TextButton.icon(
                                              key: const ValueKey(
                                                'home-work-networks',
                                              ),
                                              onPressed: onWorkNetworks,
                                              icon: const Icon(
                                                Icons.hub_outlined,
                                                size: 18,
                                              ),
                                              label: const Text('Рабочие сети'),
                                            ),
                                            _shortcut(
                                              'Статистика',
                                              Icons.bar_chart,
                                              'stats',
                                            ),
                                            TextButton.icon(
                                              onPressed: onExit,
                                              icon: const Icon(
                                                Icons.logout,
                                                size: 18,
                                              ),
                                              label: const Text('Выход'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Expanded(child: child),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                  _footer(),
                ],
              ),
            ),
            if (overlay != null) Positioned.fill(child: overlay!),
          ],
        ),
      ),
    );
  }

  Widget _shortcut(String label, IconData icon, String section) =>
      TextButton.icon(
        onPressed: disabled ? null : () => onSelect(section),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  Widget _header() => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _atlasBorder)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 800 ||
            MediaQuery.textScalerOf(context).scale(16) > 20;
        final brand = Semantics(
          label: 'Dropo by sunnydjam',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Dropo',
                style: TextStyle(
                  fontSize: compact ? 26 : 38,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'by sunnydjam',
                style: TextStyle(fontSize: 14, color: _atlasMuted),
              ),
            ],
          ),
        );
        final tabs = Wrap(
          spacing: 22,
          runSpacing: 4,
          children: [
            _tab('home', 'Главная', Icons.home_outlined),
            _tab('services', 'Сервисы', Icons.grid_view_outlined),
            _tab('sources', 'Источники VPN', Icons.dns_outlined),
            _tab('logs', 'Диагностика', Icons.monitor_heart_outlined),
          ],
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              brand,
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tab in tabs.children)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: tab,
                      ),
                  ],
                ),
              ),
            ],
          );
        }
        return Row(
          children: [
            brand,
            const SizedBox(width: 72),
            Expanded(child: tabs),
          ],
        );
      },
    ),
  );

  Widget _tab(String section, String label, IconData icon) {
    final selected = activeSection == section;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? _atlasMint : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Semantics(
        selected: selected,
        child: TextButton.icon(
          key: ValueKey('nav-$section'),
          onPressed: disabled ? null : () => onSelect(section),
          style: TextButton.styleFrom(
            foregroundColor: selected ? _atlasMint : _atlasText,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
            textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          icon: Icon(icon, size: 24),
          label: Text(label),
        ),
      ),
    );
  }

  Widget _footer() => Container(
    margin: const EdgeInsets.symmetric(horizontal: 24),
    padding: const EdgeInsets.symmetric(vertical: 14),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _atlasBorder)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final links = Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _shortcut('Настройки', Icons.settings, 'settings'),
            _shortcut('О приложении', Icons.info_outline, 'about'),
          ],
        );
        final diagnostic = TextButton(
          key: const ValueKey('home-diagnostics'),
          onPressed: disabled ? null : () => onSelect('logs'),
          child: const Text(
            'Проверить подключение',
            style: TextStyle(decoration: TextDecoration.underline),
          ),
        );
        if (constraints.maxWidth < 680 ||
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [links, diagnostic],
          );
        }
        return Row(
          children: [
            links,
            const Spacer(),
            Tooltip(message: version, child: diagnostic),
          ],
        );
      },
    ),
  );
}

class _AtlasHomeLayout extends StatelessWidget {
  const _AtlasHomeLayout({
    required this.connection,
    required this.source,
    required this.routes,
    required this.notices,
  });
  final Widget connection, source, routes, notices;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 900 ||
          MediaQuery.textScalerOf(context).scale(16) > 22;
      final left = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          connection,
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 390),
              child: source,
            ),
          ),
        ],
      );
      final right = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          notices,
          routes,
          const SizedBox(height: 32),
          const Text(
            'Доступность сервисов проверяется отдельно.',
            textAlign: TextAlign.end,
            style: TextStyle(color: _atlasMuted, fontSize: 13, height: 1.5),
          ),
        ],
      );
      return Padding(
        key: const ValueKey('home'),
        padding: EdgeInsets.symmetric(
          horizontal: stacked ? 20 : 28,
          vertical: 28,
        ),
        child: stacked
            ? Column(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: left,
                  ),
                  const SizedBox(height: 32),
                  right,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 37, child: left),
                  Expanded(
                    flex: 63,
                    child: Container(
                      decoration: const BoxDecoration(
                        border: Border(left: BorderSide(color: _atlasBorder)),
                      ),
                      padding: const EdgeInsets.only(
                        left: 32,
                        top: 6,
                        bottom: 20,
                      ),
                      child: right,
                    ),
                  ),
                ],
              ),
      );
    },
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
  });
  final String title;
  final Color accent;
  final bool connected, sessionActive, busy, stopping, enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Semantics(
          liveRegion: true,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: connected
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.28),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  title,
                  key: const ValueKey('home-connection-state'),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.7,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 4),
      if (MediaQuery.sizeOf(context).height > 700 ||
          MediaQuery.textScalerOf(context).scale(16) <= 22)
        ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedOpacity(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 280),
              opacity: connected ? 1 : 0.55,
              child: Image.asset(
                'assets/atlas-earth.png',
                key: const ValueKey('atlas-planet'),
                width: math.min(
                  480,
                  math.max(180, MediaQuery.sizeOf(context).height - 450),
                ),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: SizedBox(
          width: 376,
          child: FilledButton.icon(
            key: const ValueKey('home-connect'),
            onPressed: enabled ? onPressed : null,
            style: FilledButton.styleFrom(
              backgroundColor: connected ? Colors.transparent : _atlasMint,
              foregroundColor: connected ? _atlasText : _atlasBackground,
              disabledBackgroundColor: _atlasSurface,
              disabledForegroundColor: _atlasMuted,
              side: BorderSide(
                color: enabled ? _atlasMint : _atlasBorder,
                width: 2,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              textStyle: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
              shape: const StadiumBorder(),
            ),
            icon: busy
                ? const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.power_settings_new, size: 30),
            label: Text(
              busy
                  ? (stopping ? 'Отключаем…' : 'Подождите')
                  : sessionActive
                  ? 'Отключить'
                  : 'Подключить',
            ),
          ),
        ),
      ),
    ],
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
      padding: const EdgeInsets.all(18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    child: Row(
      children: [
        const Icon(Icons.dns_outlined, size: 28),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                key: const ValueKey('home-source-title'),
                style: const TextStyle(
                  fontSize: 16,
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
        const Icon(Icons.expand_more, size: 20),
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
        const Text(
          'Как подключаться',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 16),
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
            if (constraints.maxWidth < 510 ||
                MediaQuery.textScalerOf(context).scale(16) > 22) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [buttons[0], const SizedBox(height: 10), buttons[1]],
              );
            }
            return Row(
              children: [
                Expanded(child: buttons[0]),
                const SizedBox(width: 12),
                Expanded(child: buttons[1]),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          allTraffic
              ? 'Общий трафик — через VPN. Локальные и рабочие сети сохраняют исключения.'
              : 'Сервисы и правила блокировок. Остальное — напрямую.',
          style: const TextStyle(color: _atlasMuted, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 30),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            const Text(
              'Избранные сервисы',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('toggle-home-route-services'),
              onPressed: () => c.onExpandedChanged(!c.expanded),
              iconAlignment: IconAlignment.end,
              icon: Icon(c.expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(c.expanded ? 'Свернуть' : 'Развернуть'),
            ),
          ],
        ),
        const SizedBox(height: 10),
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
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(height: 1, color: _atlasBorder),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('add-home-route-service'),
                        onPressed: c.onAdd,
                        icon: const Icon(Icons.add, size: 24),
                        label: const Text('Добавить сервис'),
                      ),
                      TextButton.icon(
                        key: const ValueKey('home-all-services'),
                        onPressed: c.onAllServices,
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.arrow_forward, size: 20),
                        label: const Text('Все сервисы'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _mode(
    String key,
    String label,
    bool selected,
    VoidCallback action,
  ) => Semantics(
    selected: selected,
    child: OutlinedButton.icon(
      key: ValueKey('home-routing-$key'),
      onPressed: controls.enabled ? action : null,
      icon: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 24,
      ),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? _atlasBackground : _atlasText,
        backgroundColor: selected ? _atlasMint : _atlasSurface,
        side: BorderSide(color: selected ? _atlasMint : _atlasBorder),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
      _ => 'Автоматически',
    };
    final options = [
      'auto',
      'direct',
      'vpn',
      if (service.zapretSupported) 'zapret',
    ];
    final dropdown = Semantics(
      label: 'Способ подключения: ${_homeRouteName(service)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: _atlasSurface,
          border: Border.all(color: _atlasBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: ValueKey('home-route-policy-${service.tag}-$policy'),
            value: options.contains(policy) ? policy : 'auto',
            isExpanded: true,
            isDense: true,
            itemHeight: null,
            menuMaxHeight: 360,
            style: const TextStyle(
              color: _atlasText,
              fontSize: 17,
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
        const SizedBox(width: 18),
        Expanded(
          child: Tooltip(
            message: !controls.connected
                ? 'Сохранённая настройка · подключение выключено'
                : allTraffic
                ? 'Сейчас действует режим «Всё через VPN»'
                : 'Маршрут по данным ядра: ${service.method}',
            child: Text(
              _homeRouteName(service),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
            ),
          ),
        ),
        if (!isPrimaryHomeRouteService(service.tag))
          IconButton(
            key: ValueKey('remove-home-route-${service.tag}'),
            tooltip: 'Убрать с главной',
            onPressed: controls.enabled
                ? () => controls.onRemove(service, false)
                : null,
            icon: const Icon(Icons.close, size: 16),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 420 ||
                  MediaQuery.textScalerOf(context).scale(16) > 22) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [identity, const SizedBox(height: 12), dropdown],
                );
              }
              return Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: constraints.maxWidth > 650 ? 244 : 208,
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
        width: 44,
        height: 44,
        padding: EdgeInsets.all(tag == 'openai' ? 0 : 8),
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
