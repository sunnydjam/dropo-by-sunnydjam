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
    required this.child,
    this.notice,
    this.overlay,
  });
  final String activeSection, version;
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
  static const _primarySections = {'home', 'settings'};
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
    'services' => 'service-settings',
    'profiles' || 'work' || 'dropo_space' || 'technical-settings' => 'advanced',
    'logs' || 'stats' || 'about' => 'help',
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
    onPressed: () => close ? _close(restoreFocus: true) : _show(),
  );

  Widget _item((String, String, IconData) item, {bool compact = false}) {
    final (section, label, icon) = item;
    final selected =
        widget.activeSection == section ||
        (section == 'settings' && _hasParent);
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
    final railWidth = showRail ? 56.0 : 0.0;
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
                      enabled: !_open && widget.overlay == null,
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
                                    child: Text(
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
                            if (widget.notice != null)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: widget.notice!,
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
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
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
                            _toggle(),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                                children: [
                                  for (final item in _items.take(1))
                                    _item(item, compact: true),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: _item(_items[4], compact: true),
                            ),
                          ],
                        ),
                      ),
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
