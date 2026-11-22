# Contributing

Create feature branches from `develop`, open pull requests against it, and
test locally from `origin/develop`. Promote tested changes to `main` through
a release pull request. CI and the Windows package checks run on pull requests
to both branches. A push or merge does not publish a release.

Use these commands to switch an existing clone to the development branch.

```powershell
git fetch origin
git switch develop
git pull --ff-only
```

## Before opening a change

1. Do not commit VPN subscriptions, private keys, access tokens or raw user logs.
2. Preserve the direct-first routing contract: unknown traffic must pass
   unchanged and private/work-network routes must not leak into public VPN.
3. Keep one in-process Windows WinDivert owner. Do not add downloaded scripts,
   external anti-DPI executables, Lua or Cygwin to the Windows traffic path.
4. Add focused tests for every classifier, strategy or routing-plan change.
5. Keep upstream and third-party notices intact.

## Checks

```powershell
pwsh -File .\tools\check-powershell-syntax.ps1
pwsh -File .\tools\check-clean-contributors.ps1
Push-Location .\app
go test ./...
Pop-Location
Push-Location .\flutter_app
flutter pub get
flutter analyze
flutter test
Pop-Location
```

For a Windows release build:

```powershell
pwsh -File .\scripts\build\build.ps1 -AppOnly
```

Then run `tools/preflight-release.ps1` against the generated release folder.
For the GitHub release procedure, see [Release signing](signing/README.md#github-release-publishing).

Explain the affected traffic policy, expected direct/VPN behavior and test
evidence in the pull request. Security issues should follow
[SECURITY.md](SECURITY.md).
