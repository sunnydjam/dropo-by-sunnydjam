part of 'main.dart';

@visibleForTesting
Widget aboutContentForTest({
  required CoreStatus status,
  AppConfig appConfig = AppConfig.defaults,
  required Future<void> Function(String) onOpenExternal,
}) => _AboutContent(
  status: status,
  appConfig: appConfig,
  onOpenExternal: onOpenExternal,
);

// Shared body for the About page and the compact brand dialog. The containing
// surface supplies scrolling, so both presentations keep identical content.
class _AboutContent extends StatelessWidget {
  const _AboutContent({
    required this.status,
    required this.appConfig,
    required this.onOpenExternal,
  });

  final CoreStatus status;
  final AppConfig appConfig;
  final Future<void> Function(String) onOpenExternal;

  String get _repositoryUrl {
    final reported = Uri.tryParse(appConfig.githubUrl.trim());
    if (reported != null &&
        reported.scheme == 'https' &&
        reported.host == 'github.com' &&
        reported.userInfo.isEmpty &&
        reported.pathSegments.length == 2 &&
        reported.pathSegments.every(
          (segment) => RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(segment),
        )) {
      return 'https://github.com/${reported.pathSegments.join('/')}';
    }
    return AppConfig.defaults.githubUrl;
  }

  @override
  Widget build(BuildContext context) {
    final version = status.version;
    final repository = _repositoryUrl;
    final build = version.fullVersion.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: _HomeBrand()),
        ),
        const SizedBox(height: 12),
        const Text(
          'Ваши VPN-источники — в одном приложении. Подключайте весь трафик '
          'или выбирайте маршрут отдельно для сервисов.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFFADC1BB), height: 1.4),
        ),
        const SizedBox(height: 18),
        _AboutDetail(label: 'Версия', value: version.version),
        _AboutDetail(
          label: 'Сборка',
          value: build.isNotEmpty ? build : version.version,
        ),
        if (version.singboxVersion.trim().isNotEmpty)
          _AboutDetail(
            label: 'Сетевое ядро sing-box',
            value: version.singboxVersion,
          ),
        const SizedBox(height: 10),
        _AboutLink(
          label: 'Разработчик этой версии',
          detail: 'Джамуха (sunnydjam)',
          url: 'https://github.com/sunnydjam',
          icon: Icons.person_outline,
          onOpenExternal: onOpenExternal,
        ),
        _AboutLink(
          label: 'Основа проекта',
          detail: 'Droponevedimka',
          url: 'https://github.com/Droponevedimka',
          icon: Icons.history,
          onOpenExternal: onOpenExternal,
        ),
        const Divider(height: 24),
        _AboutLink(
          label: 'Исходный код',
          detail: Uri.parse(repository).path.substring(1),
          url: repository,
          icon: Icons.code,
          onOpenExternal: onOpenExternal,
        ),
        _AboutLink(
          label: 'Релизы и изменения',
          detail: 'Скачать версию из репозитория проекта',
          url: '$repository/releases',
          icon: Icons.new_releases_outlined,
          onOpenExternal: onOpenExternal,
        ),
        _AboutLink(
          label: 'Сообщить о проблеме',
          detail: 'Не публикуйте ссылки подписок, ключи и приватные логи',
          url: '$repository/issues',
          icon: Icons.bug_report_outlined,
          onOpenExternal: onOpenExternal,
        ),
        _AboutLink(
          label: 'Лицензия MIT',
          url: '$repository/blob/Dzhamuha-develop/LICENSE',
          icon: Icons.description_outlined,
          onOpenExternal: onOpenExternal,
        ),
        _AboutLink(
          label: 'Сторонние компоненты',
          detail: 'Лицензии и благодарности',
          url: '$repository/blob/Dzhamuha-develop/THIRD_PARTY_NOTICES.md',
          icon: Icons.extension_outlined,
          onOpenExternal: onOpenExternal,
        ),
      ],
    );
  }
}

class _AboutDetail extends StatelessWidget {
  const _AboutDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8EA2A0), fontSize: 12),
        ),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: const TextStyle(
            color: Color(0xFFE8F5F1),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _AboutLink extends StatelessWidget {
  const _AboutLink({
    required this.label,
    this.detail,
    required this.url,
    required this.icon,
    required this.onOpenExternal,
  });

  final String label;
  final String? detail;
  final String url;
  final IconData icon;
  final Future<void> Function(String) onOpenExternal;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('about-link-$label'),
    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    minVerticalPadding: 8,
    mouseCursor: SystemMouseCursors.click,
    leading: Icon(icon, color: const Color(0xFF84DBC0), size: 22),
    title: Text(label),
    subtitle: detail == null ? null : Text(detail!),
    trailing: const Icon(Icons.open_in_new, size: 16),
    onTap: () => unawaited(onOpenExternal(url)),
  );
}
