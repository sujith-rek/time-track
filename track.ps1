Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -------------------------
# User idle detection
# -------------------------
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

# -------------------------
# Settings
# -------------------------
$IdleThresholdSeconds  = 60
$FlushIntervalSeconds = 30

$dataFile = "$PSScriptRoot\screen_time.json"
$tempFile = "$dataFile.tmp"

# -------------------------
# Load data
# -------------------------
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

# -------------------------
# Persistence (atomic)
# -------------------------
function Flush-Data {
    $json = $data | ConvertTo-Json -Depth 4
    Set-Content -Path $tempFile -Value $json -Encoding UTF8
    Move-Item -Force $tempFile $dataFile
}

Register-EngineEvent PowerShell.Exiting -Action { Flush-Data }

# -------------------------
# Stats helpers
# -------------------------
function Get-TodayHours {
    [math]::Round($data.$(TodayKey).hours, 2)
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

# -------------------------
# GUI
# -------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Screen Time"
$form.Size = New-Object System.Drawing.Size(320, 150)
$form.StartPosition = "CenterScreen"

$labelTimer = New-Object System.Windows.Forms.Label
$labelTimer.Font = New-Object System.Drawing.Font("Consolas", 14)
$labelTimer.Location = New-Object System.Drawing.Point(30, 15)
$labelTimer.AutoSize = $true

$labelToday = New-Object System.Windows.Forms.Label
$labelToday.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$labelToday.Location = New-Object System.Drawing.Point(30, 55)
$labelToday.AutoSize = $true

$labelAvg = New-Object System.Windows.Forms.Label
$labelAvg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$labelAvg.Location = New-Object System.Drawing.Point(30, 80)
$labelAvg.AutoSize = $true

$form.Controls.AddRange(@(
    $labelTimer,
    $labelToday,
    $labelAvg
))

function Format-HHMMSS($totalSeconds) {
    $h = [math]::Floor($totalSeconds / 3600)
    $m = [math]::Floor(($totalSeconds % 3600) / 60)
    $s = $totalSeconds % 60
    return "{0:00}:{1:00}:{2:00}" -f $h, $m, $s
}

function Refresh-UI {
    $entry = $data.$(TodayKey)

    $labelTimer.Text = "Today: $(Format-HHMMSS $entry.seconds)"
    $labelToday.Text = "Hours today: $([math]::Round($entry.hours, 2)) hrs"
    $labelAvg.Text   = "7-day avg: $(Get-WeeklyAverage) hrs/day"
}


# -------------------------
# Main loop (single source of truth)
# -------------------------
$lastFlush = Get-Date

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$timer.Add_Tick({

    $idleMs = [UserIdle]::GetIdleMilliseconds()

    if ($idleMs -lt ($IdleThresholdSeconds * 1000)) {
        $entry = $data.$(TodayKey)
        $entry.seconds += 1
        $entry.hours   = [math]::Round($entry.seconds / 3600, 4)
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
