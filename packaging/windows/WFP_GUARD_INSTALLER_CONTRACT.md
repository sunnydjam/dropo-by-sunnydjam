# DropoWFPGuard installer contract (not yet implemented)

Current `dropo.iss` does **not** register, start, update or remove a WFP guard
service. Opt-in builds may package a signed, manifest-pinned guard executable as
an inert runtime file. This is not an installed kill switch. The portable ZIP
contains the same inert runtime but has no service lifecycle and must not claim
protection. `vpnProtection.active` must remain false.

Before service registration is enabled, the installer implementation and clean
Windows 10/11 VM tests must establish the following sequence. Treat every
failed check as a hard stop; never continue an upgrade with an unverified
ImagePath or delete an old runtime merely to make room.

1. Verify the installer, signed core and guard use the same Windows-trusted
   publisher. Verify the guard's exact size and SHA-256 through the runtime
   manifest whose SHA-256 is pinned in the signed core. The current opt-in
   build gate checks these relationships; a standalone preflight using only the
   adjacent manifest is supplemental, not independent proof of core binding.
2. Resolve ProgramData via the Windows known-folder API. Stage the guard only
   under `%ProgramData%\dropo\runtime\<validated-version>\bin\dropo-wfp-guard.exe`,
   after checking every path component and applying the existing protected
   runtime ACL. Never execute from `%TEMP%`, Program Files, a downloaded path,
   a relative path or an untrusted reparse point.
3. Determine the intended interactive user SID from the install session and
   pin it in the service's protected configuration. Reject missing or ambiguous
   SIDs; do not accept a SID supplied by an unauthenticated UI message. A
   machine-wide filter scope still needs this SID to authorize control of
   arm/disarm requests, not to narrow the egress deny.
4. Before reading or changing the SCM ImagePath, acquire
   `Global\DropoWFPRuntimeMigration` with a bounded wait. Its DACL must allow
   SYSTEM, Administrators and the pinned user the rights used by the core.
   Hold the same mutex through signed-file verification, SCM change, service
   restart/readback and rollback decision. The user core already acquires it
   across service-path readback and old-runtime cleanup. A setup process that
   ignores this lock reintroduces a deletion race.
5. On upgrade, retain the old verified service binary and its runtime until
   the new service is running, reports the expected binary/revision, and WFP
   readback confirms the required IPv4 and IPv6 deny objects. Preserve the
   previous persistent deny throughout migration. If migration fails, restore
   the old SCM ImagePath under the mutex and verify the old guard resumes; if
   that cannot be proven, leave old files and policy intact and fail closed.
   Do not silently report a successful installation.
6. Uninstall must be an explicit protection-disable operation: authenticate
   the requested owner, transactionally remove **only Dropo-owned** WFP
   provider/sublayer/filters, verify absence, then stop/delete only the exact
   `DropoWFPGuard` SCM service and retire its runtime under the migration lock.
   If the service or BFE is unavailable, leave the persistent deny and the
   binary intact, report that manual recovery is required, and provide a
   separately signed recovery path. Never delete the guard first.

Release VM cases: clean install; same-user and different-user upgrade; silent
upgrade; timeout acquiring migration lock; service start failure; ImagePath
tampering; guard hash/signature mismatch; rollback with active persistent
policy; uninstall when BFE is unavailable; abandoned mutex; concurrent core
cleanup; reboot after each failure. Capture SCM ImagePath, service state, owned
WFP GUIDs, filter revision and physical IPv4/IPv6 egress evidence after every
transition. The installer must not be enabled by a build flag alone before
these cases pass.
