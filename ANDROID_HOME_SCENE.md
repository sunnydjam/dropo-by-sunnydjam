# Android connection scene

The Android home screen embeds `assets/android_home/index.html` in a local
WebView. The Flutter shell, account flow, source consent, Android VPN permission
and CoreBridge remain authoritative. Windows keeps its existing Flutter scene.

`android_animated_home.dart` accepts only a small command vocabulary. Native
state is checked again before dispatching a command. No account tokens, source
URLs, credentials or arbitrary native calls cross this bridge. Navigation is
limited to the bundled entry point and the content security policy disables
network access. Textures are embedded as data URLs in `art.js` so they can be
loaded locally under the same restrictive policy in Android WebView.

Native connection state updates the status and routing panel synchronously.
Controls still respect native `enabled` and `canCancel` gates, but never wait
for a flight cycle or camera animation. A successful connection interrupts
takeoff/orbit with a 450 ms visual transition; Stop returns DrOppo to his seat.

The mascot uses the exact approved `assets/mascot/droppo_*.png` images, without
synthetic volume or redrawn transition poses. DrOppo sits above a gray Earth
while disconnected and flies above a green Earth when connected. A failed
connection shows a red Earth and the puzzled, palms-up pose. DrOppo keeps his
original green colors in every state, including errors. Retry clears
the error presentation; a nonfatal warning on an active connection stays green.
Background/lifecycle pauses and reduced motion are supported; changing motion
preferences never replays a stale transition. A native connection panel remains
available if WebGL fails.

The native wrapper requires the renderer's explicit `ready` message within
eight foreground seconds. Loading HTML alone does not complete startup. Missing
critical assets, uncaught JavaScript errors and WebGL failures trigger the native
fallback; an ES5 bootstrap can report even a syntax error in the scene bundle.
Background loading pauses the startup deadline. The error caption sits below
the globe without its decorative arrow so long messages remain readable on
small screens. Session time accepts corrected native uptime after startup.

The Android footer opens the real account page with `showTurbo: true`, including
for guests. The destination survives successful sign-in. Purchase capability
and distribution gates remain in the account page; this UI does not enable
payments in a channel that disallows them.

Checks: scene command parser, Android footer and purchase destination, password
sign-in destination, existing connection-race/reconnect and shell tests. Rendered
scene checks use a local browser harness with synthetic native state, exercising
immediate success, cancellation, error/retry, reduced motion, background/resume
and small/landscape viewports. These do not establish a real VPN connection or
replace validation in Android WebView on a device or isolated emulator.

`tools/android-scene-tests` runs these checks against the actual bundled assets
in Chromium and is included in CI. Flutter's `android_scene_startup_test.dart`
covers the native startup deadline, pause/resume and critical-resource fallback.
