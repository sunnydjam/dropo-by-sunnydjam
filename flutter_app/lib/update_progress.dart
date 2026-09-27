part of 'main.dart';

const _updateStages = [
  'checking',
  'downloading',
  'verifying',
  'stopping',
  'installing',
];

class _UpdateProgressOverlay extends StatelessWidget {
  const _UpdateProgressOverlay({
    required this.stage,
    required this.version,
    required this.percent,
    required this.downloaded,
    required this.total,
    required this.error,
    required this.onClose,
  });

  final String stage, version, error;
  final double? percent;
  final int downloaded, total;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final failed = stage == 'failed';
    final labels = <String, String>{
      'checking': 'Проверяем новую версию',
      'downloading': 'Загружаем обновление',
      'verifying': 'Проверяем целостность файлов',
      'stopping': 'Отключаем VPN перед установкой',
      'installing': 'Передаём управление установщику',
    };
    final details = <String, String>{
      'checking': 'Получаем сведения о выпуске. VPN пока продолжает работать.',
      'downloading':
          'Не закрывайте Dropo. Соединение сохраняется до завершения загрузки и проверки.',
      'verifying':
          'Сверяем размер и SHA-256, сохраняем проверенный установщик.',
      'stopping': 'На время установки интернет через VPN будет недоступен.',
      'installing':
          'Откроется окно с прогрессом установки. После успешного обновления Dropo запустится автоматически.',
    };
    return Material(
      key: const ValueKey('update-progress-overlay'),
      color: Colors.black.withValues(alpha: 0.78),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _atlasSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _atlasBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  failed ? Icons.error_outline : Icons.system_update_alt,
                  color: failed ? Colors.redAccent : _atlasMint,
                  size: 32,
                ),
                const SizedBox(height: 16),
                Text(
                  failed
                      ? 'Обновление не установлено'
                      : 'Обновление Dropo $version',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    failed ? error : labels[stage] ?? labels['checking']!,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                ),
                const SizedBox(height: 16),
                if (!failed) ...[
                  LinearProgressIndicator(
                    value: stage == 'downloading' && percent != null
                        ? percent! / 100
                        : null,
                    color: _atlasMint,
                    backgroundColor: _atlasBorder,
                    minHeight: 6,
                  ),
                  if (stage == 'downloading' && percent != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${percent!.round()}%${total > 0 ? ' · ${(downloaded / 1048576).toStringAsFixed(1)} из ${(total / 1048576).toStringAsFixed(1)} МБ' : ''}',
                      style: const TextStyle(
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Text(
                    details[stage] ?? details['checking']!,
                    style: const TextStyle(color: _atlasMuted, height: 1.5),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Загрузка → Проверка → Установка → Перезапуск',
                    style: TextStyle(color: _atlasMuted, fontSize: 12),
                  ),
                ] else ...[
                  const Text(
                    'Приложение не будет закрыто. Можно повторить обновление вручную. Если VPN отключился на этапе установки, подключите его заново.',
                    style: TextStyle(color: _atlasMuted, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  TextButton(onPressed: onClose, child: const Text('Понятно')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
