# Changelog

Significant changes in the `Dropo by sunnydjam` fork are documented here.

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
