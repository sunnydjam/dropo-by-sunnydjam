part of 'main.dart';

enum VpnResponseObservation { available, pending, failed, stale, unavailable }

// A scoped HTTP observation, not ICMP, game latency, or individual service RTT.
class VpnResponseSnapshot {
  const VpnResponseSnapshot({
    this.state = 'unavailable',
    this.latencyMs,
    this.checkedAt,
    this.sourceId = '',
    this.nodeId = '',
    this.target = '',
    this.sessionGeneration = 0,
  });
  final String state, sourceId, nodeId, target;
  final int? latencyMs;
  final int sessionGeneration;
  final DateTime? checkedAt;

  factory VpnResponseSnapshot.fromJson(Map<String, dynamic> json) {
    final value = _asInt(json['latencyMs']);
    return VpnResponseSnapshot(
      state: json['state']?.toString() ?? 'unavailable',
      latencyMs: value > 0 ? value : null,
      checkedAt: DateTime.tryParse(json['checkedAt']?.toString() ?? ''),
      sourceId: json['sourceId']?.toString() ?? '',
      nodeId: json['nodeId']?.toString() ?? '',
      target: json['target']?.toString() ?? '',
      sessionGeneration: _asInt(json['sessionGeneration']),
    );
  }

  // Core already fences the source, node and session. Presentation must also
  // reject clock reversals, unknown states and retained pending values instead
  // of making an old or future HTTP sample look like a live measurement.
  VpnResponseObservation observationAt(DateTime now) {
    if (state == 'pending') return VpnResponseObservation.pending;
    if (state == 'stale') return VpnResponseObservation.stale;
    if (state != 'ok' && state != 'failed') {
      return VpnResponseObservation.unavailable;
    }
    if (checkedAt != null) {
      final age = now.toUtc().difference(checkedAt!.toUtc());
      if (age.isNegative) return VpnResponseObservation.unavailable;
      if (age > const Duration(seconds: 90)) {
        return VpnResponseObservation.stale;
      }
    }
    // A failed bootstrap can legitimately have no completed timestamp. This
    // still only describes the source check, never the whole internet.
    if (state == 'failed') return VpnResponseObservation.failed;
    if (checkedAt == null || latencyMs == null || latencyMs! <= 0) {
      return VpnResponseObservation.unavailable;
    }
    return VpnResponseObservation.available;
  }

  bool get stale =>
      observationAt(DateTime.now()) == VpnResponseObservation.stale;
  bool get current =>
      observationAt(DateTime.now()) == VpnResponseObservation.available;
  String get label => labelAt(DateTime.now());
  String labelAt(DateTime now) => switch (observationAt(now)) {
    VpnResponseObservation.available => '$latencyMs мс',
    VpnResponseObservation.pending => 'Проверяем…',
    VpnResponseObservation.failed => 'Нет ответа',
    VpnResponseObservation.stale => 'Данные устарели',
    VpnResponseObservation.unavailable => 'Нет данных',
  };

  String get ageLabel => ageLabelAt(DateTime.now());
  String ageLabelAt(DateTime now) {
    if (checkedAt == null) return 'Замер ещё не получен';
    final age = now.toUtc().difference(checkedAt!.toUtc());
    if (age.isNegative) return 'Время замера неизвестно';
    final seconds = age.inSeconds;
    return seconds < 60 ? '$seconds с назад' : '${seconds ~/ 60} мин назад';
  }

  String scopeDescription(String routingMode) => switch (routingMode) {
    'all_traffic' =>
      'В режиме «Всё через VPN» это всё ещё одна HTTP-проверка, а не проверка всех сайтов, приложений или исключений.',
    'blocked_only' =>
      'В режиме «По сервисам» это отклик только VPN-источника. Он не описывает прямой трафик и не подтверждает маршрут отдельного сервиса.',
    _ =>
      'Отклик относится только к проверяемому VPN-источнику. По нему нельзя определить маршрут отдельного приложения или сервиса.',
  };
}

class _VpnResponseTile extends StatelessWidget {
  const _VpnResponseTile({
    required this.snapshot,
    this.compact = false,
    this.routingMode = 'blocked_only',
    this.onOpenHelp,
  });
  final VpnResponseSnapshot snapshot;
  final bool compact;
  final String routingMode;
  final VoidCallback? onOpenHelp;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final observation = snapshot.observationAt(now);
    final label = snapshot.labelAt(now);
    final color = switch (observation) {
      VpnResponseObservation.available => _atlasMint,
      VpnResponseObservation.failed => const Color(0xFFF8D38B),
      _ => _atlasMuted,
    };
    final detail = switch (observation) {
      VpnResponseObservation.available => snapshot.ageLabelAt(now),
      VpnResponseObservation.pending => 'Проверка в фоне',
      VpnResponseObservation.failed => 'Только HTTP-проверка',
      VpnResponseObservation.stale => 'Нужен свежий замер',
      VpnResponseObservation.unavailable => 'Замер не получен',
    };
    final style = TextStyle(
      fontFamily: _isMobileShell ? 'monospace' : 'Consolas',
      fontFamilyFallback: const ['Courier New', 'Inter'],
      fontSize: 12,
      color: color,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    return _AccessibleDescription(
      message:
          'Отклик VPN: $label. HTTP-проверка через текущий VPN-источник. Не игровой пинг и не скорость скачивания. Нажмите для объяснения и помощи.',
      child: TextButton(
        key: ValueKey(compact ? 'vpn-response-compact' : 'vpn-response-panel'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => _AppDialog(
            title: 'Отклик через VPN',
            centered: true,
            icon: Icons.network_check,
            width: 480,
            child: Column(
              key: const ValueKey('vpn-response-explanation'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Время HTTP-проверки через текущий VPN-источник. Оно включает работу соединения и тестового адреса. Это не пинг конкретной игры, не проверка всех сервисов и не скорость скачивания.',
                ),
                const SizedBox(height: 12),
                const Text(
                  '«Подключено» означает, что VPN-движок запущен. HTTP-проверка выполняется отдельно в фоне и не задерживает подключение.',
                ),
                const SizedBox(height: 12),
                Text(snapshot.scopeDescription(routingMode)),
                const SizedBox(height: 12),
                const Text(
                  '«Проверяем…» — замер ещё выполняется. «Нет ответа» — тестовый адрес не ответил; это не доказывает, что интернет не работает. «Данные устарели» и «Нет данных» не подтверждают ни работу, ни поломку подключения. Устаревший или будущий замер не показывается как текущий отклик.',
                ),
                const SizedBox(height: 12),
                if (onOpenHelp != null)
                  TextButton.icon(
                    key: const ValueKey('vpn-response-open-help'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      onOpenHelp!();
                    },
                    icon: const Icon(Icons.help_outline),
                    label: const Text('Помощь с подключением'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Понятно'),
                ),
              ],
            ),
          ),
        ),
        style: TextButton.styleFrom(
          alignment: Alignment.centerRight,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        child: compact
            ? Text(
                'VPN · $label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'ОТКЛИК VPN',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: _atlasMuted),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: _atlasMuted),
                  ),
                ],
              ),
      ),
    );
  }
}
