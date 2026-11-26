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
  });
  final String section, title;
  final String? detail;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: ListTile(
      key: ValueKey('link-$section'),
      enabled: onPressed != null,
      mouseCursor: onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onTap: onPressed,
      minTileHeight: 48,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(icon, size: 24, color: _atlasMuted),
      title: Text(
        _uiText(context, title),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      subtitle: detail == null
          ? null
          : Text(
              _uiText(context, detail!),
              style: const TextStyle(
                fontSize: 13,
                color: _atlasMuted,
                height: 1.4,
              ),
            ),
      trailing: const Icon(Icons.chevron_right, size: 20, color: _atlasMuted),
    ),
  );
}

class _MinimalSettingsPage extends StatelessWidget {
  const _MinimalSettingsPage({
    required this.section,
    required this.disabled,
    required this.onSelect,
    required this.onWorkNetworks,
  });
  final String section;
  final bool disabled;
  final ValueChanged<String> onSelect;
  final VoidCallback? onWorkNetworks;

  @override
  Widget build(BuildContext context) {
    final entries = switch (section) {
      'advanced' => <(String, String, String, IconData)>[
        if (!_isMobileShell)
          (
            'profiles',
            'Профили',
            'Сохранённые конфигурации подключения',
            Icons.layers_outlined,
          ),
        if (!_isMobileShell)
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
          'guided-help',
          'Решить проблему',
          'Нет интернета, не открывается сервис или не получается обновиться',
          Icons.help_outline,
        ),
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
      ],
      _ => <(String, String, String, IconData)>[
        (
          'app-settings',
          'Приложение',
          _isMobileShell
              ? 'Оформление и обновления'
              : 'Автозапуск и обновления',
          Icons.settings_outlined,
        ),
        (
          'advanced',
          'Дополнительно',
          _isMobileShell
              ? 'Маршруты, диагностика и совместимость'
              : 'Обход, профили и рабочие сети',
          Icons.shield_outlined,
        ),
        (
          'vpn-only-services',
          'Сервисы с обязательным VPN',
          'ИИ и сервисы с региональными ограничениями',
          Icons.public_outlined,
        ),
        ('help', 'Помощь', 'Решение проблем и диагностика', Icons.help_outline),
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
                      _ => () => onSelect(target),
                    },
            );
          },
        ),
      ),
    );
  }
}

class _VPNOnlyServicesPage extends StatefulWidget {
  const _VPNOnlyServicesPage({required this.bridge});
  final CoreBridge bridge;

  @override
  State<_VPNOnlyServicesPage> createState() => _VPNOnlyServicesPageState();
}

class _VPNOnlyServicesPageState extends State<_VPNOnlyServicesPage> {
  late Future<List<RouteService>> catalog = widget.bridge.routes();
  @override
  Widget build(BuildContext context) => _FeaturePage(
    title: 'Сервисы с обязательным VPN',
    icon: Icons.public_outlined,
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverToBoxAdapter(
          child: FutureBuilder<List<RouteService>>(
            future: catalog,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return TextButton(
                  onPressed: () =>
                      setState(() => catalog = widget.bridge.routes()),
                  child: Text(_uiText(context, 'Повторить загрузку')),
                );
              }
              final services =
                  (snapshot.data ?? []).where((s) => s.vpnOnly).toList()..sort(
                    (a, b) => _homeRouteName(a).compareTo(_homeRouteName(b)),
                  );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _uiText(
                      context,
                      'В обоих режимах эти сервисы используют только VPN. Если VPN недоступен, соединение останавливается.',
                    ),
                  ),
                  for (final service in services)
                    ListTile(
                      key: ValueKey('vpn-only-${service.tag}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(_homeRouteName(service)),
                      subtitle: SelectableText(
                        service.domainSuffixes.join(', '),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ],
  );
}
