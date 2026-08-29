# dropo Tools

Утилиты для разработки и ручной проверки маршрутизации dropo.

## Среда разработки Windows

Flutter, Go, Visual Studio Build Tools и Inno Setup следует хранить отдельно от
репозитория. Укажите их общий каталог пользовательской переменной окружения:

```powershell
[Environment]::SetEnvironmentVariable(
    "DROPO_TOOLCHAIN_ROOT",
    "E:\Development\Toolchains\Dropo",
    "User"
)
```

После изменения откройте новое окно терминала. Скрипты сборки ищут Go, Flutter
и Inno Setup в этом каталоге, затем используют системные установки. Локальная
папка `.toolchain` поддерживается только как обратный совместимый вариант.

## preflight-release.ps1

Главный релизный gate. Скрипт запускает Go- и Flutter-проверки, собирает релиз,
валидирует артефакты и при необходимости выполняет runtime-smoke.

Минимальный запуск перед билдом:

```powershell
.\tools\preflight-release.ps1 -Build
```

Полный запуск с сетью и подпиской выполняйте из PowerShell с правами администратора:

```powershell
$env:DROPO_TEST_SUBSCRIPTION_URL = "<subscription-url>"
.\tools\preflight-release.ps1 -WithNetwork -WithSubscription -Build
Remove-Item Env:\DROPO_TEST_SUBSCRIPTION_URL
```

Полезные параметры:

- `-WithNetwork` запускает free-access runtime smoke на релизной папке.
- `-WithSubscription` запускает subscription/xHTTP runtime smoke через Xray bridge.
- `-WireGuardConfigPath <path>` проверяет парсинг WireGuard-конфига без записи секрета в репозиторий.
- `-ReleaseFolder <path>` позволяет валидировать уже собранную папку.

## publish-release-assets.ps1

Локально проверяет и загружает Windows installer, portable ZIP, их SHA-256,
SBOM/provenance и, для полного релиза, подписанный Android APK в уже созданную
карточку GitHub Release. Actions при этом не получает signing keys и не собирает
артефакты.

```powershell
.\publish-release-assets.ps1 -ReleaseFolder ..\release\dropo-<version>-<hash>
```

Windows-only release candidate публикуется с явными тегом и режимом:

```powershell
.\publish-release-assets.ps1 `
  -ReleaseFolder ..\release\dropo-<version>-<hash> `
  -Tag v<version>-rc.1 `
  -WindowsOnly
```

Аутентификация берётся из `GH_TOKEN` или из локального Git credential manager.
Без `-ReplaceExisting` скрипт откажется заменять уже загруженный файл.

## check-services.ps1

Проверяет доступность набора сайтов в двух группах:

- `Phase 1`: сервисы, которые должны открываться напрямую.
- `Phase 2`: сервисы, которые должны открываться через VPN/free-access маршрут.

Запуск:

```powershell
cd tools
.\check-services.ps1
.\check-services.ps1 -SkipIPCheck
.\check-services.ps1 -Verbose
.\check-services.ps1 -Phase1Only
.\check-services.ps1 -Phase2Only
.\check-services.ps1 -Json
```

## check-routes.ps1

Проверяет фактически запущенный маршрут. В selective-режиме сначала читает
`deep_windows_proxy_config.json`, а `active_config.json` использует только как
резервный источник:

- `.\resources\deep_windows_proxy_config.json`
- `%LOCALAPPDATA%\dropo\resources\deep_windows_proxy_config.json`
- `.\resources\active_config.json` (fallback)
- `%LOCALAPPDATA%\dropo\resources\active_config.json`

Запуск:

```powershell
cd tools
.\check-routes.ps1
```

Preferred client flow: **Настройки → `🔍 Проверить`** (the in-app availability
test, moved from the home screen into Settings). It runs a native concurrent
check inside dropo, updates the result table dynamically, does not open
PowerShell windows, and does not write the quick-check output into the main app
logs. For diagnosing *how* a provider blocks (RST/timeout/IP/DNS), use
**Настройки → `🩻 Снять отпечаток`** and send the file to the developer. The
local censor lab used to reproduce these reports lives in `testlab/`.

Manual quick client bundle script, for emergency support only. Current Windows
diagnostics inspect the in-process traffic orchestrator, the single WinDivert
owner, VPN-source health and stale app-owned processes from older installations.

```powershell
.\client-quick-check.ps1
```

Run it while dropo is connected. It writes a Desktop folder with service results, a redacted configuration summary, ports, adapters, routes and authenticated Clash API data. The raw configs are deliberately excluded because they can contain VPN credentials and the process-local Clash API secret. The check follows the configured route: VPN services use the live mixed proxy, Direct services bypass PAC, and Zapret services use the transparent engine. Steam/EA/Apex probes are always negative Direct guards.

For blocked-service failures, run the deeper method matrix:

```powershell
.\client-quick-check.ps1 -DeepMethodCheck
```

This adds `free-method-results.csv` for compatibility with older support
automation. Native per-service strategy decisions, target matrices and fallback
transitions are recorded in the app diagnostics and main route indicator.

Dropo now cleans bundled sidecar processes automatically on startup, before VPN
start, on failed starts, on stop, and on quit. It also scans sibling portable
folders named `dropo-*`, so a newly unpacked build can clean sidecars left by an
older unpacked build. If the app itself cannot be launched, use the manual
cleanup command as an emergency fallback:

```powershell
.\client-quick-check.ps1 -DeepMethodCheck
.\client-quick-check.ps1 -CleanupDropoOrphans
```

`-CleanupDropoOrphans` kills current managed sidecars and historical app-owned
sidecars only when their executable path is inside the detected Dropo app root.
It does not target other VPN applications.

## Практические сценарии

1. Без VPN-ключа: включить `Бесплатный доступ`, выбрать Zapret для нужных сервисов, запустить приложение и проверить `check-services.ps1 -Phase2Only`.
2. С VPN-подпиской: добавить подписку в UI, подключиться и проверить `check-services.ps1`; тест проверит только выбранные непрямые сервисы и Direct-регрессии.
3. С WireGuard: добавить рабочую сеть, подключиться, затем проверить корпоративные домены и маршруты через `check-routes.ps1`.
4. В режиме `Только заблокированные` проверить `route.final=direct`: blocked-domain правила идут до known-domain `direct`, generic blocked-IP правила — после него, а service-specific IP-списки не входят в global catch-all. Широкие сети общих CDN не должны перехватывать обычный трафик.
5. AI services: без подписки `openai.com`, `api.openai.com`, Copilot/Cursor endpoints должны идти direct/pass-through; с подпиской должен появиться `bypass-openai` с единственным кандидатом `auto-select`.
