<#
.SYNOPSIS
    Manually triggers the Wooltari daily check-in script anytime.
.DESCRIPTION
    Runs Invoke-WooltariDailyCheckIn.ps1 on-demand. If check-in already ran
    earlier today, it safely verifies the completed status and exits.
    If check-in did not run (e.g., missed 9:00 AM), it performs the check-in.
.PARAMETER CreateDesktopShortcut
    If specified, creates a "Wooltari Daily Check-In" shortcut on your Desktop.
#>
[CmdletBinding()]
param(
    [switch]$CreateDesktopShortcut
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
}

if ($CreateDesktopShortcut) {
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopPath 'Wooltari Daily Check-In.lnk'
    $batPath = Join-Path $ScriptDir 'Run-WooltariDailyCheckIn.bat'

    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $batPath
    $shortcut.WorkingDirectory = $ScriptDir
    $shortcut.Description = 'Run Wooltari Daily Check-In manually'
    $shortcut.Save()

    Write-Host "[OK] Created desktop shortcut: $shortcutPath" -ForegroundColor Green
    return
}

$checkInScript = Join-Path $ScriptDir 'Invoke-WooltariDailyCheckIn.ps1'
if (-not (Test-Path $checkInScript)) {
    Write-Error "Cannot find script: $checkInScript"
    return
}

Write-Host '========================================================' -ForegroundColor Cyan
Write-Host '         Wooltari Daily Check-In (Manual Run)           ' -ForegroundColor Cyan
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host "Starting manual run at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')..." -ForegroundColor Yellow

$proc = Start-Process powershell.exe `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$checkInScript`"" `
    -WorkingDirectory $ScriptDir `
    -Wait `
    -PassThru

$exitCode = $proc.ExitCode
$todayLog = Join-Path $ScriptDir ("wooltari-checkin-logs\checkin-{0:yyyy-MM-dd}.log" -f (Get-Date))

Write-Host ''
Write-Host '========================================================' -ForegroundColor Cyan

switch ($exitCode) {
    0 {
        Write-Host '[SUCCESS] Wooltari daily check-in completed or already verified for today!' -ForegroundColor Green
    }
    2 {
        Write-Host '[ACTION REQUIRED] Could not confirm login.' -ForegroundColor Yellow
        Write-Host 'Please open Chrome, log in to https://wooltariusa.com once, and rerun.' -ForegroundColor Yellow
    }
    3 {
        Write-Host '[NOTICE] Check-in state after page refresh was unexpected.' -ForegroundColor Yellow
    }
    4 {
        Write-Host '[NOTICE] Check-in text was found, but button was not clickable.' -ForegroundColor Yellow
    }
    5 {
        Write-Host '[NOTICE] Clicked check-in, but final confirmation timed out.' -ForegroundColor Yellow
    }
    6 {
        Write-Host '[NOTICE] Check-in button or completed state was not detected on page.' -ForegroundColor Yellow
    }
    Default {
        Write-Host "[ERROR] Check-in process exited with code $exitCode." -ForegroundColor Red
    }
}

Write-Host '========================================================' -ForegroundColor Cyan

if (Test-Path $todayLog) {
    Write-Host "`nRecent log entries ($todayLog):" -ForegroundColor Gray
    Get-Content -Path $todayLog -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

$global:LASTEXITCODE = $exitCode

$isInteractiveHost = ($Host.Name -match 'Visual Studio Code Host|ConsoleHost') -and
    (-not [Console]::IsInputRedirected) -and
    ($MyInvocation.Line -match 'Invoke-Wooltari|Run-Wooltari|\.ps1')

if ($isInteractiveHost) {
    return $exitCode
}

exit $exitCode
