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

Native connection status updates immediately. The connected controls, source,
session time and VPN response stay hidden through takeoff and flight. After
success, the mascot completes the orbit, Earth shrinks and the mascot settles
before the connected panel appears. Reduced motion shows the settled layout
directly. Earth accepts a connection request while idle or in the error state.
Disconnect and cancel have separate buttons.

Moving between sections keeps the Android WebView and its renderer mounted.
Drawing pauses behind Flutter pages and resumes without reloading the scene.

The mascot uses the exact approved `assets/mascot/droppo_*.png` images, without
synthetic volume or redrawn transition poses. DrOppo sits above a gray Earth
while disconnected and flies above a green Earth when connected. A failed
connection shows a red Earth and the puzzled, palms-up pose. DrOppo keeps his
original green colors in every state, including errors. Retry clears
the error presentation; a nonfatal warning on an active connection stays green.
Background/lifecycle pauses and reduced motion are supported; changing motion
preferences never replays a stale transition. A native connection panel remains
available if WebGL fails.

The Android shell paints one green space background across the viewport, including
the footer. The transparent WebView draws the planet and mascot at device pixel
density with a 4.2-megapixel ceiling. The Earth uses the 1774 × 887 local atlas.
Meteor showers of one to three cross the native star field; motion pauses in
the background and follows reduced-motion preferences. A rightward swipe from
the left half of a page (up to 200 dp in) opens the drawer. With Android gesture
navigation, the central 160 dp of the left edge also opens it. The remaining
edges and modal dialogs retain system Back. Vertical scrolling and taps keep
their normal behavior. WebGL1 textures retain their native dimensions.
Android 10/11 with WebView 83 or older uses the bundled native scene before
attaching the platform view, avoiding a graphics-thread stall on those engines.

Flutter covers the WebView with its moving star field while the bundled assets
and local fonts load. The scene needs native state and two rendered frames at
the same measured viewport before posting readiness. Android then confirms the
WebView's visual state. If the viewport has changed, the scene rejects the old
layout revision and prepares a fresh one. The planet and controls appear only
after this handshake, with motion following the app and system preferences.
After eight foreground seconds, missing readiness shows the native fallback.
The native callback also checks that the Android view size matches the CSS
viewport. Critical asset, JavaScript and WebGL failures can trigger the fallback
earlier. If the renderer process exits, Android discards that WebView and the
Flutter controls take over.
Background loading pauses the deadline. An ES5 bootstrap reports syntax errors
in the scene bundle.
The error caption sits below
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
