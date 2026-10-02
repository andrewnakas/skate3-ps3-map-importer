param(
    # A .big holding the map's authored world stream tables. For PS3 world mods that replace
    # the city (New San Van), that is the mod's data\big\miscload.big.
    [Parameter(Mandatory=$true)][string]$BigPath,
    # The converted Xbox 360 DIST folder (…\<map>\X360-DIST\DIST_*).
    [Parameter(Mandatory=$true)][string]$ConvertedDist,
    # Where to write <DIST>_Pres.xml / <DIST>_Sim.xml. Pass this folder to the importer as
    # -WorldStreamDir when converting or rebuilding a Location group.
    [Parameter(Mandatory=$true)][string]$OutDir,
    # Also complete the Sim table: add every tile whose collision reaches a centre tile (plus
    # LeadMeters of lead), while the tiles one centre streams stay under BudgetMb.
    [switch]$CompleteSim,
    [double]$LeadMeters = 100,
    [double]$BudgetMb = 12.5,
    # Keep the authored Pres (render) table too. Off by default: it streams more render tiles
    # around the skater than the generated ring, which costs memory in heavy worlds.
    [switch]$IncludePres
)

$ErrorActionPreference = "Stop"
$toolRoot = Join-Path $env:LOCALAPPDATA "Skate3PS3ToX360MapImporter\v1.00\skate3-ps3-to-x360"
$cliDll = Join-Path $toolRoot "src\Sk3.Cli\bin\Release\net9.0\Sk3.Cli.dll"
if (-not (Test-Path $cliDll)) { throw "Converter not built yet ($cliDll). Convert a map with the importer first." }
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) { $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe" }

& $dotnet $cliDll extract-world-streams $BigPath $ConvertedDist $OutDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$dist = Split-Path -Leaf ($ConvertedDist.TrimEnd('\', '/'))
if (-not $IncludePres) {
    Remove-Item -LiteralPath (Join-Path $OutDir "${dist}_Pres.xml") -Force -ErrorAction SilentlyContinue
}

if ($CompleteSim) {
    $simTable = Join-Path $OutDir "${dist}_Sim.xml"
    $authored = Join-Path $OutDir "${dist}_Sim.authored.xml"
    Copy-Item -LiteralPath $simTable -Destination $authored -Force
    $inv = [Globalization.CultureInfo]::InvariantCulture
    & $dotnet $cliDll complete-sim-table $ConvertedDist $authored $simTable $LeadMeters.ToString($inv) $BudgetMb.ToString($inv)
    $code = $LASTEXITCODE
    # Only <DIST>_Sim.xml / _Pres.xml may stay in the folder the importer reads.
    Remove-Item -LiteralPath $authored -Force -ErrorAction SilentlyContinue
    exit $code
}
exit 0
