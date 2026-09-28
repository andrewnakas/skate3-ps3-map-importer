param(
    # PS3 source DIST folder holding <DIST>_Sim.loc (the map's authored locator table).
    [Parameter(Mandatory=$true)][string]$SourceDist,
    # Already converted Xbox 360 DIST folder (…\<map>\X360-DIST\DIST_*), from a normal import.
    [Parameter(Mandatory=$true)][string]$ConvertedDist,
    # Parent name shown in the Locations menu, e.g. "New San Van".
    [Parameter(Mandatory=$true)][string]$GroupName,
    # The importer output root (same folder you convert into). The project is written to
    # <OutputRoot>\Location-Groups\<slug>\location-group.json.
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    # Locators whose Name matches become Locations. San Van's freeskate list is F_<district>_<place>.
    [string]$NamePattern = '^F_',
    # Raised above the authored locator so the skater does not start inside the ground.
    [double]$SpawnLift = 0.5,
    # Also run the importer's saved-group rebuild right away.
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Make-Slug([string]$Text) {
    $s = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'map' }
    return $s
}

# District codes used by the San Van locator names (Skate 1/2). Unknown codes pass through.
$Districts = [ordered]@{
    DT = 'Downtown'; OT = 'Old Town'; PJ = 'Projects'; SH = 'Soho'
    SVM = 'San Van Mountain'; UR = 'Urban Res'; WF = 'Waterfront'
}

$loc = Get-ChildItem -LiteralPath $SourceDist -Filter '*_Sim.loc' -File | Select-Object -First 1
if (-not $loc) { throw "No *_Sim.loc in $SourceDist" }
if (-not (Test-Path -LiteralPath $ConvertedDist -PathType Container)) { throw "Converted DIST not found: $ConvertedDist" }
$ConvertedDist = (Resolve-Path -LiteralPath $ConvertedDist).Path
$worldId = Split-Path -Leaf $ConvertedDist

# The .loc is plain XML: <LocationTable><Location><Name/><Category/><Transform>16 floats</Transform>.
[xml]$xml = [System.IO.File]::ReadAllText($loc.FullName, [System.Text.Encoding]::GetEncoding(28591))
$rows = foreach ($l in $xml.LocationTable.Location) {
    $name = [string]$l.Name
    if ($name -cnotmatch $NamePattern) { continue }   # case-sensitive: f_* are challenge locators
    $m = [double[]](([string]$l.Transform) -split ',' | ForEach-Object { [double]::Parse($_.Trim(), [Globalization.CultureInfo]::InvariantCulture) })
    if ($m.Count -ne 16) { continue }

    # Row 2 is the facing: DlcBuilder's Transform44.YawAt writes it as (sin, 0, cos).
    $yaw = [Math]::Round([Math]::Atan2($m[8], $m[10]) * 180 / [Math]::PI, 2)

    $rest = $name -creplace $NamePattern, ''
    $code, $place = if ($rest -match '^([A-Za-z]+)_(.+)$') { $Matches[1], $Matches[2] } else { '', $rest }
    $place = (($place -creplace '(?<=[a-z])(?=[A-Z])', ' ') -replace '_', ' ').Trim()
    $district = if ($Districts.Contains($code.ToUpperInvariant())) { $Districts[$code.ToUpperInvariant()] } else { $code }
    $display = if (-not $district) { $place }
               elseif ($place -ieq $district -or $place -ieq $code) { $district }
               else { "$district - $place" }
    $rank = [array]::IndexOf(@($Districts.Values), $district); if ($rank -lt 0) { $rank = 99 }

    [PSCustomObject]@{
        Rank = $rank; DisplayName = $display
        X = $m[12]; Y = $m[13] + $SpawnLift; Z = $m[14]; Yaw = $yaw
    }
}
$rows = @($rows | Sort-Object Rank, DisplayName)
if ($rows.Count -eq 0) { throw "No locators in $($loc.Name) match '$NamePattern'." }

$seen = @{}
$maps = foreach ($r in $rows) {
    $suffix = Make-Slug $r.DisplayName
    $n = 2; while ($seen.ContainsKey($suffix)) { $suffix = "$(Make-Slug $r.DisplayName)_$n"; $n++ }
    $seen[$suffix] = $true
    [PSCustomObject]@{
        DisplayName = $r.DisplayName; WorldId = $worldId; DistFolderPath = $ConvertedDist
        SlugSuffix = $suffix; SpawnX = $r.X; SpawnY = $r.Y; SpawnZ = $r.Z; SpawnYaw = $r.Yaw
    }
}

$groupSlug = Make-Slug $GroupName
$groupRoot = Join-Path ([System.IO.Path]::GetFullPath($OutputRoot)) "Location-Groups\$groupSlug"
New-Item -ItemType Directory -Force -Path $groupRoot | Out-Null
$projectPath = Join-Path $groupRoot 'location-group.json'
[PSCustomObject]@{
    FormatVersion = 3
    GroupName = $GroupName
    ParentLocationName = $GroupName
    GroupSlug = $groupSlug
    MenuShape = 'ParentCategoryWithChildFreeskateLocations'
    ExpectedMenuCount = @($maps).Count
    UpdatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Maps = @($maps)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $projectPath -Encoding UTF8

Write-Host "$(@($maps).Count) Locations from $($loc.Name) -> $projectPath" -ForegroundColor Green
$maps | ForEach-Object { Write-Host ("  {0,-40} {1,8:N1} {2,7:N1} {3,8:N1}  yaw {4}" -f $_.DisplayName, $_.SpawnX, $_.SpawnY, $_.SpawnZ, $_.SpawnYaw) }

if ($Rebuild) {
    & (Join-Path $Here 'Skate3-PS3-to-X360-Map-Importer.ps1') -RebuildGroupProject $projectPath -NonInteractive
    exit $LASTEXITCODE
}
Write-Host "Build it with:  Skate3-PS3-to-X360-Map-Importer.ps1 -RebuildGroupProject `"$projectPath`" -NonInteractive"
