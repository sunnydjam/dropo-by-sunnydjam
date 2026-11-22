# Android scene regression checks

Run from this directory with Node 20 or newer:

```sh
npm ci --ignore-scripts
npx --no-install playwright install chromium
npm test
```

Alternatively, set `DROPO_TEST_BROWSER` to an existing Chromium/Chrome executable.
The CI job installs its pinned Playwright Chromium build, including Linux system
dependencies. Test dependencies are development-only and never enter the app.

The fixture serves the real `flutter_app/assets` over loopback, feeds synthetic
native connection states and captures outgoing bridge commands. External page
requests are rejected. It never starts a VPN or accesses production accounts.

Coverage includes immediate success and native busy gates, cancellation/retry,
native uptime corrections, background rendering pause, reduced motion, original
mascot assets, failed resources/runtime errors and small/landscape error layouts.
Flutter tests cover the native readiness timeout and fallback dispatch. These
checks complement Android device/WebView testing; they do not replace it.
