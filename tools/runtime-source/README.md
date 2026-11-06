# Bundled runtime source build

The Windows sidecars retain the reviewed sing-box 1.14.4 and Xray 26.10.31
upstream source releases. This module overrides vulnerable transitive versions
and builds with Go 1.27.3. It does not modify upstream module-cache source files.
The sing-box feature tags match the reviewed official Windows binary.

`runtime.lock.json` pins the upstream module checksums, complete go.mod/go.sum
bytes, build flags and expected PE hashes. From the repository root run:

```powershell
pwsh -File tools/build-runtime-source.ps1 -Component singbox
pwsh -File tools/build-runtime-source.ps1 -Component xray
```

These commands compile or verify files under `dependencies`; they never install
the application or change network settings. Unknown existing executable bytes
are refused, and reviewed original binaries are retained before replacement.
The normal Windows build calls both commands and packages their license texts.
Do not run `go mod tidy` here: this module builds dependency CLI entry points
directly and intentionally has no local Go package.

The release also accompanies the binaries with `dropo-Runtime-Sources.zip`.
It contains all module source archives selected by the actual Windows package
graphs, their checksums/licenses, this build recipe and the reviewed lock.
Each upstream zip retains its original module path and version. `modules.json`
maps each zip to its Go module checksum and SHA-256. Source code and licenses
remain under their respective upstream terms, including sing-box GPL-3.0 and
Xray MPL-2.0. The Go toolchain is obtained through Go's authenticated toolchain
distribution. Android has its separate module graph and verified MPL overlay.

Dependency security results apply to a concrete scanned binary and database
snapshot; they do not replace client compatibility tests or future monitoring.
