#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CheckInUrl = 'https://wooltariusa.com/pages/check-in',
    [string]$LoginUrl = 'https://wooltariusa.com/account/login',
    [int]$PageLoadSeconds = 10,
    [int]$VerifySeconds = 35
)

$ErrorActionPreference = 'Stop'

$LogDir = Join-Path $PSScriptRoot 'wooltari-checkin-logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ('checkin-{0:yyyy-MM-dd}.log' -f (Get-Date))

function Write-CheckInLog {
    param([string]$Message)

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Import-UiAutomation {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms

    if (-not ('WooltariNativeWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WooltariNativeWindow
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
'@
    }
}

function Get-ChromePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    throw 'Google Chrome was not found in the usual install locations.'
}

function Open-ChromeUrl {
    param(
        [string]$ChromePath,
        [string]$Url
    )

    Write-CheckInLog "Opening $Url in Chrome."
    Start-Process -FilePath $ChromePath -ArgumentList $Url | Out-Null
    Start-Sleep -Seconds $PageLoadSeconds
}

function Get-ChromeAutomationWindows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        'Chrome_WidgetWin_1'
    )

    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $chromeWindows = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $windows.Count; $i++) {
        $window = $windows.Item($i)
        try {
            $process = Get-Process -Id $window.Current.ProcessId -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -eq 'chrome') {
                $chromeWindows.Add($window)
            }
        }
        catch {
            continue
        }
    }

    return $chromeWindows
}

function Get-WooltariWindow {
    $windows = Get-ChromeAutomationWindows

    foreach ($window in $windows) {
        try {
            if ($window.Current.Name -match 'wooltari|Wooltari|check-in|출석') {
                return $window
            }
        }
        catch {
            continue
        }
    }

    if ($windows.Count -gt 0) {
        return $windows.Item(0)
    }

    return $null
}

function Wait-WooltariWindow {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $window = Get-WooltariWindow
        if ($window) {
            return $window
        }

        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    throw 'Could not find an open Chrome window to automate.'
}

function Focus-AutomationWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [WooltariNativeWindow]::ShowWindow($handle, 3) | Out-Null
    Start-Sleep -Milliseconds 300
    [WooltariNativeWindow]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 500
}

function Find-AutomationElementByText {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string[]]$Patterns,
        [switch]$RequireEnabled
    )

    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )

    for ($i = 0; $i -lt $all.Count; $i++) {
        $element = $all.Item($i)
        try {
            $name = $element.Current.Name
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if ($RequireEnabled -and -not $element.Current.IsEnabled) {
                continue
            }

            foreach ($pattern in $Patterns) {
                if ($name -match $pattern) {
                    return $element
                }
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Test-PageText {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string[]]$Patterns
    )

    return [bool](Find-AutomationElementByText -Root $Window -Patterns $Patterns)
}

function Click-AutomationElement {
    param([System.Windows.Automation.AutomationElement]$Element)

    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        $invokePattern.Invoke()
        return
    }

    $point = $Element.GetClickablePoint()
    [WooltariNativeWindow]::SetCursorPos([int]$point.X, [int]$point.Y) | Out-Null
    Start-Sleep -Milliseconds 100
    [WooltariNativeWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [WooltariNativeWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Refresh-Page {
    param([System.Windows.Automation.AutomationElement]$Window)

    Focus-AutomationWindow -Window $Window
    [System.Windows.Forms.SendKeys]::SendWait('^r')
    Start-Sleep -Seconds $PageLoadSeconds
}

function Invoke-CachedLogin {
    param(
        [string]$ChromePath,
        [System.Windows.Automation.AutomationElement]$Window
    )

    Write-CheckInLog 'Login state was not confirmed. Opening the login page and trying the saved Chrome credentials flow.'
    Open-ChromeUrl -ChromePath $ChromePath -Url $LoginUrl
    $Window = Wait-WooltariWindow
    Focus-AutomationWindow -Window $Window

    $loginButton = Find-AutomationElementByText -Root $Window -Patterns @('로그인', 'Sign in', 'Log in') -RequireEnabled
    if ($loginButton) {
        Click-AutomationElement -Element $loginButton
        Start-Sleep -Seconds $PageLoadSeconds
    }

    return (Wait-ForLoggedInState -Window $Window -TimeoutSeconds $VerifySeconds)
}

function Wait-ForLoggedInState {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$TimeoutSeconds = 30
    )

    $loggedInPatterns = @('마이페이지', 'My Page', 'Account')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        if (Test-PageText -Window $Window -Patterns $loggedInPatterns) {
            return $true
        }

        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-ForCheckInState {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$TimeoutSeconds = 30
    )

    $alreadyPatterns = @('Checked\s+In\s+Already', 'Checked\s+in\s+Already')
    $checkInPatterns = @('출석하기')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        if (Test-PageText -Window $Window -Patterns $alreadyPatterns) {
            return 'Already'
        }

        if (Test-PageText -Window $Window -Patterns $checkInPatterns) {
            return 'Ready'
        }

        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)

    return 'Unknown'
}

try {
    Import-UiAutomation
    $chromePath = Get-ChromePath

    Write-CheckInLog 'Starting Wooltari daily check-in.'
    Open-ChromeUrl -ChromePath $chromePath -Url $CheckInUrl

    $window = Wait-WooltariWindow
    Focus-AutomationWindow -Window $window

    $loggedIn = Wait-ForLoggedInState -Window $window -TimeoutSeconds 10
    if (-not $loggedIn) {
        $loggedIn = Invoke-CachedLogin -ChromePath $chromePath -Window $window
        Open-ChromeUrl -ChromePath $chromePath -Url $CheckInUrl
        $window = Wait-WooltariWindow
        Focus-AutomationWindow -Window $window
    }

    if (-not $loggedIn) {
        Write-CheckInLog 'Could not confirm login. If Chrome did not autofill credentials, sign in once in Chrome and rerun this script.'
        exit 2
    }

    Write-CheckInLog 'Login confirmed.'
    $state = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

    if ($state -eq 'Already') {
        Write-CheckInLog 'The page already shows "Checked In Already"; refreshing to verify.'
        Refresh-Page -Window $window
        $window = Wait-WooltariWindow
        $verifiedState = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

        if ($verifiedState -eq 'Already') {
            Write-CheckInLog 'Verified after refresh: today has already been checked in.'
            exit 0
        }

        Write-CheckInLog "After refresh, expected already-checked-in state but saw: $verifiedState."
        exit 3
    }

    if ($state -eq 'Ready') {
        $button = Find-AutomationElementByText -Root $window -Patterns @('출석하기') -RequireEnabled
        if (-not $button) {
            Write-CheckInLog 'Found check-in text, but no enabled clickable check-in control was available.'
            exit 4
        }

        Write-CheckInLog 'Clicking the 출석하기 button.'
        Click-AutomationElement -Element $button
        Start-Sleep -Seconds $PageLoadSeconds

        Write-CheckInLog 'Refreshing after click to verify completed state.'
        Refresh-Page -Window $window
        $window = Wait-WooltariWindow
        $verifiedState = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

        if ($verifiedState -eq 'Already') {
            Write-CheckInLog 'Verified after click and refresh: today is checked in.'
            exit 0
        }

        Write-CheckInLog "Clicked check-in, but final verification state was: $verifiedState."
        exit 5
    }

    Write-CheckInLog 'Could not find either the 출석하기 button or the Checked In Already state.'
    exit 6
}
catch {
    Write-CheckInLog ('Failed: {0}' -f $_.Exception.Message)
    exit 1
}
