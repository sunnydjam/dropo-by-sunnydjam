part of 'main.dart';

/// Android's VPN protection is reported independently from the VPN session.
///
/// [alwaysOn], [lockdown], and [killSwitchActive] are nullable on purpose:
/// `null` means Android did not provide an authoritative value. A missing or
/// malformed native response must never be presented as either enabled or
/// disabled protection.
class AndroidVpnProtection {
  const AndroidVpnProtection({
    required this.observed,
    required this.alwaysOn,
    required this.lockdown,
    required this.killSwitchActive,
  });

  final bool observed;
  final bool? alwaysOn;
  final bool? lockdown;
  final bool? killSwitchActive;

  bool get confirmedKillSwitch =>
      observed &&
      alwaysOn == true &&
      lockdown == true &&
      killSwitchActive == true;

  factory AndroidVpnProtection.fromJson(Map<String, dynamic> json) {
    final observed = json['observed'] == true;
    if (!observed) {
      return AndroidVpnProtection.unknown();
    }
    return AndroidVpnProtection(
      observed: true,
      alwaysOn: _nullableProtectionBool(json['alwaysOn']),
      lockdown: _nullableProtectionBool(json['lockdown']),
      killSwitchActive: _nullableProtectionBool(json['killSwitchActive']),
    );
  }

  factory AndroidVpnProtection.unknown() {
    return const AndroidVpnProtection(
      observed: false,
      alwaysOn: null,
      lockdown: null,
      killSwitchActive: null,
    );
  }
}

bool? _nullableProtectionBool(Object? value) => value is bool ? value : null;

class _AndroidVpnProtectionCopy {
  const _AndroidVpnProtectionCopy({
    required this.title,
    required this.body,
    required this.icon,
    required this.color,
  });

  final String title;
  final String body;
  final IconData icon;
  final Color color;
}

_AndroidVpnProtectionCopy _androidVpnProtectionCopy(
  AndroidVpnProtection protection, {
  required bool loading,
  required String error,
}) {
  if (loading) {
    return const _AndroidVpnProtectionCopy(
      title: 'Проверяем системную защиту',
      body: 'Запрашиваем у Android состояние VPN и блокировки без VPN.',
      icon: Icons.sync,
      color: Color(0xFF8EA19D),
    );
  }
  if (error.trim().isNotEmpty || !protection.observed) {
    return _AndroidVpnProtectionCopy(
      title: 'Статус защиты не определён',
      body: error.trim().isNotEmpty
          ? 'Android не подтвердил состояние защиты: ${error.trim()}'
          : 'Android пока не подтвердил состояние. Откройте системные настройки VPN и проверьте оба параметра.',
      icon: Icons.shield_outlined,
      color: const Color(0xFFF59E0B),
    );
  }
  if (protection.confirmedKillSwitch) {
    return const _AndroidVpnProtectionCopy(
      title: 'Защита от утечки включена',
      body:
          'Android подтвердил Always-on VPN и «Блокировать подключения без VPN». Kill switch активен.',
      icon: Icons.gpp_good,
      color: Color(0xFF36D399),
    );
  }
  if (protection.alwaysOn == true && protection.lockdown == false) {
    return const _AndroidVpnProtectionCopy(
      title: 'Блокировка трафика выключена',
      body:
          'Always-on для Dropo включён, но «Блокировать подключения без VPN» выключено. Это не kill switch: при разрыве трафик может пойти напрямую.',
      icon: Icons.gpp_maybe_outlined,
      color: Color(0xFFF59E0B),
    );
  }
  if (protection.alwaysOn == false && protection.lockdown == false) {
    return const _AndroidVpnProtectionCopy(
      title: 'Системная защита выключена',
      body:
          'Android не будет блокировать соединения при разрыве VPN. Для kill switch включите оба системных параметра.',
      icon: Icons.shield_outlined,
      color: Color(0xFFF59E0B),
    );
  }
  return const _AndroidVpnProtectionCopy(
    title: 'Настройка защиты неполная',
    body:
        'Android не подтвердил одновременно Always-on VPN и блокировку соединений без VPN. Kill switch не считается активным.',
    icon: Icons.gpp_maybe_outlined,
    color: Color(0xFFF59E0B),
  );
}

class _AndroidVpnProtectionCard extends StatelessWidget {
  const _AndroidVpnProtectionCard({
    required this.protection,
    required this.loading,
    required this.error,
    required this.openingSettings,
    required this.onOpenSettings,
  });

  final AndroidVpnProtection protection;
  final bool loading;
  final String error;
  final bool openingSettings;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final copy = _androidVpnProtectionCopy(
      protection,
      loading: loading,
      error: error,
    );
    return Container(
      key: const ValueKey('android-vpn-protection-card'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: copy.color.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(copy.icon, color: copy.color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      copy.body,
                      style: const TextStyle(
                        color: Color(0xFF9CB0AD),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            key: const ValueKey('android-open-vpn-settings'),
            child: _ActionButton(
              label: openingSettings ? 'Открываем...' : 'Открыть настройки VPN',
              icon: Icons.open_in_new,
              compact: true,
              onPressed: openingSettings ? null : onOpenSettings,
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
Widget androidVpnProtectionCardForTest({
  required AndroidVpnProtection protection,
  bool loading = false,
  String error = '',
  bool openingSettings = false,
  VoidCallback? onOpenSettings,
}) {
  return _AndroidVpnProtectionCard(
    protection: protection,
    loading: loading,
    error: error,
    openingSettings: openingSettings,
    onOpenSettings: onOpenSettings,
  );
}
