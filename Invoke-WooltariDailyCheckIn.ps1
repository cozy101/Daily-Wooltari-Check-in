#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CheckInUrl = 'https://wooltariusa.com/pages/check-in',
    [string]$LoginUrl = 'https://wooltariusa.com/account/login',
    [int]$PageLoadSeconds = 10,
    [int]$VerifySeconds = 35,
    [int]$LogRetentionDays = 30
)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    if ($PSCommandPath) {
        $PSScriptRoot = Split-Path -Parent $PSCommandPath
    } else {
        $PSScriptRoot = (Get-Location).Path
    }
}

$LogDir = Join-Path $PSScriptRoot 'wooltari-checkin-logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ('checkin-{0:yyyy-MM-dd}.log' -f (Get-Date))
$Script:OpenedChromeWindowHandles = New-Object 'System.Collections.Generic.HashSet[int]'

function Write-CheckInLog {
    param([string]$Message)

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function ConvertFrom-CodePoints {
    param([int[]]$CodePoints)

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

# Windows PowerShell 5.1 can misread UTF-8 scripts without a BOM. Build Korean
# page text from code points so scheduled runs match the live page reliably.
$WooltariText = @{
    MyPage = ConvertFrom-CodePoints @(0xB9C8, 0xC774, 0xD398, 0xC774, 0xC9C0)
    Login = ConvertFrom-CodePoints @(0xB85C, 0xADF8, 0xC778)
    Logout = ConvertFrom-CodePoints @(0xB85C, 0xADF8, 0xC544, 0xC6C3)
    CheckIn = ConvertFrom-CodePoints @(0xCD9C, 0xC11D, 0xD558, 0xAE30)
    AccountTitle = ConvertFrom-CodePoints @(0xACC4, 0xC815)
    CheckInTitle = ConvertFrom-CodePoints @(0xCD9C, 0xC11D, 0xCCB4, 0xD06C)
    SiteTitle = ConvertFrom-CodePoints @(0xC6B8, 0xD0C0, 0xB9AC)
    Close = ConvertFrom-CodePoints @(0xB2EB, 0xAE30)
    Times = [char]0x00D7
}

$WooltariPattern = @{
    MyPage = [regex]::Escape($WooltariText.MyPage)
    LoginButton = ('^\s*({0}|Log in|Login|Sign in)\s*$' -f [regex]::Escape($WooltariText.Login))
    Logout = [regex]::Escape($WooltariText.Logout)
    CheckIn = [regex]::Escape($WooltariText.CheckIn)
    AccountTitle = [regex]::Escape($WooltariText.AccountTitle)
    CheckInTitle = [regex]::Escape($WooltariText.CheckInTitle)
    SiteTitle = ('wooltari|{0}' -f [regex]::Escape($WooltariText.SiteTitle))
    Close = ('^\s*{0}\s*$' -f [regex]::Escape($WooltariText.Close))
    Times = ('^\s*{0}\s*$' -f [regex]::Escape($WooltariText.Times))
}

$WooltariTitlePattern = @{
    CheckIn = @(
        ('{0}.*({1})|({1}).*{0}' -f $WooltariPattern.CheckInTitle, $WooltariPattern.SiteTitle),
        'check-in.*wooltari|wooltari.*check-in',
        'check.*wooltari|wooltari.*check'
    )
    Login = @(
        ('{0}.*({1})|({1}).*{0}' -f $WooltariPattern.AccountTitle, $WooltariPattern.SiteTitle),
        'account.*wooltari|wooltari.*account',
        'login.*wooltari|wooltari.*login'
    )
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
    Start-Process -FilePath $ChromePath -ArgumentList @('--new-window', '--start-maximized', $Url) | Out-Null
    # Wait for Chrome's window to materialise in the UIA tree before we start
    # polling.  Cold-start Chrome can take several seconds to show its first
    # Chrome_WidgetWin_1 window, so 5 s is a reliable baseline.
    Start-Sleep -Seconds 5
}

function Get-ChromeAutomationWindows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        'Chrome_WidgetWin_1'
    )

    # Return every top-level Chrome_WidgetWin_1 window.  The handle-exclusion
    # logic in Wait-NewWooltariWindow already filters out pre-existing windows,
    # so we do not need a secondary PID filter here.  Filtering by PID caused
    # cold-start failures when the window appeared before chrome.exe was fully
    # indexed by Get-Process.
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $chromeWindows = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $windows.Count; $i++) {
        $window = $windows.Item($i)
        try {
            # Basic sanity check: the element must still be accessible.
            $null = $window.Current.ProcessId
            $chromeWindows.Add($window)
        }
        catch {
            continue
        }
    }

    return $chromeWindows
}

function Get-AutomationWindowHandle {
    param([System.Windows.Automation.AutomationElement]$Window)

    try {
        return [int]$Window.Current.NativeWindowHandle
    }
    catch {
        return 0
    }
}

function Get-ChromeAutomationWindowHandles {
    $handles = New-Object 'System.Collections.Generic.HashSet[int]'

    foreach ($window in (Get-ChromeAutomationWindows)) {
        $handle = Get-AutomationWindowHandle -Window $window
        if ($handle -gt 0) {
            [void]$handles.Add($handle)
        }
    }

    return $handles
}

function Get-ChromeAutomationWindowByHandle {
    param([int]$Handle)

    foreach ($window in (Get-ChromeAutomationWindows)) {
        if ((Get-AutomationWindowHandle -Window $window) -eq $Handle) {
            return $window
        }
    }

    return $null
}

function Test-ChromeWindowTitle {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string[]]$TitlePatterns = @()
    )

    if ($TitlePatterns.Count -eq 0) {
        return $true
    }

    try {
        foreach ($pattern in $TitlePatterns) {
            if ($Window.Current.Name -match $pattern) {
                return $true
            }
        }
    }
    catch {
    }

    return $false
}

function Register-OpenedChromeWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $handle = Get-AutomationWindowHandle -Window $Window
    if ($handle -gt 0) {
        [void]$Script:OpenedChromeWindowHandles.Add($handle)
    }
}

function Wait-NewWooltariWindow {
    param(
        [System.Collections.Generic.HashSet[int]]$ExistingWindowHandles,
        [int]$TimeoutSeconds = 30,
        [string[]]$TitlePatterns = @()
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $newWindow = $null

    do {
        foreach ($window in (Get-ChromeAutomationWindows)) {
            $handle = Get-AutomationWindowHandle -Window $window
            if ($handle -le 0 -or $ExistingWindowHandles.Contains($handle)) {
                continue
            }

            if (-not $newWindow) {
                $newWindow = $window
            }

            if (Test-ChromeWindowTitle -Window $window -TitlePatterns $TitlePatterns) {
                return $window
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if ($newWindow) {
        Write-CheckInLog 'Using the newly opened Chrome window; its title did not match the expected page yet.'
        return $newWindow
    }

    throw 'Could not find the newly opened Chrome window to automate.'
}

function Close-OpenedChromeWindows {
    if ($Script:OpenedChromeWindowHandles.Count -eq 0) {
        return
    }

    Write-CheckInLog ('Closing {0} Chrome window(s) opened by this run.' -f $Script:OpenedChromeWindowHandles.Count)

    $handles = @()
    foreach ($handle in $Script:OpenedChromeWindowHandles) {
        $handles += [int]$handle
    }

    foreach ($handle in $handles) {
        $window = Get-ChromeAutomationWindowByHandle -Handle $handle
        if (-not $window) {
            continue
        }

        try {
            $windowPattern = $null
            if ($window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$windowPattern)) {
                $windowPattern.Close()
                Start-Sleep -Milliseconds 500
                continue
            }
        }
        catch {
        }

        try {
            Focus-AutomationWindow -Window $window
            [System.Windows.Forms.SendKeys]::SendWait('%{F4}')
            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-CheckInLog ('Could not close Chrome window handle {0}: {1}' -f $handle, $_.Exception.Message)
        }
    }
}

function Get-WooltariWindow {
    param([string[]]$TitlePatterns = @())

    $windows = Get-ChromeAutomationWindows
    $openedWindows = New-Object System.Collections.Generic.List[object]

    foreach ($window in $windows) {
        $handle = Get-AutomationWindowHandle -Window $window
        if ($handle -gt 0 -and $Script:OpenedChromeWindowHandles.Contains($handle)) {
            $openedWindows.Add($window)
        }
    }

    if ($openedWindows.Count -gt 0) {
        $windows = $openedWindows
    }

    if ($TitlePatterns.Count -gt 0) {
        foreach ($window in $windows) {
            if (Test-ChromeWindowTitle -Window $window -TitlePatterns $TitlePatterns) {
                return $window
            }
        }

        return $null
    }

    foreach ($window in $windows) {
        try {
            if ($window.Current.Name -match ('wooltari|Wooltari|check-in|{0}' -f $WooltariPattern.CheckIn)) {
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
    param(
        [int]$TimeoutSeconds = 30,
        [string[]]$TitlePatterns = @()
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $window = Get-WooltariWindow -TitlePatterns $TitlePatterns
        if ($window) {
            return $window
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw 'Could not find an open Chrome window to automate.'
}

function Focus-AutomationWindow {
    param([System.Windows.Automation.AutomationElement]$Window)

    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [WooltariNativeWindow]::ShowWindow($handle, 3) | Out-Null
    Start-Sleep -Milliseconds 150
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.AppActivate($Window.Current.ProcessId) | Out-Null
        Start-Sleep -Milliseconds 150
    }
    catch {
    }

    [WooltariNativeWindow]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 300
}

function Test-PageContentElement {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [System.Windows.Automation.AutomationElement]$Element
    )

    try {
        $windowBounds = $Window.Current.BoundingRectangle
        $elementBounds = $Element.Current.BoundingRectangle

        if ($elementBounds.Width -le 0 -or $elementBounds.Height -le 0) {
            return $false
        }

        # Reject elements in the very top strip (navigation bar / announcement
        # banner area).  100px is enough to exclude the fixed header.
        if ($elementBounds.Top -lt ($windowBounds.Top + 100)) {
            return $false
        }

        # Reject elements horizontally outside the window.
        if ($elementBounds.Left -lt $windowBounds.Left -or $elementBounds.Right -gt ($windowBounds.Right + 5)) {
            return $false
        }

        # Accept elements that start within the window even if they extend
        # below the visible fold (the page can be taller than the viewport).
        return $elementBounds.Top -le ($windowBounds.Bottom + 10)
    }
    catch {
        return $false
    }
}

function Find-AutomationElementByText {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string[]]$Patterns,
        [switch]$RequireEnabled,
        [System.Windows.Automation.ControlType[]]$ControlTypes = @(),
        [switch]$PageContentOnly
    )

    # Build a UIA condition that pre-filters by control type so the accessibility
    # layer does the heavy lifting instead of pulling every node into managed code.
    if ($ControlTypes.Count -gt 0) {
        $typeConditions = @(foreach ($ct in $ControlTypes) {
            New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
        })

        if ($typeConditions.Count -eq 1) {
            $searchCondition = $typeConditions[0]
        }
        else {
            $searchCondition = New-Object System.Windows.Automation.OrCondition($typeConditions)
        }
    }
    else {
        $searchCondition = [System.Windows.Automation.Condition]::TrueCondition
    }

    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $searchCondition)

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

            if ($PageContentOnly -and -not (Test-PageContentElement -Window $Root -Element $element)) {
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
        [string[]]$Patterns,
        [switch]$PageContentOnly
    )

    return [bool](Find-AutomationElementByText -Root $Window -Patterns $Patterns -PageContentOnly:$PageContentOnly)
}

function Test-LoggedOutState {
    param([System.Windows.Automation.AutomationElement]$Window)

    $loginTypes = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Hyperlink
    )

    return [bool](Find-AutomationElementByText `
        -Root $Window `
        -Patterns @($WooltariPattern.LoginButton) `
        -RequireEnabled `
        -ControlTypes $loginTypes `
        -PageContentOnly)
}

function Click-AutomationElement {
    param([System.Windows.Automation.AutomationElement]$Element)

    # Prefer InvokePattern first: it is instant, requires no mouse movement,
    # and works even when the element is partially off-screen.
    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        try {
            $invokePattern.Invoke()
            return
        }
        catch {
            Write-CheckInLog ('InvokePattern failed, falling back to mouse simulation: {0}' -f $_.Exception.Message)
        }
    }

    # Fall back to mouse simulation via a clickable point.
    try {
        $point = $Element.GetClickablePoint()
        [WooltariNativeWindow]::SetCursorPos([int]$point.X, [int]$point.Y) | Out-Null
        Start-Sleep -Milliseconds 100
        [WooltariNativeWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 100
        [WooltariNativeWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        return
    }
    catch {
        Write-CheckInLog ('GetClickablePoint failed, trying bounding-rectangle centre: {0}' -f $_.Exception.Message)
    }

    # Last resort: compute the centre of the bounding rectangle.
    try {
        $bounds = $Element.Current.BoundingRectangle
        if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) {
            $x = [int]($bounds.Left + ($bounds.Width / 2))
            $y = [int]($bounds.Top + ($bounds.Height / 2))
            [WooltariNativeWindow]::SetCursorPos($x, $y) | Out-Null
            Start-Sleep -Milliseconds 100
            [WooltariNativeWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 100
            [WooltariNativeWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
            return
        }
    }
    catch {
        Write-CheckInLog ('Bounding-rectangle click also failed: {0}' -f $_.Exception.Message)
    }
}

function Close-WooltariPopups {
    param([System.Windows.Automation.AutomationElement]$Window)

    Focus-AutomationWindow -Window $Window

    # NOTE: Do NOT send {ESC} here. Sending ESC immediately after a page
    # navigation or reload aborts Chrome's in-flight XHR/fetch requests,
    # which prevents the check-in widget from loading.

    $closePatterns = @(
        $WooltariPattern.Close,
        $WooltariPattern.Times,
        '^\s*x\s*$',
        '^Close$',
        '^Dismiss$',
        '^No thanks$',
        '^Not now$'
    )
    $closeTypes = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Hyperlink
    )

    $windowBounds = $null
    try { $windowBounds = $Window.Current.BoundingRectangle } catch {}

    # Track RuntimeIds of close buttons already clicked this call.
    # NOTE: NativeWindowHandle is 0 for all Chrome web-content UIA elements,
    # so it cannot be used for deduplication.  RuntimeId is the correct
    # per-element unique identifier in UIA and survives until the element
    # is destroyed (i.e., the popup is actually dismissed).
    $clickedIds = New-Object 'System.Collections.Generic.HashSet[string]'

    # Allow up to 8 button-click dismissals (the site can show several popups
    # in sequence). Each popup is dismissed and we wait 600 ms for the animation
    # before looking for the next one.
    for ($i = 0; $i -lt 8; $i++) {
        $all = $Window.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )

        $closeButton = $null
        for ($k = 0; $k -lt $all.Count; $k++) {
            $el = $all.Item($k)
            try {
                $ct = $el.Current.ControlType
                if ($ct -ne [System.Windows.Automation.ControlType]::Button -and
                    $ct -ne [System.Windows.Automation.ControlType]::Hyperlink) {
                    continue
                }

                if (-not $el.Current.IsEnabled) { continue }

                $n = $el.Current.Name
                if ([string]::IsNullOrWhiteSpace($n)) { continue }

                $matched = $false
                foreach ($pat in $closePatterns) {
                    if ($n -match $pat) { $matched = $true; break }
                }
                if (-not $matched) { continue }

                # Skip elements in the persistent top announcement/navigation
                # banner (top 150 px of the window). Those X buttons do not
                # dismiss a blocking modal and will loop forever.
                if ($windowBounds) {
                    $eb = $el.Current.BoundingRectangle
                    if ($eb.Top -lt ($windowBounds.Top + 150)) { continue }
                }

                $rid = [string]::Join(',', $el.GetRuntimeId())
                if ($clickedIds.Contains($rid)) { continue }

                $closeButton = $el
                break
            } catch { continue }
        }

        if (-not $closeButton) {
            return
        }

        $rid = [string]::Join(',', $closeButton.GetRuntimeId())
        [void]$clickedIds.Add($rid)
        Write-CheckInLog ('Closing page popup: {0}' -f $closeButton.Current.Name)
        Click-AutomationElement -Element $closeButton
        Start-Sleep -Milliseconds 600
    }
}

function Wait-PageLoad {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string[]]$TitlePatterns = @(),
        [int]$MaxSeconds = 10
    )

    # Poll until the window title indicates the page has committed, rather than
    # sleeping a fixed duration.  Falls through after MaxSeconds either way.
    if ($TitlePatterns.Count -eq 0) {
        Start-Sleep -Seconds $MaxSeconds
        return
    }

    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    do {
        if (Test-ChromeWindowTitle -Window $Window -TitlePatterns $TitlePatterns) {
            # Give the page a brief moment to finish rendering after the title
            # updates, then return.
            Start-Sleep -Milliseconds 800
            return
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
}

function Refresh-Page {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string[]]$TitlePatterns = @()
    )

    Focus-AutomationWindow -Window $Window
    [System.Windows.Forms.SendKeys]::SendWait('^r')
    Wait-PageLoad -Window $Window -TitlePatterns $TitlePatterns -MaxSeconds $PageLoadSeconds
}

function Navigate-WindowToUrl {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [string]$Url,
        [string[]]$TitlePatterns = @()
    )

    Write-CheckInLog "Navigating the current Chrome window to $Url."
    Focus-AutomationWindow -Window $Window
    # Select the address bar, clear any existing text, then type the URL.
    [System.Windows.Forms.SendKeys]::SendWait('^l')
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait($Url)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')

    Wait-PageLoad -Window $Window -TitlePatterns $TitlePatterns -MaxSeconds $PageLoadSeconds

    if ($TitlePatterns.Count -gt 0 -and -not (Test-ChromeWindowTitle -Window $Window -TitlePatterns $TitlePatterns)) {
        Write-CheckInLog 'The current Chrome window title did not match the expected page title after navigation yet.'
    }

    Focus-AutomationWindow -Window $Window
    Close-WooltariPopups -Window $Window

    return $Window
}

function Refresh-CheckInPageForAutomation {
    param([System.Windows.Automation.AutomationElement]$Window)

    Write-CheckInLog 'Refreshing the check-in page once after login confirmation.'
    Refresh-Page -Window $Window -TitlePatterns $WooltariTitlePattern.CheckIn
    Focus-AutomationWindow -Window $Window
    Close-WooltariPopups -Window $Window

    return $Window
}

function Open-WooltariPageForAutomation {
    param(
        [string]$ChromePath,
        [string]$Url,
        [string[]]$TitlePatterns = @()
    )

    $existingWindowHandles = Get-ChromeAutomationWindowHandles
    Open-ChromeUrl -ChromePath $ChromePath -Url $Url
    $Window = Wait-NewWooltariWindow -ExistingWindowHandles $existingWindowHandles -TitlePatterns $TitlePatterns
    Register-OpenedChromeWindow -Window $Window
    Focus-AutomationWindow -Window $Window
    Close-WooltariPopups -Window $Window

    return $Window
}

function Open-CheckInPageForAutomation {
    param([string]$ChromePath)

    return (Open-WooltariPageForAutomation `
        -ChromePath $ChromePath `
        -Url $CheckInUrl `
        -TitlePatterns $WooltariTitlePattern.CheckIn)
}

function Open-CheckInOrLoginPageForAutomation {
    param([string]$ChromePath)

    return (Open-WooltariPageForAutomation `
        -ChromePath $ChromePath `
        -Url $CheckInUrl `
        -TitlePatterns @($WooltariTitlePattern.CheckIn + $WooltariTitlePattern.Login))
}

function Open-LoginPageForAutomation {
    param([string]$ChromePath)

    return (Open-WooltariPageForAutomation `
        -ChromePath $ChromePath `
        -Url $LoginUrl `
        -TitlePatterns $WooltariTitlePattern.Login)
}

function Invoke-CachedLogin {
    param(
        [string]$ChromePath,
        [System.Windows.Automation.AutomationElement]$Window
    )

    Write-CheckInLog 'Login state was not confirmed. Navigating the current window to the login page and trying the saved Chrome credentials flow.'
    $Window = Navigate-WindowToUrl -Window $Window -Url $LoginUrl -TitlePatterns $WooltariTitlePattern.Login

    if (Wait-ForLoggedInState -Window $Window -TimeoutSeconds 3) {
        Write-CheckInLog 'Login page already shows a signed-in account.'
        return $true
    }

    $loginPatterns = @(
        $WooltariPattern.LoginButton,
        '^\s*로그인\s*$',
        '^\s*Log in\s*$',
        '^\s*Login\s*$',
        '^\s*Sign in\s*$'
    )
    $buttonTypes = @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::Custom,
        [System.Windows.Automation.ControlType]::Hyperlink
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Close-WooltariPopups -Window $Window

        $loginButton = Find-AutomationElementByText `
            -Root $Window `
            -Patterns $loginPatterns `
            -RequireEnabled `
            -ControlTypes $buttonTypes `
            -PageContentOnly

        if (-not $loginButton) {
            Write-CheckInLog ('Login submit button was not found on attempt {0}.' -f $attempt)
            Start-Sleep -Seconds 2
            continue
        }

        $bounds = $loginButton.Current.BoundingRectangle
        Write-CheckInLog ('Clicking the login submit button. Attempt {0}. Button bounds: {1},{2},{3},{4}.' -f $attempt, [int]$bounds.Left, [int]$bounds.Top, [int]$bounds.Width, [int]$bounds.Height)
        Click-AutomationElement -Element $loginButton
        Start-Sleep -Seconds 3

        if (Wait-ForLoggedInState -Window $Window -TimeoutSeconds 8) {
            return $true
        }

        Write-CheckInLog ('Login was not confirmed after click attempt {0}.' -f $attempt)
    }

    return $false
}

function Wait-ForLoggedInState {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$TimeoutSeconds = 30
    )

    $loggedInPatterns = @(
        $WooltariPattern.MyPage,
        '^My Page$',
        'My Page',
        'My Account',
        $WooltariPattern.Logout,
        '^Logout$',
        '^Log out$'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        # Check logged-out indicator first (login button present = not logged in).
        if (Test-LoggedOutState -Window $Window) {
            return $false
        }

        # Check logged-in indicator (My Page link present = logged in).
        if (Test-PageText -Window $Window -Patterns $loggedInPatterns -PageContentOnly) {
            return $true
        }

        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-ForCheckInState {
    param(
        [System.Windows.Automation.AutomationElement]$Window,
        [int]$TimeoutSeconds = 30
    )

    # Patterns for the already-checked-in state: English UIA text + Korean
    # variants the site uses when the UI renders in Korean locale.
    $alreadyKorean1 = ConvertFrom-CodePoints @(0xCD9C, 0xC11D, 0xC644, 0xB8CC)   # 출석완료
    $alreadyKorean2 = ConvertFrom-CodePoints @(0xC774, 0xBBF8, 0x20, 0xCD9C, 0xC11D) # 이미 출석
    $alreadyPatterns = @(
        'Checked\s+In\s+Already',
        'Checked\s+in\s+Already',
        'Already\s+Checked\s+In',
        [regex]::Escape($alreadyKorean1),
        [regex]::Escape($alreadyKorean2)
    )
    $checkInPatterns = @($WooltariPattern.CheckIn)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        if (Test-PageText -Window $Window -Patterns $alreadyPatterns -PageContentOnly) {
            return 'Already'
        }

        if (Test-PageText -Window $Window -Patterns $checkInPatterns -PageContentOnly) {
            return 'Ready'
        }

        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)

    return 'Unknown'
}

function Remove-OldCheckInLogs {
    param([int]$RetentionDays)

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $removed = 0
    Get-ChildItem -Path $LogDir -Filter 'checkin-*.log' |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item -Path $_.FullName -Force
            $removed++
        }

    if ($removed -gt 0) {
        Write-CheckInLog ('Removed {0} log file(s) older than {1} days.' -f $removed, $RetentionDays)
    }
}

function Invoke-WooltariDailyCheckIn {
    # Exit codes:
    # 0 = success (check-in completed or already checked in today)
    # 1 = unhandled exception
    # 2 = could not confirm login
    # 3 = unexpected state after already-checked-in refresh
    # 4 = check-in text found but no enabled clickable button
    # 5 = clicked check-in but final verification did not confirm it
    # 6 = neither check-in button nor Checked-In-Already state was found
try {
    Import-UiAutomation
    $chromePath = Get-ChromePath

    Write-CheckInLog 'Starting Wooltari daily check-in.'
    Remove-OldCheckInLogs -RetentionDays $LogRetentionDays
    $window = Open-CheckInOrLoginPageForAutomation -ChromePath $chromePath

    $loggedIn = Wait-ForLoggedInState -Window $window -TimeoutSeconds 10
    if (-not $loggedIn) {
        $loggedIn = Invoke-CachedLogin -ChromePath $chromePath -Window $window
    }

    if (-not $loggedIn) {
        Write-CheckInLog 'Could not confirm login. If Chrome did not autofill credentials, sign in once in Chrome and rerun this script.'
        return 2
    }

    Write-CheckInLog 'Login confirmed.'
    if (Test-ChromeWindowTitle -Window $window -TitlePatterns $WooltariTitlePattern.CheckIn) {
        # Already on the check-in page — dismiss popups and proceed directly
        # without reloading.  Reloading here was causing ESC to abort the
        # page fetch, preventing the check-in widget from rendering.
        Write-CheckInLog 'Already on the check-in page; dismissing popups and proceeding.'
        Focus-AutomationWindow -Window $window
        Close-WooltariPopups -Window $window
    }
    else {
        $window = Navigate-WindowToUrl -Window $window -Url $CheckInUrl -TitlePatterns $WooltariTitlePattern.CheckIn
        Close-WooltariPopups -Window $window
    }

    # Give the check-in widget a moment to finish rendering its dynamic content
    # (calendar, button state) before we start polling for it.
    Start-Sleep -Milliseconds 1500
    $state = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

    if ($state -eq 'Already') {
        Write-CheckInLog 'The page already shows "Checked In Already"; refreshing to verify.'
        Refresh-Page -Window $window -TitlePatterns $WooltariTitlePattern.CheckIn
        Focus-AutomationWindow -Window $window
        Close-WooltariPopups -Window $window
        $verifiedState = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

        if ($verifiedState -eq 'Already') {
            Write-CheckInLog 'Verified after refresh: today has already been checked in.'
            return 0
        }

        Write-CheckInLog "After refresh, expected already-checked-in state but saw: $verifiedState."
        return 3
    }

    if ($state -eq 'Ready') {
        Close-WooltariPopups -Window $window

        # Search for the check-in button across multiple control types: the site
        # sometimes exposes the click target as Button, Custom, or Hyperlink.
        $buttonTypes = @(
            [System.Windows.Automation.ControlType]::Button,
            [System.Windows.Automation.ControlType]::Custom,
            [System.Windows.Automation.ControlType]::Hyperlink
        )
        $button = Find-AutomationElementByText `
            -Root $window `
            -Patterns @($WooltariPattern.CheckIn) `
            -RequireEnabled `
            -ControlTypes $buttonTypes `
            -PageContentOnly

        if (-not $button) {
            # The button might be below the visible fold; try scrolling down once
            # and searching again before giving up.
            Write-CheckInLog 'Check-in button not found in viewport; scrolling down and retrying.'
            Focus-AutomationWindow -Window $window
            [System.Windows.Forms.SendKeys]::SendWait('{PGDN}')
            Start-Sleep -Milliseconds 800
            Close-WooltariPopups -Window $window
            $button = Find-AutomationElementByText `
                -Root $window `
                -Patterns @($WooltariPattern.CheckIn) `
                -RequireEnabled `
                -ControlTypes $buttonTypes `
                -PageContentOnly
        }

        if (-not $button) {
            Write-CheckInLog 'Found check-in text, but no enabled clickable check-in control was available.'
            return 4
        }

        $bounds = $button.Current.BoundingRectangle
        Write-CheckInLog ('Clicking the check-in button. Button bounds: {0},{1},{2},{3}.' -f [int]$bounds.Left, [int]$bounds.Top, [int]$bounds.Width, [int]$bounds.Height)
        Click-AutomationElement -Element $button
        # Brief pause to let the site register the click before navigating away.
        Start-Sleep -Seconds 3

        Write-CheckInLog 'Reloading the current check-in page to verify completed state.'
        $window = Navigate-WindowToUrl -Window $window -Url $CheckInUrl -TitlePatterns $WooltariTitlePattern.CheckIn
        $verifiedState = Wait-ForCheckInState -Window $window -TimeoutSeconds $VerifySeconds

        if ($verifiedState -eq 'Already') {
            Write-CheckInLog 'Verified after click: today is checked in.'
            return 0
        }

        Write-CheckInLog "Clicked check-in, but final verification state was: $verifiedState."
        return 5
    }

    Write-CheckInLog 'Could not find either the check-in button or the Checked In Already state.'
    return 6
}
catch {
    Write-CheckInLog ('Failed: {0}' -f $_.Exception.Message)
    return 1
}
}

$exitCode = 1
try {
    $exitCode = Invoke-WooltariDailyCheckIn
}
finally {
    try {
        Close-OpenedChromeWindows
    }
    catch {
        Write-CheckInLog ('Cleanup failed: {0}' -f $_.Exception.Message)
    }
}

$global:LASTEXITCODE = $exitCode

# If running directly inside an interactive shell, return so the host terminal session stays open.
# When running non-interactively or via powershell.exe -File, exit to communicate the process exit code.
$isInteractiveHost = ($Host.Name -match 'Visual Studio Code Host|ConsoleHost') -and
    (-not [Console]::IsInputRedirected) -and
    ($MyInvocation.Line -match 'Invoke-Wooltari|\.ps1')

if ($isInteractiveHost) {
    return $exitCode
}

exit $exitCode
