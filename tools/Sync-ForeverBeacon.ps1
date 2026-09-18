<#
.SYNOPSIS
    Archives ForeverBeacon's SavedVariables and extracts it to CSV/JSONL.

.DESCRIPTION
    WoW only writes SavedVariables on /reload, logout or a clean exit. This
    finds the newest ForeverBeacon.lua under every WoW flavor folder (so it
    does not matter what the Forever beta installs as), copies it to
    ..\data\raw\<timestamp>-ForeverBeacon.lua when it has changed, and runs
    fb_extract.py on it. Nothing is uploaded anywhere; the beta data stays on
    this PC until a bridge exists for it.

.PARAMETER Force
    Archive and extract even if the file has not changed.

.PARAMETER Register
    Create a scheduled task that runs this every IntervalMinutes (default 30)
    plus once at logon. Needs an elevated shell.

.EXAMPLE
    .\Sync-ForeverBeacon.ps1
    .\Sync-ForeverBeacon.ps1 -Force
    .\Sync-ForeverBeacon.ps1 -Register -IntervalMinutes 30
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Register,
    [int]$IntervalMinutes = 30,
    [string]$WowRoot   = "C:\Program Files (x86)\World of Warcraft",
    [string]$StateFile = "$env:LOCALAPPDATA\foreverbeacon-sync-state.txt"
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot is empty inside param defaults on PS 5.1, so resolve it here.
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir  = Join-Path (Split-Path -Parent $ToolsDir) "data"
$RawDir   = Join-Path $DataDir "raw"

function Get-BeaconFile {
    $found = Get-ChildItem -Path $WowRoot -Directory -Filter "_*_" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $acct = Join-Path $_.FullName "WTF\Account"
            if (Test-Path $acct) {
                Get-ChildItem -Path $acct -Filter "ForeverBeacon.lua" -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -like "*\SavedVariables\ForeverBeacon.lua" }
            }
        } | Sort-Object LastWriteTime -Descending
    if (-not $found) {
        throw "No ForeverBeacon.lua found under $WowRoot. Log in with Forever Beacon enabled, run '/fb flush', then '/reload'."
    }
    return $found[0]
}

if ($Register) {
    # The task runs the .vbs wrapper next to this script: wscript has no console
    # and starts PowerShell hidden, so no window ever flashes.
    $ps  = "$env:SystemRoot\System32\wscript.exe"
    $arg = "`"$(Join-Path $ToolsDir 'Sync-ForeverBeacon-hidden.vbs')`""
    $action   = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $triggers = @(
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    try {
        Register-ScheduledTask -TaskName "ForeverBeaconSync" -Action $action -Trigger $triggers -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Host "Registered task ForeverBeaconSync (every $IntervalMinutes min + logon)."
    } catch {
        # Register-ScheduledTask needs elevation from some shells; schtasks does not for a user task.
        $tr = "`"$ps`" $arg"
        schtasks.exe /Create /F /TN ForeverBeaconSync /SC MINUTE /MO $IntervalMinutes /TR $tr | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not register the task: $($_.Exception.Message)" }
        Write-Host "Registered task ForeverBeaconSync via schtasks (every $IntervalMinutes min)."
    }
    return
}

$file = Get-BeaconFile
$stamp = $file.LastWriteTime.ToString("yyyyMMdd-HHmmss")
$last = if (Test-Path $StateFile) { Get-Content $StateFile -Raw } else { "" }
if (-not $Force -and $last.Trim() -eq "$($file.FullName)|$stamp") {
    Write-Host "No new SavedVariables since $stamp."
    return
}

New-Item -ItemType Directory -Force $RawDir | Out-Null
$archive = Join-Path $RawDir "$stamp-ForeverBeacon.lua"
Copy-Item $file.FullName $archive -Force
Write-Host "Archived $($file.FullName) -> $archive ($([math]::Round($file.Length / 1MB, 2)) MB)"

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source (Join-Path $ToolsDir "fb_extract.py") $archive
} else {
    Write-Warning "python not on PATH; archived only. Run fb_extract.py manually."
}

[System.IO.File]::WriteAllText($StateFile, "$($file.FullName)|$stamp", (New-Object System.Text.UTF8Encoding($false)))
