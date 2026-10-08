# Privacy policy

dropo does not include advertising, analytics, telemetry or automatic crash
reporting. Profiles, subscription URLs, VPN credentials, settings and logs are
stored locally in the user's Windows or Android application data.

Network requests are made only to provide features requested by the user or
needed to operate the application:

- configured VPN, proxy and WireGuard endpoints receive the traffic routed to
  them according to the active profile;
- service health checks contact the service domains shown by the application;
- update checks contact this fork's GitHub Releases API;
- the optional network fingerprint check contacts `ipinfo.io` to determine the
  public country code;
- subscription import and refresh contact the URL supplied by the user.
- after explicit consent, adding Dropo Free contacts the configured account
  backend without an account token to obtain the one managed subscription;
  the third-party subscription provider and VPN operator receive the requests
  needed to import and use that source. The public aggregator is no longer offered.

## Optional account

The fork's configured production account service is hosted at
`ms-api.ordaflow.net` and uses `@DropoRigistration_bot`. It is separate from the
upstream project. The bot token and server signing/identity secrets are never
included in Windows or Android clients.

Telegram registration is optional and does not gate free VPN or personal
subscriptions. Only an explicit sign-in action opens Telegram. After approval,
the account backend stores the Telegram user ID, optional display name/username,
separate device sessions and account-action audit events. New registration does
not request a phone number, contact, Telegram password or login codes. Legacy
accounts may retain previously stored pseudonymised phone digests for continuity.

Windows account sessions use current-user DPAPI encryption; Android uses
Keystore-backed encrypted app-private storage excluded from backup. A backend
outage does not automatically delete a valid stored session. Tokens are bound to
their issuing backend endpoint. Local development approval pages are clearly
labelled mocks and must only be served on loopback, not as real Telegram login.

Purchases are disabled until real paid VPN infrastructure is available. The
account backend is not a VPN relay and does not receive VPN traffic, visited
sites, DNS history or the user's personal subscription URLs.

The application does not upload profiles, VPN credentials, visited URLs or
VPN logs to the upstream or fork maintainers. Optional account requests described
above send only the data required for that feature. Third-party endpoints are governed by their respective
privacy policies. Users can avoid optional checks by not invoking those
features, remove local application data after uninstall, and inspect all
network behavior in the source code in this repository.
