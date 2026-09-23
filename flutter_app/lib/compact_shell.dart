part of 'main.dart';

// Navigation is presentation-only. The session-aware callbacks still own all
// route/source changes, including mobile restrictions while connected.
class _AtlasDesktopShell extends StatefulWidget {
  const _AtlasDesktopShell({
    required this.activeSection,
    required this.disabled,
    required this.onSelect,
    this.onBack,
    required this.onWorkNetworks,
    required this.onExit,
    required this.version,
    this.onAbout,
    this.homeTelemetry,
    this.visible = true,
    required this.child,
    this.notice,
    this.overlay,
  });
  final String activeSection, version;
  final VoidCallback? onAbout;
  final Widget? homeTelemetry;
  final bool visible;
  final bool disabled;
  final ValueChanged<String> onSelect;
  final VoidCallback? onBack;
  final VoidCallback? onWorkNetworks, onExit;
  final Widget child;
  final Widget? notice, overlay;

  @override
  State<_AtlasDesktopShell> createState() => _AtlasDesktopShellState();
}

class _AtlasDesktopShellState extends State<_AtlasDesktopShell> {
  static const _items = <(String, String, IconData)>[
    ('home', 'Подключение', Icons.home_rounded),
    ('services', 'Сервисы', Icons.grid_view_rounded),
    ('sources', 'Источники VPN', Icons.dns_outlined),
    ('logs', 'Диагностика', Icons.monitor_heart_outlined),
    ('settings', 'Настройки', Icons.settings_outlined),
    ('profiles', 'Профили', Icons.layers_outlined),
    ('work', 'Рабочие сети', Icons.hub_outlined),
    ('dropo_space', 'Dropo Space', Icons.workspaces_outline),
    ('stats', 'Статистика', Icons.bar_chart_rounded),
    ('about', 'О приложении', Icons.info_outline),
    ('service-settings', 'Сервисы', Icons.grid_view_rounded),
    ('app-settings', 'Приложение', Icons.settings_outlined),
    ('advanced', 'Дополнительно', Icons.tune),
    ('technical-settings', 'Сеть и диагностика', Icons.tune),
    ('help', 'Помощь', Icons.help_outline),
  ];
  static const _primarySections = {
    'home',
    'services',
    'sources',
    'settings',
    'help',
  };
  bool _open = false;
  final _toggleFocus = FocusNode(debugLabel: 'navigation-toggle');
  final _drawerFocus = FocusScopeNode(debugLabel: 'navigation-drawer');

  @override
  void dispose() {
    _toggleFocus.dispose();
    _drawerFocus.dispose();
    super.dispose();
  }

  void _close({bool restoreFocus = false}) {
    if (!_open) return;
    setState(() {
      _open = false;
    });
    if (restoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toggleFocus.requestFocus();
      });
    }
  }

  void _show() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _drawerFocus.requestFocus();
    });
  }

  String get _parentSection => switch (widget.activeSection) {
    'service-settings' => 'services',
    'profiles' || 'work' || 'dropo_space' || 'technical-settings' => 'advanced',
    'logs' || 'stats' || 'about' => 'help',
    _ => 'settings',
  };

  String get _selectedPrimary => switch (widget.activeSection) {
    'service-settings' => 'services',
    'logs' || 'stats' || 'about' => 'help',
    final section when _primarySections.contains(section) => section,
    _ => 'settings',
  };

  bool get _hasParent => !_primarySections.contains(widget.activeSection);

  void _back() {
    if (widget.disabled) return;
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      widget.onSelect(_parentSection);
    }
  }

  void _select(String section) {
    if (widget.disabled) return;
    _close();
    if (section == 'work') {
      widget.onWorkNetworks?.call();
    } else {
      widget.onSelect(section);
    }
  }

  Widget _toggle({bool close = false}) => IconButton(
    key: ValueKey(close ? 'close-navigation' : 'toggle-navigation'),
    focusNode: close ? null : _toggleFocus,
    tooltip: close ? 'Закрыть меню' : 'Открыть меню',
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    icon: Icon(close ? Icons.close : Icons.menu_rounded),
    mouseCursor: SystemMouseCursors.click,
    onPressed: () => close ? _close(restoreFocus: true) : _show(),
  );

  Widget _item((String, String, IconData) item, {bool compact = false}) {
    final (section, label, icon) = item;
    final selected = _selectedPrimary == section;
    final enabled =
        !widget.disabled &&
        (section != 'work' || widget.onWorkNetworks != null);
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: compact ? label : '',
        excludeFromSemantics: compact,
        child: TextButton(
          key: ValueKey('nav-$section'),
          onPressed: enabled ? () => _select(section) : null,
          style: TextButton.styleFrom(
            enabledMouseCursor: SystemMouseCursors.click,
            disabledMouseCursor: SystemMouseCursors.basic,
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 0 : 14,
              vertical: 12,
            ),
            foregroundColor: selected ? _atlasMint : _atlasMuted,
            backgroundColor: selected
                ? _atlasMint.withValues(alpha: 0.12)
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: compact
              ? Icon(icon, size: 24, semanticLabel: label)
              : Row(
                  children: [
                    Icon(icon, size: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(label, style: const TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final showRail = screen.width >= 520;
    final navigationTextScale = MediaQuery.textScalerOf(context).scale(15) / 15;
    final expandedRail = screen.width >= 800 && navigationTextScale <= 1.5;
    final railWidth = showRail
        ? (expandedRail
              ? 208.0 + math.max(0.0, navigationTextScale - 1) * 144
              : 56.0)
        : 0.0;
    final contentWidth = screen.width - railWidth;
    final reserveFooter =
        widget.activeSection != 'home' ||
        contentWidth < 608 ||
        navigationTextScale > 1.3;
    final compactTelemetry = contentWidth < 760 || navigationTextScale > 1.5;
    Widget versionLink() => Tooltip(
      message: 'О приложении',
      child: TextButton(
        key: const ValueKey('app-version'),
        onPressed: widget.onAbout,
        style: TextButton.styleFrom(
          minimumSize: const Size(88, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerRight,
        ),
        child: Text(
          'v${widget.version}',
          style: const TextStyle(fontSize: 12, color: _atlasMuted),
        ),
      ),
    );
    final title =
        _items
            .where((item) => item.$1 == widget.activeSection)
            .firstOrNull
            ?.$2 ??
        'Подключение';
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
            enabledMouseCursor: SystemMouseCursors.click,
            disabledMouseCursor: SystemMouseCursors.basic,
            textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(color: _atlasSurface),
      ),
      child: PopScope(
        canPop: !_open && !_hasParent,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            if (_open) {
              _close(restoreFocus: true);
            } else if (_hasParent && !widget.disabled) {
              _back();
            }
          }
        },
        child: Scaffold(
          backgroundColor: _atlasBackground,
          body: SafeArea(
            child: Stack(
              children: [
                ExcludeFocus(
                  excluding: _open,
                  child: ExcludeSemantics(
                    excluding: _open,
                    child: TickerMode(
                      enabled:
                          widget.visible && !_open && widget.overlay == null,
                      child: Padding(
                        padding: EdgeInsets.only(left: railWidth),
                        child: Column(
                          children: [
                            Container(
                              key: const ValueKey('compact-header'),
                              constraints: const BoxConstraints(minHeight: 48),
                              padding: EdgeInsets.only(
                                left: showRail ? 16 : 0,
                                right: 16,
                              ),
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: _atlasBorder),
                                ),
                              ),
                              child: Row(
                                children: [
                                  if (!showRail) _toggle(),
                                  if (_hasParent)
                                    IconButton(
                                      key: const ValueKey('section-back'),
                                      tooltip: 'Назад',
                                      onPressed: widget.disabled ? null : _back,
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                  const Text(
                                    'Dropo',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.8,
                                    ),
                                  ),
                                  if (screen.width >= 600 &&
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) <=
                                          20) ...[
                                    const SizedBox(width: 8),
                                    const Text(
                                      'by sunnydjam',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _atlasMuted,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: widget.activeSection == 'home'
                                        ? Align(
                                            alignment: Alignment.centerRight,
                                            child: compactTelemetry
                                                ? widget.homeTelemetry
                                                : null,
                                          )
                                        : Text(
                                            title,
                                            textAlign: TextAlign.end,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: widget.activeSection == 'home'
                                  ? widget.child
                                  : Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        children: [
                                          Expanded(child: widget.child),
                                        ],
                                      ),
                                    ),
                            ),
                            if (reserveFooter)
                              Align(
                                alignment: Alignment.centerRight,
                                child: versionLink(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!reserveFooter && !_open && widget.overlay == null)
                  Positioned(right: 8, bottom: 0, child: versionLink()),
                if (showRail && !_open)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: railWidth,
                    child: MouseRegion(
                      key: const ValueKey('navigation-rail'),
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: _atlasSurface,
                          border: Border(
                            right: BorderSide(color: _atlasBorder),
                          ),
                        ),
                        child: Column(
                          children: [
                            if (expandedRail)
                              const SizedBox(
                                height: 48,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 18),
                                    child: Text(
                                      'Навигация',
                                      style: TextStyle(color: _atlasMuted),
                                    ),
                                  ),
                                ),
                              )
                            else
                              _toggle(),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                                children: [
                                  for (final item in _items)
                                    if (_primarySections.contains(item.$1))
                                      _item(item, compact: !expandedRail),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (widget.notice != null && !_open)
                  Positioned(
                    top: 4,
                    left: railWidth + 8,
                    right: 8,
                    child: _AtlasNoticeOverlay(
                      identity: widget.notice!.key,
                      maxHeight: 96,
                      child: widget.notice!,
                    ),
                  ),
                if (_open) ...[
                  Positioned.fill(
                    child: ModalBarrier(
                      key: const ValueKey('navigation-scrim'),
                      dismissible: true,
                      onDismiss: () => _close(restoreFocus: true),
                      color: Colors.black.withValues(alpha: 0.35),
                      semanticsLabel: 'Закрыть меню',
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: math.min(280, screen.width - 48),
                    child: MouseRegion(
                      child: FocusScope(
                        node: _drawerFocus,
                        autofocus: true,
                        onKeyEvent: (_, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.escape) {
                            _close(restoreFocus: true);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: Material(
                          key: const ValueKey('navigation-drawer'),
                          color: _atlasSurface,
                          elevation: 16,
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  _toggle(close: true),
                                  const Text(
                                    'Dropo',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 1),
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.all(12),
                                  children: [
                                    for (final item in _items)
                                      if (_primarySections.contains(item.$1))
                                        _item(item),
                                    Padding(
                                      padding: const EdgeInsets.only(top: 16),
                                      child: Text(
                                        widget.version,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: _atlasMuted,
                                        ),
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
                  ),
                ],
                if (widget.overlay != null)
                  Positioned.fill(child: widget.overlay!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Overlay messages never become layout children of the page. Closing only
// collapses the presentation: errors and ongoing probes can still be opened.
class _AtlasNoticeOverlay extends StatefulWidget {
  const _AtlasNoticeOverlay({
    required this.child,
    required this.maxHeight,
    this.identity,
  });

  final Widget child;
  final double maxHeight;
  final Key? identity;

  @override
  State<_AtlasNoticeOverlay> createState() => _AtlasNoticeOverlayState();
}

class _AtlasNoticeOverlayState extends State<_AtlasNoticeOverlay> {
  bool _collapsed = false;

  @override
  void didUpdateWidget(covariant _AtlasNoticeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) _collapsed = false;
  }

  void _showDetails() {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Сообщения подключения')),
                    IconButton(
                      tooltip: 'Закрыть',
                      mouseCursor: SystemMouseCursors.click,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Flexible(child: SingleChildScrollView(child: widget.child)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Material(
        key: const ValueKey('notice-overlay'),
        elevation: 6,
        color: _atlasSurface,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: _collapsed
            ? TextButton.icon(
                key: const ValueKey('reopen-notice'),
                onPressed: _showDetails,
                icon: const Icon(Icons.notifications_none, size: 18),
                label: const Text('Сообщения'),
              )
            : ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.maxHeight),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: SingleChildScrollView(child: widget.child),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('expand-notice'),
                      tooltip: 'Открыть сообщение полностью',
                      mouseCursor: SystemMouseCursors.click,
                      onPressed: _showDetails,
                      icon: const Icon(Icons.open_in_full, size: 16),
                    ),
                    IconButton(
                      key: const ValueKey('dismiss-notice'),
                      tooltip: 'Свернуть сообщение',
                      mouseCursor: SystemMouseCursors.click,
                      onPressed: () => setState(() => _collapsed = true),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}
