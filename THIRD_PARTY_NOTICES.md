# Third-party notices and research references

Этот файл разделяет компоненты, которые поставляются с dropo, и проекты,
использованные только для изучения общих сетевых техник. Наличие ссылки в
исследовательском разделе не означает включение исходников или runtime проекта.

## Компоненты Windows release

Интерфейс Atlas использует 21 локальный SVG-знак из
[Simple Icons 14.0.0](https://github.com/simple-icons/simple-icons/tree/14.0.0)
и отдельные функциональные пиктограммы для восьми сервисов или групп.
Текст лицензии коллекции CC0-1.0 поставляется в Flutter assets как
`Simple-Icons-LICENSE.txt`; он не отменяет отдельные условия логотипов и товарных
знаков. Источники, условия использования и причины замены отдельных логотипов
описаны в [SERVICE_ICONS_NOTICE.md](flutter_app/assets/SERVICE_ICONS_NOTICE.md).
Товарные знаки принадлежат своим владельцам; их использование обозначает сервисы,
а не партнёрство или одобрение Dropo.
Рендерер [flutter_svg](https://pub.dev/packages/flutter_svg) — MIT;
лицензии Dart/Flutter-зависимостей входят в стандартный Flutter license bundle.

Ночная планета использует оригинальное декоративное изображение сайта Dropo
`flutter_app/assets/maps/earth_night_globe.webp`, включённое в приложение.
Три позы оригинального персонажа DrOppo находятся в `flutter_app/assets/mascot/`.
Происхождение изображений и исходные brief сохранены в
`store-assets/source/earth-night-globe.provenance.json` и
`store-assets/source/DROPPO_SCENE_ASSETS.json`.
Это художественные изображения, не спутниковые наблюдения и не карта серверов.
Предыдущий атлас `flutter_app/assets/maps/earth_night_atlas.png` сохранён
в репозитории, но больше не включается в Flutter asset bundle.

Предыдущая поверхность использовала Natural Earth 1:110m land; исходные данные
сохранены в репозитории (`flutter_app/assets/maps/ne_110m_land.geojson`),
но больше не включаются в Flutter asset bundle.
Made with Natural Earth. Данные находятся в public domain согласно
[условиям Natural Earth](https://www.naturalearthdata.com/about/terms-of-use/).
Это декоративная географическая карта, не карта серверов или реальных замеров.

| Компонент | Назначение | Лицензия / источник |
| --- | --- | --- |
| WinDivert 2.2.2 | Перехват и reinjection пакетов в собственном Windows engine | [Официальный сайт и документация](https://reqrypt.org/windivert.html), LGPL-3.0-only / GPL-2.0-only; текст лицензии включается в `licenses/WinDivert-LICENSE.txt` |
| sing-box | TUN, VPN-протоколы и маршрутизация | [SagerNet/sing-box](https://github.com/SagerNet/sing-box); текст лицензии включается в release |
| WireGuard for Windows / Wintun | Рабочие и пользовательские WireGuard-туннели | [WireGuard/wireguard-windows](https://github.com/WireGuard/wireguard-windows); текст лицензии включается в release |
| Xray-core | Поддержка отдельных VLESS transport-вариантов | [XTLS/Xray-core](https://github.com/XTLS/Xray-core); текст лицензии включается в release |
| Flowseal zapret-discord-youtube 1.10.2 protocol payloads | Восемь неизменяемых fake TLS/QUIC/STUN/Discord payload встроены как данные в подписанное ядро | MIT; copyright и полный текст разрешения сохранены ниже. `winws`, Cygwin, Lua, драйвер и код Flowseal не включаются |
| metacubex/uTLS 1.8.4 | Chromium-compatible TLS ClientHello только для проверки выбранной Discord-стратегии через сервисно-ограниченный CONNECT relay | BSD-3-Clause; текст лицензии включается в `licenses/metacubex-utls-LICENSE.txt` |
| Flutter | Пользовательский интерфейс | [flutter/flutter](https://github.com/flutter/flutter), BSD-3-Clause |
| Re-filter lists | Вложенный каталог заблокированных доменов и IP-сетей, а также локально скомпилированные sing-box rule-set | [1andrevich/Re-filter-lists](https://github.com/1andrevich/Re-filter-lists), MIT; точный release и SHA-256 записываются в `bin/filters/version.json`, лицензия включается в `licenses/Re-filter-lists-LICENSE.txt` |

Точные версии и хеши закреплены в `version.json`, file-level
`runtime-manifest.json` и `dropo-sbom.spdx.json`, создаваемых сборкой.
Windows-ядра собираются из закреплённых исходников с обновлёнными зависимостями:
рецепт, контрольные суммы и параметры находятся в `tools/runtime-source/`.
Архив `dropo-Runtime-Sources.zip` сопровождает Windows-пакеты и содержит
исходники всех модулей, вошедших в эти ядра, с исходными лицензиями.

## Компоненты Android

Android использует встроенный gomobile bridge: sing-box отвечает за TUN и
маршрутизацию, а Xray-core 26.10.31 обеспечивает VLESS XHTTP через локальный
bridge внутри процесса приложения. Windows-исполняемые файлы, shell runtime,
загрузка исполняемых зависимостей при первом запуске и базы geoip/geosite Xray
для этого пути не используются.

Закреплённый Go module — `github.com/xtls/xray-core v1.260327.1-0.20261031132019-a4a3dff5b20c`, исходная
ревизия — `a4a3dff5b20c2faae567b742c172c7b95e75c083`.
Полный неизменённый текст MPL-2.0 и notice с точной версией и ссылками на
соответствующий исходный код входят в APK как Flutter assets:
`assets/licenses/Xray-core-LICENSE.txt` и `assets/licenses/Xray-core-NOTICE.txt`.
Исходники доступны в [репозитории Xray-core на закреплённой ревизии](https://github.com/XTLS/Xray-core/tree/a4a3dff5b20c2faae567b742c172c7b95e75c083)
и в [архиве соответствующих исходников](https://github.com/XTLS/Xray-core/archive/a4a3dff5b20c2faae567b742c172c7b95e75c083.tar.gz).
Для строгого завершения VPN-сессии Dropo применяет узкий MPL-2.0 lifecycle patch:
изолированные HTTP-пулы и отмена XHTTP-запросов вместо общего upstream cache.
Полные соответствующие изменённые исходники `client.go.txt`, `dialer.go.txt`,
`managed_session.go.txt` и `managed_session_test.go.txt` включены в APK в
`assets/licenses/xray-core-source/`; остальные исходники доступны на закреплённой
upstream-ревизии выше. Патч компилируется через проверенный Go overlay, без
изменения module cache. SHA-256 исходных и заменяющих файлов записаны в
`app/mobile/dropoandroid/xray_overlay/manifest.json` и проверяются до сборки.
Изменённые покрытые файлы сохраняют MPL notice и распространяются по MPL-2.0.
Отдельный integration code хранится в `app/mobile/dropoandroid` и
`app/mobile/dropocore`. При дальнейших изменениях необходимо сохранить
уведомления и предоставить соответствующие изменённые исходники по MPL-2.0.

## Внешние источники конфигураций (по выбору пользователя)

[kort0881/vpn-checker-backend](https://github.com/kort0881/vpn-checker-backend)
предоставляет публичный список VPN-конфигураций. Репозиторий upstream указывает
MPL-2.0. Dropo не включает его исходный код, исполняемые файлы или снимок списка:
после согласия пользователя загружаются только данные HTTPS-подписки.
Серверы принадлежат третьим лицам; их безопасность и работоспособность Dropo не
гарантирует. Порядок использования описан в [PUBLIC_VPN_SOURCES.md](PUBLIC_VPN_SOURCES.md).

## Исследовательские источники

| Проект | Что изучается | Статус в release |
| --- | --- | --- |
| [bol-van/zapret2](https://github.com/bol-van/zapret2) | Узкая kernel-side фильтрация, классификация STUN/Discord/WireGuard, порядок и ограничения desync-техник | Процесс, Lua, Cygwin, бинарники и исходники не поставляются. Собственная реализация написана на Go с типизированными bounded actions. Upstream MIT license учитывается при любом будущем переносе существенного кода. |
| [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) | Все 22 профиля `general*.bat` релиза 1.10.2 для YouTube/Google и Discord media/voice, активные Discord/STUN decoy-пакеты и актуальные hostlist-наборы | Встроены восемь MIT-лицензированных protocol payload. `winws`, Cygwin, Lua, драйвер, hostlist и исходный runtime не поставляются и не вызываются; профили исполняются собственной сервисно-ограниченной типизированной реализацией. Глобальные IP/game rules намеренно исключены; ALT5 использует только data-phase `multidisorder`, потому что на SYN браузера ещё нет безопасного доказательства сервиса. |
| [bol-van/zapret](https://github.com/bol-van/zapret) | Исторические описания split/overlap/fake-подходов и blockcheck | Не поставляется и не вызывается |
| [hufrea/byedpi](https://github.com/hufrea/byedpi) | Сравнение proxy-based обхода с прозрачным packet engine | Не входит в Windows release |

Последние исследованные ревизии на 2026-08-09:

- zapret2: `032651deeb2117a32c67fdf5cec115d5e52a63dd`;
- Flowseal zapret-discord-youtube 1.10.2: `dfd8e613b099676cf2aa7b474ee5923801514dec` (все 22 профиля перенесены в сервисно-ограниченный типизированный каталог; универсальные/game filters намеренно не перенесены, потому что Dropo применяет Zapret только к выбранным сервисам; ALT5 ограничен безопасной data phase).

## Flowseal / bol-van MIT notice

MIT License

Copyright (c) 2016-2026 bol-van
Copyright (c) 2024-2026 Flowseal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Обновление upstream само по себе не обновляет dropo: сначала выполняются
license/security review, перевод идеи в типизированную модель, unit/fixture/
Windows VM тесты и release audit.

## Google Play In-App Review

The Android client includes `com.google.android.play:review:2.0.2` from Google's
Maven repository. It is governed by the
[Play Core Software Development Kit Terms of Service](https://developer.android.com/guide/playcore/license).
Production creates `ReviewManagerFactory`; `FakeReviewManager` is used only by
isolated test instrumentation and is never selected by application settings.
