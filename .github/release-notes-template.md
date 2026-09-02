## Dropo by sunnydjam {{TAG}}

Стабильный Windows-выпуск независимого fork на основе
[Droponevedimka/dropo](https://github.com/Droponevedimka/dropo). Основной режим —
выборочная маршрутизация: только выбранные сервисы используют VPN или встроенный
обход, а игры, Steam и остальной трафик остаются на прямом подключении.

### Скачать

| Платформа | Файл | Ссылка | Назначение |
| --- | --- | --- | --- |
| Windows 10/11 x64 | `dropo-Windows-Setup-x64.exe` | [Установщик](https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/{{TAG}}/dropo-Windows-Setup-x64.exe) | Рекомендуемая установка с защищённым runtime-каталогом и обновлением поверх предыдущей версии. |
| Windows 10/11 x64 | `dropo-Windows-Portable-x64.zip` | [Portable](https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/{{TAG}}/dropo-Windows-Portable-x64.zip) | Версия без установки; настройки сохраняются в AppData. |

Windows installer SHA-256: `__WINDOWS_INSTALLER_SHA256_PENDING_LOCAL_UPLOAD__`

Windows portable SHA-256: `__WINDOWS_PORTABLE_SHA256_PENDING_LOCAL_UPLOAD__`

### Рекомендуемый профиль

| Трафик | Маршрут |
| --- | --- |
| YouTube | `Обход (Zapret)` с автоподбором или проверенной ручной стратегией |
| Discord web, приложение и voice/video | `Через VPN` |
| Instagram и ChatGPT | `Через VPN` |
| Игры, Steam, сайты и другие невыбранные сервисы | `Напрямую` |

Новая установка получает этот профиль автоматически. Обновление не меняет
ранее сохранённый явный выбор Direct/VPN/Zapret.

### Что изменилось

- Установленная Windows-версия автоматически загружает проверенные стабильные
  обновления из GitHub Releases, тихо устанавливает их и перезапускает Dropo.
- Добавлена поддержка VLESS HTTPUpgrade; прямой ввод нескольких proxy-ссылок
  создаёт отдельные узлы для ручного выбора.
- Загрузка обновления больше не останавливает рабочий VPN-маршрут до завершения
  проверки размера и SHA-256.
- Стабилизирована выборочная VPN-маршрутизация приложений при сохранении прямого
  игрового трафика и обычных сайтов.
- Все 22 профиля Flowseal 1.10.2 адаптированы к встроенным типизированным
  стратегиям Dropo без запуска внешнего anti-DPI executable, Lua или BAT-файлов.
- Исправлены scoped CONNECT-проверки и приоритет проверенной General ALT.
- Добавлено безопасное обнаружение Discord TLS на альтернативных портах `2053`,
  `2083`, `2087`, `2096`, `8443`: стратегия применяется только при подтверждении
  процесса Discord и не захватывает общий `443` или игровые порты.
- Автоподбор Discord отделён от обычной готовности подключения и помечен как
  экспериментальный.

### Почему Discord Zapret экспериментальный

Discord web/API, gateway и voice/media — разные сетевые плоскости. Работа сайта
не доказывает работу приложения или голосового канала. Voice использует
альтернативный TLS и динамический двусторонний UDP, а DPI-правила провайдера
могут измениться независимо от версии Dropo.

Dropo намеренно не применяет стратегию ко всему общему Cloudflare/CDN IP: это
могло бы затронуть Steam, игры и посторонние сайты. Поэтому Discord Zapret
оставлен для ручных экспериментов, а стабильным маршрутом выпуска является VPN.
Подробности: [EXPERIMENTAL_ZAPRET.md](https://github.com/sunnydjam/dropo-by-sunnydjam/blob/{{TAG}}/EXPERIMENTAL_ZAPRET.md).

### Проверка и ограничения

- Go, Flutter и Android core tests пройдены.
- Windows package прошёл manifest/SBOM/provenance validation, MOTW simulation и
  Microsoft Defender scan.
- Пакет не содержит внешнего Zapret runtime или first-run download executable.
- Windows-файлы пока не имеют публично доверенной Authenticode-подписи.
- Android не входит в этот Windows-выпуск.

Происхождение fork и сохранённая MIT-лицензия описаны в
[FORK_NOTICE.md](https://github.com/sunnydjam/dropo-by-sunnydjam/blob/{{TAG}}/FORK_NOTICE.md).
