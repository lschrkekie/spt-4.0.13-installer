# spt-4.0.13-installer

Automates the manual SPT 4.0.13 install (pinned version, not whatever
forge.sp-tarkov.com/installer currently ships — that always installs the
latest branch, currently 4.1.2).

Sources, per https://wiki.sp-tarkov.com/en/SPT_40/Manual-Installation-Instructions_40
and https://github.com/sp-tarkov/build/releases/tag/4.0.13:

- Downgrade patcher: `Patcher_1.1.0.0.46657_to_16.9.0.40087.7z` (~7 GB)
- SPT release archive: `SPT-4.0.13-40087-2891fd4.7z` (~220 MB)

Both hosted on `spt-patches.modd.in`.

## Quick start (Windows)

Run from an elevated PowerShell prompt:

```powershell
irm https://raw.githubusercontent.com/lschrkekie/spt-4.0.13-installer/main/install-spt-4.0.13.ps1 | iex
```

With no arguments it:

- looks for a retail EFT install in a few common locations (`C:\Battlestate
  Games\Escape from Tarkov`, `C:\Battlestate Games\EFT`, common Steam
  library paths) and uses the first one found
- installs into `C:\Games\SPT` by default

If none of the default locations match, or you want a different target,
download the script and run it with explicit parameters instead (piping to
`iex` doesn't accept parameters):

```powershell
iwr https://raw.githubusercontent.com/lschrkekie/spt-4.0.13-installer/main/install-spt-4.0.13.ps1 -OutFile install-spt-4.0.13.ps1
.\install-spt-4.0.13.ps1 -RetailPath "D:\Games\Escape from Tarkov" -InstallPath "D:\Games\SPT"
```

## Requirements

- A working retail EFT install on version `1.1.0.0.46657`. If your retail
  copy is newer, the patcher will not match and the patch step fails
  (this is an upstream constraint, not something the script can fix).
- 7-Zip (`7z`) on PATH, or pass it explicitly.
- Windows: PowerShell 5.1+.
- Linux: bash, curl, p7zip, and `wine` for the patch step (patcher.exe is a
  Windows binary). Without wine, everything runs except the actual patch.
  No auto-detection of the retail path on Linux — always pass
  `--retail-path` explicitly, there's no single standard location.

## Usage

Windows:

```powershell
.\install-spt-4.0.13.ps1
# or explicitly:
.\install-spt-4.0.13.ps1 -RetailPath "C:\Battlestate Games\Escape from Tarkov" -InstallPath "C:\Games\SPT"
```

Linux:

```bash
./install-spt-4.0.13.sh --retail-path "$HOME/.steam/steam/steamapps/common/EscapeFromTarkov"
# installs into ~/Games/SPT by default
```

Both scripts are idempotent-ish: downloads resume/skip if already present
with matching size, and `--skip-copy` / `--skip-patch` / `--skip-release` /
`--skip-verify` let you resume after a failure without redoing earlier
steps.

## Source completeness check

Before copying (or before patching, if `--skip-copy`/`-SkipCopy` was used),
the script lists every `.delta` entry in the downloaded patcher archive and
checks that a matching file exists in the source folder. This is a
**presence check, not a hash/content check** — BSG doesn't publish an
official per-file hash list for this build, so this can't be a full
integrity verification. It does catch the most common real-world failure
mode: a file silently missing from the source copy.

Skip it with `-SkipVerify` / `--skip-verify` if you've already confirmed
your source is fine and just want to save the couple of seconds it takes.

## Known failure mode this script guards against

If `UnityCrashHandler64.exe` is missing from the copied files, the patcher
fails with:

```
Failed to find matching source file for '...\UnityCrashHandler64.exe.delta'
```

This file is a common antivirus false-positive target. The completeness
check above catches this (and any other missing file) before the patcher
runs, instead of failing midway through applying deltas.
