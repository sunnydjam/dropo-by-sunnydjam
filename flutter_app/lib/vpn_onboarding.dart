part of 'main.dart';

enum _VpnOnboardingAction { ready, manage, services }

/// Preparing an optional public source is separate from starting the VPN.
/// No source is fetched or enabled until the user accepts the disclosure.
class _VpnOnboardingDialog extends StatefulWidget {
  const _VpnOnboardingDialog({
    required this.bridge,
    required this.hasDisabledSources,
  });

  final CoreBridge bridge;
  final bool hasDisabledSources;

  @override
  State<_VpnOnboardingDialog> createState() => _VpnOnboardingDialogState();
}

class _VpnOnboardingDialogState extends State<_VpnOnboardingDialog> {
  List<PublicVpnProviderInfo> providers = const [];
  bool loading = true;
  bool busy = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    if (widget.hasDisabledSources) {
      loading = false;
    } else {
      unawaited(_loadCatalog());
    }
  }

  Future<void> _loadCatalog() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final loaded = await widget.bridge.publicVpnProviders().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() {
        providers = loaded;
        if (loaded.isEmpty) error = 'Бесплатный каталог сейчас недоступен.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось получить бесплатный каталог. Попробуйте ещё раз или добавьте свою подписку.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _continueFree(PublicVpnProviderInfo provider) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.bridge.addPublicVpnSource(provider.id, true);
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() => error = _friendlyVpnSourceError(result['error']));
        return;
      }
      Navigator.of(context).pop(_VpnOnboardingAction.ready);
    } catch (failure) {
      if (mounted) setState(() => error = _friendlyVpnSourceError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      key: const ValueKey('full-vpn-onboarding'),
      title: Text(
        widget.hasDisabledSources
            ? 'Источники VPN выключены'
            : 'Как подключиться?',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.hasDisabledSources
                    ? 'Откройте источники и включите нужный. Мы не включаем отключённые вами источники автоматически.'
                    : 'Для режима «Всё через VPN» можно использовать бесплатный публичный источник или свою подписку.',
              ),
              if (!widget.hasDisabledSources) ...[
                const SizedBox(height: 16),
                const Text(
                  'Это сторонние серверы, не сеть Dropo. Оператор может видеть адреса соединений и незашифрованный трафик. Скорость, конфиденциальность и доступность не гарантируются.',
                  style: TextStyle(fontSize: 13, height: 1.4),
                ),
                if (loading || busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    busy ? 'Готовим бесплатный источник…' : 'Получаем каталог…',
                  ),
                ],
                for (final provider in providers) ...[
                  const SizedBox(height: 16),
                  Text(
                    provider.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: ValueKey('onboarding-free-${provider.id}'),
                    onPressed: busy ? null : () => _continueFree(provider),
                    icon: const Icon(Icons.public),
                    label: const Text('Продолжить бесплатно'),
                  ),
                ],
                if (providers.isNotEmpty)
                  const Text(
                    'Продолжая, вы соглашаетесь использовать этот публичный источник.',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (providers.isEmpty && !loading)
                  TextButton.icon(
                    key: const ValueKey('onboarding-retry-catalog'),
                    onPressed: busy ? null : _loadCatalog,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить'),
                  ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const ValueKey('onboarding-own-source'),
                onPressed: busy
                    ? null
                    : () => Navigator.pop(context, _VpnOnboardingAction.manage),
                icon: const Icon(Icons.add_link),
                label: Text(
                  widget.hasDisabledSources
                      ? 'Открыть источники'
                      : 'Добавить свою подписку',
                ),
              ),
              TextButton(
                key: const ValueKey('onboarding-services-mode'),
                onPressed: busy
                    ? null
                    : () =>
                          Navigator.pop(context, _VpnOnboardingAction.services),
                child: const Text('Выбрать режим «По сервисам»'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('onboarding-cancel'),
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    ),
  );
}
