# Разработка Dropo

Команды запускаются из корня checkout в PowerShell. Версии Go и Flutter указаны в [CI](../../.github/workflows/ci.yml).

| Задача | Команда |
| --- | --- |
| Проверить общий код источников | `go -C app/mobile/dropocore test ./ownedprofile` |
| Проверить bootstrap | `pwsh -File scripts/check/bootstrap.ps1` |
| Проверить Flutter | `Push-Location flutter_app`, затем `flutter test` и `Pop-Location` |
| Собрать Windows | `pwsh -File scripts/build/build.ps1 -Build` |
| Собрать Android Preview | `pwsh -File scripts/build/build.ps1 -AndroidPreview -AndroidArchitecture universal` |
| Подготовить Google Play AAB | `pwsh -File tools/build-google-play-release.ps1` |

Модули Go в `app`, `app/mobile/dropocore`, `app/mobile/dropoandroid`, `launcher` и `bootstrap` проверяются раздельно. Для Android bridge применяются build tags и XHTTP overlay из [сборщика](../../scripts/build/build.ps1).

[Источники VPN](../architecture/PUBLIC_VPN_SOURCES.md) · [Android и Play Console](../release/ANDROID_GOOGLE_PLAY_RELEASE.md) · [Правила подписи](../release/CODE_SIGNING_POLICY.md)

## Слияние и выпуск

Рабочие изменения поступают в `develop` через PR. Переход в `main` выполняет ответственный за выпуск после независимого ревью. Для действующего правила веток подготовлен [проект изменений](../release/branch-protection.proposed.json). Он сохраняет защиту исторической ветки и пустой список обхода, добавляет защиту `main` и `develop` и одно независимое одобрение. Перед применением сверьте набор обязательных проверок с последним успешным PR и действующие права владельцев путей.

Обработчик публикации GitHub берёт из ветки по умолчанию. Историческая версия на `Dzhamuha-develop` ожидает событие `push` этой ветки и пропускает ручную сборку `main`. Версия обработчика на `main` до оптимизации принимала любую успешную ручную сборку этой ветки. До смены ветки по умолчанию сверьте ревизию обработчика и условия события. После переключения проверьте целевую ветку и условия правила через GitHub API. При ручной проверке выберите `validate` и сравните список релизов и файлов до и после. Публикация требует отдельного запуска с `release`.

Для проверки существующего Windows-пакета используйте `tools/preflight-release.ps1 -ReleaseFolder <папка>` в выделенной Windows VM. Для отчёта поддержки на пользовательском ПК используйте `tools/client-quick-check.ps1`.

[Проверка первого подключения](BETA_TEST_PLAN.md) · [Защита Windows](../architecture/WINDOWS_WFP_PROTECTION_PLAN.md) · [Архив решений](../archive/README.md)
