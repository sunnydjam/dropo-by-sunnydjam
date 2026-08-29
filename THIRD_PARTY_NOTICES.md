# Third-party notices and research references

Этот файл разделяет компоненты, которые поставляются с dropo, и проекты,
использованные только для изучения общих сетевых техник. Наличие ссылки в
исследовательском разделе не означает включение исходников или runtime проекта.

## Компоненты Windows release

| Компонент | Назначение | Лицензия / источник |
| --- | --- | --- |
| WinDivert 2.2.2 | Перехват и reinjection пакетов в собственном Windows engine | [Официальный сайт и документация](https://reqrypt.org/windivert.html), LGPL-3.0-only / GPL-2.0-only; текст лицензии включается в `licenses/WinDivert-LICENSE.txt` |
| sing-box | TUN, VPN-протоколы и маршрутизация | [SagerNet/sing-box](https://github.com/SagerNet/sing-box); текст лицензии включается в release |
| WireGuard for Windows / Wintun | Рабочие и пользовательские WireGuard-туннели | [WireGuard/wireguard-windows](https://github.com/WireGuard/wireguard-windows); текст лицензии включается в release |
| Xray-core | Поддержка отдельных VLESS transport-вариантов | [XTLS/Xray-core](https://github.com/XTLS/Xray-core); текст лицензии включается в release |
| tg-ws-proxy | Локальный MTProto-over-WebSocket transport для Telegram | Локально закреплённая версия 1.7.3, MIT; текст лицензии включается в `licenses/tg-ws-proxy-LICENSE.txt` |
| Flowseal zapret-discord-youtube 1.10.2 protocol payloads | Четыре неизменяемых fake TLS/QUIC/STUN/Discord payload встроены как данные в подписанное ядро | MIT; copyright и полный текст разрешения сохранены ниже. `winws`, Cygwin, Lua, драйвер и код Flowseal не включаются |
| Flutter | Пользовательский интерфейс | [flutter/flutter](https://github.com/flutter/flutter), BSD-3-Clause |
| Re-filter lists | Вложенный каталог заблокированных доменов и IP-сетей, а также локально скомпилированные sing-box rule-set | [1andrevich/Re-filter-lists](https://github.com/1andrevich/Re-filter-lists), MIT; точный release и SHA-256 записываются в `bin/filters/version.json`, лицензия включается в `licenses/Re-filter-lists-LICENSE.txt` |

Точные версии и хеши закреплены в `version.json`, file-level
`runtime-manifest.json` и `dropo-sbom.spdx.json`, создаваемых сборкой.

## Исследовательские источники

| Проект | Что изучается | Статус в release |
| --- | --- | --- |
| [bol-van/zapret2](https://github.com/bol-van/zapret2) | Узкая kernel-side фильтрация, классификация STUN/Discord/WireGuard, порядок и ограничения desync-техник | Процесс, Lua, Cygwin, бинарники и исходники не поставляются. Собственная реализация написана на Go с типизированными bounded actions. Upstream MIT license учитывается при любом будущем переносе существенного кода. |
| [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) | Все 22 профиля `general*.bat` релиза 1.10.2 для YouTube/Google и Discord media/voice, активные Discord/STUN decoy-пакеты и актуальные hostlist-наборы | Встроены только четыре MIT-лицензированных protocol payload для точной стратегии General ALT. `winws`, Cygwin, Lua, драйвер, hostlist и исходный runtime не поставляются и не вызываются; профили исполняются собственной типизированной реализацией. |
| [bol-van/zapret](https://github.com/bol-van/zapret) | Исторические описания split/overlap/fake-подходов и blockcheck | Не поставляется и не вызывается |
| [hufrea/byedpi](https://github.com/hufrea/byedpi) | Сравнение proxy-based обхода с прозрачным packet engine | Не входит в Windows release |

Последние исследованные ревизии на 2026-08-09:

- zapret2: `032651deeb2117a32c67fdf5cec115d5e52a63dd`;
- Flowseal zapret-discord-youtube 1.10.2: `dfd8e613b099676cf2aa7b474ee5923801514dec` (General ALT перенесена и проверена как типизированный сервисный профиль; универсальные/game filters намеренно не перенесены, потому что Dropo применяет Zapret только к выбранным сервисам).

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
