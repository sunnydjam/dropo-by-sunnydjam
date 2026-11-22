# Release signing

Private keys and passwords must never be stored in this repository. Only public
certificate material and fingerprints are committed here.

## Local Android release

Gradle reads `%USERPROFILE%\.dropo-signing\android-signing.properties` by
default. The local publisher uses these values to build and verify the APK:

- `DROPO_ANDROID_KEYSTORE_PATH`
- `DROPO_ANDROID_STORE_PASSWORD`
- `DROPO_ANDROID_KEY_ALIAS`
- `DROPO_ANDROID_KEY_PASSWORD`

The expected release certificate SHA-256 is stored in
`android-release-cert.sha256`.

## Local Windows release

Windows builds are left unsigned when no publicly trusted signing identity is
configured. To sign them, use either a certificate already installed in the
Windows certificate store (`DROPO_WINDOWS_CERT_SHA1`) or:

- `DROPO_WINDOWS_PFX_PATH`
- `DROPO_WINDOWS_PFX_PASSWORD`

Use `-RequireWindowsSigning` (or `DROPO_REQUIRE_WINDOWS_SIGNING=1`) in a release
environment that must fail closed. Self-signed certificates are not bundled or
offered to public users.

For an OSI-licensed, fully open-source release, the preferred free option is the
SignPath Foundation program. Until a project is accepted, unsigned artifacts
are safer and less misleading than installing a private root certificate on a
user's machine.

## GitHub release publishing

1. Promote tested changes from `develop` to `main` through a release pull
   request. Wait for CI to pass on the resulting `main` commit.
2. In GitHub Actions, manually run **Windows package release gate** on `main`.
   It produces the installer, portable archive, source archive and checksums.
3. **Publish Windows Release** verifies the exact commit and downloads the
   packages from that run. The channel in `version.json` determines whether it
   creates a pilot draft or attempts a stable release. Stable releases require
   a publicly trusted publisher signature.

Pull-request package checks never publish. Publication requires successful CI
and a manual package-gate run for the same `main` commit. A newer failed or
pending run takes precedence over an older success.

No private signing keys are configured in this workflow, so these packages
remain unsigned. SHA-256 verification provides integrity checking, not a
publicly trusted publisher identity. Android is not published by this workflow.

For an explicitly approved local release, `tools/publish-release-assets.ps1`
uploads locally built and validated artifacts using `GH_TOKEN` or the local
Git credential manager. It does not upload private signing material to GitHub.
