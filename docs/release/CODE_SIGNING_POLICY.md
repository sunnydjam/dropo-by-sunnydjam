# Code signing policy

The canonical source and release location for this fork is
[`sunnydjam/dropo-by-sunnydjam`](https://github.com/sunnydjam/dropo-by-sunnydjam).
The upstream source is [`Droponevedimka/dropo`](https://github.com/Droponevedimka/dropo). Release
artifacts are produced by the versioned build scripts in this repository and
must pass the repository's manifest, SHA-256, clean-Windows and Microsoft
Defender gates before publication.

For the owner-approved Windows 4.0.3 release, the local build uses the project’s self-signed Authenticode certificate with a timestamp. The release notes disclose its limited trust. The manual package gate verifies the certificate SHA-256 against the pin in tools/verify-project-windows-signature.ps1 for the installer, launcher, UI and core. The automatic stable publisher requires a publicly trusted signing identity. The project never asks users to install a private root certificate
and never presents a self-signed executable as a trusted public release.

This fork does not currently claim participation in an external signing
program. A signing provider and its required attribution will be documented
before a signed public release is published. A release is considered signed
only when Windows shows a valid publicly trusted Authenticode signature.

## Roles and controls

- upstream author: [Droponevedimka](https://github.com/Droponevedimka);
- fork maintainer and signing approver: [sunnydjam](https://github.com/sunnydjam);
- changes from external contributors require maintainer review;
- every signing request requires manual approval;
- source repository and signing accounts must use multi-factor authentication;
- upstream binaries may be included and described by the SBOM, but are never
  re-signed as if they were authored by dropo.

See the [privacy policy](../../PRIVACY.md), [MIT license](../../LICENSE), release SHA-256
files, SPDX SBOM and build provenance included with each release.
