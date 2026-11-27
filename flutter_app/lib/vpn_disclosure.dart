part of 'main.dart';

/// Native storage is also checked by the Android VPN service, including restart.
class VpnDisclosureConsentStore {
  VpnDisclosureConsentStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dropo/core');

  static const version = 1;
  final MethodChannel _channel;

  Future<bool> isAccepted() async {
    final value = await _channel
        .invokeMethod<Object?>('getVpnDisclosureConsent')
        .timeout(const Duration(seconds: 5));
    return value is Map &&
        value['accepted'] == true &&
        value['version'] == version;
  }

  Future<void> accept() async {
    final value = await _channel
        .invokeMethod<Object?>('acceptVpnDisclosureConsent', {
          'version': version,
        })
        .timeout(const Duration(seconds: 5));
    if (value is! Map || value['success'] != true || !await isAccepted()) {
      throw StateError('VPN consent was not stored');
    }
  }
}

class _VpnDisclosureDialog extends StatefulWidget {
  const _VpnDisclosureDialog({
    required this.onAccept,
    required this.onOpenPrivacy,
  });

  final Future<void> Function() onAccept;
  final Future<void> Function() onOpenPrivacy;

  @override
  State<_VpnDisclosureDialog> createState() => _VpnDisclosureDialogState();
}

class _VpnDisclosureDialogState extends State<_VpnDisclosureDialog> {
  bool _saving = false;
  bool _openingPrivacy = false;
  String _error = '';

  Future<void> _accept() async {
    if (_saving || _openingPrivacy) return;
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.onAccept();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              'Не удалось сохранить согласие. VPN не запущен. '
              'Повторите попытку или нажмите «Не сейчас».';
        });
      }
    }
  }

  Future<void> _openPrivacy() async {
    if (_saving || _openingPrivacy) return;
    setState(() {
      _openingPrivacy = true;
      _error = '';
    });
    try {
      await widget.onOpenPrivacy();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось открыть политику. '
              'Ссылка также доступна в разделе «О приложении».',
        );
      }
    } finally {
      if (mounted) setState(() => _openingPrivacy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _openingPrivacy;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        key: const ValueKey('vpn-data-disclosure'),
        title: Text(
          _tr(context, 'Как Dropo использует VPN', 'How Dropo uses VPN'),
        ),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _tr(
                  context,
                  'Для подключения и маршрутизации Dropo использует Android '
                      'VpnService. На устройстве обрабатываются сетевые пакеты, '
                      'DNS-запросы, адреса и домены соединений, а также идентификаторы '
                      'приложений, которым принадлежат соединения.',
                  'Dropo uses Android VpnService to connect and route traffic. On your device it processes network packets, DNS requests, connection addresses and domains, and the IDs of apps that make those connections.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _tr(
                  context,
                  'Трафик, выбранный для VPN, передаётся оператору вашего '
                      'VPN-источника. Оператор может видеть адреса соединений и '
                      'содержимое, не защищённое самим сайтом или приложением. '
                      'DNS-запросы получает используемый DNS-сервис. '
                      'В режиме «Ручное» остальной трафик может идти напрямую; '
                      'сохранённые исключения также остаются прямыми.',
                  'Traffic routed through the VPN goes to your VPN provider. The provider can see connection addresses and content that the website or app does not encrypt. Your DNS provider receives DNS requests. In Manual mode, other traffic can use the direct connection. Saved exclusions also stay direct.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _tr(
                  context,
                  'Эти данные используются для работы подключения, а не для '
                      'рекламы. Диагностические журналы хранятся на устройстве и могут '
                      'содержать адреса соединений. Dropo не отправляет их автоматически '
                      'на сервер аккаунтов или разработчику. Отдельная настройка '
                      '«Помогать улучшать подключение» позволяет с вашего разрешения '
                      'отправлять ограниченные технические события без полных журналов; '
                      'по умолчанию она выключена. При доступности сервера Dropo '
                      'автоматически создаёт бесплатный профиль со случайным '
                      'идентификатором установки, без MAC-адреса и входа через Telegram. '
                      'После вашего согласия '
                      'Android отдельно запросит системное разрешение на VPN, если оно '
                      'ещё не выдано.',
                  'Dropo uses this data to operate the VPN. Diagnostic logs stay on your device and may contain connection addresses. Dropo does not automatically share these logs with the account service or the developer. The optional Help improve connections setting sends limited technical events without full logs and is off by default. To provide Free access, Dropo creates a profile with a random installation ID. No MAC address or Telegram sign-in is required. Android will ask separately for VPN permission if needed.',
                ),
              ),
              if (_isPlayDistribution) ...[
                const SizedBox(height: 12),
                Text(
                  _tr(
                    context,
                    'Для выдачи Free Google Play проверяет установку и целостность устройства. Google получает хеш запроса без секрета установки и VPN-трафика.',
                    'Google Play verifies the installation and device integrity for Free access. Google receives a request hash without the installation secret or VPN traffic.',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextButton.icon(
                key: const ValueKey('vpn-disclosure-privacy'),
                onPressed: busy ? null : _openPrivacy,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(
                  _tr(context, 'Политика конфиденциальности', 'Privacy policy'),
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  key: const ValueKey('vpn-disclosure-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('vpn-disclosure-decline'),
            onPressed: busy ? null : () => Navigator.of(context).pop(false),
            child: Text(_tr(context, 'Не сейчас', 'Not now')),
          ),
          FilledButton(
            key: const ValueKey('vpn-disclosure-accept'),
            onPressed: busy ? null : _accept,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _tr(context, 'Согласен, продолжить', 'I agree, continue'),
                  ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
Widget vpnDisclosureDialogForTest({
  required Future<void> Function() onAccept,
  required Future<void> Function() onOpenPrivacy,
}) => _VpnDisclosureDialog(onAccept: onAccept, onOpenPrivacy: onOpenPrivacy);
