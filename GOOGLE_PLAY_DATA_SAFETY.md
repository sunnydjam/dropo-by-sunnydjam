# Google Play Data safety — Dropo 3.0.54

Подготовлено 31 октября 2026 года для Android Play, package `com.dropo.myapp`.
Это ответы по проверенному коду и известным получателям данных, а не подтверждение
одобрения Google. Документ не содержит ключей, паролей проверки или ссылок личных
подписок. Перед отправкой сверить пункт «Что подтверждает владелец» ниже и все
активные версии этого package в Play Console. Windows и отдельный APK имеют другую
модель обновлений и не определяют ответы для Play автоматически.

Политика: <https://dropo.fun/privacy>. Удаление: <https://dropo.fun/account/delete>.
Контакт: `dr.oponevedimka@gmail.com`; разработчик: Indzhiev Ayush.

## Готовая основа верхнего уровня

| Поле / смысл вопроса | Ответ для этой версии |
| --- | --- |
| Does your app collect or share any of the required user data types? | **Yes**. Автоматический гостевой профиль уже означает сбор данных. |
| Is all of the user data collected by your app encrypted in transit? | **Yes** для проверенной Play-конфигурации и каналов приложения, с границами, описанными ниже. |
| Account creation | **Yes**. Гостевой профиль создаётся автоматически, Telegram-регистрация необязательна. |
| Account deletion URL | **https://dropo.fun/account/delete** |
| Deletion of account and associated data | **Yes**: внутри приложения и через указанный сайт, после подтверждения владения. |
| Deletion of some or all data without deleting the account | **No** для текущего самостоятельного интерфейса. Выключение диагностики останавливает отправку и удаляет локальную очередь, но само по себе не удаляет уже принятые сервером события. Не путать с удалением аккаунта. |
| Independent security review | **No**, если владелец отдельно не получил действующее подтверждение признанной Google лаборатории. Наши тесты такой проверкой не являются. |
| Families / UPI badges | Не заявлять без соответствующей программы/подтверждения. Покупки и Boost в этой версии отключены. |

В вопросе **о способах создания**, а не входа, использовать **Other** и пояснить
автоматический гостевой профиль и Telegram bot confirmation. Это не OAuth.
Если форма отдельно спрашивает доступные способы **authentication/sign-in**, также
указать **Username and password** для заранее подготовленных демонстрационных
аккаунтов. Самостоятельной публичной регистрации по паролю сейчас нет.

English explanation:

> Dropo creates a guest profile using a random installation credential. Users may
> optionally link a profile by confirming sign-in in the Telegram bot. Pre-provisioned
> demonstration accounts support username/password sign-in for review without
> Telegram; there is no public password sign-up flow.

## Матрица данных

Названия категорий ниже соответствуют английской форме. **Collected** учитывает
отправку с устройства также внешнему получателю, а не только нашей базе.
**Not ephemeral** здесь означает, что нельзя утвердительно заявить исключительно
краткую обработку текущего запроса. Это не означает бессрочное хранение.
Где один тип используется несколькими путями, ответ объединяет все эти пути.

| Category → Data type | Collected | Shared | Ephemeral | Required / Optional | Purposes и основание |
| --- | --- | --- | --- | --- | --- |
| Personal info → Name | Yes | No¹ | No | Optional | **Account management, App functionality**. Telegram display name/имя/username при добровольном подтверждении входа; имя демонстрационного профиля. |
| Personal info → User IDs | Yes | No¹ | No | Required | **Account management, App functionality, Analytics, Fraud prevention, security, and compliance**. Случайный account ID, session identifiers; по желанию Telegram user/chat ID, username либо логин демонстрационного аккаунта. Required из-за автоматического гостя, хотя Telegram необязателен. Аналитика — подсчёт активных профилей, не реклама. |
| Personal info → Other info | Yes | No¹ | No | Optional | **Account management, App functionality, Fraud prevention, security, and compliance**. Консервативная классификация введённого пароля/проверочного значения демонстрационного входа и персональных реквизитов подписки при их добровольном использовании. Пароль передаётся для проверки; на бэке хранится солёный производный verifier. Это интерпретация общего поля, отдельного поля Passwords в текущем перечне Google нет. |
| Device or other IDs → Device or other IDs | Yes | Yes² | No | Required | **App functionality, Account management, Analytics, Fraud prevention, security, and compliance**. Случайный installation ID/credential и его серверный хеш; IP-метаданные соединений у получателей, сетевой префикс у защиты API. Внешним DNS/VPN-получателям раскрывается сетевой IP, а не наш installation secret/account token. MAC/IMEI/advertising ID не используются. |
| App activity → App interactions | Yes | No¹ | No | Required | **App functionality, Account management, Analytics, Fraud prevention, security, and compliance**. Время создания/последнего обращения, события входа и управления сессиями. При отдельном согласии дополнительно технические результаты подключения/проверок. Нет общего трекера кликов/экранов. |
| App info and performance → Diagnostics | Yes | No¹ | No | Optional | **Analytics, App functionality**. Отдельно включаемые ограниченные отчёты: результат/категория проверки, сервис из списка, режим, версия/платформа, диапазон длительности. Для помощи можно вручную скопировать техническую сводку. Полные журналы автоматически не загружаются. |
| Web browsing → Web browsing history | Yes | Yes² | No | Required | **App functionality, Analytics, Fraud prevention, security, and compliance**. Консервативно учитываются домены DNS-запросов, передаваемые выбранному DNS, и видимые VPN-оператору адреса/домены соединений. Это не утверждение, что сервер аккаунтов хранит посещённые страницы. Для Google DNS известны эксплуатационные/защитные цели и статистика; дополнительные цели VPN-оператора требуют подтверждения. |
| Location → Approximate location | Yes | Yes² | No | Required | **App functionality, Analytics, Fraud prevention, security, and compliance**. Производная география публичного IP у Google Public DNS: его опубликованная политика описывает country/region/city в статистике DNS. Сам Android-клиент не запрашивает GPS и не вызывает Windows-проверку IPinfo. В режиме с туннелем внешний сервис может видеть расположение выхода VPN; прямой DNS-путь также существует. |

¹ **No в Shared не означает отсутствие внешних обращений.** Вход через Telegram,
загрузка указанной пользователем подписки и отправка выбранному пользователем
адресату подготовленной сводки — конкретные действия пользователя с ожидаемым
получателем. Для них применимо исключение user-initiated sharing; это не отменяет
Collected. Случайный secret и данные аккаунта не отправляются рекламным SDK.
Нельзя автоматически назвать любого внешнего получателя нашим service provider:
нужна реальная обработка по поручению и инструкциям разработчика.

² **Shared = Yes — консервативный вариант для самостоятельно выбранного приложением
публичного DNS и его собственной обработки.** Мы не располагаем договором,
превращающим Google Public DNS/каждого VPN-оператора в обработчика только по нашим
инструкциям. Применимость исключения prominent disclosure/consent ко всем целям
всех получателей не предполагается. Поэтому не ставить общий «No data shared».
Значения не утверждают передачу всех данных этой категории каждому получателю.

Google Public DNS прямо описывает временные записи IP + DNS query на 24–48 часов
(возможны более длительные меры при злоупотреблениях), а также статистические
записи с производной географией. Поэтому **Yes, processed ephemerally** для этого
пути не обосновано. [Политика Google Public DNS](https://developers.google.com/speed/public-dns/privacy).

Для набора наших гостевых/сессионных данных также не выбирать ephemeral: они
сохраняются в базе. Сетевой префикс `/24` или `/64` в limiter находится в памяти
между запросами; отсутствие дискового IP-журнала не делает такую обработку
исключительно обработкой одного запроса. Диагностика хранится до 30 дней.

## Что не нужно автоматически отмечать

- **Installed apps**: finite-list проверки Dropo Space и определение владельца
  соединения для маршрутизации происходят локально; список приложений не входит
  в payload гостя или инцидента. Android package visibility/наличие разрешения
  сами по себе не доказывают отправку списка.
- **Precise location**, contacts, calendar, SMS, microphone, photos/videos,
  financial/payment data: таких сборщиков/форм/SDK в проверенном Android-пути нет.
  IP-derived approximate location уже отдельно учтена выше.
- **Email address**, **Phone number**: текущая Android-регистрация не запрашивает
  их. Контакт разработчика — не пользовательские данные. Совместимые старые поля
  `phone_hash/phone_last4` в бэке не означают новый сбор телефонов этой версией.
  Если старая активная Play-версия ещё собирает телефон, глобальную форму надо
  дополнить по этой версии.
- **Crash logs**, **Other app performance data**: автоматического crash SDK нет,
  схема инцидента не содержит stack trace/raw error; описанные события покрыты
  Diagnostics. Локальный журнал — не автоматический upload. Если поддержка начнёт
  принимать журналы через встроенную форму/сервер, пересмотреть фактический состав,
  сроки и типы до её выпуска.
- Telegram используется для подтверждения аккаунта, не для чтения личных чатов.
  Не заявлять сбор всех сообщений только потому, что сетевой трафик идёт через VPN.
- HTTPS/E2E payload другого приложения, который не может прочитать Dropo или
  посредник, не превращается в сбор текста/фото/паролей Dropo. При этом VPN не
  скрывает от оператора все сетевые метаданные. Незащищённый исходным приложением
  контент может быть виден оператору; нельзя обещать его отсутствие или no-logs
  без сведений оператора. Пользовательское перенаправление данных и E2E-исключение
  следует оценивать отдельно от серверной аналитики Dropo.

Основание классификации — [Google Data safety](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
и [Android data-use guidance](https://developer.android.com/privacy-and-security/declare-data-use).
Маркетинговое название Connect Booster не меняет фактическое использование VPN.

## Шифрование: почему выбран Yes и что именно проверено

В этой Android-реализации нет необходимости разрешать HTTP для подписок:
`validateSubscriptionURL` требует HTTPS и проверяет каждый redirect. Account API
допускает production HTTPS, запрещает перенаправление запросов с credential и
использует обычную проверку сертификата. HTTP loopback допускается только для
локальной debug-разработки; нативный Android bridge не отправляет credential на
Windows localhost API.

Оба явных DNS outbounds — DoH; health probes — HTTPS. Google Play native policy
проверяет реальный runtime graph перед запуском, включая кешированные конфигурации
и независимые источники, запрещает небезопасный TLS и незашифрованные VPN outbounds.
Проверка действует также при самостоятельном перезапуске VpnService.

Это подтверждает защищённую передачу данных приложения и участок устройство →
VPN endpoint. Это **не** обещание сквозного шифрования после VPN endpoint, защиты
пользовательского HTTP-сайта, всех локальных/system DNS операций или трафика,
исключённого из туннеля. Режим «По сервисам» оставляет другой трафик прямым.
Данные, которые пользователь поручает передать иному сервису, нужно отличать от
собственного сбора приложения; Google отдельно описывает этот случай в разделе
Encryption in transit своей [инструкции Data safety](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).

Не переносить на Play без проверки заявления о произвольных конфигурациях Windows
или GitHub APK. После добавления нового SDK/endpoint либо HTTP-import это решение
потребует повторной проверки. Нельзя обосновывать Yes тем, что «всё всегда идёт
через VPN»: до подключения и при split routing это неверно.

## Удаление: поля и текст для партнёра

Ссылка для формы, без секрета или параметров:

`https://dropo.fun/account/delete`

English copy for account-deletion instructions:

> Dropo provides account deletion in the app and at https://dropo.fun/account/delete.
> Guest users can create and save a deletion-only code in Account → Deletion on the
> website before uninstalling the app. Enter the saved code in the website's guest
> form, confirm deletion and submit. The code cannot sign in or access account data.
> Telegram users confirm deletion using the same Telegram account. Demonstration
> username/password accounts use the password form. The website works without the
> app installed. If you no longer have the required proof, contact
> dr.oponevedimka@gmail.com; ownership must be verified before deletion.

English copy for data removed / retention:

> Confirmed deletion removes the Dropo profile, associated installation/session
> records and connection incident reports from the active account database. For
> guests, a minimal revoked-installation credential digest is retained for up to
> 30 days to prevent reuse of the old credential. A deletion-code digest receipt
> without the deleted account identity is retained for up to 24 hours to safely
> confirm a repeated request. The deletion code is otherwise invalidated. Linked
> Telegram identifiers, profile details and account history are removed when the
> registered account is deleted. The pre-provisioned demonstration login may remain
> available for repeat review, but a later explicit sign-in creates a new empty
> profile and does not restore deleted data. Deletion does not delete an independent
> Telegram account, a third-party VPN subscription, or another provider's records.

На сайте должна быть видимая помощь человеку, потерявшему код, без требования
сначала переустановить приложение. Без кода, активной сессии или иных достоверных
данных нельзя гарантировать нахождение и удаление именно его случайного профиля;
IP/MAC и фраза «это мой телефон» не являются доказательством. Этот предел явно
объясняется, а не заменяется обещанием восстановления по устройству.

Скопированный код даёт возможность удаления любому его обладателю. Он появляется
только по явному действию, хранится отдельно от installation credential,
не копируется автоматически и не включается в URL. Привязка гостя к зарегистрированному
аккаунту отзывает гостевой код: далее используется удаление подтверждённого аккаунта.

Наличие кода не отменяет более простой кнопки удаления гостя в приложении. После
удаления нельзя незаметно восстановить прежний профиль из старого секрета.
Сроки очистки при недоступности сервиса и остальные ограничения изложены в политике.
[Требования Google к удалению](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).

## Что подтверждает владелец перед отправкой формы

1. **Dropo Free / VPN-оператор**: кто оператор, политика/контакт; какие IP, домены,
   содержимое, идентификаторы или геоданные он сохраняет, на сколько, кому передаёт
   и для каких целей; есть ли независимая реклама/профилирование. Эти факты нельзя
   вывести из клиента или общей ссылки подписки. Не заявлять no-logs и не исключать
   дополнительные категории на основании молчания провайдера. Это ограничение
   полноты финальной декларации, а не препятствие сборке AAB.
2. **Активные Play-версии/каналы**: нет ли старого сбора телефона, иного SDK,
   иных сетевых endpoint или устаревшего disclosure, которые ещё должны учитываться
   в глобальной форме пакета.
3. **Рабочая среда**: production endpoint `https://dropo.fun`, актуальная политика и
   все три пути удаления действительно развёрнуты; нет внешнего слоя логирования,
   не отражённого в политике. После изменений CDN/логов/резервных копий проверить
   это заново. Матрица не утверждает сроков хранения у неизвестного провайдера.

После подтверждения этих трёх пунктов партнёр переносит матрицу в Play Console,
проверяет preview и отправляет. Если сведения оператора не получены, сохранить
черновик и не выдавать документ за окончательное подтверждение всей обработки.
Сам AAB можно собрать, проверить и передать отдельно от отправки декларации.

## Следы проверки в исходниках

Пути приложения относительны этому репозиторию. Пути backend относительны
репозиторию DropoVPN-Backend; названия функций стабильнее номеров строк.

| Утверждение | Где проверять |
| --- | --- |
| Production account HTTPS, без redirects | `flutter_app/lib/account.dart`: `accountEndpointAvailable`, `_AccountApi.request` |
| Гостевой credential и восстановление | `flutter_app/lib/guest_identity.dart`; backend `guest_http.go`, `guest_store.go`: `LoginGuest` |
| Защищённое хранилище Android | `flutter_app/lib/account_session_store.dart`; Android `SecureAccountSessionStore.kt`, `AccountSessionEnvelope.kt` |
| Собственные данные профиля/сессий | backend `models.go`, `store.go`: `Account`, `AccountBySessionToken`, session activity |
| Вход Telegram | backend `telegram.go`, `store.go`: challenge binding/exchange; `models.go`: Telegram fields |
| Демонстрационный пароль | backend `password_http.go`, `password_store.go`: `derivePassword`, `verifyPassword` |
| Опциональные инциденты, allowlist и очереди | `flutter_app/lib/incident_reporting.dart`; backend `incident_http.go`, `incident_store.go`, `incident_security.go` |
| IP/subnet и счётчики | backend `server.go`: `remotePrefix`, `memoryLimiter.Allow` |
| Гостевое веб-удаление | `flutter_app/lib/guest_identity.dart`, `flutter_app/lib/account.dart`; backend `guest_deletion_store.go`, `guest_http.go`, `deletion_web.go` |
| Запрет журналирования API и deletion forms | backend `ops/nginx-account.locations`, `ops/hetzner/nginx-dropo.https.conf` |
| Отдельное согласие на VPN | `flutter_app/lib/vpn_disclosure.dart`; Android `DropoVpnService.kt` |
| HTTPS subscription и redirects | `app/mobile/dropocore/subscription.go`: `validateSubscriptionURL`, `newSubscriptionFetcher` |
| HTTPS health probes | `app/mobile/dropocore/android_services.go` |
| Google DNS DoH, direct exceptions | `app/mobile/dropocore/singbox_config.go`: `buildAndroidDNSServers`, `buildAndroidDNSRules` |
| Play encryption gate и insecure rejection | `app/mobile/dropoandroid/vpn_encryption_policy.go`; Android `AndroidDistributionPolicy.kt` |
| IPinfo не используется на Android | `app/mobile/dropocore/dropocore.go`: `CaptureDPIFingerprint` no-op; сравнить Windows `app/app_api_fingerprint.go` |
| Только локальные проверки пакетов | Android `MainActivity.kt`, `DropoVpnService.kt`, основной `AndroidManifest.xml` queries |
| Ручная безопасная сводка поддержки | `flutter_app/lib/guided_help.dart`: `buildSafeSupportReport`, preview/copy |
| Google Play без APK self-install | `flutter_app/android/app/src/play/AndroidManifest.xml`; `AndroidDistributionPolicy.kt` |

Дополнительно перед отправкой не скрывать VPN в технических раскрытиях:
[VpnService policy](https://support.google.com/googleplay/android-developer/answer/12564964?hl=en).
Правила обращения с чувствительными данными:
[User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en).
Приватные проверочные credentials вводятся только в App access, а не в эту
публичную памятку; инструкции: [GOOGLE_PLAY_APP_ACCESS.md](GOOGLE_PLAY_APP_ACCESS.md).
