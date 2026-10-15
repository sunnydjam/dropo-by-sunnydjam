# Android APK и Google Play AAB

Dropo выпускает Windows installer и portable, Android Preview APK для прямой
установки и Android App Bundle для Google Play. AAB — пакет для загрузки в
Play Console, а не файл для установки на телефон. Google Play создаёт из него
подходящие устройству APK. Подготовленная сборка не означает одобрение приложения
магазином. На GitHub публикуются Windows-пакеты и APK; AAB сохраняется в локальном
архиве сборок для отдельной отправки в Play Console.
[Об Android App Bundle](https://developer.android.com/guide/app-bundle).

## Каналы Android

| Канал | Файл | Package | Подпись и обновления |
| --- | --- | --- | --- |
| Прямая установка Preview | `dropo-Android-Preview-universal.apk` | `in.droponevedimka.dropo.preview` | Прежняя Preview-подпись; подтверждённая загрузка и установка APK из GitHub. |
| Google Play | `dropo-Android-Play-universal.aab` | `com.dropo_dzhamuha.app` | Сохранённый upload-ключ; установленные APK подписывает Play App Signing, обновления через Google Play. |

Оба пакета включают ARM32 и ARM64, Android 10+ и target SDK 36. Preview остаётся
отдельным приложением: AAB не заменяет установленный Preview поверх него и не
переносит его данные автоматически. Release-ключ для стабильного sideload APK
настраивается отдельно; `-Android` без `-AndroidPreview` требует именно его.
Идентификатор Play закреплён по требованию созданного приложения в Console.
Preview сохраняет `in.droponevedimka.dropo.preview`; namespace Kotlin остаётся
`in.droponevedimka.dropo` и не меняет идентификатор Play. Ранние AAB с прежним
package сохраняются как история сборок, но для этой записи Play Console не подходят.

Play-вариант не запрашивает `REQUEST_INSTALL_PACKAGES`, не включает APK
FileProvider и не использует встроенную загрузку и установку собственных APK.
Google запрещает Play-приложениям обновлять себя в обход магазина; подтверждение
пользователя само по себе не снимает это ограничение.
[Политика обновлений](https://support.google.com/googleplay/android-developer/answer/16559646?hl=en),
[ограничения установки пакетов](https://support.google.com/googleplay/android-developer/answer/9888170?hl=en).

## Ключи Google Play

Upload-ключ подписывает AAB при отправке в Console. App signing key подписывает
APK, которые получат пользователи. Эти ключи могут отличаться. При первом
публикуемом AAB владелец настраивает Play App Signing; выбор ключа для установленных
APK нельзя подменять выбором upload-ключа. Если нужен одинаково подписанный
стабильный APK для Google Play и других магазинов, владелец должен предоставить
свой app signing key при настройке Play App Signing вместо автоматически
созданного Google. [Подпись приложения](https://developer.android.com/studio/publish/app-signing).

Локальная конфигурация upload-подписи находится вне репозитория:
`%USERPROFILE%\.dropo-signing\google-play\android-upload-signing.properties`.
Она содержит `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. Не добавляйте
этот файл, `.jks`, пароль или приватный ключ в Git, релиз, переписку или Actions.
Создание и замена ключей выполняются только с разрешения владельца. Храните
защищённую резервную копию ключа и паролей отдельно от этого ПК.

Можно указать другой файл через `DROPO_ANDROID_UPLOAD_SIGNING_PROPERTIES`.
Для процессного окружения также поддерживаются
`DROPO_ANDROID_UPLOAD_KEYSTORE_PATH`, `DROPO_ANDROID_UPLOAD_STORE_PASSWORD`,
`DROPO_ANDROID_UPLOAD_KEY_ALIAS`, `DROPO_ANDROID_UPLOAD_KEY_PASSWORD`.
Публичный SHA-256 сертификата закрепляется в
`signing/android-upload-cert.sha256`; это не приватный ключ. Старый
`signing/android-release-cert.sha256` для другого канала не заменяется.
Без настроенной подписи и подходящего сертификата Play-сборка завершается ошибкой;
debug/Preview-подпись вместо неё не используется.

## Сборка пакетов

Требуются настроенные Go, Flutter, Java и Android SDK. Для проверки AAB используется
закреплённый bundletool. Если его ещё нет в локальном build-cache, подготовьте его
через `tools/prepare-android-bundletool.ps1 -Download`. Загрузка относится только к
инструменту сборки, не к runtime приложения.

Только AAB:

```powershell
pwsh -File .\scripts\build\build.ps1 -AndroidBundle `
    -KeepExistingBuilds -AccountEndpoint https://dropo.fun
```

Android Preview APK и Play AAB:

```powershell
pwsh -File .\scripts\build\build.ps1 -AndroidPreview -AndroidBundle `
    -AndroidArchitecture universal -KeepExistingBuilds `
    -AccountEndpoint https://dropo.fun
```

Windows installer, Windows portable, Android Preview APK и Play AAB:

```powershell
pwsh -File .\scripts\build\build.ps1 -All -AndroidPreview `
    -AndroidArchitecture universal -KeepExistingBuilds `
    -AccountEndpoint https://dropo.fun
```

`-All` без `-AndroidPreview` собирает стабильный APK и поэтому дополнительно
требует его отдельную release-подпись. `-AndroidArchitecture` относится к APK;
AAB всегда содержит оба ARM ABI. `-AllowDirtySource` допустим только для разработки,
не для публикации. Публичные пакеты собираются из чистого коммита. Версия должна
совпадать в `version.json` и `flutter_app/pubspec.yaml`, а `versionCode` новой
Play-загрузки должен быть больше всех предыдущих загруженных кодов.

Результат появляется в `release/dropo-<version>-<commit>/`: каждый Android-файл
имеет `.sha256` и `.build.json` с полной исходной ревизией, каналом и хешем.
Подписанные файлы не меняются после выпуска.

## Локальный архив AAB

Чистая проверенная Play-сборка автоматически сохраняется в
`build-archive/android-play/<version>/<full-commit-sha>-<aab-hash-prefix>/`.
Архив содержит только AAB, его `.sha256` и `.build.json`; ключ подписи, пароли и
`signing.properties` туда не копируются. Каталог исключён из Git и не затрагивается
очисткой старых каталогов `release/`. Архив локальный: резервную копию храните
отдельно от этого ПК.

Уже собранный чистый AAB можно сохранить без повторной сборки:

```powershell
pwsh -File .\tools\archive-android-aab.ps1 `
    -ReleaseFolder .\release\dropo-<version>-<commit>
```

Перед сохранением проверяются подпись, SHA-256 и данные исходного коммита.
Повторное архивирование идентичных файлов безопасно; существующие файлы с другими
байтами не заменяются. Сборки из незакоммиченных исходников, разрешённые через
`-AllowDirtySource`, остаются только в рабочем каталоге `release/` и не попадают
в архив релизов. Для Play Console используйте
AAB из архива, соответствующий нужной версии.

## Проверка AAB

```powershell
pwsh -File .\tools\verify-android-aab.ps1 `
    -Path .\release\dropo-<version>-<commit>\dropo-Android-Play-universal.aab
```

Проверка контролирует bundletool validation, подпись и закреплённый upload-сертификат,
package, версию, Android SDK, оба ARM ABI, совместимость ELF с 16 KB страницами и
запрос `PAGE_ALIGNMENT_16K` для создаваемых APK. Проверяются отсутствие
установочных разрешений Play-варианта, лицензия Xray и соответствующие изменённые
MPL-исходники в assets. Одного переименования APK в `.aab` недостаточно.
[Поддержка страниц 16 KB](https://developer.android.com/guide/practices/page-sizes).

## Публикация файлов на GitHub

Сначала общий CI и Windows package gate должны успешно завершиться для одного
полного SHA. Workflow создаёт GitHub release с проверенными Windows-файлами.
Android APK и его SHA-256 добавляются к этому же tag отдельным локальным шагом;
Windows-файлы не заменяются, signing secrets в Actions не передаются. AAB и его
сопутствующие файлы остаются в локальном архиве, загрузка в GitHub запрещена
проверкой допустимых имён файлов.

```powershell
pwsh -File .\tools\publish-android-release-assets.ps1 `
    -ReleaseFolder .\release\dropo-<version>-<commit> `
    -SourceRevision <full-40-character-commit-sha>
```

Команда требует чистый checkout, совпадение SHA в `.build.json`, tag и последних
успешных CI/gate, подходящие подписи и SHA-256 sidecars. Уже опубликованные
идентичные файлы пропускаются; отличающиеся файлы с тем же именем не перезаписываются.
Этот шаг не создаёт release, не меняет Windows-пакеты и не загружает приложение
в Play Console. Для Android используйте его, а не прежний
`tools/publish-release-assets.ps1` со стабильным ARM64 APK и Windows preflight.

## Первый выпуск в Google Play

Проверено по опубликованным требованиям Google на 15 октября 2026 года. Перед
каждой отправкой сверяйте актуальную политику и требования самой Console.

1. Подготовьте подтверждённый **аккаунт организации**: Google требует такой тип
   аккаунта для приложений, одобренных к использованию `VpnService`. Для организации
   требуется D-U-N-S. Проверьте доступность и владение package
   `com.dropo_dzhamuha.app` до первого выпуска; не меняйте его после публикации.
   [Требования Play Console](https://support.google.com/googleplay/android-developer/answer/10788890?hl=en),
   [выбор аккаунта](https://support.google.com/googleplay/android-developer/answer/13634885?hl=en).
2. Создайте приложение и настройте Play App Signing. Загрузите проверенный AAB
   сначала в тестовый канал; проверьте полученные Google APK и их app-signing
   сертификат отдельно от upload-сертификата.
3. Заполните VPN declaration и декларацию foreground service `specialUse`.
   Подготовьте описание применения VPN и демонстрационное видео по форме Console.
   Проверьте шифрование от устройства до предлагаемых VPN endpoint, корректность
   информирования и согласия пользователя. Формат AAB не подтверждает шифрование
   произвольной пользовательской подписки.
   [Требования VpnService](https://support.google.com/googleplay/android-developer/answer/12564964?hl=en),
   [требования foreground services](https://support.google.com/googleplay/android-developer/answer/16559646?hl=en).
4. Опубликуйте доступную privacy policy, заполните Data safety, App access,
   возрастной рейтинг и сведения о Telegram-регистрации. Проверьте соответствие
   ручного Dropo Space и device-admin функций реальному назначению и описанию;
   наличие VPN не является автоматическим разрешением всех сопутствующих функций.
   [Требования перед отправкой](https://support.google.com/googleplay/android-developer/answer/10788890?hl=en).
5. Проверьте target API и совместимость native-библиотек: текущая сборка использует
   API 36 и проходит отдельный 16 KB gate. По опубликованной политике Google,
   новые приложения и обновления для телефонов с 31 августа 2026 года должны
   target Android 16, API 36 или выше.
   [Требования target API](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en).
6. Завершите тестирование и проверку Console. Публикация в GitHub не выпускает
   приложение в магазине: rollout выполняется отдельно владельцем Play Console.

Подключение оплаты и подписок Google Play Billing в этот этап не входит.
