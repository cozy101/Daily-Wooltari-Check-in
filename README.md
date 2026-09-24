# Daily Wooltari Check-In Automation

Automated daily check-in script for [Wooltari USA](https://wooltariusa.com) to earn daily rewards and points using Windows UI Automation and Chrome.

---

## Features

- **Automated Check-in Execution**: Navigates to Wooltari USA check-in page and verifies authentication status.
- **Robust UI Automation**:
  - Searches for check-in controls across multiple UI control types (`Button`, `Custom`, `Hyperlink`).
  - Automatically scrolls down (`Page Down`) if the check-in button is below the visible viewport.
  - Closes promotional/announcement popups blocking automation.
- **PowerShell 5.1 Encoding Safety**: Korean UI strings (출석하기, 마이페이지, 로그인, etc.) are constructed via explicit Unicode code points to avoid UTF-8 BOM encoding issues in Windows PowerShell.
- **Chrome Lifecycle Management**: Tracks opened Chrome windows and guarantees clean closure via a `try/finally` block.
- **Log Management**: Maintains daily logs under `wooltari-checkin-logs/` with an automatic 30-day retention cleanup.
- **Flexible Execution Modes**:
  - Scheduled daily automation via Windows Task Scheduler.
  - Manual on-demand PowerShell runner with formatted console feedback.
  - Double-clickable `.bat` batch launcher for quick desktop execution.

---

## File Overview

| File | Description |
| --- | --- |
| `Invoke-WooltariDailyCheckIn.ps1` | Core automation script performing navigation, popup dismissal, button detection, click execution, and verification. |
| `Register-WooltariDailyCheckInTask.ps1` | PowerShell script to register or update the Windows Scheduled Task to run daily. |
| `Run-WooltariCheckIn.ps1` | Manual PowerShell runner providing status summaries, log previews, and desktop shortcut creation. |
| `Run-WooltariDailyCheckIn.bat` | Double-clickable batch file wrapper for one-click manual check-ins. |

---

## Prerequisites

1. **Google Chrome**: Installed at default location.
2. **Saved Wooltari Credentials**: Log into [wooltariusa.com](https://wooltariusa.com) once in Google Chrome with "Remember Me" / autofill saved so the script can access your account session.
3. **Windows PowerShell 5.1 or PowerShell 7+** with execution policy configured to permit script execution.

---

## Setup & Usage

### 1. Register Scheduled Task (Automated Daily Run)
To schedule the task to run automatically every morning at 9:00 AM:

```powershell
powershell -ExecutionPolicy Bypass -File .\Register-WooltariDailyCheckInTask.ps1 -At "09:00AM"
```

### 2. Manual On-Demand Check-In
Run directly in PowerShell:
```powershell
.\Run-WooltariCheckIn.ps1
```

Or double-click `Run-WooltariDailyCheckIn.bat` in Windows Explorer.

To create a desktop shortcut for manual check-ins:
```powershell
.\Run-WooltariCheckIn.ps1 -CreateDesktopShortcut
```

---

## Summary of Changes & Improvements

### `Invoke-WooltariDailyCheckIn.ps1`
- **Unicode Code Point Construction**: Replaced raw UTF-8 Korean strings with `ConvertFrom-CodePoints` helper so scripts run reliably on Windows PowerShell 5.1 regardless of file BOM encoding.
- **Flexible Control Type Detection**: Expanded check-in button locator to match `Button`, `Custom`, and `Hyperlink` control types.
- **Viewport Fallback Scrolling**: Added automatic `{PGDN}` scrolling if the check-in button is not located in the initial viewport.
- **Popup Handling**: Added `Close-WooltariPopups` helper to dismiss promotional banners before and after navigation.
- **Cold-Start Chrome Handling**: Switched Chrome launch to `--new-window --start-maximized` and refined window matching to avoid PID race conditions during Chrome cold start.
- **Automatic Log Pruning**: Added `Remove-OldCheckInLogs` with 30-day retention to prevent unbounded log accumulation.
- **Window Cleanup in Finally**: Ensured all script-launched Chrome instances are safely closed even if exceptions occur.
- **Standardized Exit Codes**:
  - `0`: Success (checked in or already checked in today)
  - `1`: Unhandled exception
  - `2`: Could not confirm login
  - `3`: Unexpected state after refresh
  - `4`: Check-in text found but control not clickable
  - `5`: Clicked check-in but verification timed out
  - `6`: Check-in button or checked-in status not found

### `Register-WooltariDailyCheckInTask.ps1`
- Added `-STA` (Single-Threaded Apartment) flag to PowerShell task action to ensure UI Automation runs without COM threading issues.
- Configured `-WorkingDirectory $PSScriptRoot` so task execution correctly resolves local paths and log directories.

### New Helper Scripts
- Added `Run-WooltariCheckIn.ps1` for interactive manual execution with colored output, exit code translation, and desktop shortcut generation.
- Added `Run-WooltariDailyCheckIn.bat` for one-click manual runs.

### Repository Cleanup
- Updated `.gitignore` to exclude daily execution logs (`wooltari-checkin-logs/`), temporary test captures, and local IDE agent metadata.
