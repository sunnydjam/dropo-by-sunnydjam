# DrOppo and the home planet

Prepared for application release 3.1.7 on top of the published 3.1.6 Boost
payment implementation. Windows and Android share the same decorative scene.

## Approved behavior

- Connected: emerald nighttime Earth with warm city lights; DrOppo flies.
- Disconnected: gray Earth; DrOppo sits and waits.
- Connection error: red Earth; DrOppo stands with a puzzled shrug.
- Connecting or stopping: existing amber progress state; DrOppo waits until the
  connection result is known. The existing button and spinner remain authoritative.
- DrOppo retains green skin, an ivory doctor's coat and an emerald cape in every
  state. The illustration adds no pop-ups, tooltips or interaction targets.

The shared Flutter home scene serves Windows and Android. The detailed Earth is
the site's original decorative artwork, with gentle floating and a small tilt
instead of the previous atlas's full axial rotation. All graphics are bundled;
rendering them does not access the network or change connection behavior.

## Assets

- `flutter_app/assets/maps/earth_night_globe.webp`: site Earth master.
- `flutter_app/assets/mascot/droppo_flying.png`: connected pose.
- `flutter_app/assets/mascot/droppo_waiting.png`: disconnected/busy pose.
- `flutter_app/assets/mascot/droppo_puzzled.png`: connection-error pose.

The original approved character is in `store-assets/source/app-icon-master.png`.
Generation prompts for the transparent pose assets are retained in
`store-assets/source/DROPPO_SCENE_ASSETS.json`; the site's Earth provenance is
retained in `store-assets/source/earth-night-globe.provenance.json`.

Decorative rendering is excluded from hit testing and accessibility semantics.
The existing labelled connection control remains on top. Animation stops in the
background, when covered by a route, with disabled tickers, and when the user
requests reduced motion. Missing artwork falls back without blocking connection.

## Checks before the combined release

Run Flutter analysis and the planet surface/motion, DrOppo home, existing home
layout and space-shell tests. The DrOppo integration tests cover desktop, compact
Windows, Android and a narrow phone with enlarged text. For actual UI renders,
run them with `DROPO_UI_CAPTURE=true` and an external `DROPO_UI_CAPTURE_DIR`.

Source implementation and simulated UI checks do not replace the combined
Windows/Android package, signing and release checks after Boost is complete.

## Verification completed 2026-11-11

- Flutter 3.47.1 / Dart 3.13.1: `flutter analyze --no-pub` passed with no issues.
- `planet_surface_test.dart`, `planet_rotation_test.dart`,
  `droppo_home_test.dart`: 41 tests passed, including generated Flutter renders.
- `home_dashboard_test.dart`, `home_variant_one_test.dart`,
  `space_shell_test.dart`, `ui_feedback_shell_test.dart`,
  `space_background_test.dart`, `vpn_response_test.dart`: 157 tests passed.
- `git diff --check` passed.
- Visually inspected desktop and Android-layout captures, including the narrow
  phone at 1.6 text scale, seated contact with the rim and error notification
  collapse. These are widget-test renders with a mock connection bridge, not
  a new device or network test.
- The three PNGs have genuine alpha and are decoded once at bounded resolution.
  The Earth preserves the source's soft alpha in every color state. The original
  site asset has mostly alpha 252–253, so tests compare alpha byte-for-byte
  instead of incorrectly requiring 255.
- Replacing the old bundled atlas offsets most of the new sprite size: the net
  uncompressed bundled artwork increase is 830,341 bytes.

These checks describe the original visual implementation. The 3.1.7 release
also runs the integrated CI and Windows packaging gates on the final commit;
Android APK and Google Play AAB receive separate artifact verification.
