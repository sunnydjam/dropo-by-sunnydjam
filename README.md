# Dropo by sunnydjam

Windows-first VPN-клиент с выборочной маршрутизацией сервисов. Проект позволяет
отправлять выбранные сервисы через VPN, оставляя игры, сайты и остальной трафик
на прямом подключении. Также доступен режим полного VPN и экспериментальный
встроенный режим обхода блокировок.

[![CI](https://github.com/sunnydjam/dropo-by-sunnydjam/actions/workflows/ci.yml/badge.svg?branch=Dzhamuha-develop)](https://github.com/sunnydjam/dropo-by-sunnydjam/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> [!IMPORTANT]
> Это независимая доработка открытого проекта
> [Droponevedimka/dropo](https://github.com/Droponevedimka/dropo), а не его
> официальный релиз. Основа проекта и исходная MIT-лицензия сохранены. Подробно:
> [FORK_NOTICE.md](FORK_NOTICE.md).

> [!WARNING]
> Встроенный режим `Обход (Zapret)` пока экспериментальный. Рабочей базовой
> конфигурацией fork считаются выборочные VPN-маршруты и режим `Всё через VPN`.

[Лицензия](LICENSE) · [Конфиденциальность](PRIVACY.md) ·
[Безопасность](SECURITY.md) · [История изменений](CHANGELOG.md) ·
[Исходный проект](https://github.com/Droponevedimka/dropo)

## Статус проекта

| Возможность | Статус |
| --- | --- |
| Windows 10/11 x64 | Основная поддерживаемая платформа |
| Выборочные сервисы через VPN, остальное напрямую | Работает, основной режим |
| Режим `Всё через VPN` | Работает |
| YouTube, Discord, Instagram и ChatGPT на главной | Работает |
| Добавление других сервисов | Работает |
| Игры и невыбранные приложения напрямую | Работает; проверено без роста игрового пинга |
| Встроенный обход без VPN | Экспериментальный, требует дальнейшей доработки |
| Android | Унаследован от upstream, релиз fork пока не проверен |
| Windows prerelease fork | `v3.0.26-rc.1`, unsigned |
| Публичная Authenticode-подпись | Пока отсутствует |

Текущая ветка разработки: `Dzhamuha-develop`. Текущая версия исходников:
`3.0.26`.

## Как работает маршрутизация

На главной странице доступны два основных режима.

### Выборочные маршруты

Для каждого добавленного сервиса можно выбрать политику:

- `Напрямую` — сервис не использует VPN;
- `Через VPN` — только трафик этого сервиса уходит в выбранный VPN-источник;
- `Обход (Zapret)` — экспериментальная локальная стратегия без VPN.

По умолчанию доступны YouTube, Discord, Instagram и ChatGPT. Блок сервисов
сворачивается, а дополнительные сервисы добавляются отдельной кнопкой.

Главный контракт этого режима: **невыбранный и неуверенно распознанный трафик
проходит напрямую без изменения**. Не требуется добавлять каждую игру или сайт
в исключения.

### Всё через VPN

Весь обычный интернет-трафик направляется через активный VPN-источник. Этот
режим предназначен для ситуаций, когда выборочная маршрутизация не нужна.

### Приоритеты

```text
Рабочая сеть / WireGuard overlay
        ↓
Явная политика сервиса: Direct / VPN / экспериментальный обход
        ↓
Нераспознанный или невыбранный трафик: Direct
```

Рабочие сети и частные адреса имеют приоритет над публичным VPN. Явный выбор
пользователя не заменяется автоматической стратегией.

## Архитектура Windows

- Flutter отвечает за интерфейс;
- Go core управляет профилями, VPN-источниками и жизненным циклом соединения;
- sing-box TUN обеспечивает системную маршрутизацию и VPN outbounds;
- встроенный `app/trafficorchestrator` является единственным Dropo-владельцем
  WinDivert;
- полный неизменяемый `TrafficPlan` применяется атомарно;
- классификация использует домены, процесс, CIDR с обязательным контекстом,
  TCP/UDP-порты, TLS SNI и QUIC Initial;
- неизвестный трафик и ошибки классификации обрабатываются fail-safe: пакет
  проходит без изменения.

Dropo не запускает скачанные anti-DPI-скрипты, Lua/Cygwin runtime или внешние
командные стратегии в Windows traffic path. Внешние проекты обхода используются
только как исследовательские источники, перечисленные в
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Подробный контракт маршрутизации находится в
[ROUTING_CONTRACT.md](ROUTING_CONTRACT.md).

## VPN-источники

Поддерживаются подписки и отдельные конфигурации VLESS, VMess, Trojan,
Shadowsocks, Hysteria2, TUIC и WireGuard.

- одна подписка считается одним VPN-источником;
- пользователь может выбрать поддерживаемый узел внутри источника;
- fallback выполняется между независимыми источниками;
- порядок источников и выбранные политики сохраняются локально;
- секретные ссылки и ключи не записываются в обычные журналы.

## Discord и приложения

Discord классифицируется не только как сайт. Учитываются web/API, gateway,
STUN/discovery и динамические voice/video/Go Live endpoints. Успешное открытие
сайта не считается доказательством исправности голосового канала.

Маршрутизация рассчитана как на браузеры, так и на приложения. Невыбранные игры
и клиенты, включая Steam, должны сохранять прямой маршрут.

## Установка и выпуск

Первый Windows release candidate публикуется как
[`v3.0.26-rc.1`](https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v3.0.26-rc.1).
Не выдавайте сборки upstream за сборки этого fork и не скачивайте исполняемые
файлы из случайных источников.

Windows prerelease содержит:

- `dropo-Windows-Setup-x64.exe` — автономный установщик;
- `dropo-Windows-Portable-x64.zip` — portable-версию без установки.

До появления доверенной Authenticode-подписи тестовые Windows-артефакты будут
отмечаться как unsigned. Отключать Defender или добавлять исключения не нужно.
Политика описана в [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md).

## Сборка Windows

Требования:

- Go 1.25.13;
- Flutter 3.47.1 stable;
- Visual Studio Build Tools 2022 с Desktop development with C++;
- Windows 10/11 SDK;
- Inno Setup 7.1.0.

SDK принято хранить отдельно от репозитория. Общий каталог задаётся переменной:

```powershell
[Environment]::SetEnvironmentVariable(
    "DROPO_TOOLCHAIN_ROOT",
    "E:\Development\Toolchains\Dropo",
    "User"
)
```

Откройте новое окно PowerShell и выполните:

```powershell
git clone https://github.com/sunnydjam/dropo-by-sunnydjam.git
cd dropo-by-sunnydjam
git switch Dzhamuha-develop
flutter --version
go version
pwsh -File .\scripts\build\build.ps1 -AppOnly
```

Результат появится в `release/dropo-<version>-<commit>/`.

Проверка уже собранного Windows-релиза (подставьте созданный каталог):

```powershell
pwsh -File .\tools\preflight-release.ps1 `
    -ReleaseFolder .\release\dropo-<version>-<commit> `
    -SkipInstall `
    -SkipLifecycleSmoke
```

Запуск `preflight-release.ps1 -Build` проверяет полный набор платформ и поэтому
дополнительно требует Android SDK и настроенный Flutter Android toolchain.
Lifecycle smoke требует PowerShell с правами администратора.

## Диагностика

Логи Windows находятся в `%LOCALAPPDATA%\dropo\logs`.

Для подробной packet-диагностики можно временно задать
`DROPO_TRAFFIC_PACKET_DEBUG=1` или создать `traffic-debug.txt` рядом с launcher.
Публикуя отчёт, удалите VPN-ключи, subscription URL и персональные адреса.

## Конфиденциальность и безопасность

В приложении нет рекламы, телеметрии и автоматической отправки crash reports.
Профили, ключи, настройки и логи остаются на устройстве. Сетевые запросы
выполняются только для работы выбранных подключений, проверок доступности,
обновлений и явно вызванной диагностики. Подробнее:
[PRIVACY.md](PRIVACY.md).

Windows-пакет включает file-level runtime manifest, SPDX SBOM и provenance.
Версии основных runtime-компонентов и их SHA-256 закреплены в исходниках.

## План развития

- довести встроенный обход YouTube и Discord до стабильного состояния;
- проверять стратегию по полному набору web/TCP/UDP-целей до сохранения;
- улучшить диагностику приложений и Discord voice/video;
- подготовить подписанный публичный Windows-релиз fork;
- восстановить проверяемую Android release-сборку.

## Участие в разработке

Правила находятся в [CONTRIBUTING.md](CONTRIBUTING.md). Сообщения об уязвимостях
следует отправлять по инструкции из [SECURITY.md](SECURITY.md), а не публиковать
вместе с ключами или полными логами.

## Происхождение и лицензия

Репозиторий основан на
[Droponevedimka/dropo](https://github.com/Droponevedimka/dropo) и продолжает
использовать MIT License оригинального проекта. Изменения fork поддерживаются
пользователем [sunnydjam](https://github.com/sunnydjam).

Copyright © 2026 Droponevedimka and contributors. См. [LICENSE](LICENSE) и
[FORK_NOTICE.md](FORK_NOTICE.md).
