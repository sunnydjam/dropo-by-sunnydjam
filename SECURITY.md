# Security policy

## Reporting a vulnerability

Do not publish VPN credentials, subscription URLs, private keys, authenticated
logs or a working exploit in a public issue.

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/sunnydjam/dropo-by-sunnydjam/security/advisories/new>

Include the affected version or commit, Windows/Android version, reproduction
steps and a redacted diagnostic excerpt. If private reporting is unavailable,
open a public issue containing no secrets and ask the maintainer for a private
contact channel.

## Supported versions

Report issues against the latest stable Windows release or the current
`Dzhamuha-develop` branch. Fixes are developed on that branch and distributed
in subsequent releases; historical versions do not have separate maintenance
branches. Android fork releases have not completed the Windows release gate
and must be evaluated separately. Builds are provided without warranty under
the MIT License; current Windows packages lack publicly trusted Authenticode
signatures. Update hashes are integrity checks, not publisher signatures.
