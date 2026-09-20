part of 'main.dart';

/// One navigation row, shared by the connection screen and settings hubs.
/// Navigating never changes a saved route or starts a network operation.
class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.section,
    required this.title,
    required this.icon,
    required this.onPressed,
    this.detail,
    this.trailing,
  });
  final String section, title;
  final String? detail;
  final IconData icon;
  final VoidCallback? onPressed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: ListTile(
      key: ValueKey('nav-$section'),
      enabled: onPressed != null,
      onTap: onPressed,
      minTileHeight: 48,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(icon, size: 24, color: _atlasMuted),
      title: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      subtitle: detail == null
          ? null
          : Text(
              detail!,
              style: const TextStyle(
                fontSize: 13,
                color: _atlasMuted,
                height: 1.4,
              ),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
          const Icon(Icons.chevron_right, size: 20, color: _atlasMuted),
        ],
      ),
    ),
  );
}

class _MinimalSettingsPage extends StatelessWidget {
  const _MinimalSettingsPage({
    required this.section,
    required this.disabled,
    required this.onSelect,
    required this.onWorkNetworks,
    required this.onExit,
  });
  final String section;
  final bool disabled;
  final ValueChanged<String> onSelect;
  final VoidCallback? onWorkNetworks, onExit;

  @override
  Widget build(BuildContext context) {
    final entries = switch (section) {
      'advanced' => <(String, String, String, IconData)>[
        (
          'service-settings',
          'Обход и стратегии',
          'Маршруты сервисов и экспериментальный Zapret',
          Icons.alt_route,
        ),
        (
          'profiles',
          'Профили',
          'Сохранённые конфигурации подключения',
          Icons.layers_outlined,
        ),
        (
          'work',
          'Рабочие сети',
          'Защищённый доступ к частным сетям',
          Icons.hub_outlined,
        ),
        (
          'technical-settings',
          'Сеть и диагностика',
          'Логирование, проверка сервисов и компоненты',
          Icons.tune,
        ),
        if (_isMobileShell)
          (
            'dropo_space',
            'Dropo Space',
            'Совместимость приложений на Android',
            Icons.workspaces_outline,
          ),
      ],
      'help' => <(String, String, String, IconData)>[
        (
          'logs',
          'Диагностика',
          'Журнал и данные для решения проблем',
          Icons.monitor_heart_outlined,
        ),
        (
          'stats',
          'Статистика',
          'Трафик текущего подключения',
          Icons.bar_chart_rounded,
        ),
        (
          'about',
          'О приложении',
          'Версия, проект и лицензии',
          Icons.info_outline,
        ),
        ('exit', 'Выход', 'Отключить соединение и закрыть Dropo', Icons.logout),
      ],
      _ => <(String, String, String, IconData)>[
        ('sources', 'Подключение', 'Подписки и серверы', Icons.dns_outlined),
        (
          'service-settings',
          'Сервисы',
          'Маршруты приложений и сайтов',
          Icons.grid_view_rounded,
        ),
        (
          'app-settings',
          'Приложение',
          'Автозапуск и обновления',
          Icons.settings_outlined,
        ),
        (
          'advanced',
          'Дополнительно',
          'Обход, профили и рабочие сети',
          Icons.shield_outlined,
        ),
        ('help', 'Помощь', 'Диагностика и о приложении', Icons.help_outline),
      ],
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView.separated(
          key: ValueKey('$section-section'),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final (target, title, detail, icon) = entries[index];
            return _SettingsLink(
              section: target,
              title: title,
              detail: detail,
              icon: icon,
              onPressed: disabled
                  ? null
                  : switch (target) {
                      'work' => onWorkNetworks,
                      'exit' => onExit,
                      _ => () => onSelect(target),
                    },
            );
          },
        ),
      ),
    );
  }
}
