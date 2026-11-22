# Sources screen refinement — 2026-09-28

## Revision 2 — flat space background (current)

The user rejected the tinted nested-window presentation. This revision supersedes
the earlier visual ledger below. The reference is now the existing approved home
screen, `sources-refinement/home-820-night-1.0.png`, plus the explicit request to
use its background throughout the application. No new generated artwork needed.

Current renders are in:
`C:/Users/sunny/.codex/visualizations/2026/09/20/01a0c0f3-382f-7af1-91d6-a0725118ca47/flat-space-sections`

| Comparison | Change and verification |
| --- | --- |
| Background / assets | Exactly the existing single global black star field; no extra image, tint, gradient or animation instance |
| Container model | Feature pages and embedded menu pages share a transparent scroll surface; removed outer frame, fill, shadow and arbitrary page-height cap |
| Source/service list | Flat rows with bottom dividers, no filled cards; active source is distinguished by mint icon/status text, not an enclosing green panel |
| Secondary content | Boost and public-source offers are divider-separated sections; real modal dialogs retain neutral dark material for legibility and working ink feedback |
| Typography and icons | Existing Inter, Material icons and monospace telemetry preserved; fixed ActionButton font inheritance; no new visible copy |
| Spacing and responsiveness | Removed double outer padding; checked 1100x760, 820x560, 390x568 and 200% text. Diagnostics toolbar wraps and statistics tiles size to their content |
| Interaction and motion | Existing source selection, priority, disclosure and consent flows preserved; star field remains single-instance and respects reduced-motion/modal pause |

Above-the-fold copy diff: no new/renamed labels; more existing actions become
visible after removal of the outer panel. Intentional deviations from home are
page-specific lists and controls, plus opaque actual modal dialogs. The night
planet remains exclusive to the connection screen.

Compared the home reference and native Flutter RepaintBoundary renders using
view_image (not browser screenshots: this is a native Flutter desktop UI).
Inspected source list, expanded controls, services, application settings and
compact/200%-text layouts. The implementation matches the requested flat
background treatment; no remaining material mismatch in that scope.

Validation: flutter analyze clean; full Flutter suite 229 tests passed; additional
all-section tests check transparent page material, full-window single background,
unfilled source rows, navigation and layouts. No core/network logic changed in
this visual revision. No release or installed-client mutation was performed.

## Scope

Deferred sources-menu request: saved sources lead the page, real response data,
manual selection, expandable maintenance controls, optional public sources and
future Boost below the working list. No release, installation or live VPN changes.

The saved order is not visually reordered by latency. Selecting a source uses the
existing transactional MoveVPNSource API and persists manual priority; selecting
the first source also exits automatic mode. It does not implicitly start a stopped
VPN. Active status remains a core observation, not an optimistic selection state.
Re-enabling automatic selection uses the existing API. Sibling server selection,
fallback semantics and service routing are unchanged. Android keeps its existing
single-subscription contract.

GetVPNSources exposes existing session/profile/node-bound HTTP observations and
the running/mode flags. Reading the page does not probe or change selectors.
Unmeasured, failed, stale, disabled and disconnected states do not display a fake
millisecond value. Inactive observations can expire; the page does not continuously
probe every subscription. HTTP response is not game latency or download speed.

## Visual spec and fidelity ledger

This is a targeted refinement within the approved Flutter design system, not a
new visual concept. Reference directory:
`C:/Users/sunny/.codex/visualizations/2026/09/20/01a0c0f3-382f-7af1-91d6-a0725118ca47/shell-refinement`

Latest native-render directory:
`C:/Users/sunny/.codex/visualizations/2026/09/20/01a0c0f3-382f-7af1-91d6-a0725118ca47/sources-refinement`

| Check | Reference / issue | Render and resolution |
| --- | --- | --- |
| First viewport | `sources-820.png` hid the list below explanations and Boost | Latest `sources-820.png` shows the source, selected server, response and selection controls immediately |
| Copy | Long repeated heading and paragraphs preceded the useful content | Intentional copy diff: concise actual automatic/manual mode, source state, HTTP response, Choose and Settings; Boost moved below sources |
| Density | Initial implementation used separate tall action/disclosure rows | Combined actions into a wrapping row; two-source desktop view is `source-list-1100-1.0.png` |
| Typography | Existing Inter hierarchy and monospace numeric telemetry | Inter retained; status messages use Inter rather than an unavailable test-font fallback; numeric response retains Consolas |
| Palette and artwork | Existing dark panel, mint accent, global sparse star field | Preserved shell/background/planet assets; quieter Boost panel is intentional to demote the future offer |
| Controls | Always-visible node picker, arrows, switch and removal cluttered every card | Controls preserved under Settings; source choice remains visible. Public consent remains mandatory |
| Responsive | Desktop reference 820x560 and compact 390x568 | Both checked at original dimensions; extra 1100x760, 390x568 at 200% text and expanded-settings renders inspected; vertical scrolling is intentional |

No Image Gen or browser rendering was needed for this existing native Flutter
surface. Flutter widget interactions and RepaintBoundary screenshots are the
verification method; these are fixture-driven renders, not screenshots of the
installed client or evidence of a live VPN connection. Reference and latest images
were inspected with view_image. The refined page preserves the approved design
system with the deliberate hierarchy/copy changes listed above; no unresolved
material visual mismatches remain.

## Verification

- `flutter analyze --no-pub`: clean.
- Full `flutter test --no-pub --reporter expanded`: 227 tests passed.
- `go test ./...` from app: passed, including trafficorchestrator.
- Source response tests: independent sources, read-only/no extra HTTP requests,
  credential omission, expiry, future time, node/profile/session/disabled/offline
  and stop invalidation.
- UI tests: real/unknown/failed/stale response states; automatic/manual choice;
  source ordering; explicit public consent; expanded controls; onboarding;
  core-state loss/recovery; text scaling; 600-node search; no visual tooltips.
- Native captures: `space_shell_test.dart` and `vpn_sources_test.dart`, with
  DROPO_UI_CAPTURE and an external DROPO_UI_CAPTURE_DIR.

Real Windows packaging/update gates and live network smoke testing remain part of
a subsequent requested release, not this local UI change.
