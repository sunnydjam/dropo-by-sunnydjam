# Shell refinement and source latency selection (3.0.38)

## Scope

- No visual hover/long-press tooltips. Icon actions keep explicit semantic names;
  explanatory text remains accessible to screen readers. The app root also
  suppresses implicit framework tooltip overlays, including on dialog routes.
- Dropo replaces the expanded left rail's Navigation heading. Compact windows
  retain the brand beside the menu button. The developer information remains in
  About. One star field covers the whole shell, including navigation and settings.
- Home contains connection, two routing modes and service navigation, without a
  VPN source card. Source management is reached through primary navigation.
- The larger source-page redesign, source ping list and Boost placement are deferred.

## Windows automatic source selection

New profiles use `vpn_source_selection_mode: latency`. After connection-ready,
the existing safe bootstrap selector remains active while at most three workers
measure HTTP response time through each enabled, generated `vpn-source-*`
selector. The comparison has a 15-second budget; committing a measured candidate
has a separate 5-second budget. This is not ICMP/game ping or download speed.

Only positive, successful, session-bound samples participate. The lowest measured
latency wins; equal/unknown results retain saved ordering. The session fallback
chain contains independent sources only. A subscription's selected node is never
changed. Healthy sessions do not continually switch on small latency variations.
Failed active sources still use the existing health thresholds and fallback logic.

Reordering explicitly selects `priority` mode. The source-page action “Автовыбор
по пингу” restores latency mode through the existing transactional reconnect path.
Both modes persist per profile. Existing multi-source profiles without this field
retain their prior order conservatively: older versions did not record whether
that ordering was manual. A user may enable latency mode explicitly. Refreshes
do not reset the preference. Stop cancels probes and drains selector writes before
a new session can use the engine.

Android still has one active subscription; this does not introduce Windows-style
multi-source ranking to its native backend.

## Native visual QA

This is Flutter desktop/mobile, not a browser frontend. Use the existing native
Flutter widget renderer (`test/space_shell_test.dart`, capture defines) and inspect
PNGs with `view_image`; do not present these fixture scenes as a live VPN session.
The approved baseline is `night-earth-preview/home-820-night-1.0.png` in the local
visualizations directory; current scenes are in `shell-refinement` alongside it.

| Comparison | Result / intentional change |
| --- | --- |
| Copy | Navigation heading and home source text removed; Dropo moved left. Connection and routing labels preserved. |
| Layout | Existing 208 px desktop rail retained; home content recentred after card removal. Source link removed from settings to avoid duplicate navigation. |
| Typography | Inter scale, weights and existing icons retained; accessible icon names no longer rely on tooltip popups. |
| Palette | Same near-black sky, mint actions and restrained stars; opaque rail/header/footer fills removed. |
| Artwork | Approved night Earth unchanged, with gray/green/red/connecting states and city-light behavior intact. |
| Responsive / motion | 820×560 baseline, 684×461, 1100×760 and 390×568 at 100%/200% text; drawer hides underlying page controls, star field pauses under overlays and reduced motion. |

Above-the-fold copy differences are the requested source-card removal, brand move
and removal of the redundant developer byline on expanded-rail layouts. There are
no added home CTAs or invented metrics. The source page has one necessary action
and explanatory copy for the new automatic/manual choice, not its deferred redesign.

Functional tests cover source navigation, connect/disconnect without manual source
selection, overlay stability, pointer cursors, keyboard/accessibility, suppressed
tooltips on the real app root and dialog routes, full-window background dimensions,
latency ranking/ties/failure, bounded probe concurrency, cancellation, manual-choice
races, preference migration/persistence and restoration of automatic mode.

Validation on 2026-09-27: `flutter analyze` clean, all 216 Flutter tests pass,
`go test ./...` passes in `app` (including trafficorchestrator/WFP packages), and
`git diff --check` passes. The baseline and latest native renders were inspected
with `view_image`; the existing design is preserved with the intentional changes
above, with no remaining observed layout/copy/artwork mismatch. The actual
connect/disconnect and source-navigation widget paths were exercised with mocks.
Go's race detector could not run in this local environment (`CGO_ENABLED=0`, no
configured GCC/Clang); bounded concurrency and manual/Stop races have deterministic
tests. No live VPN/network change, installation, commit, push or release was made.
