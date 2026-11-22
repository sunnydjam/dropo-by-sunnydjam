# Разработка Dropo

Команды запускаются из корня checkout в PowerShell. Версии Go и Flutter указаны в [CI](../../.github/workflows/ci.yml).

| Задача | Команда |
| --- | --- |
| Проверить общий код источников | `go -C app/mobile/dropocore test ./ownedprofile` |
| Проверить Flutter | `Push-Location flutter_app`, затем `flutter test` и `Pop-Location` |
| Собрать Windows | `pwsh -File scripts/build/build.ps1 -Build` |
| Собрать Android Preview | `pwsh -File scripts/build/build.ps1 -AndroidPreview -AndroidArchitecture universal` |
| Подготовить Google Play AAB | `pwsh -File tools/build-google-play-release.ps1` |

Модули Go в `app`, `app/mobile/dropocore`, `app/mobile/dropoandroid`, `launcher` и `bootstrap` проверяются раздельно. Для Android bridge применяются build tags и XHTTP overlay из [сборщика](../../scripts/build/build.ps1).

[Источники VPN](../architecture/PUBLIC_VPN_SOURCES.md) · [Android и Play Console](../release/ANDROID_GOOGLE_PLAY_RELEASE.md) · [Правила подписи](../release/CODE_SIGNING_POLICY.md)
