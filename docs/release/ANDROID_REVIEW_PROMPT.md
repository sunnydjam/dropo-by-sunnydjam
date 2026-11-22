# Android Google Play review request

Automatic eligibility is unchanged: three completed successful VPN cycles or
one uninterrupted24-hour native service session. Elapsed realtime includes
sleep/background time, without a new alarm, network probe or backend request.

## Google Play edition

The `com.dropo.myapp` Play build uses Google's official In-App Review2.0.2 SDK
without our preliminary dialog. Request ReviewInfo only at an eligible foreground
home screen; recheck foreground/UI readiness before reserving and launching.
A10-second preparation timeout discards late results; ReviewInfo is short-lived.
Native code confirms the durable reservation immediately before Google's launch.
Google owns its card; do not alter, overlay, auto-dismiss or replace it.

A completed launch task does not tell whether the card appeared or a review was
submitted. Quota suppression therefore consumes the one-time launch budget too.
No automatic repeat, custom dialog or Play/browser fallback follows a launch,
including SDK errors. Known preparation failure never used the launch budget;
it stays silent and suppresses retry for this UI instance. A new instance may
retry preparation. Background/UI changes before launch release only the owning
unpresented reservation. An already confirmed request cannot be released.

The existing `dropo_review_prompt` preferences/key names are preserved. Users
who already saw the3.1.3 dialog are not asked again after updating. Restarts,
updates, logout and traffic-stat resets preserve the flag. Clearing all app data
or uninstalling without data restoration removes local preferences. No
cross-reinstall identity is collected.

## Manual button and other distributions

About has an Android review button. It opens the canonical listing with an
ACTION_VIEW Intent pinned to com.android.vending; if no store handler exists,
it uses the HTTPS/browser fallback. Manual buttons never call the quota-limited
review SDK. The listing URL is
https://play.google.com/store/apps/details?id=com.dropo.myapp. This is a listing,
not a documented direct review editor link. No undocumented review query
parameters are used.

Sideload/preview application IDs differ from the registered Play package. They
retain the optional one-time link dialog and never launch an SDK review for
the wrong application ID. They use the same documented store/browser link.

## Verification limits

Native engagement/store-link tests and Flutter coordinator/UI tests cover
thresholds, foreground deferral, concurrency, storage failure, no preliminary
Play dialog, no forced fallback, both manual link outcomes and existing flags.
FakeReviewManager tests validate SDK wiring and lifecycle handling in an owned
emulator. FakeReviewManager shows no card and submits no review; it is not proof
of real Google UI or account eligibility. Final real-card acceptance requires
an eligible Google Play account and an internal-track installation; internal
app sharing can show a card but disables submission. No Play upload/publication
is implied by local tests.

Sources checked2026-11-06:
- https://developer.android.com/guide/playcore/in-app-review
- https://developer.android.com/guide/playcore/in-app-review/kotlin-java
- https://developer.android.com/guide/playcore/in-app-review/test
- https://developer.android.com/distribute/marketing-tools/linking-to-google-play
