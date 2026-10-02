using System.Buffers.Binary;
using Sk3.Stream;
using Sk3.Transcode;

/// <summary>
/// Importer-only CLI helper: fills in textures a converted world's materials reference but the
/// world does not contain, taking the texture arenas from a donor Xbox 360 world.
/// </summary>
/// <remarks>
/// A material channel names its texture by GUID, and a texture arena declares the GUID it answers
/// to in its TableOfContents. A GUID no arena in the world declares resolves to nothing and the
/// mesh draws black. The New San Van PS3 mod references about 3,000 textures it never shipped;
/// the Skate 2 Xbox 360 world it was built from declares nearly all of them, and texture arenas
/// have the same layout in Skate 2 and Skate 3 on Xbox 360 (resource, 52-byte texture object,
/// TableOfContents, VersionData), so they are added unchanged.
///
/// Each donor arena is appended to every tile whose materials name it, as shared textures are in
/// stock worlds, and the tile's CMAP entry and the world's ATOC are restated.
///
/// The same is done for textures the world does hold, but only in some other tile. A GUID
/// resolves among the streams that are resident, so a texture stored once, kilometres from a
/// mesh that uses it, is black there too. New San Van keeps about 4,200 textures that way (the
/// nearest copy is never closer than 200 m). Those arenas are copied from the tile that has them.
///
/// Movable props (bins, benches, barricades, pylons) take their textures from the game's prop
/// stream, not from the world: Skate 2 keeps them in <c>world\dmo\DMO\cPres_Global.xsf</c> and
/// declares each with the top bit of its GUID set (8000NNNN03E3870A), while the world's materials
/// name the same texture without it. Skate 3 matches GUIDs exactly (its own prop materials carry
/// the bit), so a prop texture is taken from the donor with the bit cleared in its
/// TableOfContents, under a new asset id so it cannot collide with the game's resident prop stream.
/// Several donor folders may be given, separated by ';'.
/// </remarks>
public static class ImporterTextureFillCommand
{
    private const uint TextureType = 0x000200E8;
    private const uint TocType = 0x00EB000B;
    private const uint MaterialType = 0x00EB0005;

    public static int Run(string targetDist, string donorDist)
    {
        string dist = Path.GetFileName(Path.TrimEndingDirectorySeparator(targetDist));
        var tileFiles = Directory.GetFiles(targetDist, "cPres*.xsf").OrderBy(p => p, StringComparer.Ordinal).ToList();

        // Pass 1: what the target declares, and what each tile's materials ask for.
        var declared = new HashSet<ulong>();
        var declaredByTile = new Dictionary<string, HashSet<ulong>>();
        var home = new Dictionary<ulong, (string Path, ulong AssetId)>();
        var wantedByTile = new Dictionary<string, HashSet<ulong>>();
        foreach (var path in Directory.GetFiles(targetDist, "*.xsf"))
        {
            bool pres = Path.GetFileName(path).StartsWith("cPres", StringComparison.Ordinal);
            var wants = new HashSet<ulong>();
            var has = new HashSet<ulong>();
            foreach (var asset in SfilFile.Read(path).Assets)
            {
                ArenaImage img;
                try { img = ArenaImage.Parse(asset.Arena); } catch { continue; }
                foreach (ulong g in DeclaredGuids(img))
                {
                    declared.Add(g);
                    has.Add(g);
                    if (pres) home.TryAdd(g, (path, asset.AssetId));
                }
                if (pres) foreach (ulong g in MaterialGuids(img)) wants.Add(g);
            }
            if (pres) { wantedByTile[path] = wants; declaredByTile[path] = has; }
        }
        // cPres_Global is resident everywhere, so what it declares never needs a local copy.
        var global = declaredByTile.Where(kv => Path.GetFileName(kv.Key).StartsWith("cPres_Global", StringComparison.Ordinal))
                                   .SelectMany(kv => kv.Value).ToHashSet();
        int remoteRefs = wantedByTile.Sum(kv => kv.Value.Count(g => !declaredByTile[kv.Key].Contains(g) && !global.Contains(g) && home.ContainsKey(g)));
        var missing = wantedByTile.Values.SelectMany(w => w).Where(g => !declared.Contains(g)).ToHashSet();
        Console.WriteLine($"{dist}: {declared.Count} declared texture GUIDs; materials reference {missing.Count} that nothing declares, "
                          + $"and {remoteRefs} tile reference(s) to a texture held only by another tile");
        if (missing.Count == 0 && remoteRefs == 0) return 0;

        // Pass 2: donor arenas that declare a missing GUID.
        var donorByGuid = new Dictionary<ulong, StreamAsset>();
        int propTextures = 0;
        foreach (var path in donorDist.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                                      .SelectMany(d => Directory.GetFiles(d, "*.xsf")))
        {
            List<StreamAsset> assets;
            try { assets = SfilFile.Read(path).Assets; } catch { continue; }
            foreach (var asset in assets)
            {
                ArenaImage img;
                try { img = ArenaImage.Parse(asset.Arena); } catch { continue; }
                foreach (ulong g in DeclaredGuids(img))
                {
                    if (missing.Contains(g)) donorByGuid.TryAdd(g, asset);
                    else if ((g & PropBit) != 0 && missing.Contains(g & ~PropBit) && !donorByGuid.ContainsKey(g & ~PropBit))
                    {
                        donorByGuid[g & ~PropBit] = AsWorldTexture(asset, img, g);
                        propTextures++;
                    }
                }
            }
            if (donorByGuid.Count == missing.Count) break;
        }
        Console.WriteLine($"donor(s) supply {donorByGuid.Count} of {missing.Count} ({propTextures} from a prop stream)");
        if (donorByGuid.Count == 0 && remoteRefs == 0) return 0;

        // Texture arenas the world already holds, fetched from their home tile on demand.
        var homeCache = new Dictionary<string, Dictionary<ulong, StreamAsset>>();
        StreamAsset? FromHome(ulong guid)
        {
            var (homePath, assetId) = home[guid];
            if (!homeCache.TryGetValue(homePath, out var byId))
            {
                if (homeCache.Count > 24) homeCache.Clear();
                byId = SfilFile.Read(homePath).Assets.GroupBy(a => a.AssetId).ToDictionary(g => g.Key, g => g.First());
                homeCache[homePath] = byId;
            }
            return byId.GetValueOrDefault(assetId);
        }

        // Pass 3: append to the tiles that need them.
        var tiles = new Dictionary<string, (uint Size, uint Chunks)>(StringComparer.OrdinalIgnoreCase);
        var newRecords = new Dictionary<ulong, AtocFile.Record>();
        int tilesChanged = 0, added = 0;
        long bytes = 0;
        foreach (var path in tileFiles)
        {
            var need = wantedByTile[path].Where(donorByGuid.ContainsKey).Select(g => donorByGuid[g]).ToList();
            foreach (ulong g in wantedByTile[path])
                if (!declaredByTile[path].Contains(g) && !global.Contains(g) && home.ContainsKey(g)
                    && FromHome(g) is { } local)
                    need.Add(local);
            need = need.DistinctBy(a => a.AssetId).ToList();
            if (need.Count == 0) continue;
            var (header, assets) = SfilFile.Read(path);
            var have = assets.Select(a => a.AssetId).ToHashSet();
            var extra = need.Where(a => !have.Contains(a.AssetId)).ToList();
            if (extra.Count == 0) continue;
            assets.AddRange(extra);
            byte[] xsf = SfilFile.WriteXbox360Raw(header, assets);
            File.WriteAllBytes(path, xsf);
            tiles[Path.GetFileNameWithoutExtension(path)] = ((uint)xsf.Length, (uint)assets.Count);
            foreach (var a in extra)
            {
                newRecords[a.AssetId] = AtocFile.RecordFor(a.AssetId, a.Arena);
                bytes += a.Arena.Length;
            }
            tilesChanged++;
            added += extra.Count;
        }

        // Manifests: tile sizes/chunk counts in the CMAP, one ATOC record per new asset.
        string cmapPath = Path.Combine(targetDist, $"{dist}_Pres.xsm");
        var cmap = CmapFile.Read(cmapPath);
        var entries = cmap.Entries.Select(e => tiles.TryGetValue(e.Name, out var t)
            ? e with { TotalSize = t.Size, ChunkCount = t.Chunks } : e).ToList();
        File.WriteAllBytes(cmapPath, CmapFile.Write(cmap with { Entries = entries }));

        string atocPath = Path.Combine(targetDist, $"{dist}_Pres.xst");
        var atoc = AtocFile.Read(atocPath, StreamPlatform.Xbox360);
        var records = atoc.Records.ToList();
        var known = records.Select(r => r.AssetId).ToHashSet();
        records.AddRange(newRecords.Values.Where(r => known.Add(r.AssetId)));
        File.WriteAllBytes(atocPath, AtocFile.WriteXbox360(atoc.GroupHash, records));

        Console.WriteLine($"largest changed tile {(tiles.Count == 0 ? 0 : tiles.Values.Max(t => t.Size)) / 1048576.0:F1} MB");
        Console.WriteLine($"added {added} texture arena(s) ({newRecords.Count} distinct, {bytes / 1048576.0:F0} MB) to {tilesChanged} tile(s); "
                          + $"{missing.Count - donorByGuid.Count} GUID(s) still unresolved");
        return 0;
    }

    private const ulong PropBit = 0x8000000000000000;
    private const uint WorldTextureTag = 0x9B0F1678;

    /// <summary>Copies a prop-stream texture arena so it answers to the GUID without the prop bit.</summary>
    private static StreamAsset AsWorldTexture(StreamAsset asset, ArenaImage img, ulong propGuid)
    {
        byte[] arena = (byte[])asset.Arena.Clone();
        foreach (var toc in img.Objects.Where(o => o.TypeId == TocType))
            for (int i = 4; i + 8 <= toc.Data.Length; i += 4)
            {
                int at = checked((int)toc.Ptr) + i;
                if (BinaryPrimitives.ReadUInt64BigEndian(arena.AsSpan(at, 8)) != propGuid) continue;
                BinaryPrimitives.WriteUInt64BigEndian(arena.AsSpan(at, 8), propGuid & ~PropBit);
                // The word before the GUID is 9B0F1678 on every texture Skate 3 ships.
                BinaryPrimitives.WriteUInt32BigEndian(arena.AsSpan(at - 4, 4), WorldTextureTag);
            }
        return new StreamAsset(asset.AssetId ^ 0x4E53565F50524F50UL, arena);
    }

    private static IEnumerable<ulong> DeclaredGuids(ArenaImage img)
    {
        if (!img.Objects.Any(o => o.TypeId == TextureType)) yield break;
        foreach (var toc in img.Objects.Where(o => o.TypeId == TocType))
            for (int i = 0; i + 8 <= toc.Data.Length; i += 4)
                yield return BinaryPrimitives.ReadUInt64BigEndian(toc.Data.AsSpan(i, 8));
    }

    // RenderMaterialData: count at +0x04, channel table at +0x0C, 0x20 bytes per channel with the
    // flags at +4 (bit 1 = scalar constant, not a texture) and the texture GUID at +0x10.
    private static IEnumerable<ulong> MaterialGuids(ArenaImage img)
    {
        foreach (var o in img.Objects.Where(o => o.TypeId == MaterialType))
        {
            var s = o.Data;
            if (s.Length < 0x14) continue;
            uint count = BinaryPrimitives.ReadUInt32BigEndian(s.AsSpan(4, 4));
            uint table = BinaryPrimitives.ReadUInt32BigEndian(s.AsSpan(0xC, 4));
            if (count > 65535 || table > s.Length) continue;
            for (uint i = 0; i < count; i++)
            {
                long off = table + (long)i * 0x20;
                if (off + 0x20 > s.Length) break;
                if ((BinaryPrimitives.ReadUInt16BigEndian(s.AsSpan((int)off + 4, 2)) & 2) != 0) continue;
                // "Name" and "AttribulatorMaterialName" rows carry a name hash, not a texture.
                uint nameAt = BinaryPrimitives.ReadUInt32BigEndian(s.AsSpan((int)off, 4));
                if (nameAt + 4 <= s.Length && (s[nameAt] == (byte)'N' || s[nameAt] == (byte)'A')
                    && (s.AsSpan((int)nameAt).StartsWith("Name"u8) || s.AsSpan((int)nameAt).StartsWith("Attribulator"u8)))
                    continue;
                ulong guid = BinaryPrimitives.ReadUInt64BigEndian(s.AsSpan((int)off + 0x10, 8));
                if (guid != 0) yield return guid;
            }
        }
    }
}
