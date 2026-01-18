Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -------------------------------------------------
# Idle detection (keyboard / mouse)
# -------------------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class UserIdle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static uint GetIdleMilliseconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        GetLastInputInfo(ref lii);
        return ((uint)Environment.TickCount - lii.dwTime);
    }
}
"@

# -------------------------------------------------
# Foreground app detection (meetings)
# -------------------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class ForegroundApp {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

$MeetingProcesses = @(
    "ms-teams",
    "teams",
    "zoom",
    "webex",
    "slack",
    "chrome",
    "msedge",
    "firefox"
)

function Is-MeetingForeground {
    $hwnd = [ForegroundApp]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }

    $pid = 0
    [ForegroundApp]::GetWindowThreadProcessId($hwnd, [ref]$pid) | Out-Null

    try {
        $proc = Get-Process -Id $pid -ErrorAction Stop
        $name = $proc.ProcessName.ToLower()

        foreach ($m in $MeetingProcesses) {
            if ($name -like "*$m*") {
                return $true
            }
        }
    } catch {}

    return $false
}

# -------------------------------------------------
# Settings
# -------------------------------------------------
$IdleThresholdSeconds  = 10
$FlushIntervalSeconds = 30

$dataFile = "$PSScriptRoot\screen_time.json"
$tempFile = "$dataFile.tmp"

# -------------------------------------------------
# Load data
# -------------------------------------------------
if (Test-Path $dataFile) {
    $data = Get-Content $dataFile -Raw | ConvertFrom-Json
} else {
    $data = @{}
}

function TodayKey {
    (Get-Date).ToString("yyyy-MM-dd")
}

function Get-NextIndex {
    if ($data.PSObject.Properties.Count -eq 0) { return 1 }
    return (
        $data.PSObject.Properties |
        ForEach-Object { $_.Value.index } |
        Measure-Object -Maximum
    ).Maximum + 1
}

# Ensure today exists
$today = TodayKey
if (-not $data.$today) {
    $data | Add-Member -MemberType NoteProperty -Name $today -Value @{
        index   = Get-NextIndex
        seconds = 0
        hours   = 0.0
    }
}

# -------------------------------------------------
# Persistence (atomic write)
# -------------------------------------------------
function Flush-Data {
    $json = $data | ConvertTo-Json -Depth 4
    Set-Content -Path $tempFile -Value $json -Encoding UTF8
    Move-Item -Force $tempFile $dataFile
}

Register-EngineEvent PowerShell.Exiting -Action { Flush-Data }

# -------------------------------------------------
# Stats helpers
# -------------------------------------------------
function Format-HHMMSS($totalSeconds) {
    $h = [math]::Floor($totalSeconds / 3600)
    $m = [math]::Floor(($totalSeconds % 3600) / 60)
    $s = $totalSeconds % 60
    "{0:00}:{1:00}:{2:00}" -f $h, $m, $s
}

function Get-WeeklyAverage {
    $sum = 0.0
    $days = 0

    0..6 | ForEach-Object {
        $d = (Get-Date).AddDays(-$_).ToString("yyyy-MM-dd")
        if ($data.$d) {
            $sum += $data.$d.hours
            $days++
        }
    }

    if ($days -eq 0) { return 0 }
    [math]::Round($sum / $days, 2)
}

# -------------------------------------------------
# GUI
# -------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Screen Time"
$form.Size = New-Object System.Drawing.Size(330, 160)
$form.StartPosition = "CenterScreen"

$labelTimer = New-Object System.Windows.Forms.Label
$labelTimer.Font = New-Object System.Drawing.Font("Consolas", 14)
$labelTimer.Location = New-Object System.Drawing.Point(25, 15)
$labelTimer.AutoSize = $true

$labelToday = New-Object System.Windows.Forms.Label
$labelToday.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$labelToday.Location = New-Object System.Drawing.Point(25, 55)
$labelToday.AutoSize = $true

$labelAvg = New-Object System.Windows.Forms.Label
$labelAvg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$labelAvg.Location = New-Object System.Drawing.Point(25, 80)
$labelAvg.AutoSize = $true

$form.Controls.AddRange(@(
    $labelTimer,
    $labelToday,
    $labelAvg
))

function Refresh-UI {
    $entry = $data.$(TodayKey)
    $labelTimer.Text = "Today: $(Format-HHMMSS $entry.seconds)"
    $labelToday.Text = "Hours today: $([math]::Round($entry.hours,2)) hrs"
    $labelAvg.Text   = "7-day avg: $(Get-WeeklyAverage) hrs/day"
}

$form.Add_FormClosing({
    try {
        $timer.Stop()
        Flush-Data
    } catch {}
})

# -------------------------------------------------
# Main loop
# -------------------------------------------------
$lastFlush = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$timer.Add_Tick({

    $idleMs      = [UserIdle]::GetIdleMilliseconds()
    $activeInput = $idleMs -lt ($IdleThresholdSeconds * 1000)
    $meeting     = Is-MeetingForeground

    if ($activeInput -or $meeting) {
        $entry = $data.$(TodayKey)
        $entry.seconds++
        $entry.hours = [math]::Round($entry.seconds / 3600, 4)
    }

    if ((Get-Date) - $lastFlush -ge [TimeSpan]::FromSeconds($FlushIntervalSeconds)) {
        Flush-Data
        $lastFlush = Get-Date
    }

    Refresh-UI
})

$timer.Start()
Refresh-UI
[System.Windows.Forms.Application]::Run($form)
