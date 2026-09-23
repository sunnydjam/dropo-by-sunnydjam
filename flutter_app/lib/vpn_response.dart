part of 'main.dart';

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

  bool get stale =>
      state == 'stale' ||
      (checkedAt != null &&
          DateTime.now().toUtc().difference(checkedAt!).inSeconds > 90);
  bool get current =>
      state == 'ok' && latencyMs != null && checkedAt != null && !stale;
  String get label => stale
      ? 'Данные устарели'
      : current
      ? '$latencyMs мс'
      : switch (state) {
          'pending' => 'Проверяем…',
          'failed' => 'Нет ответа',
          _ => 'Нет данных',
        };
  String get ageLabel {
    if (checkedAt == null) return 'Замер ещё не получен';
    final seconds = math.max(
      0,
      DateTime.now().toUtc().difference(checkedAt!).inSeconds,
    );
    return seconds < 60 ? '$seconds с назад' : '${seconds ~/ 60} мин назад';
  }
}

class _VpnResponseTile extends StatelessWidget {
  const _VpnResponseTile({required this.snapshot, this.compact = false});
  final VpnResponseSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = snapshot.current ? _atlasMint : _atlasMuted;
    final style = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: const ['Courier New'],
      fontSize: 12,
      color: color,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    return Tooltip(
      message:
          'HTTP-проверка через текущий VPN-источник. Не игровой пинг и не скорость скачивания.',
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
                  'Проверка выполняется в фоне примерно раз в 30 секунд. В режиме «По сервисам» показатель относится только к VPN-источнику, а не ко всему трафику.',
                ),
                const SizedBox(height: 12),
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
                'VPN · ${snapshot.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('ОТКЛИК VPN', style: style.copyWith(color: _atlasMuted)),
                  const SizedBox(height: 6),
                  Text(snapshot.label, style: style.copyWith(fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    snapshot.ageLabel,
                    style: style.copyWith(color: _atlasMuted),
                  ),
                ],
              ),
      ),
    );
  }
}
