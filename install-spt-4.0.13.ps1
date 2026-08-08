#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RetailPath,

    [string]$InstallPath = "C:\Games\SPT",

    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA "spt-4.0.13-installer\cache"),

    [string]$SevenZipPath,

    [switch]$SkipCopy,
    [switch]$SkipPatch,
    [switch]$SkipRelease,
    [switch]$SkipVerify,
    [switch]$AddDefenderExclusion
)

$ErrorActionPreference = "Stop"

$PatcherUrl  = "https://spt-patches.modd.in/Patcher_1.1.0.0.46657_to_16.9.0.40087.7z"
$PatcherName = "Patcher_1.1.0.0.46657_to_16.9.0.40087.7z"
$ReleaseUrl  = "https://spt-patches.modd.in/SPT-4.0.13-40087-2891fd4.7z"
$ReleaseName = "SPT-4.0.13-40087-2891fd4.7z"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-SevenZip {
    if ($SevenZipPath) {
        if (Test-Path -LiteralPath $SevenZipPath) { return $SevenZipPath }
        throw "7z.exe not found at -SevenZipPath '$SevenZipPath'."
    }
    $candidates = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "7-Zip not found. Install it from https://www.7-zip.org/ or pass -SevenZipPath."
}

function Find-RetailInstall {
    # Best-effort: only checked against the exact layout the BSG launcher
    # and Steam use on this machine's setup. Not a guaranteed detection —
    # if none of these match, pass -RetailPath explicitly.
    $candidates = @(
        "C:\Battlestate Games\Escape from Tarkov",
        "C:\Battlestate Games\EFT",
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\EscapeFromTarkov",
        "$env:ProgramFiles\Steam\steamapps\common\EscapeFromTarkov"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $c "EscapeFromTarkov.exe")) { return $c }
    }
    return $null
}

function Get-FileWithResume {
    param(
        [string]$Url,
        [string]$Destination
    )
    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $head = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
    $expectedLength = [int64]$head.Headers["Content-Length"]

    if (Test-Path -LiteralPath $Destination) {
        $existing = Get-Item -LiteralPath $Destination
        if ($existing.Length -eq $expectedLength) {
            Write-Host "Already downloaded, size matches: $Destination"
            return
        }
        Write-Host "Partial or stale file found ($($existing.Length) of $expectedLength bytes), removing and restarting."
        Remove-Item -LiteralPath $Destination -Force
    }

    Write-Host "Downloading $Url"
    Write-Host "  -> $Destination ($([math]::Round($expectedLength / 1MB, 1)) MB)"

    $bitsAvailable = Get-Module -ListAvailable -Name BitsTransfer
    if ($bitsAvailable) {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "spt-4.0.13-installer"
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }

    $final = Get-Item -LiteralPath $Destination
    if ($final.Length -ne $expectedLength) {
        throw "Download incomplete: got $($final.Length) bytes, expected $expectedLength. Re-run the script to resume."
    }
}

function Test-PatchSourceCompleteness {
    param(
        [string]$SevenZip,
        [string]$Archive,
        [string]$SourceRoot
    )
    Write-Step "Checking source files against patcher manifest (file presence, not a full hash check)"
    Write-Host "No official per-file hash list is published for this build, so this only confirms"
    Write-Host "every file the patcher expects to touch actually exists in '$SourceRoot'."

    $listing = & $SevenZip l -slt $Archive
    $missing = New-Object System.Collections.Generic.List[string]
    $checked = 0
    $prefix = "SPT_Patches\"

    foreach ($line in $listing) {
        if ($line -notmatch '^Path = (.+\.delta)$') { continue }
        $deltaPath = $Matches[1]
        if (-not $deltaPath.StartsWith($prefix)) { continue }
        $relative = $deltaPath.Substring($prefix.Length)
        $relative = $relative.Substring(0, $relative.Length - ".delta".Length)
        $checked++
        if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot $relative))) {
            $missing.Add($relative)
        }
    }

    Write-Host "Checked $checked expected source files."
    if ($missing.Count -gt 0) {
        Write-Warning "$($missing.Count) expected source file(s) missing from '$SourceRoot':"
        $missing | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        if ($missing.Count -gt 20) { Write-Host "  ... and $($missing.Count - 20) more" -ForegroundColor Yellow }
        throw "Source integrity check failed: $($missing.Count) file(s) missing. Common cause: " +
              "antivirus quarantine. Check quarantine/log, or run 'Verify/Repair Game Files' in the " +
              "BSG Launcher, then re-run this script (add -SkipVerify to bypass once you've confirmed " +
              "it's a false positive)."
    }
    Write-Host "All expected source files present."
}

Write-Step "Checking prerequisites"
$sevenZip = Resolve-SevenZip
Write-Host "7-Zip: $sevenZip"

if (-not $SkipCopy -and -not $RetailPath) {
    $detected = Find-RetailInstall
    if ($detected) {
        $RetailPath = $detected
        Write-Host "Auto-detected retail install: $RetailPath"
    }
    else {
        throw "No -RetailPath given and none of the known default locations were found. " +
              "Pass -RetailPath explicitly."
    }
}

if (-not $SkipCopy) {
    $retailExe = Join-Path $RetailPath "EscapeFromTarkov.exe"
    if (-not (Test-Path -LiteralPath $retailExe)) {
        throw "RetailPath '$RetailPath' does not look like an EFT install (missing EscapeFromTarkov.exe)."
    }
}

if (-not (Test-Path -LiteralPath $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

if ($AddDefenderExclusion) {
    Write-Step "Adding Windows Defender exclusions"
    try {
        Add-MpPreference -ExclusionPath $InstallPath -ErrorAction Stop
        if (-not $SkipCopy) { Add-MpPreference -ExclusionPath $RetailPath -ErrorAction Stop }
        Write-Host "Exclusions added. Existing quarantined files are not restored automatically."
    }
    catch {
        Write-Warning "Could not add Defender exclusions (needs admin PowerShell): $($_.Exception.Message)"
    }
}

Write-Step "Downloading patcher and SPT 4.0.13 release archive"
$patcherArchive = Join-Path $CacheDir $PatcherName
$releaseArchive = Join-Path $CacheDir $ReleaseName
Get-FileWithResume -Url $PatcherUrl -Destination $patcherArchive
if (-not $SkipRelease) {
    Get-FileWithResume -Url $ReleaseUrl -Destination $releaseArchive
}

if (-not $SkipVerify -and -not $SkipPatch) {
    $verifyRoot = if ($SkipCopy) { $InstallPath } else { $RetailPath }
    Test-PatchSourceCompleteness -SevenZip $sevenZip -Archive $patcherArchive -SourceRoot $verifyRoot
}

if (-not $SkipCopy) {
    Write-Step "Copying retail game files into $InstallPath"
    $robocopyArgs = @($RetailPath, $InstallPath, "/E", "/R:2", "/W:2", "/NFL", "/NDL", "/NJH", "/NJS")
    $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ge 8) {
        throw "robocopy failed with exit code $($proc.ExitCode)."
    }

    $crashHandler = Join-Path $InstallPath "UnityCrashHandler64.exe"
    if (-not (Test-Path -LiteralPath $crashHandler)) {
        throw "UnityCrashHandler64.exe is missing from '$InstallPath' after copy. " +
              "This file is a common antivirus false-positive target and often gets quarantined or " +
              "silently skipped during copy. Check your antivirus quarantine/log, restore or re-copy " +
              "it manually, then re-run with -SkipCopy."
    }
}

if (-not $SkipPatch) {
    Write-Step "Extracting patcher into $InstallPath"
    & $sevenZip x $patcherArchive "-o$InstallPath" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to extract patcher archive (exit $LASTEXITCODE)." }

    Write-Step "Running patcher.exe (this can take a while for large bundle files)"
    $patcherExe = Join-Path $InstallPath "patcher.exe"
    if (-not (Test-Path -LiteralPath $patcherExe)) {
        throw "patcher.exe not found in '$InstallPath' after extraction."
    }
    $proc = Start-Process -FilePath $patcherExe -WorkingDirectory $InstallPath -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "patcher.exe exited with code $($proc.ExitCode)."
    }

    $log = Get-ChildItem -LiteralPath $InstallPath -Filter "Log_*.txt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        $exceptions = Select-String -Path $log.FullName -Pattern "EXCEPTION" -SimpleMatch
        if ($exceptions) {
            Write-Warning "Patcher log contains exceptions, review before continuing:"
            $exceptions | ForEach-Object { Write-Host "  $($_.Line)" -ForegroundColor Yellow }
            throw "Patching failed, see $($log.FullName). Fix the underlying issue and re-run with -SkipCopy -SkipPatch:`$false."
        }
    }
    Write-Host "Patch applied cleanly."
}

if (-not $SkipRelease) {
    Write-Step "Extracting SPT 4.0.13 release archive into $InstallPath"
    & $sevenZip x $releaseArchive "-o$InstallPath" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to extract SPT release archive (exit $LASTEXITCODE)." }
}

Write-Step "Done"
$sptFolder = Join-Path $InstallPath "SPT"
Write-Host "Install target: $InstallPath"
Write-Host "Next steps:"
Write-Host "  1. Open '$sptFolder'"
Write-Host "  2. Run SPT.Server.exe, wait for 'Server has started, happy playing'"
Write-Host "  3. Run SPT.Launcher.exe"
Write-Host "Do not move SPT.Server / SPT.Launcher out of that folder (causes the Watermark error)."
