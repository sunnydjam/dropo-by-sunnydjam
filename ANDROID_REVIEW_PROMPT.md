# Android review request

The Android home screen may ask once for an optional Google Play review after
either three completed successful VPN connect/disconnect cycles or one
uninterrupted 24-hour VPN session. The button opens exactly
`https://play.google.com/store/apps/details?id=com.dropo.myapp`.

The native service starts the session clock only after the engine is active.
Only a successful explicit stop (app or notification) completes a cycle.
Failed starts, revoked permission, service destruction and duplicate callbacks
do not count. An interrupted session is not restored after process death.
Short sessions are not summed for the 24-hour alternative. The duration uses
Android elapsed realtime, so changes to the calendar or timezone do not help
reach the threshold. Session tracking continues while Flutter is paused.

Presentation waits for the foreground home route with no connection operation,
error or other dialog. A background session that becomes eligible is checked
on the next foreground refresh. There is no alarm, notification permission,
extra network probe, analytics call, rating reward or positive-rating filter.

Native private SharedPreferences contain the bounded cycle count, eligibility
and `shown` flag. The flag is committed before presentation; a rejected durable
write does not authorize a prompt. Once claimed, dismissal, Back, decline and
failed Play Store navigation never enable another automatic request. Native
claims are synchronized and Flutter refreshes are serialized. A crash in the
small interval after claim can omit the prompt; preventing repeat requests takes
priority. These preferences survive app restarts, updates, logout and resetting
traffic statistics, and are independent of account/managed-profile deletion.
Explicitly clearing app data or uninstalling without restored app data removes
local preferences, including this flag; cross-reinstall identity is not collected.

`ReviewPromptTrackerTest` covers cycle thresholds, failures, duplicate callbacks,
the exact 24-hour boundary with an injected monotonic clock, short sessions,
restart persistence, concurrent claims and failed writes. `review_prompt_test.dart`
covers foreground deferral, persistence-before-presentation, concurrent refresh,
bridge failures, both buttons, the exact Play URL, Back and small-screen layout
with large text. No test submits a real Google Play review.
