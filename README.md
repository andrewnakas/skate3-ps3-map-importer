# Skate 3 PS3 → Xbox 360 Map Importer

Converts PlayStation 3 Skate 3 custom maps into Xbox 360-native DLC that
skate3recomp (and the Skate 3 level loader builds) load from the
in-game Locations menu. Point it at a map archive or folder, and it produces a finished `.big`.

It is a Windows PowerShell GUI + CLI around a C# converter and EA's own DLC tooling:

```
PS3 map (.rar/.zip/.7z/folder)
  └─ importer (this repo: GUI, discovery, patches, packaging, install)
       └─ skate3-ps3-to-x360  (PS3 → Xbox 360 arena transcoder, pinned)
            └─ DumbadsSkate3ModdingTools  (ArenaBuilder + DlcBuilder.Core + EA bigfile.exe, pinned)
                 └─ <map>_00000000.big  → skate3recomp dlc folder → Locations menu
```

**How to use it:** see [docs/USAGE.md](docs/USAGE.md). Short version: run `START-MAP-IMPORTER-GUI.bat`,
pick a map, press **CONVERT**, then drop the `.big` into your recomp's `dlc` folder.

No game data is included here. The importer downloads its two pinned source dependencies on first
run, and you supply the maps.

## History

This tool is the work of several people in the **Dumbads & SunJays Skate3 Modding** Discord. In order:

### 1. Dumbads (Ethanw05): ArenaBuilder and DlcBuilder (May–June 2026)

[DumbadsSkate3ModdingTools](https://github.com/Ethanw05/DumbadsSkate3ModdingTools) is the foundation:
**ArenaBuilder Modular** (reads and writes Skate 3's PSG arenas: meshes, textures, collision, and the
Xenos texture tiler), **DlcBuilder.Core** (turns a DIST world plus spawns, challenges and triggers into
a complete DLC staging tree: manifests, vaults, unlocks, locators, menu rows), and the
**ChallengeEditor**. It also brings the pipeline that packs through EA's `bigfile.exe`. Its
2026-06-17 commit added the **Xbox 360 platform target and the `.xsf` stream-pack fix** that this
whole path depends on. Every map this importer produces is built by DlcBuilder.

### 2. andrewnakas (Nakas): the PS3 → X360 converter (August 2026)

[skate3-ps3-to-x360](https://github.com/andrewnakas/skate3-ps3-to-x360) v0.1 (2026-08-18) is the
transcoder: it reads PS3 `.psf` streams and rebuilds each arena in Xbox 360 form. That covers
vertex-buffer decode and rebuild, DXT texture re-tiling for Xenos, cubemap face layout, and
RenderModel/material conversion. It then packages the result as a standalone DLC through
DlcBuilder. Follow-ups diagnosed the Downhill Jam renderer stall (08-20) and flattened all-black
texture stubs that were rendering white (08-21).

### 3. randyadr: the GUI importer (August–September 2026)

On 2026-08-25 **randyadr** started the *PS3 Map Converter/Importer (DLC Listing)* thread and shared
the first GUI importer (v1.04). It turned the converter into something anyone can use. Over the
following releases up to **v1.16** it added:

- a Windows Forms GUI with a live log, drag and drop, and saved settings;
- archive import (`.rar`/`.zip`/`.7z`, including nested archives) and **recursive subfolder
  discovery** of the real `DIST_*` world inside wrapper and author folders;
- first-run bootstrap of Git, .NET 9 and 7-Zip, and a pinned, patched toolchain cache;
- robust EA `bigfile.exe` packing;
- converter patches for full vertex rebuild (FLOAT2 UV / stride 32), RenderModel bounds repair and
  the PS3 → X360 material GUID remap;
- stock-style **parent Location groups** ("Community Maps (4)" → child maps);
- the **DLC map manager** for uninstalling maps and removing maps from a group;
- several rounds of baked-lightmap and texture safety work, ending in v1.16's selective
  referenced-lightmap repair and lossless textures by default;
- direct install into skate3recomp.

### 4. Final pass: v1.17 (2026-09-27)

Done by andrewnakas with Claude while converting the **New San Van** RPCS3 mod, a full-city world of
909 render and 908 collision streams:

- **The cache reset bug.** The importer rebuilt its converter from scratch on every run. The marker
  file's last line ends in CRLF, and the upgrade check's regex `(?m)^…=1$` cannot match before
  `\r`. Any fix applied to the cache was silently wiped.
- **dec3n normals.** Vertex normals packed as `dec3n` (VT6) are now decoded, using the same 11:11:10
  unpacking the converter already applied to tangents.
- **Linear A8R8G8B8 textures** (GCM format `0xA5`) are now re-encoded to DXT5 before tiling.
- **All refusal reasons** are printed, grouped by reason, instead of only the first eight.
- **Many Locations in one world.** Group entries may share a DIST, and the new
  `Make-LocationGroupFromLoc.ps1` builds the Locations list from the map's own authored locators.
  New San Van gets its original 45 freeskate spots, from Downtown Library to the SVM Peak.

Result: New San Van converts with 0 of 41,893 arenas refused and 0 model-validation findings, and it
loads in the v0.1.5 level loader build.

## Credits

See [CONTRIBUTORS.md](CONTRIBUTORS.md). In short: **Dumbads (Ethanw05)** for ArenaBuilder and
DlcBuilder, **andrewnakas** for the converter, **randyadr** for the GUI importer, and the testers in
the Dumbads & SunJays Skate3 Modding Discord who fed it maps. randyadr gave permission for this
repository on 2026-09-27.

The maps you convert belong to their authors. Credit them when you share conversions.
