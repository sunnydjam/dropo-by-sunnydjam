# Scripts

`filters/update-blocked-lists.ps1` checks Re-filter on every build, stores the
normalized source catalogs and compiled rule-sets in `dependencies/filters`,
and supports `-CheckOnly` for CI/release gates. The application itself never
downloads these catalogs during startup.

- `build/build.ps1` — Windows and Android build orchestration.
- `release/bump-version.ps1` — synchronized application version update.
- `../packaging/windows/` — Inno Setup source for installer and portable packaging.

Windows release packages require a clean Git worktree. Their source revision,
timestamps, Go build IDs, ZIP entry order/times and Inno file timestamps are
fixed so CI can compare a second byte-for-byte rebuild. Use
`-AllowDirtySource` only for local development output that will not be published.

Diagnostics and release validation remain in `tools/`.

## Account backend in builds

Pass the same public HTTPS backend origin to Windows and Android with
`-AccountEndpoint https://accounts.example.com`, or explicitly set the process
environment `DROPO_ACCOUNT_ENDPOINT` before invoking the build script. A non-empty
parameter overrides the environment; neither configured means accounts remain
unavailable, with no implicit localhost service.

Only an HTTPS origin is allowed: no credentials, query, fragment, URL path, local
hostname or private/loopback IP. The origin becomes Flutter's compile-time
`DROPO_ACCOUNT_ENDPOINT`; it is not read from the user's environment at app
startup. Bot tokens, account secrets and private VPN links must never be supplied
as Dart defines. Builds do not resolve DNS or contact the account backend.

A configured backend cannot be combined with `-ReuseFlutterWindowsOutput`:
compile Flutter afresh so a previous origin cannot enter the new package.
`tools/test-account-build-endpoint.ps1` validates these rules without building,
packaging, fetching dependencies or reading credentials.
