# Changelog

Significant changes in the `Dropo by sunnydjam` fork are documented here.

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
