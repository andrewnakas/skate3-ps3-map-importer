param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SawImporterFatal = $false
$Engine = Join-Path $Here 'Skate3-PS3-to-X360-Map-Importer.ps1'

function Write-PlainLine($Value) {
    if ($null -eq $Value) { return }
    $text = if ($Value -is [System.Management.Automation.InformationRecord]) {
        [string]$Value.MessageData
    } elseif ($Value -is [System.Management.Automation.ErrorRecord]) {
        [string]$Value.ToString()
    } else {
        [string]$Value
    }
    if ($text -match '^\s*ERROR:') { $script:SawImporterFatal = $true }
    [Console]::Out.WriteLine($text)
    [Console]::Out.Flush()
}

try {
    if (-not (Test-Path -LiteralPath $Engine)) { throw "Importer engine is missing: $Engine" }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "GUI job file is missing: $ConfigPath" }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue

    $invoke = @{
        SourcePath = [string]$cfg.SourcePath
        OutputRoot = [string]$cfg.OutputRoot
        DisplayName = [string]$cfg.DisplayName
        SpawnX = [double]$cfg.SpawnX
        SpawnY = [double]$cfg.SpawnY
        SpawnZ = [double]$cfg.SpawnZ
        SpawnYaw = [double]$cfg.SpawnYaw
        SkipInstallPrompt = $true
        NonInteractive = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.DistName)) { $invoke.DistName = [string]$cfg.DistName }
    $groupEnabled = ($null -ne $cfg.GroupEnabled -and [bool]$cfg.GroupEnabled)
    if ($groupEnabled) {
        $groupName = [string]$cfg.GroupName
        if ([string]::IsNullOrWhiteSpace($groupName)) { throw 'GUI requested Parent/District grouping but no parent name was supplied.' }
        $invoke.GroupName = $groupName.Trim()
        Write-PlainLine ("GUI Parent/District grouping: ENABLED -> " + $invoke.GroupName)
    } else {
        Write-PlainLine 'GUI Parent/District grouping: OFF'
    }
    if ([bool]$cfg.NeutralizeLightmaps) { $invoke.NeutralizeLightmaps = $true }
    if ([bool]$cfg.SuppressMacroOverlay) { $invoke.SuppressMacroOverlay = $true }
    if ([bool]$cfg.ForceToolchainRefresh) { $invoke.ForceToolchainRefresh = $true }
    if ([bool]$cfg.KeepStaging) { $invoke.KeepStaging = $true }
    if ([bool]$cfg.InstallToRecomp) {
        $invoke.InstallToRecomp = $true
        $invoke.RecompDir = [string]$cfg.RecompDir
    }

    # Merge every PowerShell stream and emit it through Console.Out as literal text.
    # This prevents Windows PowerShell's CLIXML serialization from filling the GUI log.
    & $Engine @invoke 6>&1 5>&1 4>&1 3>&1 2>&1 | ForEach-Object { Write-PlainLine $_ }
    # A child .ps1 can call `exit 1` without terminating this wrapper process.
    # v1.08 therefore printed an ERROR line and then returned GUI success. Treat
    # the importer's own fatal marker as authoritative and propagate failure.
    if ($script:SawImporterFatal) { exit 1 }
    exit 0
} catch {
    [Console]::Error.WriteLine('GUI worker error: ' + $_.Exception.Message)
    [Console]::Error.Flush()
    exit 1
}
