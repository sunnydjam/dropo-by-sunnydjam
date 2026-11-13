# Android connection scene

The Android home screen embeds `assets/android_home/index.html` in a local
WebView. The Flutter shell, account flow, source consent, Android VPN permission
and CoreBridge remain authoritative. Windows keeps its existing Flutter scene.

`android_animated_home.dart` accepts only a small command vocabulary. Native
state is checked again before dispatching a command. No account tokens, source
URLs, credentials or arbitrary native calls cross this bridge. Navigation is
limited to the bundled entry point and the content security policy disables
network access. Textures are embedded in `art.js` because `file:` images taint
the canvas used to construct the mascot's volume in Android WebView.

The scene waits for the actual native connection. It loops the orbit until
success, reverses on failure/Stop and hides routing controls while disconnected.
Its 10 intermediate sprite cells and distance-weighted timing preserve the
approved DrOppo artwork. Background/lifecycle pauses and reduced motion are
supported; a native connection panel remains available if WebGL fails.

The Android footer opens the real account page with `showTurbo: true`, including
for guests. The destination survives successful sign-in. Purchase capability
and distribution gates remain in the account page; this UI does not enable
payments in a channel that disallows them.

Checks: scene command parser, Android footer and purchase destination, password
sign-in destination, existing connection-race/reconnect and shell tests. Device
verification uses an isolated Android emulator, never a VPN on the Windows host.
