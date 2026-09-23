# Changelog

Significant changes in the `Dropo by sunnydjam` fork are documented here.

## 3.0.33 — 2026-09-23

### Windows interface and first connection

- persistent adaptive navigation for connection, services, VPN sources, settings
  and help; overlays no longer shift page layout and remain accessible;
- DPI-aware client window sizing and per-user normal placement restoration,
  with work-area clamping and compact/large-text layout regression tests;
- the connection button and planet now distinguish idle, connecting, connected
  and failed states without a duplicate large status heading; click cursors and
  accessible state announcements are retained;
- one VPN source page with optional public sources, personal subscriptions,
  editable shared priority and a non-purchasable Boost coming-soon section;
- public sources no longer override saved order. Failover remains between
  independent sources, never an automatic ladder of nodes within a subscription;
- fresh Windows installations default to full VPN and offer an explicit-consent
  public-source onboarding path. Existing, legacy and recovery settings keep
  their routing mode; no public source is enabled without consent;
- disconnected full-VPN preferences can be saved without a source, with cached
  configs invalidated. Start/build still reject a missing source; failed active
  changes restore the previous state rather than falling back to direct traffic;
- malformed direct keys lacking server/port are rejected before persistence.
  Android network parity and actual Boost purchasing remain separate work.

## 3.0.32 — 2026-09-23

### Windows update hotfix

- fixed VPN startup after an installed update when the saved sing-box profile
  still referenced filter files in the previous protected runtime directory;
- startup now detects Dropo-owned local rule-set paths from another runtime and
  rewrites only those references to the current signed bundle before launching
  the selective proxy, without contacting the subscription provider;
- subscriptions, source order, selected nodes, profiles, routing modes and
  per-service Direct/VPN/Zapret policies are preserved during the migration;
- routing behavior is otherwise unchanged from 3.0.31. Android remains outside
  this Windows release.

## 3.0.31 — 2026-09-23

### Full VPN and Windows routing

- repaired `Everything through VPN`: the final Internet route and remote DoH
  now use the selected VPN source, with no hidden Direct candidate in the
  selector or stale selective-mode cache;
- full VPN now refuses to start without a usable VPN source, while local/private
  destinations and work-network WireGuard overlays keep their higher-priority
  routes across every mode;
- route diagnostics separate endpoint reachability from a confirmed effective
  route and no longer present fallback/catalog data as a live route;
- VPN start, stop, reconnect, source, subscription and route changes are
  serialized and transactional; stale background work cannot revive or mutate
  a disconnected session.

### Telegram and Discord

- Windows no longer bundles, starts or opens the legacy `tg-ws-proxy` sidecar;
  Telegram follows the same explicit Direct/VPN service policy as other apps;
- upgrades remove the obsolete sidecar binary and show a non-modal, explicit
  migration action when an older Dropo version may have left a localhost proxy
  saved in Telegram; Dropo never edits Telegram settings automatically;
- Discord strategy selection and media health run in the background, are fenced
  to the active VPN session, and mark voice/video working only after sustained
  bidirectional evidence; explicit Direct/VPN policy remains authoritative.

### Release reliability

- Windows UI now uses the static MSVC runtime, fixing startup error
  `0x0000135` on clean systems without a machine-wide Visual C++ runtime;
- runtime manifest, SBOM and provenance checks reject the removed Telegram
  sidecar and cover the self-contained Windows package;
- WFP kill-switch code remains an inactive architecture prototype: it is not
  installed, does not create filters and is not advertised as active protection;
- Android source changes remain behind a separate Android release gate; no APK
  is included in this Windows release.

## 3.0.30 — 2026-09-21

### Minimal Atlas interface

- compact 700×500 Windows window with an animated globe and a centred connection
  action; Home shows only connection state, source, mode and the service shortcut;
- two primary destinations: Connection and Settings; subscriptions, services,
  app options, advanced tools and help are grouped without removing features;
- click-to-open side navigation, correct Back history, keyboard focus recovery
  and layouts tested at 100/150/200% text scale;
- service policies remain saved while full VPN is active; failed writes restore
  the confirmed value and settings recover after bridge errors;
- Windows no longer offers a misleading Auto service route that the core stores
  as Direct; strategy auto-selection is separate, Android retains its own Auto;
- animation respects reduced motion and pauses behind overlays/inactive views.

### Release checks

- publication now requires both general CI and the Windows package gate to pass
  for the exact commit, with 24 offline readiness fixtures;
- 93 Flutter tests cover navigation, accessibility, route editing and failures;
- routing, packet strategies and VPN sources are unchanged; saved subscriptions
  and policies are retained. Discord Zapret remains experimental;
- Windows packages remain unsigned. Android is not part of this release; live
  network acceptance after updating is separate from automated package checks.

## 3.0.29 — 2026-09-17

### Atlas desktop interface

- forest-green desktop theme with a decorative globe, one connection button,
  horizontal navigation, and a collapsible favourites list;
- modes and per-service dropdowns remain on Home; advanced strategy details,
  profiles, work networks and diagnostics remain available;
- responsive layouts keep the connection action visible in compact windows;
  source priority is distinct from confirmed active-source state;
- rejected route writes restore the last confirmed policy, and full-VPN mode
  clearly marks service policies as saved for selective mode;
- fixed the diagnostics scrollbar; routing and packet-engine logic unchanged.

### Reopen after installed updates

- silent updates directly launch the newly installed app instead of passing
  the executable to Explorer; no Finish-page action is required;
- disabled competing Restart Manager relaunch; the installer owns one launch;
- added installer-contract tests and a clean-Windows smoke check requiring one
  visible UI after the same `--from-update` hand-off used by older clients;
- saved settings and autostart choices are preserved. Portable remains a manual
  archive update; reopening the window does not force a VPN connection.

## 3.0.28 — 2026-09-17

### Interface and navigation

- clear connection states and one source panel distinguishing saved priority
  from the active session; collapsible quick routes remain on Home;
- separate Services and VPN Sources pages, domain/name search, pinned services,
  and a single route editor instead of duplicate settings;
- stale/offline states no longer claim an active route; writes lock conflicting
  navigation and recover controls on failure;
- accessible layouts tested at 100/150/200% text scale; native widget screenshots
  and 67 Flutter regression tests, without starting another VPN core.

### Optional public VPN fallback

- public VPN Checker RU catalog requires opt-in consent and stays after personal
  sources, including when its URL was imported manually;
- exactly one selected node per source; no automatic sweep of sibling nodes;
- manual node selection survives updated labels; cached lists retain their
  original update time and show an offline warning;
- removing the final source no longer restores an obsolete subscription URL;
- public providers are third parties: reachability, privacy and speed are not
  guaranteed. Existing service policies and direct-first traffic rules remain.

Installed Windows 3.0.27 can obtain this release through the existing updater.
Discord Zapret remains experimental; selective VPN is recommended for voice.

## 3.0.27 — 2026-09-03

### VPN compatibility and diagnostics

- added desktop support for VLESS HTTPUpgrade transports and preserved their
  host/path parameters when importing links and subscriptions;
- direct input now accepts a newline-delimited bundle of proxy links and keeps
  every supported node available for explicit selection;
- exposed VPN-source health in the application status instead of reporting a
  configured but unreachable source as healthy;
- kept the active VPN route online while an update is downloaded and verified,
  so users who need Dropo to reach GitHub do not lose the transfer midway.

### Automatic Windows updates

- installed Windows builds automatically download stable updates from this
  repository when update checks are enabled;
- the exact release asset is validated by declared size and GitHub SHA-256
  before the active connection is stopped;
- verified updates run through a silent in-place installer and relaunch Dropo;
- portable Windows and Android builds remain download-notification only and
  never overwrite their own files automatically;
- release CI and the Windows package gate now follow `Dzhamuha-develop`, the
  actual release branch.

### Build reliability

- added explicit offline switches for the pinned blocked-list bundle and cached
  Flutter packages without weakening the normal publication gate;
- updated the inherited Android bridge to gRPC `1.83.1`, which contains the
  upstream fix for HTTP/2 DATA-frame fragmentation memory exhaustion;
- expanded transport, subscription and updater regression coverage.

## 3.0.26 — 2026-08-30

### Stable routing profile

- fresh Windows installations start with YouTube on scoped Zapret, Discord,
  Instagram and ChatGPT on selective VPN, and all unrelated traffic on Direct;
- upgrades preserve every explicit per-service policy already selected by the
  user;
- Discord VPN remains the recommended release route for web, the desktop app,
  voice, video and Go Live;
- Steam, games and unknown/shared-CDN traffic keep the direct-first fail-safe.

### Zapret development

- adapted all 22 Flowseal 1.10.2 strategy profiles to bounded, typed in-process
  packet actions without an external executable, Lua runtime or shell command;
- restored the live-tested General ALT recipe and scoped CONNECT probes;
- added alternative Discord TLS discovery ports `2053`, `2083`, `2087`,
  `2096` and `8443`, guarded by process identity and initial TLS evidence;
- kept YouTube strategy selection available in automatic and manual modes;
- marked Discord Zapret and its automatic selector as experimental because a
  successful web/API probe cannot prove a bidirectional voice/media session;
- never persists a Discord candidate as fully working without sustained live
  media evidence.

### Release engineering and documentation

- documented the recommended per-service profile, experimental-mode contract,
  provider/DPI variability and Discord voice limitations;
- added regression coverage for shared Cloudflare addresses, Steam/game Direct,
  bounded WinDivert filters and preservation of saved user policies;
- Windows installer and portable artifacts are validated by tests, runtime
  manifest/SBOM checks, MOTW simulation and Microsoft Defender scanning.

### Known limitations

- Discord Zapret may open web/API while the desktop app or voice remains
  unavailable; use the selective VPN route for stable Discord operation;
- YouTube Zapret depends on the ISP's current DPI behavior and may require a
  different strategy on another network;
- Windows binaries are unsigned until a publicly trusted Authenticode identity
  is available;
- Android is not included in this Windows release.

## 3.0.26-rc.1 — 2026-08-29

### Added

- per-service policies for Direct, VPN and experimental local bypass;
- primary service routes for YouTube, Discord, Instagram and ChatGPT;
- collapsible service-route controls and support for adding services;
- immediate `Всё через VPN` mode;
- in-process Windows traffic orchestrator with one WinDivert owner;
- service-aware TLS/QUIC/process classification and direct-first fail-safe;
- background strategy selection state and diagnostics;
- external `DROPO_TOOLCHAIN_ROOT` support for developer SDKs.

### Improved

- unselected games, Steam traffic and unrelated sites remain on the direct path;
- application traffic classification, including Discord gateway and media;
- route-aware quick checks for selected VPN services and direct/game guards;
- Discord idle diagnostics without ten-second log spam from control-only TCP
  connections;
- cleanup of stale Dropo processes, proxy state and temporary host mappings;
- reproducible Windows packaging, runtime manifest, SBOM and Defender gate;
- Android transitive security dependencies updated to `grpc 1.82.1` and
  `edwards25519 1.1.1`.

### Known limitations

- the built-in Zapret-style bypass is experimental and is not yet the stable
  connection method for Discord and YouTube;
- the Windows release candidate is unsigned until a publicly trusted
  Authenticode identity is available;
- the Android release workflow still requires a validated Android SDK setup.

## Upstream history

History before this fork is available in the upstream repository:
[Droponevedimka/dropo](https://github.com/Droponevedimka/dropo).
