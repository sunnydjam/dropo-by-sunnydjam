part of 'main.dart';

@visibleForTesting
class ConnectionHealthResult {
  const ConnectionHealthResult({
    required this.serviceTag,
    required this.name,
    required this.target,
    required this.success,
    required this.statusText,
    required this.expectedRoute,
    required this.latencyMs,
    required this.error,
    required this.regional,
    required this.routeVerified,
  });

  final String serviceTag;
  final String name;
  final String target;
  final bool success;
  final String statusText;
  final String expectedRoute;
  final int latencyMs;
  final String error;
  final bool regional;
  final bool routeVerified;

  factory ConnectionHealthResult.fromJson(Map<String, dynamic> json) {
    final expectedRoute =
        json['expectedRoute']?.toString().trim().toLowerCase() ?? '';
    final normalLatency = _asInt(json['normalTimeMs']);
    final proxyLatency = _asInt(json['proxyTimeMs']);
    final androidLatency = _asInt(json['latencyMs']);
    final usesProxyProbe =
        expectedRoute == 'vpn' || expectedRoute == 'ru-route';
    final latency = androidLatency > 0
        ? androidLatency
        : usesProxyProbe && proxyLatency > 0
        ? proxyLatency
        : normalLatency > 0
        ? normalLatency
        : proxyLatency;
    final error = usesProxyProbe
        ? _firstHealthText([
            json['proxyError'],
            json['error'],
            json['normalError'],
          ])
        : _firstHealthText([
            json['normalError'],
            json['error'],
            json['proxyError'],
          ]);
    return ConnectionHealthResult(
      serviceTag: _firstHealthText([json['serviceTag'], json['tag']]),
      name: json['name']?.toString().trim().isNotEmpty == true
          ? json['name'].toString().trim()
          : 'Сервис',
      target: _firstHealthText([json['url'], json['target']]),
      success: json['success'] == true,
      statusText:
          json['statusText']?.toString().trim() ??
          json['methodLabel']?.toString().trim() ??
          '',
      expectedRoute: expectedRoute.isNotEmpty
          ? expectedRoute
          : json['methodTag']?.toString().trim().toLowerCase() ?? '',
      latencyMs: latency,
      error: error,
      regional: json['regional'] == true,
      // Windows verifies the selected client transport when the core exposes a
      // scoped probe path. TUN-only Windows checks and Android explicitly send
      // false because an ordinary app HTTP request cannot prove its transport.
      routeVerified: json['routeVerified'] != false,
    );
  }
}

@visibleForTesting
class ConnectionHealthReport {
  const ConnectionHealthReport({
    required this.success,
    required this.total,
    required this.okCount,
    required this.failedCount,
    required this.durationMs,
    required this.checkedAt,
    required this.error,
    required this.sessionValid,
    required this.results,
  });

  final bool success;
  final int total;
  final int okCount;
  final int failedCount;
  final int durationMs;
  final DateTime? checkedAt;
  final String error;
  final bool sessionValid;
  final List<ConnectionHealthResult> results;

  bool get routesVerified =>
      results.isNotEmpty && results.every((item) => item.routeVerified);

  factory ConnectionHealthReport.fromJson(Map<String, dynamic> json) {
    final results =
        (json['services'] is List ? json['services'] as List : const [])
            .map(_asMap)
            .where((item) => item.isNotEmpty)
            .map(ConnectionHealthResult.fromJson)
            .toList(growable: false);
    final derivedOk = results.where((item) => item.success).length;
    final total = _asInt(json['total']) > 0
        ? _asInt(json['total'])
        : _asInt(json['totalCount']) > 0
        ? _asInt(json['totalCount'])
        : results.length;
    final failed = json.containsKey('failedCount')
        ? _asInt(json['failedCount'])
        : results.where((item) => !item.success).length;
    final checkedAtText = json['checkedAt']?.toString().trim() ?? '';
    return ConnectionHealthReport(
      success: json['success'] == true && failed == 0,
      total: total,
      okCount: json.containsKey('okCount')
          ? _asInt(json['okCount'])
          : derivedOk,
      failedCount: failed,
      durationMs: _asInt(json['durationMs']),
      checkedAt: checkedAtText.isEmpty
          ? null
          : DateTime.tryParse(checkedAtText)?.toLocal(),
      error: json['error']?.toString().trim() ?? '',
      sessionValid: json['sessionValid'] != false,
      results: results,
    );
  }
}

String _firstHealthText(List<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}

class _ConnectionHealthPanel extends StatefulWidget {
  const _ConnectionHealthPanel({
    required this.bridge,
    required this.connected,
    required this.routingMode,
    required this.routes,
    required this.routesAreLive,
  });

  final CoreBridge bridge;
  final bool connected;
  final String routingMode;
  final List<RouteService> routes;
  final bool routesAreLive;

  @override
  State<_ConnectionHealthPanel> createState() => _ConnectionHealthPanelState();
}

class _ConnectionHealthPanelState extends State<_ConnectionHealthPanel> {
  ConnectionHealthReport? report;
  bool checking = false;
  bool showAllResults = false;
  String actionError = '';
  int checkGeneration = 0;

  @override
  void didUpdateWidget(covariant _ConnectionHealthPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final routesChanged =
        _healthRouteFingerprint(oldWidget.routes, oldWidget.routesAreLive) !=
        _healthRouteFingerprint(widget.routes, widget.routesAreLive);
    if ((oldWidget.connected && !widget.connected) ||
        oldWidget.routingMode != widget.routingMode ||
        routesChanged) {
      checkGeneration++;
      checking = false;
      report = null;
      actionError = '';
      showAllResults = false;
    }
  }

  Future<void> _runCheck() async {
    if (checking || !widget.connected) return;
    final generation = ++checkGeneration;
    final routeFingerprint = _healthRouteFingerprint(
      widget.routes,
      widget.routesAreLive,
    );
    setState(() {
      checking = true;
      actionError = '';
    });
    try {
      final payload = await widget.bridge.runQuickCheck();
      if (!mounted ||
          generation != checkGeneration ||
          !widget.connected ||
          routeFingerprint !=
              _healthRouteFingerprint(widget.routes, widget.routesAreLive)) {
        return;
      }
      final parsed = ConnectionHealthReport.fromJson(payload);
      if (!parsed.sessionValid) {
        setState(() {
          checking = false;
          report = null;
          actionError =
              'Подключение изменилось во время проверки. Запустите её снова.';
        });
        return;
      }
      setState(() {
        checking = false;
        report = parsed;
        actionError = parsed.results.isEmpty && parsed.error.isNotEmpty
            ? _cleanError(parsed.error)
            : '';
      });
    } catch (error) {
      if (!mounted || generation != checkGeneration || !widget.connected) {
        return;
      }
      setState(() {
        checking = false;
        actionError = _cleanError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final allTraffic = widget.routingMode == 'all_traffic';
    final routes = widget.routes;
    final activeRoutes = widget.routesAreLive
        ? _diagnosticRoutes(routes)
        : const <RouteService>[];
    final groups = _healthGroups(
      report?.results ?? const [],
      widget.routesAreLive ? routes : const <RouteService>[],
    );
    final visibleGroups = showAllResults || groups.length <= 8
        ? groups
        : groups.take(8).toList(growable: false);
    final activeNode = widget.routesAreLive ? _activeVPNNode(routes) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DiagnosticCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;
                  final summary = _healthSummary(
                    connected: widget.connected,
                    allTraffic: allTraffic,
                    activeNode: activeNode,
                    routesAreLive: widget.routesAreLive,
                  );
                  final action = FilledButton.icon(
                    key: const ValueKey('diagnostics-run-check'),
                    onPressed: widget.connected && !checking
                        ? () => unawaited(_runCheck())
                        : null,
                    style: _withClickCursor(
                      FilledButton.styleFrom(
                        backgroundColor: _atlasMint,
                        foregroundColor: _atlasBackground,
                        disabledBackgroundColor: const Color(0xFF243C33),
                        disabledForegroundColor: _atlasMuted,
                        minimumSize: Size(compact ? double.infinity : 170, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    icon: checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check, size: 18),
                    label: Text(
                      checking
                          ? 'Проверяем...'
                          : report == null
                          ? 'Проверить'
                          : 'Проверить снова',
                    ),
                  );
                  final heading = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _HealthIcon(
                        icon: widget.connected
                            ? Icons.verified_user_outlined
                            : Icons.shield_outlined,
                        color: widget.connected ? _atlasMint : _atlasMuted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Проверяемое подключение',
                              style: TextStyle(
                                color: _atlasText,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              summary,
                              style: const TextStyle(
                                color: _atlasMuted,
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [heading, const SizedBox(height: 12), action],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 14),
                      action,
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _HealthPill(
                    icon: widget.connected ? Icons.link : Icons.link_off,
                    label: widget.connected ? 'Подключено' : 'Отключено',
                    color: widget.connected ? _atlasMint : _atlasMuted,
                  ),
                  _HealthPill(
                    icon: allTraffic ? Icons.public : Icons.grid_view_rounded,
                    label: allTraffic
                        ? 'Весь трафик через VPN'
                        : 'Только выбранные сервисы',
                    color: const Color(0xFF8BC5FF),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _DiagnosticCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _DiagnosticTitle(
                icon: Icons.alt_route,
                title: 'Фактические маршруты ядра',
                subtitle:
                    'Правило — сохранённый выбор. Маршрут — то, что ядро применило сейчас.',
              ),
              const SizedBox(height: 10),
              if (!widget.connected)
                const _DiagnosticEmpty(
                  text: 'Подключитесь, чтобы увидеть активные маршруты и узел.',
                )
              else if (!widget.routesAreLive)
                const _DiagnosticEmpty(
                  text:
                      'Ядро ещё не подтвердило активные маршруты. Сохранённые правила не выдаются за фактическое состояние.',
                )
              else if (allTraffic)
                _DiagnosticRouteRow(
                  key: const ValueKey('diagnostics-route-all'),
                  name: 'Весь интернет',
                  policy: 'Режим: весь трафик',
                  actualRoute: 'VPN',
                  source: activeNode.isEmpty
                      ? widget.routesAreLive
                            ? 'Узел выбирается VPN-ядром'
                            : 'Подтверждение активного узла ожидается'
                      : 'Узел: $activeNode',
                  delayMs: 0,
                )
              else if (activeRoutes.isEmpty)
                const _DiagnosticEmpty(
                  text: 'Нет активных индивидуальных маршрутов.',
                )
              else ...[
                for (final route in activeRoutes.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DiagnosticRouteRow(
                      key: ValueKey('diagnostics-route-${route.tag}'),
                      name: route.name,
                      policy:
                          'Правило: ${_healthPolicyLabel(route.selectedMethod)}',
                      actualRoute: _healthActualRoute(route.method),
                      source: _routeSourceLabel(route),
                      // Route-summary latency is an opportunistic cache, not a
                      // health verdict. Only explicit checks below show time.
                      delayMs: 0,
                    ),
                  ),
                if (activeRoutes.length > 6)
                  Text(
                    'Ещё активных маршрутов: ${activeRoutes.length - 6}',
                    style: const TextStyle(color: _atlasMuted, fontSize: 12),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        _DiagnosticCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DiagnosticTitle(
                icon: Icons.monitor_heart_outlined,
                title: _isMobileShell
                    ? 'Проверка адресов'
                    : 'Проверка маршрутов',
                subtitle: _isMobileShell
                    ? 'Проверяется ответ адреса. Транспорт этой HTTP-проверкой не подтверждается; активный маршрут ядра показан отдельно.'
                    : 'Маршрут подтверждается только через изолированный канал ядра; TUN-проверка подтверждает лишь ответ адреса. Это не проверка входа, звонков или медиапотока.',
              ),
              if (actionError.isNotEmpty) ...[
                const SizedBox(height: 10),
                _HealthMessage(
                  icon: Icons.error_outline,
                  color: const Color(0xFFFF8A80),
                  text: actionError,
                ),
              ] else if (report == null) ...[
                const SizedBox(height: 10),
                _DiagnosticEmpty(
                  text: _isMobileShell
                      ? 'Запустите проверку: доступность адреса и задержка будут показаны отдельно от активного маршрута ядра.'
                      : 'Запустите проверку: ответ маршрута и задержка будут показаны отдельно от сохранённых правил.',
                ),
              ] else ...[
                const SizedBox(height: 10),
                _HealthReportSummary(report: report!),
                if (visibleGroups.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final group in visibleGroups)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _HealthResultRow(group: group),
                    ),
                  if (groups.length > 8)
                    TextButton.icon(
                      key: const ValueKey('diagnostics-toggle-results'),
                      onPressed: () =>
                          setState(() => showAllResults = !showAllResults),
                      icon: Icon(
                        showAllResults ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: Text(
                        showAllResults
                            ? 'Свернуть результаты'
                            : 'Показать все (${groups.length})',
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _atlasSurface.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _atlasBorder),
    ),
    child: child,
  );
}

class _DiagnosticTitle extends StatelessWidget {
  const _DiagnosticTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: _atlasMint, size: 20),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: _atlasText,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(
                color: _atlasMuted,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _HealthIcon extends StatelessWidget {
  const _HealthIcon({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Icon(icon, color: color, size: 21),
  );
}

class _HealthPill extends StatelessWidget {
  const _HealthPill({
    required this.icon,
    required this.label,
    required this.color,
  });
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.28)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _DiagnosticRouteRow extends StatelessWidget {
  const _DiagnosticRouteRow({
    super.key,
    required this.name,
    required this.policy,
    required this.actualRoute,
    required this.source,
    required this.delayMs,
  });

  final String name;
  final String policy;
  final String actualRoute;
  final String source;
  final int delayMs;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    ),
    child: Row(
      children: [
        const Icon(Icons.route_outlined, color: Color(0xFF8BC5FF), size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _atlasText,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '$policy  ·  Маршрут: $actualRoute',
                style: const TextStyle(color: _atlasMuted, fontSize: 11),
              ),
              if (source.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF8FA79C),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (delayMs > 0) ...[
          const SizedBox(width: 10),
          Text(
            '$delayMs мс',
            style: const TextStyle(color: _atlasText, fontSize: 11),
          ),
        ],
      ],
    ),
  );
}

class _HealthReportSummary extends StatelessWidget {
  const _HealthReportSummary({required this.report});
  final ConnectionHealthReport report;

  @override
  Widget build(BuildContext context) {
    final color = report.success ? _atlasMint : const Color(0xFFFFB74D);
    final title = report.routesVerified
        ? report.success
              ? 'Проверка маршрутов пройдена'
              : 'Некоторые маршруты не ответили'
        : report.success
        ? 'Адреса ответили'
        : 'Некоторые адреса не ответили';
    final detail = StringBuffer(
      '${report.okCount} из ${report.total} проверок успешны',
    );
    if (report.durationMs > 0) {
      detail.write(' · ${(report.durationMs / 1000).toStringAsFixed(1)} с');
    }
    if (report.checkedAt != null) {
      detail.write(' · ${_healthTime(report.checkedAt!)}');
    }
    if (!report.routesVerified) {
      detail.write('\nТранспорт этой HTTP-проверкой не подтверждается.');
    }
    return _HealthMessage(
      icon: report.success ? Icons.check_circle_outline : Icons.warning_amber,
      color: color,
      text: '$title\n$detail',
    );
  }
}

class _HealthMessage extends StatelessWidget {
  const _HealthMessage({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.26)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _DiagnosticEmpty extends StatelessWidget {
  const _DiagnosticEmpty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(color: _atlasMuted, fontSize: 12, height: 1.35),
    ),
  );
}

class _HealthGroup {
  const _HealthGroup({
    required this.keyName,
    required this.name,
    required this.results,
    required this.route,
  });

  final String keyName;
  final String name;
  final List<ConnectionHealthResult> results;
  final RouteService? route;

  bool get success => results.every((item) => item.success);
  bool get routeVerified => results.every((item) => item.routeVerified);
  int get latencyMs =>
      results.fold<int>(0, (value, item) => math.max(value, item.latencyMs));
  String get error {
    for (final result in results) {
      if (!result.success && result.error.isNotEmpty) return result.error;
    }
    return '';
  }

  String get expectedRoute {
    for (final result in results) {
      if (result.expectedRoute.isNotEmpty) return result.expectedRoute;
    }
    return '';
  }

  bool get regionalLimit => results.any(
    (item) =>
        item.regional && item.statusText.trim().toUpperCase() == 'REGION_LIMIT',
  );
}

class _HealthResultRow extends StatelessWidget {
  const _HealthResultRow({required this.group});
  final _HealthGroup group;

  @override
  Widget build(BuildContext context) {
    final color = group.regionalLimit
        ? const Color(0xFFFFB74D)
        : group.success
        ? _atlasMint
        : const Color(0xFFFF8A80);
    final route = group.route;
    final expected = _healthExpectedRoute(group.expectedRoute);
    final actual = route == null ? '' : _healthActualRoute(route.method);
    final responseText = group.regionalLimit
        ? 'Адрес недоступен из текущего региона'
        : group.routeVerified
        ? group.success
              ? 'Маршрут отвечает через: $expected'
              : 'Нет ответа через: $expected'
        : group.success
        ? 'Адрес отвечает · путь этой проверкой не подтверждён'
        : 'Адрес не ответил · путь этой проверкой не подтверждён';
    final routeText = actual.isNotEmpty
        ? group.routeVerified
              ? '$responseText · Активный маршрут: $actual'
              : '$responseText · Маршрут ядра: $actual'
        : responseText;
    final endpointText = group.results.length > 1
        ? '${group.results.length} адреса'
        : '1 адрес';
    return Container(
      key: ValueKey('diagnostics-health-${group.keyName}'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            group.regionalLimit
                ? Icons.language_outlined
                : group.success
                ? Icons.check_circle
                : Icons.cancel_outlined,
            color: color,
            size: 19,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _atlasText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (group.latencyMs > 0)
                      Text(
                        '${group.latencyMs} мс',
                        style: const TextStyle(
                          color: _atlasMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '$routeText · $endpointText',
                  style: const TextStyle(color: _atlasMuted, fontSize: 11),
                ),
                if (group.error.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    _cleanError(group.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFFB4AB),
                      fontSize: 11,
                    ),
                  ),
                ] else if (group.regionalLimit) ...[
                  const SizedBox(height: 3),
                  const Text(
                    'Региональное ограничение учтено как ожидаемое.',
                    style: TextStyle(color: Color(0xFFFFD180), fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<RouteService> _diagnosticRoutes(List<RouteService> routes) {
  final result = routes
      .where((route) {
        final method = route.method.trim().toLowerCase();
        final active =
            method.isNotEmpty &&
            method != 'auto' &&
            method != 'waiting' &&
            !method.contains('direct') &&
            !method.contains('напрямую');
        return route.homeVisible || route.requiresVpn || active;
      })
      .toList(growable: false);
  result.sort((left, right) {
    if (left.homeVisible != right.homeVisible) return left.homeVisible ? -1 : 1;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return result;
}

List<_HealthGroup> _healthGroups(
  List<ConnectionHealthResult> results,
  List<RouteService> routes,
) {
  final grouped = <String, List<ConnectionHealthResult>>{};
  for (final result in results) {
    final key = result.serviceTag.isNotEmpty
        ? result.serviceTag
        : 'endpoint:${result.name.toLowerCase()}';
    grouped.putIfAbsent(key, () => []).add(result);
  }
  final routeByTag = {for (final route in routes) route.tag: route};
  final groups = grouped.entries
      .map((entry) {
        final first = entry.value.first;
        final route = first.serviceTag.isEmpty
            ? null
            : routeByTag[first.serviceTag];
        return _HealthGroup(
          keyName: _healthKey(entry.key),
          name: route?.name ?? first.name,
          results: List.unmodifiable(entry.value),
          route: route,
        );
      })
      .toList(growable: false);
  groups.sort((left, right) {
    if (left.success != right.success) return left.success ? 1 : -1;
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return groups;
}

String _healthRouteFingerprint(List<RouteService> routes, bool routesAreLive) {
  if (!routesAreLive) return 'unconfirmed';
  final entries =
      routes
          .map(
            (route) => [
              route.tag,
              route.method,
              route.actualOutbound,
              route.selectedMethod,
              route.requiresVpn ? 'vpn' : 'direct',
            ].join('|'),
          )
          .toList(growable: false)
        ..sort();
  return entries.join('\n');
}

String _healthSummary({
  required bool connected,
  required bool allTraffic,
  required String activeNode,
  required bool routesAreLive,
}) {
  if (!connected) {
    return 'Нет активной сессии. Фактический маршрут появится после подключения.';
  }
  if (!routesAreLive) {
    return 'Сессия подключена. Актуальные маршруты ядра пока не подтверждены.';
  }
  if (allTraffic) {
    return activeNode.isEmpty
        ? 'Весь публичный трафик направлен через VPN. Узел выбирается ядром.'
        : 'Весь публичный трафик направлен через VPN · $activeNode.';
  }
  return 'Выбранные сервисы используют свои маршруты, остальной трафик идёт напрямую.';
}

String _healthPolicyLabel(String policy) =>
    switch (policy.trim().toLowerCase()) {
      'vpn' => 'VPN',
      'direct' => 'Напрямую',
      'zapret' => 'Обход',
      _ => 'Авто',
    };

String _healthActualRoute(String method) {
  final value = method.trim();
  final lower = value.toLowerCase();
  if (lower.isEmpty || lower == 'waiting') return 'Определяется';
  if (lower.contains('no vpn')) return 'Напрямую · VPN недоступен';
  if (lower == 'direct' || lower.contains('напрямую')) return 'Напрямую';
  if (lower == 'vpn' || lower.contains('vpn')) return 'VPN';
  return value;
}

String _healthExpectedRoute(String route) =>
    switch (route.trim().toLowerCase()) {
      'vpn' => 'VPN',
      'direct' => 'напрямую',
      'zapret' => 'обход',
      'ru-route' => 'RU-маршрут',
      '' => 'текущий маршрут',
      final value => value,
    };

String _routeSourceLabel(RouteService route) {
  final outbound = route.actualOutbound.trim();
  if (outbound.isEmpty || outbound == 'direct' || outbound == 'auto-select') {
    return '';
  }
  final method = route.method.toLowerCase();
  return method.contains('vpn') ? 'Узел: $outbound' : 'Стратегия: $outbound';
}

String _activeVPNNode(List<RouteService> routes) {
  for (final route in routes) {
    final outbound = route.actualOutbound.trim();
    if (route.method.toLowerCase().contains('vpn') &&
        outbound.isNotEmpty &&
        outbound != 'direct' &&
        outbound != 'auto-select') {
      return outbound;
    }
  }
  return '';
}

String _healthTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

String _healthKey(String value) => value
    .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-')
    .replaceAll(RegExp(r'-+'), '-')
    .replaceAll(RegExp(r'^-|-$'), '');
