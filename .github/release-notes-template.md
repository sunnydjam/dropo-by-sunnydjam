## Тестовая сборка Dropo {{TAG}}

В Windows добавлена проверка служб авторизации EA app, Epic Games, Battle.net и Riot Client. Обычный запрос игрового лаунчера остаётся прямым при совпадении CDN-адреса с выбранным сервисом. При смене политики новые соединения получают новый маршрут, а открытые соединения продолжают обмен.

В выборочном режиме Windows и Android используют системный DNS для прямых назначений. Подробные результаты стенда и сценарии для тестировщиков собраны в [заметках к версии 3.1.27](https://github.com/{{REPOSITORY}}/blob/{{TAG}}/docs/release/3.1.27-testing.md).

### Файлы для тестирования

| Файл | Назначение |
| --- | --- |
| [Установщик Windows x64](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Windows-Setup-x64.exe) | Установка и обновление с сохранением настроек |
| [Портативная версия Windows x64](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Windows-Portable-x64.zip) | Запуск без установки |
| [Исходники и лицензии сетевых компонентов](https://github.com/{{REPOSITORY}}/releases/download/{{TAG}}/dropo-Runtime-Sources.zip) | Соответствующие исходники встроенных компонентов |

Тестовые пакеты Windows собраны без цифровой подписи издателя.

Windows installer SHA-256: `__WINDOWS_INSTALLER_SHA256_PENDING_LOCAL_UPLOAD__`

Windows portable SHA-256: `__WINDOWS_PORTABLE_SHA256_PENDING_LOCAL_UPLOAD__`
