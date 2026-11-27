# Windows WFP protection: implementation contract and release gate

Status: preparatory stage only. The current Windows build **does not** have an
active kill switch. `GetStatus().reconnectProtected` and
`GetStatus().vpnProtection.active` remain `false` until a separately installed
guard confirms its live WFP policy. Automatic process reconnection is not leak
protection.

## Independent Wintun router and Windows acceptance

The Windows protected-routing setting defaults to enabled. While the Dropo
core is open, a separate process from the verified bundled runtime owns
`Dropo Protected Routing`.
It uses the VPN-only catalog, provides local synthetic DNS for catalog names,
and sends recognized flows only to an authenticated loopback transport link.
Ordinary traffic has a direct outbound. Disconnecting the VPN closes the
transport link while keeping the router available. The Windows setting is in
«Настройки → Ручное → Всегда через VPN». Closing the core ends this router, and the
persistent WFP service described below is still a separate deliverable.

Run `tools/test-windows-protected-routing.ps1` in the dedicated Dropo Hyper-V
guest using a hash-verified portable archive and a fresh isolated data folder.
The fixture checks the cold-start default, the IPv4 routing interface, a
synthetic Claude DNS record, the local VPN-required page and event, direct
HTTPS with the VPN off and in both routing modes, and TLS classification for
two names at the same IPv4 address. It connects an isolated loopback VLESS
peer to verify forwarding of a cached protected address in both modes.
Manual Stop and a forced transport crash must retain the router, while
toggling the feature off restores the original Windows route. Physical
packet capture across TCP/QUIC and IPv4/IPv6, enterprise DNS, and other VPN
coexistence remain part of the release acceptance below.

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

Both routing modes leave ordinary traffic on the physical connection. The
catalog preset routes listed blocked destinations and VPN-only services through
VPN. The service preset also follows explicit per-service policies. A future
guard may deny positively identified VPN destinations during a tunnel outage.
Ordinary Internet, local and work-network traffic must stay available.

A process or shared CDN address alone can misidentify a new browser connection
after the core exits. The existing WFP review plan validates known flow
evidence. Durable enforcement still requires an independent classifier, a
trusted service lifecycle, and dual-stack VM tests before activation.

The existing user core keeps ownership of user settings, sing-box and the one
in-process WinDivert handle. A separate, minimal Dropo Windows service owns
only WFP policy; it must never transform packets, run WinDivert, parse service
strategy files, download code, or execute shell commands.

## Security invariant

When the user explicitly enables protection, a persistent deny for positively classified VPN egress
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
  physical IPv4 or IPv6 egress for VPN destinations, with ordinary and work routes intact.
- VPN endpoint failover, DNS bootstrap, IPv6-only/dual-stack, network switch,
  sleep/resume, captive portal and independent VPN-source failover.
- Both routing presets and Hide-RU: ordinary traffic stays direct, and the
  reported protection scope matches the enforcing filters.
- Readback of provider/sublayer/filter GUIDs, revision and interface/endpoint
  allowlist before claiming protection. Regression tests for malformed IPC,
  overly broad exceptions, stale session generations and service-path changes.
- Verify the same self-contained package and ProgramData ACLs in the Windows
  release gate; preserve the single WinDivert owner and packet-plan tests.

Microsoft references: [WFP object lifetimes and transactions](https://learn.microsoft.com/en-us/windows/win32/fwp/object-management),
[WFP operation and filter layers](https://learn.microsoft.com/en-us/windows/win32/fwp/basic-operation),
[ALE connection filtering](https://learn.microsoft.com/en-us/windows/win32/fwp/application-layer-enforcement--ale-),
[persistent filter flags](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_filter0).
