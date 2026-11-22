## Dropo by sunnydjam v3.0.26-rc.1

Первый публичный Windows release candidate независимого fork на основе
[Droponevedimka/dropo](https://github.com/Droponevedimka/dropo).

### Скачать

| Платформа | Файл | Назначение |
| --- | --- | --- |
| Windows 10/11 x64 | `dropo-Windows-Setup-x64.exe` | Автономный установщик с обновлением поверх предыдущей версии и удалением. |
| Windows 10/11 x64 | `dropo-Windows-Portable-x64.zip` | Portable-версия; профили и настройки сохраняются в AppData. |

Windows installer SHA-256: `__WINDOWS_INSTALLER_SHA256_PENDING_LOCAL_UPLOAD__`

Windows portable SHA-256: `__WINDOWS_PORTABLE_SHA256_PENDING_LOCAL_UPLOAD__`

### Что проверено

- выборочные VPN-маршруты для YouTube, Discord, Instagram, Telegram и ChatGPT;
- весь невыбранный трафик остаётся прямым;
- Steam Store, EA, Apex Legends и CS работают без роста игрового пинга;
- Discord web, приложение и двусторонний voice UDP проходят через выбранный VPN;
- режим `Всё через VPN` сохраняет отдельный TUN-контракт;
- установщик и portable проходят Microsoft Defender/MOTW gate;
- пакет содержит SHA-256, SPDX SBOM и SLSA/in-toto provenance.

### Ограничения RC

- Windows-файлы пока не имеют публично доверенной Authenticode-подписи;
- встроенный режим `Обход (Zapret)` остаётся экспериментальным;
- Android не входит в этот RC и будет опубликован только после отдельной
  проверки устройства и подписанного APK.

Полная история изменений: [CHANGELOG.md](https://github.com/sunnydjam/dropo-by-sunnydjam/blob/v3.0.26-rc.1/CHANGELOG.md).
