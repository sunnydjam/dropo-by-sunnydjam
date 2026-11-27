part of 'main.dart';

const _languageChannel = MethodChannel('dropo/core');
final _languageChoice = ValueNotifier<String>('system');
const _languageOptions = {'system', 'ru', 'en'};

class _DropoLocale extends InheritedWidget {
  const _DropoLocale({required this.english, required super.child});
  final bool english;

  @override
  bool updateShouldNotify(_DropoLocale oldWidget) =>
      english != oldWidget.english;
}

bool _english(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_DropoLocale>()?.english ??
    false;

String _tr(BuildContext context, String russian, String english) =>
    _english(context) ? english : russian;

Future<void> _restoreAndroidLanguage() async {
  try {
    final saved = await _languageChannel.invokeMethod<String>(
      'getInterfaceLanguage',
    );
    if (saved != null && _languageOptions.contains(saved)) {
      _languageChoice.value = saved;
    }
  } on PlatformException {
    // The system locale remains available if the stored setting is unreadable.
  } on MissingPluginException {
    // Platform views and preferences are not installed in widget tests.
  }
}

Future<void> _saveAndroidLanguage(String value) async {
  if (!_languageOptions.contains(value)) return;
  if (Platform.isAndroid) {
    await _languageChannel.invokeMethod<void>('setInterfaceLanguage', {
      'language': value,
    });
  }
  _languageChoice.value = value;
}

String _uiText(BuildContext context, String value) =>
    _english(context) ? _englishUi[value] ?? value : value;

const _englishUi = <String, String>{
  'Главная': 'Home',
  'Источники VPN': 'VPN sources',
  'Сервисы': 'Services',
  'Диагностика': 'Diagnostics',
  'Настройки': 'Settings',
  'Аккаунт': 'Account',
  'Профили': 'Profiles',
  'Рабочие сети': 'Work networks',
  'Статистика': 'Statistics',
  'О приложении': 'About',
  'Приложение': 'App',
  'Дополнительно': 'Advanced',
  'Сеть и диагностика': 'Network and diagnostics',
  'Помощь': 'Help',
  'Решить проблему': 'Troubleshooting',
  'Гость': 'Guest',
  'Бесплатный тариф': 'Free plan',
  'Войти через Telegram': 'Sign in with Telegram',
  'Назад': 'Back',
  'Купить': 'Buy',
  'Выход': 'Exit',
  'Оформление и обновления': 'Appearance and updates',
  'Маршруты, диагностика и совместимость':
      'Routing, diagnostics, and compatibility',
  'Решение проблем и диагностика': 'Troubleshooting and diagnostics',
  'Логирование, проверка сервисов и компоненты':
      'Logging, service checks, and components',
  'Совместимость приложений на Android': 'Android app compatibility',
  'Нет интернета, не открывается сервис или не получается обновиться':
      'Fix internet, service access, or update issues',
  'Журнал и данные для решения проблем': 'Logs and troubleshooting data',
  'Трафик текущего подключения': 'Traffic in the current session',
  'Версия, проект и лицензии': 'Version, project, and licenses',
  'Отключить соединение и закрыть Dropo': 'Disconnect and close Dropo',
  'Защита соединения': 'Connection protection',
  'Обновления': 'Updates',
  'Обновления через Google Play': 'Updates through Google Play',
  'Новые версии устанавливаются через магазин. Настройки обновлений доступны в Google Play.':
      'Use Google Play to install new versions and manage automatic updates.',
  'Открыть Google Play': 'Open Google Play',
  'Проверять обновления автоматически': 'Check for updates automatically',
  'Сообщать о новых версиях. Скачивание и установка — только по вашему нажатию':
      'Notify me about updates. Download and install when I choose.',
  'Проверить сейчас': 'Check now',
  'Проверить стабильные релизы GitHub': 'Check stable GitHub releases',
  'Проверить': 'Check',
  'Обновить': 'Update',
  'Внешний вид': 'Appearance',
  'Анимации интерфейса': 'Interface animations',
  'Планета, звёзды и мягкий рассвет. Движение останавливается, когда приложение свёрнуто; системное уменьшение движения имеет приоритет.':
      'Animate Earth, stars, and dawn. Animations pause in the background and respect the device’s reduced-motion setting.',
  'Всегда через VPN': 'Always through VPN',
  'Ручное': 'Manual',
  'Приложения': 'Applications',
  'Домены и IP-адреса': 'Domains and IP addresses',
  'ИИ и сервисы с региональными ограничениями': 'AI and region-restricted services',
  'В обоих режимах эти сервисы используют только VPN. Если VPN недоступен, соединение останавливается.': 'These services use VPN in both modes. If VPN is unavailable, the connection stops.',
  'Маршрутизация': 'Routing',
  'Подключиться': 'Connect',
  'Попробовать снова': 'Try again',
  'Проверяем соединение…': 'Checking connection…',
  'Отключаем…': 'Disconnecting…',
  'Отключить': 'Disconnect',
  'Выбранные сервисы': 'Selected services',
  'Весь трафик': 'All traffic',
  'Политика конфиденциальности': 'Privacy policy',
  'Удаление аккаунта': 'Account deletion',
  'Закрыть': 'Close',
  'Конфиденциальность': 'Privacy',
  'Подписка': 'Subscription',
  'Помогать улучшать подключение': 'Help improve connections',
  'Отправлять технические сведения о сбоях и результатах проверок. Без переписки, посещённых страниц и ключей подписок. По умолчанию выключено.':
      'Send technical data about failures and service checks. This excludes messages, browsing history, and subscription keys. Off by default.',
  'Обновлять списки серверов в фоне': 'Refresh server lists in the background',
  'Проверяем при подключении с выбранным интервалом. Обновлённый список используется при следующем подключении.':
      'Check on connection at the selected interval and use the updated list for the next session.',
  'Проверяем системную защиту': 'Checking system VPN protection',
  'Запрашиваем у Android состояние VPN и блокировки без VPN.':
      'Checking the VPN and traffic-blocking settings in Android.',
  'Статус защиты не определён': 'VPN protection status unavailable',
  'Android пока не подтвердил состояние. Откройте системные настройки VPN и проверьте оба параметра.':
      'Open Android VPN settings to check Always-on VPN and Block connections without VPN.',
  'Защита от утечки включена': 'Kill switch is on',
  'Android подтвердил Always-on VPN и «Блокировать подключения без VPN». Kill switch активен.':
      'Android has enabled Always-on VPN and Block connections without VPN.',
  'Блокировка трафика выключена': 'Traffic blocking is off',
  'Always-on для Dropo включён, но «Блокировать подключения без VPN» выключено. Это не kill switch: при разрыве трафик может пойти напрямую.':
      'Always-on VPN is enabled for Dropo. Traffic can use the direct connection if the VPN drops. To block it, enable Block connections without VPN.',
  'Системная защита выключена': 'System protection is off',
  'Android не будет блокировать соединения при разрыве VPN. Для kill switch включите оба системных параметра.':
      'Enable Always-on VPN and Block connections without VPN in Android to prevent traffic leaks.',
  'Настройка защиты неполная': 'VPN protection setup incomplete',
  'Android не подтвердил одновременно Always-on VPN и блокировку соединений без VPN. Kill switch не считается активным.':
      'Turn on both Always-on VPN and Block connections without VPN to enable the kill switch.',
  'Открыть настройки VPN': 'Open VPN settings',
  'Открываем...': 'Opening…',
  'Тёмный космический фон с зелёными акцентами. Размер текста и уменьшение движения задаются в настройках устройства.':
      'Dark space background with green accents. Text size and reduced motion follow your device settings.',
  'Закрыть меню': 'Close menu',
};
