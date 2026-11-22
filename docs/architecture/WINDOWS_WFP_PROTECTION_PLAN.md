# Windows WFP protection: implementation contract and release gate

Status: preparatory stage only. The current Windows build **does not** have an
active kill switch. `GetStatus().reconnectProtected` and
`GetStatus().vpnProtection.active` remain `false` until a separately installed
guard confirms its live WFP policy. Automatic process reconnection is not leak
protection.

The implementation groundwork now includes a typed and bounded `wfpguard.Policy`
validator, a strict revision-fenced IPC request decoder, a read-only native
WFP object inspector, a non-executable filter review plan, and a separate SCM
service host with an authenticated local pipe. The host rejects arm/disarm and
always reports inactive; it creates no WFP filters. Opt-in build packaging
requires an independently pinned signed guard binary and binds its manifest
hash to the final signed core. Normal builds do not stage a guard. The standalone
preflight accepts an expected manifest hash from trusted build inputs but
cannot extract it from a signed core, so it remains supplemental outside the
integrated build sequence. No installer registers or starts the service yet.
The current machine-wide activation preflight explicitly returns unresolved
blockers, and a separate selected-services reviewer requires matching plan
revision, exact flow tuple, positively classified service evidence, and an
existing VPN route decision. Neither reviewer installs filters or establishes
a kill-switch guarantee.

## Product boundary

The accepted product direction has two distinct scopes, not one universal
toggle. In **All traffic through VPN**, protection should cover the device,
including other user sessions and system-originated Internet traffic, with an
explicit choice between disconnect-only and always-on behavior. Necessary
link/bootstrap traffic and approved local/work-network/WireGuard overlay routes
must be narrow, visible exceptions. In **Selected services**, unrelated traffic,
games and explicitly direct services must remain direct; only positively
classified VPN-designated traffic may be denied when the tunnel is unavailable.
A machine-wide physical-egress deny in that mode would break the product
contract. The Hide-RU toggle has no routing effect in full-tunnel mode; its
selective-mode RU proxy is part of the separate selective policy. Portable
builds remain unsupported until they have a
reliable elevated install, upgrade and uninstall lifecycle for the guard.

The first activation target remains installed Windows full-tunnel mode. Do not
advertise selected-service kill-switch protection merely because the in-process
classifier can block already-seen flows: after core/WinDivert exit, a shared
CDN IP or browser process is not sufficient evidence that a new flow belongs
to a selected service. Any broader selective protection requires a durable
classifier with the same conservative service evidence and release tests.

The existing user core keeps ownership of user settings, sing-box and the one
in-process WinDivert handle. A separate, minimal Dropo Windows service owns
only WFP policy; it must never transform packets, run WinDivert, parse service
strategy files, download code, or execute shell commands.

## Security invariant

When the user explicitly enables protection, a persistent physical-egress deny
must be committed **before** sing-box starts or default routes change. The deny
must survive core/UI exit, sing-box crash, background reconnect, network change
and service restart while armed. A failed policy update retains the previous
deny. In disconnect-only mode, an explicit user disconnect may disarm it; in
always-on mode, only an explicit protection-disable or uninstall may remove it.
The UI may show
`active=true` only after service readback confirms the expected policy revision
and both IPv4/IPv6 filters. A WFP dynamic session is insufficient because its
objects disappear when the client process exits; the guard needs an owned,
persistent provider/sublayer and transactional updates.

The policy must never whitelist all traffic from `sing-box.exe`, all DNS, or a
subscription/provider CIDR. Its physical-interface exceptions must be bounded
to verified outer tunnel endpoint tuples (process identity, protocol, exact IP,
port and interface), plus precisely scoped local/work-network/WireGuard overlay
exceptions. Inner traffic on the verified TUN interface and loopback must not
be mistaken for physical egress. Unknown or unverified exceptions fail closed.
Endpoint hostname resolution, IPv6, multiple independent VPN sources, Xray
bridges, endpoint rotation and captive-portal behavior need explicit designs
and tests before activation; DNS bootstrap cannot be solved with a broad port
53 permit.

The enforcement boundary is still unresolved: a per-user ALE deny does not
cover SYSTEM-owned DNS/network services, while a machine-wide deny can disrupt
DHCP renewal and IPv6 neighbor discovery. ALE is stateful, so previously
authorized flows and reauthorization must also be tested. The preparatory
filter-plan compiler is a specification for review, not proof of a working
kill switch; no native mutation should ship until the scope and narrow
bootstrap exceptions have clean-VM leak-test evidence.

## Trust and lifecycle

1. Build and sign a dedicated `dropo-wfp-guard.exe`, include it in the signed
   core's file-level runtime manifest, and copy it only to the ACL-protected
   ProgramData runtime. Do not download executable guard assets at first run.
2. Install/update an automatic SCM service with a verified ImagePath in that
   protected runtime. The user core must remain a per-user process, not a
   LocalSystem service. Authenticate IPC with a restrictive named-pipe ACL and
   validate every requested policy inside the service; do not trust UI-supplied
   raw WFP filters or arbitrary executable paths. The current service authenticates
   a pinned user SID, but same-user malware could also send requests; decide
   whether application identity is required before enabling disarm.
3. Before deleting an older runtime, confirm SCM points to the new verified
   binary and retain the old binary for rollback. The current cleanup now
   preserves the version referenced by a `DropoWFPGuard` service; if SCM
   readback is unavailable or its path is unexpected, cleanup skips deletion.
   Core cleanup now holds `Global\DropoWFPRuntimeMigration` across SCM readback
   and deletion. Installer migration must acquire the same interprocess lock,
   grant the pinned user SID wait/release rights when SYSTEM creates it first,
   and hold it across ImagePath changes before the service is enabled; a
   readback alone cannot exclude a concurrent SCM ImagePath change.
4. On uninstall, transactionally remove owned WFP objects and the SCM service;
   never remove another provider's filters. Define an offline recovery path for
   a machine left blocked when the guard binary or BFE is unavailable.
5. A publication gate must require trusted Authenticode signatures on the
   installer, core and guard. The existing reproducible unsigned CI build is
   useful for tests but is not sufficient evidence for the protection claim.

## Release evidence required before enabling the feature

- Fresh install, silent upgrade, rollback and uninstall on clean Windows 10/11.
- Service crash/restart and UI/core/sing-box process death while guarded: no
  physical IPv4 or IPv6 egress, no broken LAN/work overlay route.
- VPN endpoint failover, DNS bootstrap, IPv6-only/dual-stack, network switch,
  sleep/resume, captive portal and independent VPN-source failover.
- Selected-services and Hide-RU regressions: direct traffic remains direct and
  WFP protection is never reported active in those modes.
- Readback of provider/sublayer/filter GUIDs, revision and interface/endpoint
  allowlist before claiming protection. Regression tests for malformed IPC,
  overly broad exceptions, stale session generations and service-path changes.
- Verify the same self-contained package and ProgramData ACLs in the Windows
  release gate; preserve the single WinDivert owner and packet-plan tests.

Microsoft references: [WFP object lifetimes and transactions](https://learn.microsoft.com/en-us/windows/win32/fwp/object-management),
[WFP operation and filter layers](https://learn.microsoft.com/en-us/windows/win32/fwp/basic-operation),
[ALE connection filtering](https://learn.microsoft.com/en-us/windows/win32/fwp/application-layer-enforcement--ale-),
[persistent filter flags](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_filter0).
