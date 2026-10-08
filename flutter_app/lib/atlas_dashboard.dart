part of 'main.dart';

// Adaptive presentation only. Policy changes still go through the existing
// session-aware callbacks; no traffic decisions belong in these widgets.
const _atlasBackground = Color(0xFF05070A);
const _atlasSurface = Color(0xFF0D1217);
const _atlasBorder = Color(0xFF253137);
const _atlasText = Color(0xFFEDF5EF);
const _atlasMuted = Color(0xFFADB8C2);
const _atlasMint = Color(0xFF5CF0B0);

class _AtlasHomeLayout extends StatelessWidget {
  const _AtlasHomeLayout({
    required this.connection,
    required this.routes,
    required this.notices,
    this.telemetry,
    this.servicesExpanded = false,
  });
  final Widget connection, routes;
  final Widget? notices;
  final Widget? telemetry;
  final bool servicesExpanded;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      key: const ValueKey('home'),
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            key: const ValueKey('home-scroll'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: _AtlasAdaptiveHomeBody(
                  viewportHeight: math.max(0, constraints.maxHeight - 24),
                  minimumConnectionExtent:
                      160 *
                      (MediaQuery.textScalerOf(context).scale(17) / 17).clamp(
                        1.0,
                        1.5,
                      ),
                  connection: connection,
                  footer: routes,
                  footerExpanded: servicesExpanded,
                ),
              ),
            ),
          ),
        ),
        if (telemetry != null &&
            constraints.maxWidth >= 760 &&
            MediaQuery.textScalerOf(context).scale(12) <= 18)
          Positioned(top: 24, right: 12, width: 160, child: telemetry!),
        if (notices != null)
          Positioned(
            top: 4,
            left: 12,
            right: 12,
            child: _AtlasNoticeOverlay(
              identity: notices!.key,
              maxHeight: MediaQuery.textScalerOf(context).scale(17) > 23
                  ? 48
                  : constraints.maxHeight < 460
                  ? 56
                  : 100,
              child: notices!,
            ),
          ),
      ],
    ),
  );
}

// Measure the real routing controls first: text scaling must not be guessed
// from the monitor's height. The scroll view
// supplies unbounded height; only genuinely insufficient space causes overflow.
class _AtlasAdaptiveHomeBody extends MultiChildRenderObjectWidget {
  _AtlasAdaptiveHomeBody({
    required this.viewportHeight,
    required this.minimumConnectionExtent,
    required this.footerExpanded,
    required Widget connection,
    required Widget footer,
  }) : super(children: [connection, footer]);

  final double viewportHeight;
  final double minimumConnectionExtent;
  final bool footerExpanded;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAtlasAdaptiveHomeBody(
        viewportHeight,
        minimumConnectionExtent,
        footerExpanded,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAtlasAdaptiveHomeBody renderObject,
  ) {
    renderObject.viewportHeight = viewportHeight;
    renderObject.minimumConnectionExtent = minimumConnectionExtent;
    renderObject.footerExpanded = footerExpanded;
  }
}

class _AtlasHomeParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAtlasAdaptiveHomeBody extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderAtlasAdaptiveHomeBody(
    this._viewportHeight,
    this._minimumConnectionExtent,
    this._footerExpanded,
  );
  double _viewportHeight;
  double _minimumConnectionExtent;
  bool _footerExpanded;
  double? _collapsedFooterHeight;

  set footerExpanded(bool value) {
    if (value == _footerExpanded) return;
    _footerExpanded = value;
    markNeedsLayout();
  }

  set viewportHeight(double value) {
    if (value == _viewportHeight) return;
    _viewportHeight = value;
    markNeedsLayout();
  }

  set minimumConnectionExtent(double value) {
    if (value == _minimumConnectionExtent) return;
    _minimumConnectionExtent = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _AtlasHomeParentData();
    }
  }

  @override
  void performLayout() {
    final connection = firstChild!;
    final footer = lastChild!;
    final width = constraints.maxWidth;
    footer.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    // Expanding services adds content below the unchanged primary controls.
    // Keep the measured collapsed extent, instead of shrinking/recentring the
    // planet to make room for an arbitrarily long catalogue.
    if (!_footerExpanded) _collapsedFooterHeight = footer.size.height;
    final summaryHeight = _collapsedFooterHeight ?? footer.size.height;
    final planetExtent = math.min(
      width,
      math.max(
        _minimumConnectionExtent,
        math.min(280.0, _viewportHeight - summaryHeight - 8),
      ),
    );
    connection.layout(
      BoxConstraints.tightFor(width: width, height: planetExtent),
      parentUsesSize: true,
    );
    final contentHeight = connection.size.height + 8 + footer.size.height;
    final summaryContentHeight = connection.size.height + 8 + summaryHeight;
    final top = math.max(0.0, (_viewportHeight - summaryContentHeight) / 2);
    size = constraints.constrain(
      Size(width, math.max(top + contentHeight, _viewportHeight)),
    );
    (connection.parentData! as ContainerBoxParentData<RenderBox>).offset =
        Offset(0, top);
    (footer.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      0,
      top + connection.size.height + 8,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
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
    this.hasError = false,
    this.motionEnabled = true,
  });
  final String title;
  final Color accent;
  final bool connected, sessionActive, busy, stopping, enabled;
  final bool motionEnabled;
  final bool hasError;
  final VoidCallback onPressed;
  final VoidCallback? onDisabledPressed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(17) > 23;
      final planetSize = math.min(
        constraints.maxWidth,
        constraints.hasBoundedHeight ? constraints.maxHeight : 240.0,
      );
      final actionIcon = busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: MediaQuery.disableAnimationsOf(context) ? 0.65 : null,
              ),
            )
          : Icon(
              hasError && !sessionActive
                  ? Icons.refresh
                  : connected
                  ? Icons.check_circle_outline
                  : Icons.power_settings_new,
              size: 24,
            );
      final actionLabel = Text(
        busy
            ? (stopping ? 'Отключаем…' : 'Подключаем…')
            : sessionActive
            ? 'Отключить'
            : hasError
            ? 'Повторить'
            : 'Подключить',
        textAlign: TextAlign.center,
      );
      return Semantics(
        key: const ValueKey('home-connection-state'),
        label: title,
        liveRegion: true,
        child: _AccessibleDescription(
          message: connected
              ? 'Доступность сервисов проверяется отдельно.'
              : title,
          child: Center(
            child: SizedBox.square(
              dimension: planetSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: _AtlasAnimatedPlanet(
                      connected: connected,
                      busy: busy,
                      hasError: hasError,
                      motionEnabled: motionEnabled,
                      size: planetSize,
                    ),
                  ),
                  SizedBox(
                    width: largeText ? planetSize : math.min(216.0, planetSize),
                    child: FilledButton(
                      key: const ValueKey('home-connect'),
                      onPressed: enabled ? onPressed : onDisabledPressed,
                      style: FilledButton.styleFrom(
                        enabledMouseCursor: SystemMouseCursors.click,
                        disabledMouseCursor: SystemMouseCursors.basic,
                        minimumSize: const Size(48, 52),
                        backgroundColor: connected
                            ? _atlasBackground.withValues(alpha: 0.94)
                            : hasError
                            ? const Color(0xFFFFB4AB)
                            : _atlasMint,
                        foregroundColor: connected
                            ? _atlasText
                            : _atlasBackground,
                        disabledBackgroundColor: _atlasSurface,
                        disabledForegroundColor: _atlasMuted,
                        side: BorderSide(
                          color: hasError
                              ? const Color(0xFFFFB4AB)
                              : enabled
                              ? _atlasMint
                              : _atlasBorder,
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
          ),
        ),
      );
    },
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
              _AccessibleDescription(
                message: c.hasSubscription
                    ? _isMobileShell
                          ? 'Направить интернет-трафик через VPN; локальные адреса идут напрямую'
                          : 'Направить общий трафик через VPN; исключения рабочих сетей сохраняются'
                    : 'Можно использовать бесплатный публичный источник или свою подписку',
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
                ? _isMobileShell
                      ? 'Интернет-трафик — через VPN. Локальные адреса идут напрямую.'
                      : 'Общий трафик — через VPN. Локальные и рабочие сети сохраняют исключения.'
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
              _AccessibleIconButton(
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
        ],
      ],
    );
  }

  Widget _mode(String key, String label, bool selected, VoidCallback action) =>
      Semantics(
        selected: selected,
        child: OutlinedButton(
          key: ValueKey('home-routing-$key'),
          onPressed: controls.enabled ? action : null,
          style: OutlinedButton.styleFrom(
            enabledMouseCursor: SystemMouseCursors.click,
            disabledMouseCursor: SystemMouseCursors.basic,
            foregroundColor: selected ? _atlasBackground : _atlasText,
            backgroundColor: selected ? _atlasMint : _atlasSurface,
            disabledForegroundColor: selected ? _atlasBackground : _atlasMuted,
            disabledBackgroundColor: selected ? _atlasMint : _atlasSurface,
            side: BorderSide(color: selected ? _atlasMint : _atlasBorder),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(label),
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
          child: _AccessibleDescription(
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
          _AccessibleIconButton(
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
