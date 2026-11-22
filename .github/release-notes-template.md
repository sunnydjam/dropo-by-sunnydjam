## Тестовая сборка Dropo {{TAG}}

В Windows режим «По сервисам» сохраняет все независимые источники в селекторе,
даже если предыдущая проверка сохранила только основной маршрут.

На Android можно менять режим и политику сервисов при активном VPN.
Текущий источник сохраняется при перезагрузке ядра. При ошибке Dropo
восстанавливает прежнюю конфигурацию.

При обновлении из сохранённых профилей удаляется устаревший каталог VPN Checker.
Личные подписки сохраняют порядок и выбранный сервер.

### Результаты живой проверки Windows

На изолированной VM для Dropo Free подтверждено автоматическое переключение
на HTTPS-реле и LV Hysteria 2/QUIC. Через оба входа прошли HTTPS и UDP DNS.
Основной XHTTP не прошёл проверку из тестовой сети. Порт FI TCP/REALITY
был доступен, проверки трафика через него вернули HTTP 503.
Конфигурации Free и Turbo для обоих режимов проверены автоматически.

### Файлы для тестирования

| Файл | Назначение |
| --- | --- |
| [Установщик Windows x64](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Windows-Setup-x64.exe) | Установка и обновление с сохранением настроек |
| [Портативная версия Windows x64](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Windows-Portable-x64.zip) | Запуск без установки |
| [Исходники и лицензии сетевых компонентов](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Runtime-Sources.zip) | Соответствующие исходники встроенных компонентов |

Тестовые пакеты Windows собраны без цифровой подписи издателя.

Windows installer SHA-256: `__WINDOWS_INSTALLER_SHA256_PENDING_LOCAL_UPLOAD__`

Windows portable SHA-256: `__WINDOWS_PORTABLE_SHA256_PENDING_LOCAL_UPLOAD__`
