SKATE 3 PS3 -> XBOX 360 MAP IMPORTER v1.17

Full guide: docs\USAGE.md    History and credits: README.md, CONTRIBUTORS.md

V1.17 NEW SAN VAN PASS
----------------------
- Fixed: the importer rebuilt its converter from scratch on EVERY run (the
  toolchain marker's last line ends in CRLF and the check never matched it).
  Updating to v1.17 upgrades the cache once; after that it is reused.
- Converter: vertex normals packed as dec3n (VT6) now decode.
- Converter: uncompressed linear A8R8G8B8 textures (0xA5) are re-encoded to DXT5.
- The log lists every refused arena, grouped by reason.
- Several Locations in one world: MAKE-LOCATIONS-FROM-LOC.bat /
  Make-LocationGroupFromLoc.ps1 builds a Location group from the map's own
  DIST_*_Sim.loc locators (e.g. New San Van's 45 F_* freeskate spots).

V1.16 SELECTIVE REFERENCED-LIGHTMAP REPAIR
-------------------------------------------
Some PS3 custom maps load normally but show a wrong/repeating texture layer multiplied
over otherwise-correct diffuse art. Earlier repair experiments either modified every cTex
page or rewrote material lightmap bindings; on some maps those changes caused an infinite
loading screen.

v1.16 keeps the material dependency graph unchanged. When the new repair checkbox is on,
the converter first scans RenderMaterialData and collects only GUIDs actually referenced
by texture channels named "lightmap". During PS3->X360 conversion it neutralizes only the
matching texture assets, preserving their asset IDs, material GUIDs, stream names, alpha/
mask bytes, DXT selector bits, mip structure and payload size. Unrelated textures are not
touched.

GUI option:
  Fix wrong/repeated baked-light texture (selective referenced lightmaps only)

For maps without the problem, leave it OFF. The old stock-white lightmap binding bypass
is disabled because it can make affected maps hang during world loading. The macro-overlay
option remains a separate diagnostic and should normally stay OFF unless specifically needed.

V1.13 SAFE cTex RGB-ONLY LIGHTING REPAIR
-----------------------------------------
The baked-light repair is available again, but it no longer replaces whole DXT blocks.
The old mode could make the specific maps that needed lighting repair hang forever because
it forced DXT3/DXT5 alpha to opaque and could alter DXT1 transparency semantics.

v1.13 keeps normal conversion lossless by default. When "Repair baked cTex lighting" is
checked, only the RGB565 endpoints of eligible cTex lightmap blocks are moved toward neutral
gray. Original mip/layout size, selector bits, DXT3/DXT5 alpha bytes and DXT1 alpha mode are
preserved. Automatic all-black -> gray replacement remains disabled.

V1.12 LOSSLESS TEXTURE DEFAULT
------------------------------
Some custom maps intentionally contain completely black DXT textures used as masks,
placeholders or streaming resources. The pinned converter used to replace any all-black
texture with flat gray even during normal conversion. On affected maps this can cause an
infinite loading screen.

v1.12 patches the cached converter so normal conversion preserves the source texture
payload exactly before Xenos tiling. Automatic all-black -> gray replacement is disabled,
and the old full cTex neutralization remains disabled. This is now the default and safest
texture mode. Existing v1.11/v1.10 toolchain caches are upgraded automatically once.

V1.11 LIGHTMAP SAFETY FIX
--------------------------
The old full cTex neutralization option could make some custom maps hang forever
on the loading screen. It flattened every eligible cTex page, but cTex can contain
real authored streaming/bake resources that must remain intact.

v1.11 disabled that destructive path. Authored cTex pages are preserved. The
converter still performs its built-in safe repair for blank/all-black texture
stubs automatically, so there is no checkbox needed for that repair.

If a map was previously converted with full cTex neutralization enabled and it
now hangs while loading, reconvert/reinstall that map with v1.11.

V1.11 DLC MAP MANAGER
=====================
The GUI now has a "Manage / Remove DLC Maps..." button. It opens a safe manager
for importer-created Skate3Recomp marketplace content.

- Uninstall a standalone converted map from Skate3Recomp.
- Uninstall an entire stock-style parent Location group.
- Remove ONE child map from a parent group. The importer updates
  location-group.json, rebuilds the grouped BIG with the remaining maps,
  reinstalls it, and the in-game parent count drops automatically.
- Removing the final child uninstalls the parent and removes only the saved
  parent project; normal per-map converted output is kept.
- Converted map source/output files are NOT deleted by ordinary uninstall.
- The manager only lists content tied to this importer's conversion-info.json
  or location-group.json, reducing the risk of deleting stock/other DLC.

You can also launch the manager directly with:
  MANAGE-INSTALLED-DLC-MAPS.bat

================================================

V1.09 GROUPED-UNLOCK / GUI EXIT FIX
===================================
- Group builds now remove the fresh WORLDS entitlement row written by the
  grouped DlcBuilder staging pass, preserving safe DLC_PRODUCT rows.
- The grouped staging tree is re-checked after sanitization before EA BIG packing.
- The GUI worker no longer reports success after the importer emitted a fatal
  ERROR; fatal engine errors now propagate as a failed GUI job.
- No map reconversion logic changed from v1.08.

================================================


V1.09 STOCK-STYLE PARENT FIX
----------------------------
v1.07 fixed the checkbox but still had two deployment problems that could leave
all imported maps visible as separate Name (1) entries:

1. The grouped package was installed under a pretty ContentID such as
   CUSTOM_MAPS while the generated DLC manifest uses the retail 16-character
   product_id (for example CUSTOMM000000000). v1.09 installs the group under
   the exact product_id the manifest declares.
2. Existing standalone map registrations were left installed. v1.09 removes
   the matching standalone Content folders/headers for every member of the
   parent when the grouped package is installed.

v1.09 also verifies the grouped staging tree contains exactly one package
manifest and exactly N child freeskate rows before it will pack/install it.

When grouping is enabled the GUI log must include:

  Parent grouping: ENABLED
  Group staging verified: ONE parent package -> N child freeskate row(s).
  Group manifest product_id/content folder: <16-char ID>
  Collapsing standalone map entries into the grouped parent...

After install/restart, the old member Name (1) entries should be gone and the
menu should show one parent such as:

  Custom Maps (4)

Selecting it once opens the four child map locations.

START HERE
----------
Run:

  START-MAP-IMPORTER-GUI.bat

This is a PS3 -> Xbox 360 Skate 3 map converter. Skate3Recomp installation
is optional and is only a convenient deployment target for the finished X360
DLC data.

GUI WORKFLOW
------------
1. Browse to a PS3 Skate 3 custom map archive (.rar/.zip/.7z), an extracted
   DIST_* folder, or ANY parent/wrapper folder containing the map. Drag/drop
   is supported too.
2. Enter the Location display name. The GUI normally guesses it automatically.
3. Choose the Xbox 360 output folder.
4. Set spawn X/Y/Z/Yaw if needed. Default: 0,30,0,0.
5. Texture compatibility:
     Authored texture payloads are preserved by default.
   Both full cTex neutralization and automatic all-black -> gray replacement are disabled because some maps hang while loading when authored texture resources are changed. The
   PS3 -> X360 material GUID remap remains always enabled separately.
6. Optional stock-style District / Parent Location grouping:
   - check "Store this map under a parent Location / District"
   - enter a parent name, e.g. "Community Maps"
   - convert other maps later using THE SAME parent name
   The importer rebuilds one parent category shown as Name (count). Selecting
   it once opens the child list containing every member map.
7. Optional: install the finished X360 DLC into Skate3Recomp.
8. Click "CONVERT PS3 -> X360" and watch the live log.



v1.09 - STOCK-STYLE PARENT/DISTRICT GROUPS
----------------------------------------------------------
This is the exact two-level Locations behavior used by the stock districts:

    Community Maps (4)
        -> Springfield
        -> MGS2 Substance Park
        -> Simpsons Hit & Run
        -> Springfield Elementary

The parent count is the number of child freeskate map rows in that package.
Every child can point to a DIFFERENT converted DIST_* world; they are not just
multiple spawn points in one map.

GUI workflow:
1. Check "Store this map under a parent Location / District".
2. Enter the parent name, e.g. Community Maps.
3. Convert the first PS3 map.
4. Convert more maps using the SAME parent name.
5. The importer rebuilds one grouped BIG each time.
6. Install the Location-Groups\<parent> output. When Install to Skate3Recomp
   is enabled, v1.09 automatically removes the standalone registrations for
   every saved member before installing the parent package.

The GUI shows a live preview like:
    In game: Community Maps (4) -> click once to open 4 child map locations

and "View Saved Parents..." shows every saved parent and its child maps.

Internally this is one PackageInput whose Maps collection contains all member
MapInputs. The member MapInputs leave Section unset so they all resolve directly
to the same package map category, matching the stock parent -> child-list shape.

v1.05 NEW
---------
ARCHIVE / SUBFOLDER IMPORT
- ZIP, RAR and 7Z all use 7-Zip extraction.
- Recursively scans every extracted subfolder for the real PS3 DIST data.
- Accepts author/wrapper folder names that are not themselves DIST_*.
- Detects the source world from Pres/Sim manifests when possible.
- If the outer archive contains another .zip/.rar/.7z instead of the map
  directly, the importer can inspect nested archives (up to 2 levels).
- If several real maps are present, use "Source DIST (if multiple)" to select
  the intended world instead of guessing.

TEXTURE / MATERIAL COMPATIBILITY
- Keeps the working FLOAT2 / 32-byte rebuilt Xbox vertex/UV path.
- Automatically remaps the PS3 environment.default macro-overlay material
  resource to the Xbox 360 resource. This addresses maps where the diffuse
  textures are correct but an unrelated repeating surface pattern appears over
  terrain, roofs or walls after conversion.
- Adds the automatic safe cTex blank/all-black stub repair for maps whose authored PS3
  baked-light streams do not survive the X360 conversion cleanly.
- Texture arenas are still converted/re-tiled for Xenos normally.

GROUPED LOCATIONS
- A group is ONE DLC/package/category containing multiple freeskate map rows.
- Convert the first map with a Group Name, then convert additional maps with
  that exact same Group Name.
- The group project is stored at:
    <output-root>\Location-Groups\<group-slug>\location-group.json
- Each conversion adds/updates that map and rebuilds the group BIG.
- Install the GROUP output when grouping is enabled; the importer deliberately
  chooses the group package as the install target so the just-converted map
  does not create a second standalone menu entry.
- Group output includes its own DLC, Recomp-Content, build info and README.

v1.04 FIX
---------
- Clean first-run Git/dotnet/tool bootstrap uses real native process exit codes.
  Normal Git progress written to STDERR is no longer treated as a PowerShell
  terminating error.

v1.03 FIX
---------
- Robust EA bigfile.exe handling. Known recursive directory probes are ignored
  only when they are actually directory probes; real packing failures remain
  fatal.

WHAT THE CONVERTER DOES
-----------------------
Working conversion path:
- recursive PS3 DIST discovery
- full --rebuild-vertices PS3 mesh decode/rebuild
- RenderModelData zero-radius repair
- Xbox TEX0 FLOAT2 at offset 12
- Xbox 32-byte rebuilt vertex stride
- PS3 -> X360 environment.default material GUID/stream remap
- texture arena conversion / Xenos tiling
- lossless texture conversion by default
- optional safe cTex RGB-only baked-light repair (preserves alpha/masks/selectors)
- strict Xbox RenderModel validation
- grouped WORLDS unlock sanitization + post-check
- generated freeskate Location/menu DLC metadata
- EA bigfile.exe final BIG packing

INPUT
-----
- .rar
- .zip
- .7z
- extracted DIST_* folder
- parent/wrapper folder containing a DIST_* map

OUTPUT PER MAP
--------------
<output-root>\<map-slug>\

DLC\<map>_00000000.big
    Finished Xbox 360-native Skate 3 DLC BIG.

X360-DIST\DIST_*\
    Converted Xbox 360 DIST streams/manifests (.xsf/.xst/etc.).

Recomp-Content\
    Ready-made ReXGlue/Skate3Recomp marketplace Content tree.

Logs\
    Conversion and model-validation logs.

conversion-info.json
    Conversion settings and pinned revisions.

GROUP OUTPUT
------------
<output-root>\Location-Groups\<group-slug>\

DLC\<group>_00000000.big
    One Xbox 360 DLC containing all maps currently saved in the group.

Recomp-Content\
    Ready-made grouped Recomp Content tree.

location-group.json
    Persistent member list. Keep this file with the output if you want to add
    more maps to the same group later.

DEPENDENCIES
------------
On first conversion the engine can install/find:
- Git
- .NET 9 SDK
- 7-Zip

Pinned sources:
- andrewnakas/skate3-ps3-to-x360
  1bbfb1893db656bfe5d9e81ae8b1547a2f5c9a36
- Ethanw05/DumbadsSkate3ModdingTools
  23a9d63f920bf1f77d5c2f639ebaa7c9f6424c82

The importer reuses the proven cache at:
%LOCALAPPDATA%\Skate3PS3ToX360MapImporter\v1.00

v1.16 reuses the existing cache, but the first v1.16 run hard-resets the cached
source trees to the pinned commits before applying the current fixes. This removes
stale v1.11-v1.15 experiment patches without requiring a full re-download. Use
"Force toolchain refresh / rebuild" only when you intentionally want a full clean
rebuild.

OTHER LAUNCHERS
---------------
IMPORT-PS3-MAP.bat
    Interactive CLI importer. GroupName is available. NeutralizeLightmaps now enables v1.16 selective material-referenced lightmap texture repair.

CONVERT-ONLY.bat
    Conversion-only CLI launcher.

INSTALL-CONVERTED-MAP-TO-RECOMP.bat
    Installs an existing map OR Location-Group folder's Recomp-Content tree.

XBOX 360 HARDWARE NOTE
----------------------
The converter outputs Xbox 360-native Skate 3 map/game data and an EA BIG.
It does not create/sign a retail STFS container for physical Xbox 360 hardware.
