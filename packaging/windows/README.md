# Windows packages

`dropo.iss` builds the offline x64 installer with Inno Setup 6. The installer
copies the same immutable application tree used by the portable ZIP, writes the
installed-mode marker, and optionally configures UI autostart and an elevated
per-user background-core task.

The task is deliberately not a LocalSystem service: the core owns user VPN
settings and its authenticated localhost bridge. Running it as SYSTEM would mix
security principals and user profiles.

## Opening after an update

The installed updater passes `--from-update`. After a successful installation,
Setup directly launches the verified `{app}\dropo.exe` launcher, including in
`/VERYSILENT` mode. It does not delegate the executable path to Explorer or wait
for a Finish-page checkbox. Restart Manager relaunch is disabled to avoid a
second, competing UI/core launch. Regular interactive installs retain the
optional “Launch dropo” checkbox; unattended installs without `--from-update`
do not open a window.

`runasoriginaluser` uses the account which started Setup. As documented by Inno,
when Setup was started by an already-elevated core, it cannot recover the
pre-elevation token; the reopened app can inherit elevation. No credentials,
new scheduled task or SYSTEM process are used for this relaunch.

The clean Windows release gate exercises the same silent update arguments and
requires exactly one installed UI process with a visible main window. This test
must not run on a developer's active Dropo installation.

Install Inno Setup 6 before a local release build:

```powershell
winget install --id JRSoftware.InnoSetup -e
```

When `winget` is unavailable, download the current signed installer from
<https://jrsoftware.org/isdl.php> and install it for the current user.
