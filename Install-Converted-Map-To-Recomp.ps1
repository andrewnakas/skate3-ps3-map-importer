param(
    [Parameter(Position=0)]
    [string]$MapOutputFolder = "",
    [Parameter(Position=1)]
    [string]$RecompDir = ""
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Select-Folder([string]$Description) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    } catch {}
    return ""
}

function Resolve-Skate3UserDataRoot([string]$ExeRoot) {
    if (Test-Path (Join-Path $ExeRoot "portable.txt")) { return $ExeRoot }
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { Fail "APPDATA is unavailable." }
    return (Join-Path $env:APPDATA "skate3")
}

if ([string]::IsNullOrWhiteSpace($MapOutputFolder)) {
    $MapOutputFolder = Select-Folder "Select a converted map output folder containing Recomp-Content"
    if ([string]::IsNullOrWhiteSpace($MapOutputFolder)) { $MapOutputFolder = Read-Host "Paste converted map output folder" }
}
$MapOutputFolder = $MapOutputFolder.Trim().Trim('"')
$tree = Join-Path $MapOutputFolder "Recomp-Content"
if (-not (Test-Path $tree)) { Fail "No Recomp-Content folder found in: $MapOutputFolder" }

if ([string]::IsNullOrWhiteSpace($RecompDir)) {
    $RecompDir = Select-Folder "Select Skate3Recomp folder containing skate3.exe"
    if ([string]::IsNullOrWhiteSpace($RecompDir)) { $RecompDir = Read-Host "Paste Skate3Recomp folder containing skate3.exe" }
}
$RecompDir = $RecompDir.Trim().Trim('"')
if ($RecompDir.EndsWith("skate3.exe", [System.StringComparison]::OrdinalIgnoreCase)) { $RecompDir = Split-Path -Parent $RecompDir }
if (-not (Test-Path (Join-Path $RecompDir "skate3.exe"))) { Fail "That folder does not contain skate3.exe." }
if (Get-Process -Name "skate3" -ErrorAction SilentlyContinue) { Fail "Close Skate3Recomp before installing content." }

$userRoot = Resolve-Skate3UserDataRoot $RecompDir
New-Item -ItemType Directory -Force -Path $userRoot | Out-Null
Copy-Item -Path (Join-Path $tree "*") -Destination $userRoot -Recurse -Force

Write-Host ""
Write-Host "Converted Xbox 360 map content installed successfully." -ForegroundColor Green
Write-Host "Content root: $userRoot"
Write-Host "Launch skate3.exe and check Locations."
