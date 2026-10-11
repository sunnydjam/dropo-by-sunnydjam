part of 'main.dart';

enum GuidedHelpScenario { noInternet, serviceUnavailable, updateUnavailable }

String _helpScenarioCode(GuidedHelpScenario? scenario) => switch (scenario) {
  GuidedHelpScenario.noInternet => 'no_internet',
  GuidedHelpScenario.serviceUnavailable => 'service_unavailable',
  GuidedHelpScenario.updateUnavailable => 'update_unavailable',
  null => 'unspecified',
};

String _safeSupportVersion(String value) {
  final version = value.trim();
  if (version == 'dev') return 'dev';
  return RegExp(
        r'^v?\d{1,5}\.\d{1,5}\.\d{1,5}(?:-(?:preview|dev|rc)(?:\.\d{1,5})?)?$',
      ).hasMatch(version)
      ? version
      : 'unknown';
}

/// An allowlisted, local summary, not a redaction of a raw diagnostic dump.
/// Never include logs, errors, addresses, subscription/source/service names,
/// user identifiers, paths, or arbitrary backend-provided text here.
String buildSafeSupportReport({
  required CoreStatus status,
  required String routingMode,
  bool coreAvailable = true,
  ConnectionHealthReport? report,
  GuidedHelpScenario? scenario,
}) {
  final runtime = switch (coreAvailable
      ? status.vpnState.trim().toLowerCase()
      : '') {
    'stopped' => 'stopped',
    'starting' => 'starting',
    'connected' => 'connected',
    'reconnecting' => 'reconnecting',
    'disconnecting' => 'disconnecting',
    'error' => 'error',
    _ => 'unknown',
  };
  final mode = switch (routingMode) {
    'all_traffic' => 'all_traffic',
    'blocked_only' => 'selected_services',
    _ => 'unknown',
  };
  final platform = _isAndroidPlatform
      ? 'android'
      : Platform.isWindows
      ? 'windows'
      : Platform.isIOS
      ? 'ios'
      : 'other';
  final checkedAt = report?.checkedAt;
  final now = DateTime.now();
  final reportIsCurrent =
      coreAvailable &&
      status.connected &&
      !status.connecting &&
      !status.disconnecting &&
      report?.sessionValid == true &&
      checkedAt != null &&
      now.difference(checkedAt) <= const Duration(seconds: 90) &&
      checkedAt.difference(now) <= Duration.zero;
  final checks = reportIsCurrent
      ? report!.results.take(2048).toList(growable: false)
      : const <ConnectionHealthResult>[];
  final successful = checks.where((item) => item.success).length;
  return <String>[
    'Dropo support summary v1',
    'version: ${_safeSupportVersion(status.version.version)}',
    'platform: $platform',
    'scenario: ${_helpScenarioCode(scenario)}',
    'mode: $mode',
    'core_observed: $coreAvailable',
    'runtime: $runtime',
    'connected: ${coreAvailable ? status.connected : 'unknown'}',
    'running: ${coreAvailable ? status.running : 'unknown'}',
    'connecting: ${coreAvailable ? status.connecting : 'unknown'}',
    'disconnecting: ${coreAvailable ? status.disconnecting : 'unknown'}',
    'runtime_error_present: ${coreAvailable ? status.hasError : 'unknown'}',
    'checks_available: ${checks.isNotEmpty}',
    'checks_total: ${checks.length}',
    'checks_responded: $successful',
    'checks_not_responded: ${checks.length - successful}',
    'HTTP checks do not prove every app works, VPN privacy, or gaming ping.',
    'No logs, addresses, subscription links, keys, or user identifiers included.',
  ].join('\n');
}

/// Nothing is transmitted or copied until the user inspects this local preview
/// and presses Copy. Deliberately does not request bridge.diagnostics()/logs().
Future<void> showSafeSupportReportPreview(
  BuildContext context, {
  required CoreStatus status,
  required String routingMode,
  bool coreAvailable = true,
  ConnectionHealthReport? report,
  GuidedHelpScenario? scenario,
}) {
  final summary = buildSafeSupportReport(
    status: status,
    routingMode: routingMode,
    coreAvailable: coreAvailable,
    report: report,
    scenario: scenario,
  );
  return showDialog<void>(
    context: context,
    builder: (context) => _SafeSupportReportPreview(summary: summary),
  );
}

class _SafeSupportReportPreview extends StatefulWidget {
  const _SafeSupportReportPreview({required this.summary});
  final String summary;

  @override
  State<_SafeSupportReportPreview> createState() =>
      _SafeSupportReportPreviewState();
}

class _SafeSupportReportPreviewState extends State<_SafeSupportReportPreview> {
  bool copying = false;
  bool copied = false;
  bool failed = false;

  Future<void> _copy() async {
    if (copying) return;
    setState(() {
      copying = true;
      failed = false;
    });
    try {
      await Clipboard.setData(ClipboardData(text: widget.summary));
      if (mounted) {
        setState(() {
          copying = false;
          copied = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          copying = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('safe-support-preview'),
    backgroundColor: _atlasBackground,
    surfaceTintColor: Colors.transparent,
    scrollable: true,
    constraints: const BoxConstraints(maxWidth: 600),
    insetPadding: const EdgeInsets.all(16),
    title: const Text('Отчёт для помощи'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Только версия, состояние и итоги проверки. Без журналов, адресов, '
          'подписок и данных учётной записи. Ничего не отправляется: '
          'вы сами решаете, кому передать скопированный текст.',
          style: TextStyle(color: _atlasMuted, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 16),
        Text(
          widget.summary,
          key: const ValueKey('safe-support-preview-text'),
          style: const TextStyle(
            color: _atlasText,
            fontFamily: 'Inter',
            fontSize: 12,
            height: 1.5,
          ),
        ),
        if (copied || failed) ...[
          const SizedBox(height: 12),
          Text(
            failed
                ? 'Не удалось скопировать. Попробуйте ещё раз.'
                : 'Скопировано',
            style: TextStyle(
              color: failed ? const Color(0xFFFFB4AB) : _atlasMint,
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Закрыть'),
      ),
      FilledButton(
        key: const ValueKey('safe-support-copy'),
        onPressed: copying ? null : _copy,
        child: const Text('Копировать'),
      ),
    ],
  );
}

class _GuidedHelpPage extends StatefulWidget {
  const _GuidedHelpPage({
    super.key,
    required this.bridge,
    required this.status,
    required this.routingMode,
    required this.routes,
    required this.routesAreLive,
    required this.onOpenSources,
    required this.onOpenServices,
    required this.onOpenUpdates,
    required this.onOpenDiagnostics,
    required this.onGoHome,
    this.onCheckConnection,
    this.coreAvailable = true,
  });

  final CoreBridge bridge;
  final CoreStatus status;
  final String routingMode;
  final List<RouteService> routes;
  final bool routesAreLive;
  final bool coreAvailable;
  final VoidCallback? onOpenSources, onOpenServices, onOpenUpdates;
  final VoidCallback? onOpenDiagnostics, onGoHome;
  // Existing RunClientQuickCheck can retune Windows strategies. The caller
  // must supply a genuinely read-only check; never fall back to that method.
  final Future<Map<String, dynamic>> Function()? onCheckConnection;

  @override
  State<_GuidedHelpPage> createState() => _GuidedHelpPageState();
}

class _GuidedHelpPageState extends State<_GuidedHelpPage> {
  GuidedHelpScenario? scenario;
  ConnectionHealthReport? report;
  bool checking = false;
  bool probeOutstanding = false;
  String checkNotice = '';
  int generation = 0;
  Timer? expiryTimer;

  String _snapshot(_GuidedHelpPage page) => <Object>[
    page.status.connected,
    page.status.running,
    page.status.connecting,
    page.status.disconnecting,
    page.status.vpnState,
    page.status.hasError,
    page.status.vpnResponse.sessionGeneration,
    page.status.vpnResponse.sourceId,
    page.status.vpnResponse.nodeId,
    page.coreAvailable,
    page.onCheckConnection != null,
    page.routingMode,
    _healthRouteFingerprint(page.routes, page.routesAreLive),
  ].join('|');

  bool get stableConnection =>
      widget.coreAvailable &&
      widget.status.connected &&
      !widget.status.connecting &&
      !widget.status.disconnecting;

  @override
  void didUpdateWidget(covariant _GuidedHelpPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_snapshot(oldWidget) != _snapshot(widget) ||
        oldWidget.bridge != widget.bridge) {
      generation++;
      expiryTimer?.cancel();
      checking = false;
      report = null;
      checkNotice = 'Подключение или маршруты изменились. Проверьте ещё раз.';
    }
  }

  void _choose(GuidedHelpScenario value) {
    if (scenario == value) return;
    setState(() {
      generation++;
      expiryTimer?.cancel();
      scenario = value;
      report = null;
      checking = false;
      checkNotice = '';
    });
  }

  Future<void> _check() async {
    final check = widget.onCheckConnection;
    if (check == null || !stableConnection || probeOutstanding) return;
    final run = ++generation;
    final snapshot = _snapshot(widget);
    expiryTimer?.cancel();
    setState(() {
      checking = true;
      probeOutstanding = true;
      report = null;
      checkNotice = '';
    });
    try {
      // Keep the single-flight fence until the underlying call ends, including
      // after a UI timeout. A timed-out future is not a cancelled native probe.
      final pending = Future<Map<String, dynamic>>.sync(check).whenComplete(() {
        if (mounted) setState(() => probeOutstanding = false);
      });
      final payload = await pending.timeout(const Duration(seconds: 55));
      if (!mounted || run != generation || snapshot != _snapshot(widget)) {
        return;
      }
      final parsed = ConnectionHealthReport.fromJson(payload);
      if (!parsed.sessionValid ||
          parsed.checkedAt == null ||
          parsed.checkedAt != null &&
              (DateTime.now().difference(parsed.checkedAt!) >
                      const Duration(seconds: 90) ||
                  parsed.checkedAt!.difference(DateTime.now()) >
                      Duration.zero)) {
        setState(() {
          checking = false;
          checkNotice =
              'Результат устарел. Проверьте текущее подключение снова.';
        });
        return;
      }
      setState(() {
        checking = false;
        report = parsed;
      });
      final remaining =
          const Duration(seconds: 90) -
          DateTime.now().difference(parsed.checkedAt!);
      expiryTimer = Timer(
        remaining > const Duration(seconds: 90)
            ? const Duration(seconds: 90)
            : remaining,
        () {
          if (!mounted || run != generation) return;
          setState(() {
            report = null;
            checkNotice =
                'Результат устарел. Проверьте текущее подключение снова.';
          });
        },
      );
    } catch (error) {
      if (!mounted || run != generation || snapshot != _snapshot(widget)) {
        return;
      }
      setState(() {
        checking = false;
        checkNotice = error is TimeoutException
            ? 'Проверка не завершилась за 55 секунд. Подключение не изменено.'
            : 'Не удалось получить результат проверки. Подключение не изменено.';
      });
    }
  }

  @override
  void dispose() {
    generation++;
    expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: ListView(
        key: const ValueKey('guided-help-page'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          const Text(
            'С чем помочь?',
            style: TextStyle(
              color: _atlasText,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Выберите ситуацию. Проверки запускаются только по вашему нажатию '
            'и не меняют настройки подключения.',
            style: TextStyle(color: _atlasMuted, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 20),
          for (final choice in GuidedHelpScenario.values) ...[
            _HelpScenarioRow(
              scenario: choice,
              selected: scenario == choice,
              onPressed: () => _choose(choice),
            ),
            const Divider(height: 1, color: Color(0xFF26342F)),
          ],
          if (scenario != null) ...[
            const SizedBox(height: 24),
            ..._scenarioBody(),
          ],
          const SizedBox(height: 24),
          TextButton.icon(
            key: const ValueKey('guided-help-report'),
            style: _withClickCursor(
              TextButton.styleFrom(
                foregroundColor: _atlasMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
            ),
            onPressed: () => showSafeSupportReportPreview(
              context,
              status: widget.status,
              routingMode: widget.routingMode,
              coreAvailable: widget.coreAvailable,
              report: report,
              scenario: scenario,
            ),
            icon: const Icon(Icons.description_outlined, size: 20),
            label: const Text('Посмотреть отчёт для помощи'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );

  List<Widget> _scenarioBody() {
    if (scenario == GuidedHelpScenario.updateUnavailable) {
      return [
        _helpText('Обновление — отдельный шаг', heading: true),
        _helpText(
          _isAndroidPlatform
              ? 'В новой версии APK скачивается в Dropo с прогрессом, затем '
                    'Android предлагает установку. Разрешение на установку '
                    'даёт сам пользователь.'
              : 'Откройте обновления, проверьте новую версию и посмотрите этап '
                    'скачивания или установки. Обновление не запускается без '
                    'вашего подтверждения.',
        ),
        if (_isAndroidPlatform)
          _helpText(
            'Если старая версия только открывает браузер, один раз установите '
            'APK того же канала поверх приложения. Не удаляйте Dropo: это '
            'сохранит настройки. Preview и обычный выпуск — разные приложения.',
          ),
        _helpText(
          'Установщик не открылся или сообщает об ошибке? Не устанавливайте '
          'APK другого канала и не удаляйте рабочую версию.',
        ),
        _helpAction('Открыть обновления', widget.onOpenUpdates, 'updates'),
      ];
    }
    if (!widget.coreAvailable) {
      return [
        _helpText('Не удалось получить состояние подключения', heading: true),
        _helpText(
          'Состояние сетевого ядра сейчас неизвестно. Старый статус не считается '
          'актуальным. Настройки и подключение не изменялись.',
        ),
        _helpAction('Открыть диагностику', widget.onOpenDiagnostics, 'next'),
      ];
    }
    if (!stableConnection) {
      return [
        _helpText(
          widget.status.connecting || widget.status.disconnecting
              ? 'Подключение сейчас меняется'
              : 'Нет активного подключения Dropo',
          heading: true,
        ),
        _helpText(
          widget.status.connecting || widget.status.disconnecting
              ? 'Дождитесь завершения текущего действия на главном экране. '
                    'Проверка не запускается во время смены сессии.'
              : 'Вернитесь на главную и нажмите «Подключить». Если интернет '
                    'не работает и без Dropo, проверьте Wi-Fi или мобильную '
                    'сеть устройства.',
        ),
        _helpAction('На главный экран', widget.onGoHome, 'home'),
      ];
    }
    final checks = report?.results ?? const <ConnectionHealthResult>[];
    final answered = checks.where((item) => item.success).length;
    final serviceScenario = scenario == GuidedHelpScenario.serviceUnavailable;
    final partial = answered > 0 && answered < checks.length;
    final allAnswered = checks.isNotEmpty && answered == checks.length;
    final title = checks.isEmpty
        ? 'Проверим ответы адресов'
        : allAnswered
        ? 'Проверенные адреса отвечают'
        : partial
        ? 'Часть адресов не ответила'
        : 'Проверенные адреса не ответили';
    final selective = widget.routingMode == 'blocked_only';
    final action = checks.isEmpty || allAnswered
        ? serviceScenario
              ? selective
                    ? widget.onOpenServices
                    : widget.onOpenSources
              : widget.onOpenDiagnostics
        : serviceScenario && selective
        ? widget.onOpenServices
        : widget.onOpenSources;
    final actionLabel = checks.isEmpty || allAnswered
        ? serviceScenario
              ? selective
                    ? 'Посмотреть маршруты сервисов'
                    : 'Посмотреть источники'
              : 'Открыть диагностику'
        : serviceScenario && selective
        ? 'Посмотреть маршруты сервисов'
        : 'Посмотреть источники';
    return [
      _helpText(title, heading: true),
      if (checks.isNotEmpty)
        _helpText('Ответили адреса: $answered из ${checks.length}.'),
      _helpText(
        serviceScenario
            ? selective
                  ? 'В режиме «По сервисам» проверьте, что нужный сервис выбран '
                        'на главной и какой маршрут для него установлен. '
                        'Ваш выбор «Напрямую» или «VPN» остаётся главным.'
                  : 'В режиме «Всё через VPN» отдельные маршруты сервисов не '
                        'применяются. Можно посмотреть состояние выбранного '
                        'VPN-источника.'
            : 'Статус «Подключено» означает, что сетевое ядро запущено, '
                  'но сам по себе не доказывает доступность интернета.',
      ),
      if (allAnswered)
        _helpText(
          'Это не проверка входа в аккаунт, звонка или игры. Если проблема '
          'остаётся, откройте детали и проверьте именно нужное приложение.',
        )
      else if (checks.isNotEmpty)
        _helpText(
          'Отказ одного адреса не означает, что весь VPN не работает. '
          'Возможны ограничения сервиса или временный сбой; источник '
          'и настройки не переключались этой проверкой.',
        ),
      if (checkNotice.isNotEmpty)
        _helpText(checkNotice, color: const Color(0xFFFFC785)),
      if (report != null && checks.isEmpty)
        _helpText('Проверка не вернула достаточно данных для вывода.'),
      if (widget.onCheckConnection != null) ...[
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('guided-help-check'),
          style: _withClickCursor(
            FilledButton.styleFrom(
              backgroundColor: _atlasMint,
              foregroundColor: _atlasBackground,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          onPressed: probeOutstanding ? null : _check,
          icon: checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check, size: 20),
          label: Text(
            checking ? 'Проверяем адреса…' : 'Проверить ответы адресов',
          ),
        ),
        if (probeOutstanding && !checking)
          _helpText(
            'Предыдущая проверка ещё завершается. Повторный запуск пока '
            'недоступен; другие действия можно использовать.',
          ),
      ],
      const SizedBox(height: 12),
      _helpText(
        'HTTP-проверка показывает ответы адресов, а не скорость или игровой '
        'пинг. На Android она не подтверждает путь через VPN; фактические '
        'маршруты показаны отдельно в диагностике.',
        small: true,
      ),
      _helpAction(actionLabel, action, 'next'),
    ];
  }

  Widget _helpText(
    String value, {
    bool heading = false,
    bool small = false,
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      value,
      style: TextStyle(
        color: color ?? (heading ? _atlasText : _atlasMuted),
        fontSize: heading
            ? 18
            : small
            ? 12
            : 14,
        height: 1.45,
        fontWeight: heading ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
  );

  Widget _helpAction(String label, VoidCallback? action, String keyName) =>
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: OutlinedButton(
          key: ValueKey('guided-help-$keyName'),
          onPressed: action,
          style: _withClickCursor(
            OutlinedButton.styleFrom(
              foregroundColor: _atlasText,
              side: const BorderSide(color: Color(0xFF375348)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          child: Text(label, textAlign: TextAlign.center),
        ),
      );
}

class _HelpScenarioRow extends StatelessWidget {
  const _HelpScenarioRow({
    required this.scenario,
    required this.selected,
    required this.onPressed,
  });
  final GuidedHelpScenario scenario;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (scenario) {
      GuidedHelpScenario.noInternet => ('Нет интернета', Icons.wifi_off),
      GuidedHelpScenario.serviceUnavailable => (
        'Не открывается сервис',
        Icons.apps_outage_outlined,
      ),
      GuidedHelpScenario.updateUnavailable => (
        'Не получается обновиться',
        Icons.system_update_alt,
      ),
    };
    return Semantics(
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('guided-help-scenario-${_helpScenarioCode(scenario)}'),
          onTap: onPressed,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected ? _atlasMint : _atlasMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? _atlasMint : _atlasText,
                      fontSize: 16,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check : Icons.chevron_right,
                  color: selected ? _atlasMint : _atlasMuted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
Widget guidedHelpPageForTest({
  required CoreBridge bridge,
  required CoreStatus status,
  String routingMode = 'all_traffic',
  List<RouteService> routes = const [],
  bool routesAreLive = false,
  bool coreAvailable = true,
  VoidCallback? onOpenSources,
  VoidCallback? onOpenServices,
  VoidCallback? onOpenUpdates,
  VoidCallback? onOpenDiagnostics,
  VoidCallback? onGoHome,
  Future<Map<String, dynamic>> Function()? onCheckConnection,
}) => _GuidedHelpPage(
  bridge: bridge,
  status: status,
  routingMode: routingMode,
  routes: routes,
  routesAreLive: routesAreLive,
  coreAvailable: coreAvailable,
  onOpenSources: onOpenSources,
  onOpenServices: onOpenServices,
  onOpenUpdates: onOpenUpdates,
  onOpenDiagnostics: onOpenDiagnostics,
  onGoHome: onGoHome,
  onCheckConnection: onCheckConnection,
);
