# Direct-first routing contract

Этот документ фиксирует обязательную логику маршрутизации dropo для Windows и
Android. В режиме «Всё через VPN» (сохранённое значение `all_traffic`) каталог заблокированных доменов, каталог заблокированных IP для соединений без имени и именованные сервисы, включая ИИ, направляются в VPN. Для остальных соединений и DNS маршрут по умолчанию прямой. Отказ разрешённых методов оставляет выбранный сервис без рабочего маршрута.

В режиме «По сервисам» пользователь выбирает метод для настраиваемых сервисов. Остальные домены из каталога блокировок используют VPN. Список сервисов, для которых VPN обязателен, доступен в настройках.
Начиная с 3.0.33 новая Windows-установка выбирает `all_traffic`; обновления,
legacy-миграция и восстановление старых настроек не меняют сохранённый режим.
Выбор полного режима до добавления источника — только настройка: без включённого
VPN-источника Start и builder по-прежнему запрещают запуск, старый конфиг
инвалидируется. Публичный источник требует явного согласия пользователя.

## Telegram в режиме «По сервисам»

В Windows для передачи Telegram через подписку в списке сервисов выбирают Telegram → VPN. При исходной настройке Direct и после миграции старого Auto сервис подключается напрямую. Telegram Desktop устанавливает MTProto-соединения с дата-центрами по IP. Выборочный фильтр охватывает TCP на назначенном дата-центром порту, включая 5222. Для соединения без имени проверяется процесс `Telegram.exe`. Частные назначения сохраняют приоритет. Загрузка сайта Telegram сама по себе не проверяет обмен сообщениями или звонок. [Транспорт MTProto](https://core.telegram.org/mtproto/transports)

На Android правило приложения охватывает Telegram из Google Play, APK с telegram.org и Telegram X, включая соединения без доменного имени. При доступной подписке Auto направляет Telegram через VPN. Direct сохраняет прямой маршрут. VPN охватывает опознанное приложение и выбранные домены. В режиме «Всё через VPN» VPN охватывает распознанные адреса и приложение. Настроенный пользователем прокси внутри Telegram и конкретные условия мобильной сети нужно учитывать при диагностике жалобы. [Клиенты Telegram](https://telegram.org/apps)

## Порядок решений

В режиме `blocked_only` правила применяются в следующем порядке:

1. Рабочие сети, private/LAN и WireGuard overlay.
2. Обязательный VPN для доменов и приложений ИИ и регионально ограниченных сервисов. Для остальных сервисов применяется выбранная пользователем политика.
3. Положительная идентификация выбранного сервиса: домен, приложение либо
   сервисный protocol/media fingerprint.
4. Любой другой известный HTTP Host, TLS SNI, QUIC server name или DNS reverse
   mapping получает terminal `direct`/packet `pass`.
5. IP разрешено использовать только по явно заданной политике:
   - `require_context` — CIDR подтверждает уже найденный домен, процесс или
     fingerprint;
   - `hostless_only` — допустим только для общего подписанного blocked-IP
     каталога и только без hostname; это ограничение типа правила, а не
     разрешение включать общий catch-all в явном Windows-профиле.
6. Неизвестный или неоднозначный трафик проходит без изменения.

IP и даже одиночный `/32` не являются идентификатором сервиса: CDN, anycast и
reverse proxy могут обслуживать несколько независимых доменов на одном адресе.
Добавление EA, Riot, Steam или другой незаблокированной программы в специальный
direct-список поэтому не является основным способом исправления.

### Игровые клиенты в Windows

В режиме «По сервисам» Steam, EA app, Epic Games Launcher, Battle.net и Riot
пользуются прямым маршрутом для своих обычных запросов. Совпадение адреса CDN
и порта с выбранным сервисом не меняет маршрут. TLS ClientHello, HTTP-запрос,
QUIC Initial и STUN сами по себе не идентифицируют сервис. Для такого признака
классификатору нужен совпадающий домен или, если имя неизвестно, процесс этого
сервиса. Если лаунчер обращается к синтетическому адресу выбранного сервиса,
новый сокет следует текущей политике сервиса. При смене политики уже открытые
сокеты сохраняют исходный маршрут.

Встроенная диагностика проверяет магазин Steam и публичные службы авторизации
EA, Epic, Battle.net и Riot. Для четырёх служб авторизации успех требует
HTTP 200 и JSON с ожидаемым полем `issuer`. Эта проверка доступна без аккаунта.
Проверки владельца сокета, внешнего IP и сохранения соединений при смене
политики выполняются отдельно в тестовой Windows VM.

## Реализация по платформам

### Windows selected-services runtime

- В режиме «По сервисам» Windows сохраняет системный маршрут по умолчанию и DNS физической сети. PAC и синтетический DNS направляют заблокированные домены и именованные VPN-сервисы в локальный прокси. TUN получает только узкие префиксы подписанного `refilter-ips`; внутри него известное обычное имя отправляется напрямую перед проверкой IP. Частные адреса и рабочие сети сохраняют приоритет.
- `all_traffic` and Hide-RU retain the sing-box TUN path. They must not use the
  selective fake-IP/relay path as a substitute for full route coverage.
- Windows issues synthetic IPv4 addresses in `198.18.0.0/15` for selected
  VPN names and exact bootstrap names on the Zapret route. The PAC preserves
  exact names, suffixes and work-network exceptions. A launcher with a Direct
  process rule still uses the terminal relay for an already-issued address.
  Ordinary lookups use the network resolver. At mapping capacity, selected
  queries receive SERVFAIL. Idle aliases can be evicted and never reassigned
  within a session. The relay finishes established flows on their original
  exit. A cached alias whose service became Direct is dialled by name using
  the system resolver. An expired alias requires a fresh DNS lookup.
- STUN alone identifies NAT traversal. Routing it as Discord requires service
  context. A game and a voice client can share a destination IP. UDP reflection
  assigns distinct peer ports when different sessions share a client port.
- Dropo-owned runtime processes bypass fake DNS and classification of ordinary egress.
  This prevents sing-box DNS and VPN egress from recursively entering the
  relay after the original client flow has already reached its terminal path.
- Selected TCP and UDP/QUIC flows are reflected into bounded in-process relays,
  then forwarded through the loopback SOCKS5 inbound. Relay responses are
  restored to the original tuple by the same single WinDivert owner.
  The Windows firewall rules apply only to the running core executable, the
  relay's chosen port and the two reflection peers (198.18.0.1 and
  2001:db8:d20::1). Windows enforces its existing firewall policies. Stop
  removes both rules. The next selective start replaces stale session rules.
- Browser/Electron routing is decided by the requested host in the PAC file,
  before origin address selection. A selected host therefore keeps its VPN
  route when Chromium Secure DNS is enabled; HTTP/3 is not permitted to escape
  a PAC-selected HTTP proxy and falls back to the proxied TCP path.
- Exact bootstrap hosts used by selected native Discord and ChatGPT components
  receive session-local fake addresses through the reversible hosts overlay.
  Discord's authenticated raw-IP media endpoints are separately covered by
  bounded process-identity UDP discovery ranges and the SOCKS5 UDP relay.
- Unselected DoH, DoT and DoQ traffic remains byte-for-byte direct. Dropo does
  not globally block public resolvers or capture every port-443 connection,
  because doing so would put Steam, games and unrelated applications back into
  the user-mode packet path. Arbitrary non-PAC applications that combine custom
  encrypted DNS with unknown raw-IP endpoints are not claimed as classified.
- Steam, Mistfall Hunter and other unselected traffic are terminal direct.
  Packets that happen to share a service CIDR or carry a captured TLS/QUIC
  fingerprint must be reinjected byte-for-byte unchanged after direct/process
  precedence; opaque traffic outside the narrow filter never enters user mode.

- Windows sing-box: доменные и процессные правила сервиса идут раньше общей
  known-domain direct boundary. Сервисный `ip_cidr` допустим только совместно с
  `process_name`. Общий каталог IP применяется только после проверки известного домена.
- Windows Traffic Orchestrator: `ServiceRule.IPMatchPolicy` обязателен при
  наличии `IPCIDRs`. Сетевой WinDivert layer сам не предоставляет PID;
  in-process resolver сопоставляет локальный TCP/UDP endpoint с bounded
  Windows owner tables и получает только basename процесса. Недоступный или
  неоднозначный владелец остаётся unknown/direct. Решения потока привязаны к
  ревизии immutable `TrafficPlan`; один IP без process/domain/media context
  по-прежнему не является идентификатором сервиса.
- Android: домен и `package_name` определяют VPN-политику. Независимые
  service-IP правила в VPN не генерируются; после сервисных правил установлена
  known-domain direct boundary, а `route.final` в `blocked_only` равен `direct`.

В обоих режимах ChatGPT, Claude, остальные ИИ из каталога и SaaS с обязательным VPN используют только VPN. Сохранённые Direct, Auto и Zapret для этих сервисов заменяются при обновлении. После отказа последнего доступного VPN-источника соединение с таким сервисом завершается ошибкой. Следующая попытка также требует VPN.

В режиме «Всё через VPN» выбор стратегии для остальных именованных сервисов временно перекрывает политика каталога. При возврате в режим «По сервисам» клиент снова применяет сохранённый выбор. В обоих режимах `route.final=direct` обслуживает обычный трафик.

## DNS в Windows и Android

| Назначение | Как разрешается имя |
|---|---|
| Обычный сайт или сервис с явным Direct | Системный DNS текущей сети. На Android запрос привязан к физической сети под VPN, включая настройки частного DNS этой сети. |
| Выбранный VPN-сервис, а в Windows также имя выбранной стратегии | Защищённый резолвер Dropo. В Windows для нативного клиента первым ответом может быть локальный синтетический адрес. |
| «Всё через VPN» | Запросы для каталога идут через VPN к защищённому DNS. Остальные используют DNS текущей сети. |
| Рабочие и локальные зоны | Соответствующий корпоративный или системный резолвер имеет приоритет. |
| Запуск самого транспорта | Служебное разрешение адресов VPN и инфраструктуры может использовать отдельный защищённый bootstrap до установления туннеля. |

При сборке общего каталога исключаются общие имена Cloudflare ECH,
Pages и Workers. Записи отдельных сайтов на этих платформах сохраняются.
Совпадение с доменным каталогом направляет запрос в VPN после правил конкретных сервисов.
Собственный DNS-over-HTTPS игры или браузера может оставаться непрозрачным.
Выбор политики по общему IP CDN или внешнему имени ECH не применяется.
Для выбранных синтетических имён AAAA, HTTPS и SVCB получают пустой ответ,
чтобы клиент использовал выданный IPv4. Клиенту для этого пути необходим IPv4.

## Переключение при активном VPN

- **Главная** и **Настройки → Маршрутизация** переключают «По сервисам» и
  «Всё через VPN». Экран **Сервисы** принимает изменения политики отдельно
  для каждого сервиса. Эти действия доступны во время подключения.
- В режиме «Всё через VPN» изменение политики сервиса сохраняется для режима
  «По сервисам». Для сервисов с обязательным VPN выбор метода заблокирован в обоих режимах.
- На Android VpnService на своём рабочем потоке проверяет и заменяет правила
  sing-box и DNS. Используются уже подготовленные узлы Dropo Free, Turbo или
  личной подписки. Текущий физический узел, включая резервный, остаётся
  выбранным, пока он доступен. VpnService, разрешение Android и счётчик времени
  сессии сохраняются. При перезагрузке ядра открытые соединения могут прерваться.
- В Windows изменение одного сервиса обновляет план и системные правила имён
  внутри выборочного сеанса, если открытый фильтр уже покрывает новый маршрут.
  Работающие соединения продолжают обмен через прежний выход. Переход между
  выборочным и полным режимами либо добавление области захвата требует
  переподключения. В полном режиме настройки отдельных сервисов сохраняются
  до следующего включения выборочного режима.
- Если применение или запись нового выбора не удались, Dropo восстанавливает
  прежнюю политику и сообщает об ошибке. Отмена подключения имеет приоритет
  над подготовкой и восстановлением. Индикация успеха следует за применением.

## Политика сервиса в настройках

На Windows доступны три явные политики:

1. `Напрямую` — terminal direct/pass без автоматического подбора.
2. `Через VPN` — выбранный VPN-источник без подбора Zapret. Отсутствие
   рабочего VPN не должно незаметно превращать явный VPN-маршрут в прямой.
3. `Обход (Zapret)` — встроенный обход только выбранного поддерживаемого
   сервиса, без VPN fallback для этой явной политики.

Windows API принимает старое `auto` только для совместимости и нормализует его
в `direct`. UI не предлагает его как самостоятельный маршрут. Режим `Авто`
в настройке **стратегии Zapret** — другая настройка: он не меняет выбранную
политику сервиса. Работа сайта не доказывает работу Discord voice/video.

Фоновый подбор привязан к сессии, отменяется при отключении и не блокирует
готовность подключения. Кандидат сохраняется только после всех обязательных
web/TCP/UDP проверок; частичный успех не считается рабочей стратегией.
Кэш пригоден для bootstrap лишь в соответствующей сети. Продолжительность
поиска, текущая попытка и результат показываются пользователю. Внутренние
legacy-автоматические политики не являются дополнительным выбором Windows UI.

На Android доступны `Авто`, `Напрямую` и `Через VPN`. Windows-only Zapret
не предлагается как доступный маршрут. Android `Авто` выбирает VPN при наличии
подписки и direct при её отсутствии; его нельзя заменять Windows-нормализацией.

Изменение интерфейса или навигации не записывает политики. Режим «Всё через VPN»
временно перекрывает, но не удаляет индивидуальные настройки сервисов.

## Однозначная эмуляция общей IP-площадки

Основной тест создаёт настоящие IPv4/TCP пакеты с TLS ClientHello и отправляет
их через `trafficorchestrator.Processor`. Оба пакета имеют один destination
`66.22.200.1`, но разные SNI:

- `gateway.discord.com` — должен быть классифицирован как Discord и изменён
  выбранной тестовой стратегией;
- `accounts.ea.com` — не должен получить ServiceID, должен вернуться одним
  побайтно неизменённым пакетом.

Запуск:

```powershell
cd app
go test ./trafficorchestrator -run TestProcessorSharedAddressEmulationKeepsUnblockedTLSDirect -count=1 -v
go test . -run TestNamedServiceCIDRsNeverBecomeStandaloneSingBoxRoutes -count=1 -v
cd mobile\dropocore
go test . -run TestAndroidBlockedOnlyRoutesOnlyBlockedServicesThroughVPN -count=1 -v
```

Дополнительные unit-тесты проверяют, что hostless UDP на сервисном CIDR без
fingerprint проходит неизменённым, подтверждённый Discord media packet
классифицируется, а generic blocked-IP не может переопределить известный домен.

Перед релизом обязательны полный `go test ./...` для desktop/mobile модулей,
Flutter analyze/tests и `tools/preflight-release.ps1 -Build`.
