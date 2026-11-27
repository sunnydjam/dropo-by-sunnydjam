part of 'main.dart';

// Adaptive presentation only. Policy changes still go through the existing
// session-aware callbacks; no traffic decisions belong in these widgets.
const _atlasBackground = Color(0xFF05070A);
const _atlasSurface = Color(0xFF0D1217);
const _atlasBorder = Color(0xFF253137);
const _atlasText = Color(0xFFEDF5EF);
const _atlasMuted = Color(0xFFADB8C2);
const _atlasMint = Color(0xFF5CF0B0);

class _RoutingReveal extends StatelessWidget {
  const _RoutingReveal({required this.motion, required this.child});
  final Widget child;
  final bool motion;
  @override
  Widget build(BuildContext context) {
    if (!motion || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      child: child,
      builder: (context, value, content) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: value,
          child: Opacity(opacity: value, child: content),
        ),
      ),
    );
  }
}

class _AtlasHomeLayout extends StatelessWidget {
  const _AtlasHomeLayout({
    required this.connection,
    required this.routes,
    required this.notices,
    this.updateNotice,
    this.telemetry,
    required this.catalog,
    this.noticeLabel = 'Сообщения',
    this.turboOffer,
  });
  final Widget connection, routes;
  final Widget? notices;
  final Widget? updateNotice;
  final Widget? telemetry;
  final Widget catalog;
  final String noticeLabel;
  final Widget? turboOffer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        if (updateNotice != null)
          Padding(
            key: const ValueKey('home-update-slot'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: updateNotice!,
            ),
          ),
        Expanded(child: _body(context)),
        if (turboOffer != null &&
            MediaQuery.viewInsetsOf(context).bottom == 0 &&
            View.of(context).viewInsets.bottom == 0)
          SafeArea(
            top: false,
            minimum: EdgeInsets.fromLTRB(
              16,
              _compactDesktopHome(context) ? 0 : 6,
              16,
              _isMobileShell ? 12 : 6,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: turboOffer!,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _body(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      key: const ValueKey('home'),
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            key: const ValueKey('home-scroll'),
            padding: EdgeInsets.fromLTRB(
              16,
              constraints.maxHeight < 460 ? 4 : 12,
              16,
              _compactDesktopHome(context)
                  ? 0
                  : (constraints.maxHeight < 460 ? 4 : 12),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: _AtlasAdaptiveHomeBody(
                  viewportHeight: math.max(
                    0,
                    constraints.maxHeight -
                        (constraints.maxHeight < 460 ? 4 : 12) -
                        (_compactDesktopHome(context)
                            ? 0
                            : (constraints.maxHeight < 460 ? 4 : 12)),
                  ),
                  minimumConnectionExtent:
                      (_compactDesktopHome(context) ? 156 : 160) *
                      (MediaQuery.textScalerOf(context).scale(17) / 17).clamp(
                        1.0,
                        1.5,
                      ),
                  connection: connection,
                  footer: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_isMobileShell) const SizedBox(height: 16),
                      routes,
                      if (_isMobileShell) const SizedBox(height: 8),
                    ],
                  ),
                  catalog: catalog,
                  footerReserveExtent: _homeServicesHeaderExtent(context),
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
              collapsedLabel: noticeLabel,
              maxHeight:
                  MediaQuery.textScalerOf(context).scale(17) > 23 ||
                      constraints.maxHeight < 460
                  ? 48
                  : _compactDesktopHome(context)
                  ? 48
                  : constraints.maxWidth >= 960 && constraints.maxHeight >= 600
                  ? math.min(220, constraints.maxHeight * .23)
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
    required Widget catalog,
    required this.footerReserveExtent,
    required Widget connection,
    required Widget footer,
  }) : super(children: [connection, footer, catalog]);

  final double viewportHeight;
  final double minimumConnectionExtent;
  final double footerReserveExtent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAtlasAdaptiveHomeBody(
        viewportHeight,
        minimumConnectionExtent,
        footerReserveExtent,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAtlasAdaptiveHomeBody renderObject,
  ) {
    renderObject.viewportHeight = viewportHeight;
    renderObject.minimumConnectionExtent = minimumConnectionExtent;
    renderObject.footerReserveExtent = footerReserveExtent;
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
    this._footerReserveExtent,
  );
  double _viewportHeight;
  double _minimumConnectionExtent;
  double _footerReserveExtent;
  set footerReserveExtent(double value) {
    if (value == _footerReserveExtent) return;
    _footerReserveExtent = value;
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
    final footer = childAfter(connection)!;
    final catalog = lastChild!;
    catalog.layout(
      BoxConstraints.tightFor(width: constraints.maxWidth),
      parentUsesSize: true,
    );
    final width = constraints.maxWidth;
    footer.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    final summaryHeight = footer.size.height + _footerReserveExtent;
    final planetExtent = math.min(
      width,
      math.max(
        _minimumConnectionExtent,
        math.min(600.0, _viewportHeight - summaryHeight - 8),
      ),
    );
    connection.layout(
      BoxConstraints.tightFor(width: width, height: planetExtent),
      parentUsesSize: true,
    );
    final contentHeight = connection.size.height + 8 + footer.size.height;
    final summaryContentHeight = connection.size.height + 8 + summaryHeight;
    // A wide desktop composition floats slightly above the vertical centre,
    // as in the approved concept. Compact windows and phone accessibility
    // layouts retain their full measured space, without a forced top offset.
    final wideSceneBias = width >= 700 && _viewportHeight >= 760 ? 64.0 : 0.0;
    final top = math.max(
      0.0,
      (_viewportHeight - summaryContentHeight) / 2 - wideSceneBias,
    );
    // A shorter tab must still let the tab bar stay at the top of the viewport.
    final catalogHeight = catalog.size.height > 0
        ? math.max(catalog.size.height, _viewportHeight)
        : 0.0;
    size = constraints.constrain(
      Size(
        width,
        math.max(top + contentHeight + catalogHeight, _viewportHeight),
      ),
    );
    (connection.parentData! as ContainerBoxParentData<RenderBox>).offset =
        Offset(0, top);
    (footer.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      0,
      top + connection.size.height + 8,
    );
    (catalog.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      0,
      top + contentHeight,
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
    required this.checking,
    required this.busy,
    required this.stopping,
    required this.enabled,
    required this.onPressed,
    this.hasError = false,
    this.motionEnabled = true,
    this.connecting = false,
    this.animatedScene = false,
    this.connectionAttempt = 0,
    this.onLanded,
  });
  final String title;
  final Color accent;
  final bool connected, sessionActive, busy, stopping, enabled;
  final bool motionEnabled;
  final bool hasError;
  final VoidCallback onPressed;

  final bool checking;
  final bool connecting, animatedScene;
  final int connectionAttempt;
  final VoidCallback? onLanded;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(17) > 23;
      final desktopComposition = animatedScene && !_isMobileShell;
      final planetSize = math.min(
        constraints.maxWidth,
        constraints.hasBoundedHeight ? constraints.maxHeight : 240.0,
      );
      final widePlanet = planetSize >= 480;
      final actionIcon = busy || checking
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
                  ? Icons.power_settings_new
                  : Icons.power_settings_new,
              size: 24,
            );
      final actionLabel = Text(
        checking && !stopping
            ? 'Проверяем соединение…'
            : busy
            ? (stopping ? 'Отключаем…' : 'Подключаем…')
            : sessionActive
            ? 'Отключить'
            : hasError
            ? 'Повторить'
            : 'Подключить',
        textAlign: TextAlign.center,
        style: connected
            ? const TextStyle(
                shadows: [
                  Shadow(color: Colors.black, blurRadius: 6),
                  Shadow(color: Colors.black, blurRadius: 2),
                ],
              )
            : null,
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
                      connecting: animatedScene && connecting,
                      connectionAttempt: animatedScene ? connectionAttempt : 0,
                      onLanded: onLanded,
                      desktopComposition: desktopComposition,
                      hasError: hasError,
                      motionEnabled: motionEnabled,
                      size: planetSize,
                    ),
                  ),
                  if (animatedScene)
                    _PlanetAction(
                      size: planetSize,
                      accent: accent,
                      connecting: connecting || checking,
                      stopping: stopping,
                      sessionActive: sessionActive,
                      hasError: hasError,
                      onPressed: enabled ? onPressed : null,
                      desktopComposition: desktopComposition,
                    )
                  else
                    SizedBox(
                      width: largeText
                          ? planetSize
                          : math.min(
                              math.max(244.0, planetSize * 0.56),
                              planetSize,
                            ),
                      child: FilledButton(
                        key: const ValueKey('home-connect'),
                        onPressed: enabled ? onPressed : null,
                        style: FilledButton.styleFrom(
                          enabledMouseCursor: SystemMouseCursors.click,
                          disabledMouseCursor: SystemMouseCursors.basic,
                          minimumSize: Size(48, widePlanet ? 60 : 52),
                          backgroundColor: connected
                              ? Colors.transparent
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
                          textStyle: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: widePlanet ? 19 : 17,
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

class _PlanetAction extends StatelessWidget {
  const _PlanetAction({
    required this.size,
    required this.accent,
    required this.connecting,
    required this.stopping,
    required this.sessionActive,
    required this.hasError,
    required this.onPressed,
    required this.desktopComposition,
  });

  final double size;
  final Color accent;
  final bool connecting, stopping, sessionActive, hasError;
  final bool desktopComposition;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final waiting = connecting || stopping;
    final start = !sessionActive && !waiting;
    final powerSize = (size * .31).clamp(48.0, 78.0);
    final hintFontSize = desktopComposition
        ? (size * .11).clamp(20.0, 36.0)
        : (size * .13).clamp(22.0, 34.0);
    final arrowTop = size / 2 + powerSize * .25;
    final arrowHeight = desktopComposition
        ? math.max(
            size * .15,
            size -
                arrowTop -
                MediaQuery.textScalerOf(context).scale(hintFontSize) -
                7,
          )
        : size * .27;
    final hint = hasError ? 'Попробовать снова' : 'Подключиться';
    final label = stopping
        ? 'Отключаем…'
        : connecting
        ? 'Проверяем соединение…'
        : 'Отключить';
    final power = FilledButton(
      key: const ValueKey('home-connect'),
      onPressed: waiting ? null : onPressed,
      style: FilledButton.styleFrom(
        enabledMouseCursor: SystemMouseCursors.click,
        backgroundColor: start
            ? (hasError ? const Color(0x20FF566C) : const Color(0x20FFFFFF))
            : const Color(0xED102019),
        disabledBackgroundColor: const Color(0xED102019),
        foregroundColor: Colors.white,
        disabledForegroundColor: _atlasText,
        padding: start
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: start ? Size.square(powerSize) : const Size(48, 48),
        side: BorderSide(
          color: start
              ? (hasError ? const Color(0x99FF9BA8) : const Color(0x66FFFFFF))
              : const Color(0x558CAF9D),
        ),
        shape: start
            ? const CircleBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      child: start
          ? Icon(
              hasError ? Icons.refresh : Icons.power_settings_new,
              size: 32,
              semanticLabel: _uiText(context, hint),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting)
                  SizedBox.square(
                    dimension: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.power_settings_new, size: 17),
                const SizedBox(width: 8),
                Flexible(child: Text(_uiText(context, label))),
              ],
            ),
    );

    final controls = Stack(
      alignment: Alignment.center,
      children: [
        if ((start || (desktopComposition && sessionActive && !waiting)) &&
            onPressed != null)
          ClipOval(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: onPressed,
                child: SizedBox.square(
                  dimension:
                      size * (desktopComposition ? (start ? .75 : .67) : .85),
                ),
              ),
            ),
          ),
        if (start) ...[
          power,
          Positioned(
            top: arrowTop,
            left: size / 2 + powerSize * .43,
            child: IgnorePointer(
              child: CustomPaint(
                size: Size(size * .22, arrowHeight),
                painter: _ConnectArrow(compactHead: desktopComposition),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: desktopComposition ? size * .08 : 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Transform.rotate(
                    angle: -.10,
                    child: Text(
                      _uiText(context, hint),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Caveat',
                        fontWeight: FontWeight.w600,
                        fontSize: hintFontSize,
                        height: desktopComposition ? 1 : null,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ] else
          Align(
            alignment: desktopComposition && !waiting
                ? Alignment.center
                : Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: power,
            ),
          ),
      ],
    );
    return desktopComposition
        ? SizedBox.square(dimension: size, child: controls)
        : controls;
  }
}

class _ConnectArrow extends CustomPainter {
  const _ConnectArrow({required this.compactHead});

  final bool compactHead;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final headWidth = compactHead ? math.min(w * .33, 17.0) : w * .33;
    final headHeight = compactHead ? math.min(h * .24, 18.0) : h * .24;
    final arrow = Path()
      ..moveTo(w * .52, h)
      ..cubicTo(w * .99, h * .80, w * 1.04, h * .27, 0, 0)
      ..moveTo(headWidth, h * .006)
      ..lineTo(0, 0)
      ..lineTo(headWidth * (.14 / .33), headHeight);
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ConnectArrow oldDelegate) =>
      oldDelegate.compactHead != compactHead;
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
            final stacked =
                constraints.maxWidth < 275 ||
                MediaQuery.textScalerOf(context).scale(14) > 19;
            final showIcons = stacked || constraints.maxWidth >= 340;
            final buttons = [
              _AccessibleDescription(
                message:
                    'Сохранённые маршруты сервисов и каталоги блокировок. Остальное — напрямую.',
                child: _mode(
                  'selected',
                  'Ручное',
                  !allTraffic,
                  () => c.onRoutingModeChanged('blocked_only'),
                  joined: !stacked,
                  showIcon: showIcons,
                ),
              ),
              _AccessibleDescription(
                message: c.hasSubscription
                    ? 'Заблокированные сервисы и сервисы с ограничениями для РФ через VPN, обычные сайты напрямую'
                    : 'Можно использовать бесплатный публичный источник или свою подписку',
                child: _mode(
                  'all-vpn',
                  'Всё через VPN',
                  allTraffic,
                  () => c.onRoutingModeChanged('all_traffic'),
                  joined: !stacked,
                  showIcon: showIcons,
                ),
              ),
            ];
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [buttons[0], const SizedBox(height: 10), buttons[1]],
              );
            }
            return ClipRRect(
              key: const ValueKey('home-routing-switch'),
              borderRadius: BorderRadius.circular(8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: buttons[0]),
                    Expanded(child: buttons[1]),
                  ],
                ),
              ),
            );
          },
        ),
        if (_isMobileShell)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const explanation = 'Режим можно изменить при активном VPN';
                const style = TextStyle(
                  color: _atlasMuted,
                  fontFamily: 'Inter',
                  fontSize: 12,
                  height: 1.35,
                );
                final painter = TextPainter(
                  text: const TextSpan(text: explanation, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout(maxWidth: constraints.maxWidth);
                final height = painter.height;
                painter.dispose();
                return SizedBox(
                  height: height,
                  child: c.connected
                      ? const Text(
                          explanation,
                          key: ValueKey('home-routing-live'),
                          textAlign: TextAlign.center,
                          style: style,
                        )
                      : null,
                );
              },
            ),
          ),
        if (!c.summaryOnly) ...[
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
                        'Политики ниже сохранены для режима «Ручное».',
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

  Widget _mode(
    String key,
    String label,
    bool selected,
    VoidCallback action, {
    required bool joined,
    required bool showIcon,
  }) => Semantics(
    selected: selected,
    child: OutlinedButton(
      key: ValueKey('home-routing-$key'),
      onPressed: controls.enabled ? action : null,
      style: OutlinedButton.styleFrom(
        enabledMouseCursor: SystemMouseCursors.click,
        disabledMouseCursor: SystemMouseCursors.basic,
        foregroundColor: selected ? _atlasBackground : _atlasText,
        backgroundColor: selected ? _atlasMint : Colors.transparent,
        disabledForegroundColor: selected ? _atlasBackground : _atlasMuted,
        disabledBackgroundColor: selected ? _atlasMint : Colors.transparent,
        side: BorderSide(color: selected ? _atlasMint : _atlasBorder),
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: !joined
              ? BorderRadius.circular(8)
              : BorderRadius.only(
                  topLeft: Radius.circular(key == 'selected' ? 8 : 0),
                  bottomLeft: Radius.circular(key == 'selected' ? 8 : 0),
                  topRight: Radius.circular(key == 'all-vpn' ? 8 : 0),
                  bottomRight: Radius.circular(key == 'all-vpn' ? 8 : 0),
                ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showIcon) ...[
            Icon(
              key == 'selected' ? Icons.grid_view_rounded : Icons.public,
              size: 20,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
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
    final options = _homeRoutePolicyOptions(service);
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
            onChanged: controls.enabled && !allTraffic && !service.vpnOnly
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
    if (tag == 'claude') return _ServiceBrandIcon(tag: tag, size: 28);
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
