# First-connection beta and recovery checklist

This is a developer QA procedure and a proposal for a small, voluntary beta of
20–30 people. It does not launch a beta, recruit or contact anyone, enable
telemetry, change application behavior, or authorize a release. It complements
the automated release gates; it cannot replace them.

The product question is: can a new user connect, understand what is working,
and find a useful next step without the developer guiding each click?

## Privacy and participation

- Participation is explicit and optional. Explain the questions beforehand;
  declining or withdrawing must not affect Free or personal subscriptions.
- Telegram registration is not required. Do not ask participants to sign in
  merely to test first connection or to submit feedback.
- Keep the policy in `PRIVACY.md`: no automatic analytics, telemetry, crash
  uploads, background beta reporting, or silent collection of clipboard data.
- Measure manually on the device or observe with the participant's agreement.
  A participant can decline any measurement or report.
- Keep aggregate counters only. Do not collect subscription URLs, access keys,
  VPN credentials, source/node names, IP addresses, visited URLs, raw errors,
  logs, file paths, screenshots containing private data, Telegram identities,
  phone numbers, device identifiers, or lists of installed applications.
- Use optional broad device groups for coverage, not unique device IDs. Do not
  join outcomes to account data. Report small groups cautiously: this sample
  is directional usability evidence, not a population reliability estimate.
- Day-7 feedback is an optional user-initiated response. No tracking token,
  automatic follow-up, account linkage, or notification campaign is implied.

## What to measure manually

Record an outcome only after consent, then increment aggregate counters. Use
coarse time buckets (`under 30 s`, `30–60 s`, `1–3 min`, `over 3 min`,
`not completed`) rather than storing timestamps or individual sessions.

| Question | Allowed aggregate outcome | Interpretation |
| --- | --- | --- |
| First connection without coaching | completed / needed help / not completed / declined | Count completion only after the source is enabled and the system permission is granted. A deliberate permission refusal is not an engine failure. |
| Time from first launch to engine-ready state | time bucket, or not completed | Includes navigating the source choice and consent. Report separately from actual service usability. |
| Time from first launch to a usable service | time bucket, or not completed | The participant verifies one intended task in their app, such as loading a video or joining voice. Do not store the app name, destination, content, or identity. |
| Need for support | none / first-run source choice / permission / source unavailable / network change / service routing / update / interface unclear / other | Record a category, not copied raw errors or private technical details. |
| Optional day-7 use | used / not used / declined; number of replies | Describe this as self-reported use among replies, not verified cohort retention. Silence is unknown, not a negative answer. |

Keep denominators visible: people who volunteered, people who consented to the
measurement, completed trials, failures, deliberate refusals, and unknown
outcomes. Do not remove failed trials to improve the apparent success rate.
Do not equate completed registration or an account count with product success.

## Before inviting volunteers

- [ ] Flutter analysis and the complete automated test suite pass on the exact
  candidate commit; first-run, support-summary, response freshness and updater
  regression tests are included.
- [ ] Applicable Go/native tests and existing Windows/Android release gates
  pass. Routing classification changes still require Windows packet emulation
  and Android route ordering regressions.
- [ ] A clean installation, a same-channel update and a reconnect have been
  exercised on physical hardware. An emulator or a widget test is not evidence
  of Poco/HyperOS background behavior.
- [ ] At least one physical Poco F5/HyperOS, one Samsung device and one Pixel
  device are covered if available. If a device is unavailable, mark it untested
  rather than claiming compatibility. Record only broad, consented device/OS
  categories in volunteer aggregates.
- [ ] Android 10+ and both supported ARM families are represented in automated
  build checks; physical-device claims cover only devices actually tested.
- [ ] No purchase or speed-priority claim is used as proof of paid infrastructure.
  Free availability, latency and performance are not guaranteed.
- [ ] No P0/P1 issue below is open. A release remains a separate authorized step.

## Physical-device and Windows scenarios

Run source and mode scenarios for both `all_traffic` (Everything through VPN)
and `blocked_only` (Selected services). A fresh installation defaults to
`all_traffic`; later choices must survive restart and a same-channel update.

| Scenario | Required observation |
| --- | --- |
| Fresh Android installation, no sources | Connect is reachable. It opens the source choice in either mode, not a red error directing the user elsewhere. There is no automatic import and no Telegram window. |
| Fresh Windows installation, no sources | Full-VPN connection asks for a source. The explicit source-free selective alternative remains available; selecting it does not connect implicitly. |
| Accept Free | The operator disclosure is visible before the affirmative action. Only that action adds the managed source. A successful import is rechecked before connection; registration is not requested. |
| Decline or close the source choice | No source is fetched/imported or enabled, no connection starts, and the selected routing mode is unchanged. Reading catalog metadata is not importing the subscription. |
| Free unavailable, offline, or failed import | Own-source and retry paths remain understandable. Do not silently switch full-VPN traffic to Direct, claim success, or require an account as a workaround. |
| Own subscription | Import uses the participant's local data without sending it to support. Connect uses the enabled authoritative source list. No hidden sibling-node rotation is introduced. |
| All sources disabled | They remain disabled. The UI offers opening Sources; it must not enable them or insert Free automatically. |
| Android VPN permission refused | No false connected state. The UI leaves an actionable retry path; a later deliberate grant can connect without reinstalling or re-importing an already enabled source. |
| Rapid taps, Back, dismiss, screen change | A source import or connection is not duplicated. Late async results do not navigate a disposed page or revive a stopped session. |
| Switch modes and restart | The user's saved choice survives. Selective routing preserves explicit Direct/VPN choices; the source wizard does not silently select a different mode. |
| Selected-services real usage | Exercise one intended service plus one explicitly Direct/excluded app. Direct traffic remains direct; a good source HTTP response alone is not route proof for either app. |
| Wi-Fi → mobile → Wi-Fi | Existing session maintenance runs in the background. Observe usable traffic and the app's honest state, not just a green planet. No source sibling node is silently changed. |
| Sleep / background / resume | Check short sleep and a longer idle period on Poco/HyperOS, Samsung and Pixel. Record an OEM/background issue honestly; do not disable battery protections or enable system lockdown globally without an explicit user choice. |
| Physical network loss then recovery | No stale latency is presented as current. Observe whether the current app recovers, needs a deliberate reconnect, or remains unusable. Do not assume that “engine connected” proves internet reachability. |
| Disconnect during background work | Stop remains authoritative. No stale strategy/source check restarts the engine or commits a result from the previous session. |
| Small display / large text | Source choice, consent, Free/own actions, guided help and support preview remain reachable at 320 px width and 200% text scaling. No clipped primary action or added tooltip is needed to explain the flow. |

Keep work-network/WireGuard and private-destination precedence in the Windows
regression suite. The beta is not permission to route private/work traffic via a
public source or to alter the packet engine. Android system Always-on/lockdown
and excluded-app/LAN interactions need separate explicit testing; do not claim
lockdown is safe for all modes. Windows does not currently have an integrated
kill-switch enforcement path, so do not claim that the beta adds one.

## Updates and channel migration

- [ ] Checking for a version is separate from installing it. The user chooses
  installation; a visible download/verification/install state follows.
- [ ] Android's verified APK opens the system installer. An opened installer is
  not proof of completed installation; require a post-install version check.
- [ ] Reject wrong package/channel, unsupported architecture, non-newer version,
  signature mismatch, size/checksum mismatch and unsafe download locations.
  Do not ask volunteers to weaken these checks.
- [ ] Denying the per-app installation permission or cancelling the installer
  leaves the existing installation usable. A download error must not be shown
  as a connection-wide VPN failure.
- [ ] Same-channel, same-package, same-signing-identity installation preserves
  local settings and the saved mode. Warn that replacing the running Android
  app can interrupt VPN traffic; do not promise a seamless tunnel handover.
- [ ] An older Android build that only opens the browser needs one deliberate
  manual installation of the current APK **of the same channel** over the app.
  Do not recommend uninstalling first.
- [ ] Android Preview and the normal channel use different package identities.
  Preview → normal is a separate install/migration, not an in-place update.
  Do not rotate a signing key or claim local data transfers automatically.
  Until a migration workflow exists, preserve the working Preview installation
  and explain that any source/settings setup in the other app is manual and
  local; do not collect credentials to perform it remotely.

## Understanding checks and recovery

“Connected” describes the engine/session state. The source-response tile is a
scoped HTTP observation, not ICMP, gaming ping, download speed, a privacy test,
or proof that every service works. One failed HTTP target does not prove that
the entire internet is down; unknown and stale results prove neither success
nor failure. Keep pending/failed/stale states distinct.

Guided Help reuses the read-only connection check after the user's click. It
must not retune strategies, alter source or route settings, disconnect, restart,
or invoke a mutating quick-check as a fallback. Network probes still contact
their configured test endpoints; “read-only” means no configuration/runtime
mutation, not zero network activity.

Check all three help paths: no internet, one service unavailable, and update
unavailable. Recommendations should point to one appropriate next page without
silently carrying out that action. A check timeout or changed session must not
render late/stale data as a current result or globally disable settings.

## Reporting a problem safely

1. Open Help → Solve a problem (`Решить проблему`) and choose a situation.
2. If appropriate, start the read-only check yourself. Reproduce any usability
   issue using the intended app, not only the HTTP probe result.
3. Open the local **Report for help** preview (`Отчёт для помощи`) and inspect
   it before choosing Copy. No report is uploaded by the app.
4. If you consent, manually share that summary plus short, non-private steps,
   expected behavior and observed behavior. Never attach a subscription, key,
   raw log, address, full diagnostic dump, or account/Telegram identity.

The allowlist summary in `flutter_app/lib/guided_help.dart` contains only a
strictly validated version, coarse platform/scenario/mode/runtime codes,
boolean engine flags, and aggregate counts from a current, session-valid
HTTP-check report. It excludes arbitrary backend strings, endpoint/source/node
names, paths, logs, raw errors and user identifiers. Raw diagnostic/log pages
may still contain sensitive data; their existing copy action is **not** the safe
beta-report path. Opening a preview or copying it does not authorize sending it.

## Severity and decision gates

| Severity | Examples | Beta/release decision |
| --- | --- | --- |
| P0 — safety/privacy breach | Secrets or raw diagnostics exported without consent; wrong verified route/private-work traffic escapes to a public VPN; a stopped session is restarted by stale work | Stop affected testing and distribution; investigate and fix before resuming. Do not upload private evidence publicly. |
| P1 — core flow broken | A supported physical device cannot reach Connect, repeated crash/start loop, false connected result after permission refusal, settings lost on a supported same-channel update, confirmed routing policy regression | Block release and further broad beta expansion until fixed and reproduced as passing. |
| P2 — recoverable product problem | Unclear source choice, poor failure guidance, recovery requires unexplained reconnect, large-text layout issue with an available workaround | Track, reproduce and prioritize; do not describe the affected scenario as passed. |
| P3 — minor polish | Non-blocking wording or spacing issue | Track without masking higher-priority failures. |

For this first small beta, use a **provisional product target** of at least 90%
independent first-connection completion among completed, consented trials with
an available source and permission granted. Always publish the raw aggregate
counts and excluded/unknown categories alongside the percentage. This is an
internal improvement target, not an availability SLA or a compatibility claim.
Review time buckets, support categories and optional day-7 replies to choose
the next change; do not optimize only the percentage.

Expansion requires no open P0/P1 findings, successful physical-device coverage
of the critical scenarios above, passing applicable automated gates, and honest
known-issue notes for P2 or untested hardware. Failing the usability target calls
for another focused iteration; it does not justify forced registration, covert
measurement, automatic configuration changes, or premature paid-VPN claims.
