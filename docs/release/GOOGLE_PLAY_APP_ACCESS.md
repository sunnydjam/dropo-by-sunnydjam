# Google Play app access — 3.0.54

This release replaces the local mock account demonstration with server-backed
demonstration accounts. They use real session, revocation and deletion operations.
No review credentials, private VPN URLs or signing secrets belong in this file,
the application bundle or the repository.

## App access instructions (English)

The app has two sign-in methods: Telegram and username/password. Use the supplied
demonstration username and password to review account features without Telegram,
registration, an OTP or assistance from the developer. Credentials are supplied
separately in Play Console App access.

1. Open **Account / Аккаунт**, then **Sign in with username and password /
   Войти по логину и паролю**. Enter one of the supplied account pairs.
2. The account is a real server-backed demonstration profile. Open its device
   sessions to inspect actual sessions. Sign in with the same account on a second
   device to test ending other sessions. Confirm the action with the same password.
3. To test account deletion, choose **Delete account / Удалить аккаунт**, read the
   confirmation and enter the account password. The server removes the profile,
   sessions and associated history. Old session tokens no longer work.
4. The demonstration login remains available for repeated review. A later explicit
   sign-in creates a new empty profile with a new ID; deleted data is not restored.
   Use a different supplied account for independent/concurrent tests.
5. Deletion is also available without the installed app at
   https://dropo.fun/account/delete using the username/password form.

Guest profiles do not require Telegram or a password account. To review their
external deletion, use a fresh installation, open **Account / Аккаунт → Deletion
on the website / Удаление на сайте**, and create and save the deletion code. Open
https://dropo.fun/account/delete in a browser (the app may be closed or uninstalled),
enter the saved code in the guest form, confirm, and submit. The profile, sessions
and related connection diagnostics are removed immediately. This code grants no
login or data access and becomes invalid if the guest is linked to a registered
account. Guest deletion is also available directly in the app without exporting a
code. After external deletion the old installation cannot recreate the profile.

VPN use does not require sign-in. On the home screen accept the in-app VPN
disclosure, add **Dropo Free** when requested, choose **All through VPN / Всё через
VPN** or **By services / По сервисам**, and tap **Connect / Подключить**. Accept
Android's VPN permission. The connection forwards real network traffic and has an
ongoing notification; return to the app or use the notification to disconnect.
In By services mode select the services to route through the tunnel. Personal
subscription import is available in **Sources / Источники**; a working test
subscription can be supplied privately alongside the access instructions.

Purchases and paid Boost plans are not available in this release. Demonstration
accounts have no administrative privileges and do not grant access to other users.
There is no detection of Google reviewers, IP addresses or installation sources.
The same implemented user functions are used by both authentication methods.

## Before submission

- Use the exact signed `com.dropo.myapp` AAB and check it in a Play internal test.
- Paste the private reusable credentials and the English access instructions into
  Play Console → App content → App access. Do not publish the credentials in the
  store listing or screenshots.
- Verify both connection modes and background/notification disconnect on a device.
- Review the Data safety declaration against the current privacy policy: password
  accounts process a username, protected password verifier and real session data.
- Version 3.0.53 also automatically processes account/installation IDs, platform,
  version and activity metadata. Optional connection diagnostics require separate
  consent and are linked to the installation. Update Data safety accordingly;
  do not reuse a declaration claiming no collection or no diagnostics.
- Version 3.0.54 adds guest web deletion using a separately saved deletion-only
  code. Check all three forms at https://dropo.fun/account/delete and use that URL
  in the account-deletion field. See [GOOGLE_PLAY_DATA_SAFETY.md](GOOGLE_PLAY_DATA_SAFETY.md)
  for the field-by-field declaration and provider facts that require verification.
- Keep test credentials valid and the backend/free source reachable throughout
  review. Disabling an identity revokes its access; do not disable it during review.

Passing local tests and AAB validation does not confirm Google Play approval.
