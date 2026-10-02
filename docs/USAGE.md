# Using the importer

## What you need

- Windows 10/11 with Windows PowerShell 5.1 (built in).
- Git. On first run the importer installs **.NET 9 SDK** and **7-Zip** through `winget` if they
  are missing (7-Zip may show an administrator prompt).
- A Skate 3 build that loads Xbox 360 DLC: **skate3recomp** or a **Skate 3 level loader engine
  build** (`skate3-engine-<version>-windows-x86_64`). v0.1.5 or newer is recommended, because its
  startup map picker is fixed.
- A PS3 Skate 3 custom map: an archive (`.rar`/`.zip`/`.7z`) or a folder containing a `DIST_*`
  world (`cPres_*.psf`, `cSim_*.psf`, `DIST_*_Pres.psm/.pmm/.pss/.pst`, ...).
- Disk space: roughly **3× the map's size** free on the drive holding the toolchain cache and output.
  A big world such as New San Van (1.7 GB of PS3 streams) produces a 3.4 GB `.big` plus a staging
  copy.

## Quick start (GUI)

1. Run **`START-MAP-IMPORTER-GUI.bat`**.
2. **Source**: browse to, or drag in, the map archive or folder. Wrapper and author folders, and
   archives nested inside archives, are fine. If the source holds several worlds, type the one you
   want in *Source DIST* (for example `DIST_NewSanVan`).
3. **Location name**: what the in-game Locations menu shows.
4. **Output folder**: where the converted map goes.
5. **Spawn X/Y/Z/Yaw**: where the skater starts (default `0,30,0,0`). See
   [Finding a spawn](#finding-a-spawn).
6. Leave the texture options **off** unless a map shows a wrong or repeating baked-light layer
   (then try *selective referenced-lightmap repair*).
7. Optional: tick *Store this map under a parent Location* to collect several maps under one menu
   entry such as `Community Maps (4)`.
8. Press **CONVERT PS3 → X360** and watch the log. The first run clones and builds the toolchain,
   which takes a few minutes.

Output, per map, in `<output>\<map-slug>\`:

| Path | What |
|---|---|
| `DLC\<map>_00000000.big` | The finished Xbox 360 DLC. This is the file you install. |
| `X360-DIST\DIST_*` | The converted world streams (reused by Location groups). |
| `Recomp-Content\` | A ready-made recomp marketplace content tree (with `.header`). |
| `Logs\build-dlc.log`, `Logs\model-validate.log` | Conversion and validation logs. |
| `conversion-info.json` | The settings and pinned revisions used. |

## Installing into the game

**Level loader engine builds (portable).** If the build folder contains `portable.txt`, the game
reads DLC from its own `dlc` folder. Copy **only the `.big`**, into a folder of its own:

```
skate3-engine-0.1.5-windows-x86_64\dlc\NEW_SAN_VAN\new_san_van_00000000.big
```

Start `skate3.exe`. The startup picker lists the packs in `dlc\`; choose yours, then find the map
under **Locations**.

**skate3recomp (non-portable).** Same idea, with `%APPDATA%\skate3\dlc\<FOLDER>\<map>_00000000.big`.
Alternatively tick *Install to Skate3Recomp* in the GUI (or run
`INSTALL-CONVERTED-MAP-TO-RECOMP.bat`), which installs the `Recomp-Content` tree.

If the game renders black on a machine with a virtual monitor (Meta Quest Link, for example), put
`fullscreen = false` in the `skate3.toml` next to `skate3.exe`.

Keep each pack's 4-character package key unique: the engine clamps the slug (`new_san_van` becomes
`news`) and two packs with the same key collide.

## Several Locations in one world

A big world usually has many authored start points. Skate's `DIST_*_Sim.loc` is an XML table of
named locators. On San Van (Skate 1/2) the freeskate Locations list is the `F_<district>_<place>`
set, for example `F_DT_Library`, `F_UR_PinkysMotel` and `F_SVM_Peak`.

`Make-LocationGroupFromLoc.ps1` turns those into a Location group whose entries all share the
converted world:

```powershell
# 1. Convert the world once, as usual (GUI or CLI).
# 2. Build the Locations list from the map's own locators and package it:
.\Make-LocationGroupFromLoc.ps1 `
    -SourceDist    "D:\maps\...\stream\DIST_NewSanVan" `
    -ConvertedDist "D:\converted\new_san_van\X360-DIST\DIST_New_San_Van" `
    -GroupName     "New San Van" `
    -OutputRoot    "D:\converted" `
    -Rebuild
```

- `-NamePattern` picks the locators (a case-sensitive regex, default `^F_`). `^Z_` gives San Van's
  secondary start points. List a map's locators first if its naming differs.
- Positions and facing come from the locator transform; `-SpawnLift` (default 0.5) raises the
  skater slightly above the authored point.
- Without `-Rebuild` it only writes `Location-Groups\<slug>\location-group.json`, which you can edit
  (rename, reorder, drop entries) and then build with:
  `Skate3-PS3-to-X360-Map-Importer.ps1 -RebuildGroupProject "<that json>" -NonInteractive`.
- The result is `Location-Groups\<slug>\DLC\<slug>_00000000.big`, one parent entry
  `New San Van (45)` that opens the 45 spots. Install it **instead of** the single-spawn `.big`,
  not next to it.

## Falling through the floor: stream tables and collision boxes

Two things decide whether the ground is loaded before the skater reaches it.

**1. The Sim stream table.** For each 100 m tile it lists the tiles to keep loaded. The builder
generates a plain 3x3 ring. Worlds that file collision in blocks larger than a tile need more: the
block is stored under one corner tile, so with a 3x3 ring it is requested only after you are
already over it, from some directions and not others (NPC skaters follow paths and ride straight
over the spot). Take the map's own authored tables and complete them:

```powershell
.\Import-WorldStreamTables.ps1 -BigPath "...\PS3_GAME\USRDIR\data\big\miscload.big" `
    -ConvertedDist "D:\converted\new_san_van\X360-DIST\DIST_New_San_Van" `
    -OutDir D:\converted\streams -CompleteSim
```

It decodes every compressed `<StreamTiles>` table in the `.big`, keeps the pair whose tiles cover
the converted world (first = Pres, second = Sim, as in retail), then `-CompleteSim` adds every tile
whose collision mesh reaches a centre tile plus `-LeadMeters` (default 100), while the tiles one
centre streams stay under `-BudgetMb` (default 12.5). Only the Sim table is written unless you add
`-IncludePres`: the authored render table streams more tiles around the skater, which costs memory
in a heavy world and has not been needed. Pass the folder to the importer with
`-WorldStreamDir`. The game does **not** read `<World>_Sim.xml` for a DLC Location: it asks for
`data\stream\dist_<location slug>dlc_Sim.xml`, so the importer writes the table under that name
for every Location as well (`World stream tables: wrote N per-Location table(s)`).

**2. The collection boxes** (`<DIST>_Sim.xss`). The game waits for ground to load only when an
unloaded wanted tile's box overlaps the skater. If the box is the tile's bare 100 m cell and the
collision filed under that tile lies outside it, the game does not wait. Convert with
`-FixCollisionBoxes` to rewrite each box to the collision the tile really holds (the original is
kept in `Logs` as `<DIST>_Sim.xss.orig`).

## Black surfaces: missing textures, families, small textures

- **Small textures.** Textures with a side of 16 px or less (tints, default-grey swatches, 16x16
  lightmap pages) are now stored as retail stores them. Before v1.18 they read back black and,
  multiplied over walls as overlay or lightmap, turned whole buildings black. Automatic.
- **Skate 2 material families.** A world built from Skate 2 (`building.default`,
  `terrain.default`, `decal.default`, ...) uses families Skate 3 has no shader for. They are
  repointed to the Skate 3 family that draws the same thing. Automatic; the log's
  `material families:` line says how many.
- **Textures the map does not ship.** A material names its texture by GUID, and a GUID only
  resolves among the tiles that are loaded. `-TextureDonorDirs "<dist>;<dist>"` copies each
  missing texture into every tile that uses it, from the world itself (textures kept only in a
  far tile) and from donor Xbox 360 worlds. For a Skate 2 city the donors are the Skate 2 world
  stream folder and its prop stream folder (`world\dmo\DMO`), extracted from your own Skate 2
  Xbox 360 disc.

`Logs\world-repairs.log` records what each repair did.

## Finding a spawn

Open the source `DIST_*_Sim.loc` in a text editor. Each `<Location>` has a `<Name>` and a
16-float `<Transform>`, and the last four floats are `x, y, z, 1`. Good single-spawn picks are names
like `*Start*`, `*Gamestart*` or `*spawn*` (New San Van: `J_Gamestart` = `1491.8, 110, -743.3`).
Add a metre to `y`.

## Command line

```powershell
# Convert (no install prompt, fail instead of asking questions)
.\Skate3-PS3-to-X360-Map-Importer.ps1 -SourcePath "D:\maps\SomeMap.7z" -DisplayName "Some Map" `
    -OutputRoot "D:\converted" -SpawnX 0 -SpawnY 30 -SpawnZ 0 -SpawnYaw 0 `
    -SkipInstallPrompt -NonInteractive
```

Useful switches: `-DistName DIST_X` (choose a world when the source holds several), `-GroupName`,
`-NeutralizeLightmaps`, `-SuppressMacroOverlay`, `-KeepStaging`, `-ForceToolchainRefresh`,
`-RebuildGroupProject <json>`, `-InstallToRecomp -RecompDir <folder with skate3.exe>`,
`-WorldStreamDir <folder>`, `-TextureDonorDirs "<dist>;<dist>"`, `-FixCollisionBoxes`.

## Big maps: disk and memory

- The toolchain cache and working files live in `%LOCALAPPDATA%\Skate3PS3ToX360MapImporter`, and
  the converter stages through `%TEMP%`. If C: is small, point both elsewhere for the run:

  ```powershell
  $env:LOCALAPPDATA = "D:\s3import\localappdata"
  $env:TEMP = "D:\s3import\tmp"; $env:TMP = $env:TEMP
  ```
- Packing a multi-GB world needs a few GB of free RAM. `$env:DOTNET_GCConserveMemory = '7'` keeps
  the converter lean. Close heavy apps if RAM is tight. Run long conversions in their own window
  rather than from a tool that may stop background jobs.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `N refused` / "converter reported unconverted/refused arenas" | The log now lists every reason, grouped (`refused xN: ...`). A new vertex or texture format means the converter needs a decoder; report it with that line. |
| Every run prints "Upgrading the existing cached converter..." | That was the pre-v1.17 CRLF marker bug. v1.17 fixes it, and upgrades once after updating. |
| Map loads but you start in the void | Wrong spawn; see [Finding a spawn](#finding-a-spawn). |
| You fall through the ground coming from one side but not the other | Stream table and collection boxes; see [Falling through the floor](#falling-through-the-floor-stream-tables-and-collision-boxes). |
| Whole walls, props or patches of ground are pure black | See [Black surfaces](#black-surfaces-missing-textures-families-small-textures). |
| Wrong/repeating texture layer over the art | Reconvert with selective referenced-lightmap repair on. |
| Infinite loading screen | Reconvert with all texture repair options off (lossless is the default). |
| Game crashes at start with a loose `.header` in `dlc\` | Old recomp builds only. Use v0.1.5+, or keep only the `.big` in `dlc\`. |

## Worked example: New San Van (RPCS3 mod)

The *Skate 3 New San Van* RPCS3 mod replaces the whole world rather than adding one map. Its
`data\content\world\stream` holds 15 `DIST_*` folders:

- **`DIST_NewSanVan` is the city**: 909 Pres + 908 Sim streams. This is the one to convert.
- `DIST_Center/Factory/Maloof/Parkade/School` are collision-only stubs, and
  `DIST_MegaPark/Stadium` have one render cell each. They are not standalone maps.
- The `*_Proxy` folders are distance LODs.

New San Van is the Skate 2 city, so it also needs textures from Skate 2 (`<sk2>` below is your
extracted Skate 2 Xbox 360 data) and its collision is filed in 200 m blocks.

```powershell
# 1. Convert the world, with the repairs it needs
.\Skate3-PS3-to-X360-Map-Importer.ps1 -SourcePath "...\PS3_GAME\USRDIR\data\content\world\stream" `
    -DistName DIST_NewSanVan -DisplayName "New San Van" -OutputRoot D:\converted `
    -SpawnX 1491.8 -SpawnY 111 -SpawnZ -743.3 `
    -TextureDonorDirs "<sk2>\data\content\world\stream\BAM;<sk2>\data\content\world\dmo\DMO" `
    -FixCollisionBoxes -SkipInstallPrompt -NonInteractive

# 2. The mod's authored stream tables, completed
.\Import-WorldStreamTables.ps1 -BigPath "...\PS3_GAME\USRDIR\data\big\miscload.big" `
    -ConvertedDist D:\converted\new_san_van\X360-DIST\DIST_New_San_Van -OutDir D:\converted\streams -CompleteSim

# 3. The 45 Locations, packed with those tables
.\Make-LocationGroupFromLoc.ps1 -SourceDist "...\stream\DIST_NewSanVan" `
    -ConvertedDist D:\converted\new_san_van\X360-DIST\DIST_New_San_Van `
    -GroupName "New San Van" -OutputRoot D:\converted
.\Skate3-PS3-to-X360-Map-Importer.ps1 -RebuildGroupProject D:\converted\Location-Groups\new_san_van\location-group.json `
    -WorldStreamDir D:\converted\streams -NonInteractive
```

The conversion refuses 0 of 41,893 arenas, remaps 2,734 materials, adds about 10,400 texture
arenas and rewrites 227 collision boxes. Install
`D:\converted\Location-Groups\new_san_van\DLC\new_san_van_00000000.big`; the group build reports
parent **New San Van (45)**. 28 texture GUIDs (crates, a slide, a gate) are on neither disc and stay
unresolved.
