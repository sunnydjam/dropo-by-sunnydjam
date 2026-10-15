# Dropo Connect Booster privacy policy

Developer: Indzhiev Ayush. Privacy and support contact:
[dr.oponevedimka@gmail.com](mailto:dr.oponevedimka@gmail.com).

Last updated: 15 October 2026.

This policy covers Dropo (Dropo Connect Booster) for Windows and Android,
including the Google Play package `com.dropo_dzhamuha.app` and the separate Android Preview package
`in.droponevedimka.dropo.preview`. Dropo provides VPN connections and service-based
routing. Telegram registration is optional: free VPN and personal subscriptions
do not require an account.

The public policy is available at [dropo.fun/privacy](https://dropo.fun/privacy).
Account deletion is available at [dropo.fun/account/delete](https://dropo.fun/account/delete).

## VPN traffic and local data

For Android VpnService and routing, Dropo processes network packets, DNS requests,
destination addresses and domains, and the identity of the applications owning
connections on the device. This data is used to establish connections and apply
the chosen routing rules.

Traffic selected for VPN is sent to the chosen VPN operator. In service-based
mode, other traffic can use a direct connection. Local and work-network exceptions
depend on the active configuration. The VPN operator may receive connection
metadata and contents not protected by the originating application or website.
Dropo does not guarantee that a third-party operator keeps no logs. The operator's
data handling and retention are governed by its own policy.

Google Play builds accept only supported configurations with encryption between
the device and VPN endpoint. This does not hide traffic from that endpoint or
replace website HTTPS. Separate APK and Windows builds accept user configurations;
their protection depends on the selected protocol and settings.

Profiles, subscription URLs, VPN credentials, settings and diagnostic logs remain
in local application storage. Logs may contain private connection addresses.
Dropo does not automatically upload profiles, credentials, visited URLs or VPN
logs to the account service, developer or upstream maintainers. Sharing a
diagnostic report is a user action; remove sensitive data before sending it.

Dropo does not include advertising SDKs, analytics, telemetry or automatic crash
reporting. It does not redirect traffic to monetize advertising requests.

## Optional Android work profile

The optional Dropo Space section checks the presence of a finite list of known
applications and the state of Android's work profile to diagnose compatibility.
The manual compatibility check runs only after the user selects the check action.
These results stay on the device and are not uploaded to the account service.

Creating a work profile requires Android's separate system confirmation. The
profile's local helper may check these known applications while maintaining a
profile already created by the user. Activating an existing application in that
profile uses Android's own profile-management APIs, not a downloaded replacement
APK or copying the user's personal app data. Applications used inside the work
profile handle their own data under their respective privacy policies.

## Network requests and recipients

- Configured VPN, proxy and WireGuard endpoints receive traffic routed to them.
  Personal subscription import and refresh contact the user-supplied URL.
- Service health checks contact the relevant service domains. Connectivity and
  latency checks also contact Google and Cloudflare test endpoints. The selected
  DNS service, including system DNS or Google Public DNS, receives domain lookups.
- The optional network fingerprint check contacts `ipinfo.io` to obtain the
  public IP country code.
- Windows and directly installed APK update checks contact the fork's GitHub
  Releases API. Google Play builds update through Google Play and do not install
  replacement APKs from GitHub.
- After separate consent to add Dropo Free, the account service supplies the one
  managed source URL without an account token. Its subscription provider and VPN
  operator receive requests needed to import and use the source. Public VPN
  aggregators are not offered.

These requests disclose network metadata, such as IP address and request time,
to their recipients. External services, including Telegram, Google, Cloudflare,
GitHub, IPinfo and chosen VPN operators, apply their own policies. The account
service is not a VPN relay and does not receive VPN traffic, browsing history,
DNS history or personal subscription URLs.

## Optional Telegram account

An explicit sign-in action opens `@DropoRigistration_bot`. Opening the bot's
sign-in link sends Telegram user and chat IDs and available display name and
username to the service at `dropo.fun` for the short-lived login
challenge, before final approval. After approval, the service stores the account
profile, Dropo account ID, device names and session metadata, one-time confirmation
requests and account security events. These support login, session management,
confirmation of sensitive actions and account protection.

New registration does not request a phone number, contacts, Telegram password or
login codes. Legacy accounts may retain a previously stored pseudonymised phone
digest and last four digits; deletion removes them too. Bot conversations remain
in Telegram; users can remove the chat with Telegram's own controls.

Account requests use HTTPS. Windows session tokens use current-user DPAPI;
Android uses Keystore-backed encrypted private storage. Android app-data backups
are disabled. Server session and challenge tokens are stored as cryptographic
digests, and database access is restricted to the account service. Bot and server
secrets are never included in clients. These measures do not eliminate every
possible risk.

Purchases are disabled until paid infrastructure is available. The app does not
collect payment details.

## Retention

- Local settings and subscriptions remain until the user removes them or clears
  application data. Diagnostic logs use bounded rotation and can be removed with
  local application data.
- Account profiles remain until confirmed deletion. Active sessions remain until
  expiry or revocation; expired or revoked session rows are removed within 30 days.
- Expired login, action-confirmation and web-deletion challenges are removed within
  24 hours of expiry.
- Account security events remain for at most 30 days. Associated events are
  deleted immediately when the account is deleted.
- For retries after a lost deletion response, an anonymous receipt containing
  cryptographic digests of one-time tokens remains for at most 24 hours. It contains
  no Telegram ID, name or account identifier.

Maintenance runs on service startup and hourly. If the service is unavailable,
the next cleanup runs after recovery. Third-party services set their own
retention periods.

The deployed account service does not archive the account database in backups.
Deployment rollback copies contain the service binary and configuration, not
user records, and do not restore deleted accounts. Account API and deletion
request paths are excluded from reverse-proxy access logs; application logs do
not record their tokens, account IDs or Telegram identities.

## Account deletion and local removal

Request deletion in the Dropo account section or on the
[external deletion page](https://dropo.fun/account/delete), even without
the app installed. Confirm in the same Telegram identity used for registration.
No account is deleted without that explicit confirmation.

Confirmed deletion removes the profile and related data from the active server
database: Telegram IDs, name, username, legacy registration data, every session,
linked challenges and account history. All devices lose access. This is deletion,
not freezing or deactivation. Signing in later creates a new account.

Deleting a Dropo account does not delete a Telegram account, third-party VPN
subscription or VPN settings stored on users' devices. Android system settings
can clear local application data. Signing out, clearing local storage or
uninstalling Dropo does not delete the server account.

If Telegram access is lost or deletion fails, contact
[dr.oponevedimka@gmail.com](mailto:dr.oponevedimka@gmail.com). Ownership verification
is required to protect other users' accounts. Do not send Telegram passwords,
login codes, VPN credentials or subscription URLs.
