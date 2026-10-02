using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Sk3.Stream;

/// <summary>
/// Importer-only CLI helpers that repair a converted Xbox 360 world in place. Each one fixes a
/// defect found while bringing the New San Van city (a Skate 2 world rebuilt as a PS3 Skate 3
/// mod) into Skate 3 on Xbox 360; all are no-ops on a world that does not have the defect.
/// </summary>
public static class ImporterWorldFixCommands
{
    private const uint MaterialType = 0x00EB0005;
    private const uint ClusteredMeshType = 0x00080006;

    // ── shared readers ───────────────────────────────────────────────────────

    private static uint U32(ReadOnlySpan<byte> d, int o) => BinaryPrimitives.ReadUInt32BigEndian(d.Slice(o, 4));
    private static float F32(ReadOnlySpan<byte> d, int o) => BinaryPrimitives.ReadSingleBigEndian(d.Slice(o, 4));

    /// <summary>Raw arenas of a stream file as (asset id, offset, size), walking the chunk headers.</summary>
    private static List<(ulong Asset, int Offset, int Size)> Chunks(byte[] d)
    {
        var res = new List<(ulong, int, int)>();
        if (d.Length < 0x20) return res;
        int align = (int)U32(d, 0x10), off = align;
        while (align > 0 && off + 0x20 <= d.Length)
        {
            ulong aid = BinaryPrimitives.ReadUInt64BigEndian(d.AsSpan(off, 8));
            int size = (int)U32(d, off + 8), doff = (int)U32(d, off + 12), csize = (int)U32(d, off + 16);
            if (size == 0 || doff == 0 || off + doff + size > d.Length) break;
            res.Add((aid, off + doff, size));
            off += csize != 0 ? csize : (doff + size + align - 1) / align * align;
        }
        return res;
    }

    /// <summary>Main-section objects of an arena as (type id, offset, size).</summary>
    private static List<(uint Type, int Ptr, int Size)> ArenaObjects(ReadOnlySpan<byte> a)
    {
        int sec = (int)U32(a, 0x34), dic = (int)U32(a, 0x30), n = (int)U32(a, 0x24);
        var reg = new List<uint>();
        int ents = (int)U32(a, sec + 4), first = sec + (int)U32(a, sec + 8);
        for (int i = 0; i < ents; i++)
        {
            int c = sec + (int)U32(a, first + 4 * i);
            if (U32(a, c) != 0x10005) continue;
            int cnt = (int)U32(a, c + 4), arr = c + (int)U32(a, c + 8);
            reg.Clear();
            for (int k = 0; k < cnt; k++) reg.Add(U32(a, arr + 4 * k));
        }
        var res = new List<(uint, int, int)>(n);
        for (int i = 0; i < n; i++)
        {
            int b = dic + i * 24;
            uint ti = U32(a, b + 16), tid = U32(a, b + 20);
            if (ti < reg.Count) tid = reg[(int)ti];
            res.Add((tid, (int)U32(a, b), (int)U32(a, b + 8)));
        }
        return res;
    }

    private static readonly Regex SimTile = new(@"^cSim_(-?\d+)_(-?\d+)_high\.xsf$", RegexOptions.IgnoreCase);

    private static SortedDictionary<(int X, int Z), string> SimTiles(string dist)
    {
        var tiles = new SortedDictionary<(int, int), string>();
        foreach (var p in Directory.GetFiles(dist, "cSim_*_high.xsf"))
        {
            var m = SimTile.Match(Path.GetFileName(p));
            if (m.Success) tiles[(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value))] = p;
        }
        return tiles;
    }

    /// <summary>Bounds of every ClusteredMesh (collision mesh) a Sim tile holds.</summary>
    private static List<(float[] Min, float[] Max)> TileMeshBounds(string path)
    {
        var res = new List<(float[], float[])>();
        foreach (var asset in SfilFile.Read(path).Assets)
        {
            var a = asset.Arena;
            List<(uint Type, int Ptr, int Size)> objs;
            try { objs = ArenaObjects(a); } catch { continue; }
            foreach (var (type, ptr, _) in objs)
            {
                if (type != ClusteredMeshType || ptr + 0x1C > a.Length) continue;
                res.Add((new[] { F32(a, ptr), F32(a, ptr + 4), F32(a, ptr + 8) },
                         new[] { F32(a, ptr + 0x10), F32(a, ptr + 0x14), F32(a, ptr + 0x18) }));
            }
        }
        return res;
    }

    // ── fix-material-families ────────────────────────────────────────────────

    /// Skate 2-only material families and the Skate 3 family that draws the same thing. A family
    /// Skate 3 does not know resolves to no shader, and the mesh draws black.
    private static readonly Dictionary<string, string> FamilyMap = new()
    {
        ["building.default"] = "environment.default",
        ["terrain.default"] = "environment.default",
        ["terrain.decal"] = "environment.decal",
        ["decal.default"] = "environment.decal",
        ["incandescent.backlit"] = "incandescent.default",
        ["incandescent.backlitzbias"] = "incandescent.default",
        ["incandescent.incandescentzbias"] = "incandescent.default",
        ["glare.default"] = "incandescent.transparent",
        ["water.default"] = "water.alpha",
        ["godray.spotlight"] = "incandescent.transparent",
    };

    private static int CStrLen(ReadOnlySpan<byte> s, int o)
    {
        int e = o;
        while (e < s.Length && s[e] != 0) e++;
        return e - o;
    }

    private static bool StartsWith(ReadOnlySpan<byte> s, int o, string text) =>
        o >= 0 && o + text.Length <= s.Length && s.Slice(o, text.Length).SequenceEqual(Encoding.ASCII.GetBytes(text));

    /// <summary>
    /// Repoints materials that use a Skate 2-only family to the Skate 3 one. The family is a
    /// string inside the material object, so the object never changes size: the replacement
    /// reuses a string the object already has, else is carved from the tail of the material's
    /// own debug Name, else is written over the old string when the padding after it allows.
    /// </summary>
    public static int FixMaterialFamilies(string dist)
    {
        int repoint = 0, carved = 0, inPlace = 0, noRoom = 0, files = 0;
        var perFamily = new SortedDictionary<string, int>(StringComparer.Ordinal);
        var attribulator = Encoding.ASCII.GetBytes("Attribulator");
        foreach (var f in Directory.GetFiles(dist, "cPres_*.xsf").OrderBy(p => p, StringComparer.Ordinal))
        {
            if (new FileInfo(f).Length <= 512) continue;
            var d = File.ReadAllBytes(f);
            bool dirty = false;
            foreach (var (_, a0, size) in Chunks(d))
            {
                var a = d.AsSpan(a0, size);
                if (size < 0x60 || a[0] != 0x89 || a[1] != (byte)'R' || a[2] != (byte)'W' || a[3] != (byte)'4') continue;
                if (a.IndexOf(attribulator) < 0) continue;
                List<(uint Type, int Ptr, int Size)> objs;
                try { objs = ArenaObjects(a); } catch { continue; }
                foreach (var (type, p, sz) in objs)
                {
                    if (type != MaterialType || sz < 0x14 || p + sz > size) continue;
                    var s = d.AsSpan(a0 + p, sz);
                    uint cnt = U32(s, 4), tab = U32(s, 0xC);
                    if (cnt > 65535 || tab > sz) continue;

                    var rows = new List<(int Row, int Str, string Name, (int Off, int Len)? DebugName)>();
                    (int Off, int Len)? lastName = null;
                    for (int i = 0; i < cnt; i++)
                    {
                        int o = (int)tab + i * 0x20;
                        if (o + 0x20 > sz) break;
                        int na = (int)U32(s, o);
                        if (StartsWith(s, na, "Name"))
                        {
                            int so = (int)U32(s, o + 0x18);
                            if (so > 0 && so < sz) lastName = (so, CStrLen(s, so));
                        }
                        if (StartsWith(s, na, "Attribulator"))
                        {
                            int so = (int)U32(s, o + 0x18);
                            if (so > 0 && so < sz)
                            {
                                rows.Add((o, so, Encoding.Latin1.GetString(s.Slice(so, CStrLen(s, so))), lastName));
                                lastName = null;
                            }
                        }
                    }

                    var have = new Dictionary<string, int>(StringComparer.Ordinal);
                    foreach (var r in rows) have[r.Name] = r.Str;
                    foreach (var (row, so, name, nm) in rows)
                    {
                        if (!FamilyMap.TryGetValue(name, out var replacement)) continue;
                        perFamily[name] = perFamily.GetValueOrDefault(name) + 1;
                        var bytes = Encoding.ASCII.GetBytes(replacement);
                        if (have.TryGetValue(replacement, out int at))
                        {
                            BinaryPrimitives.WriteUInt32BigEndian(s.Slice(row + 0x18, 4), (uint)at);
                            repoint++; dirty = true;
                            continue;
                        }

                        int room = so + name.Length + 1;
                        while (room < sz && s[room] == 0 && room - so < replacement.Length + 1) room++;

                        if (nm is { } dbg && dbg.Len >= replacement.Length + 8)
                        {
                            int cut = dbg.Off + dbg.Len - replacement.Length;
                            s[cut - 1] = 0;
                            bytes.CopyTo(s.Slice(cut));
                            BinaryPrimitives.WriteUInt32BigEndian(s.Slice(row + 0x18, 4), (uint)cut);
                            have[replacement] = cut;
                            carved++; dirty = true;
                        }
                        else if (room - so >= replacement.Length + 1)
                        {
                            bytes.CopyTo(s.Slice(so));
                            s[so + replacement.Length] = 0;
                            have[replacement] = so;
                            inPlace++; dirty = true;
                        }
                        else noRoom++;
                    }
                }
            }
            if (dirty) { File.WriteAllBytes(f, d); files++; }
        }

        foreach (var kv in perFamily) Console.WriteLine($"  {kv.Value,6} x {kv.Key} -> {FamilyMap[kv.Key]}");
        Console.WriteLine($"material families: {perFamily.Values.Sum()} materials ({repoint} repointed, {carved} carved from the debug name, "
                          + $"{inPlace} rewritten in place, {noRoom} had no room) in {files} tile(s)");
        return 0;
    }

    // ── fix-collision-boxes ──────────────────────────────────────────────────

    private const float PadYDown = 100f, PadYUp = 300f;

    /// <summary>
    /// Rewrites the Sim collection boxes (&lt;DIST&gt;_Sim.xss, "CSPA") so each tile's boxes contain
    /// the collision the tile holds. The game only waits for ground to load when an unloaded
    /// wanted collection's box overlaps the skater; a box that is the tile's bare 100 m cell does
    /// not contain collision filed under that tile but lying next to it, and the skater falls
    /// through before the tile is in. The first record's box defines the grid cell size and is
    /// left as a plain cell.
    /// </summary>
    public static int FixCollisionBoxes(string dist)
    {
        var xss = Directory.GetFiles(dist, "*_Sim.xss").SingleOrDefault();
        if (xss == null) { Console.Error.WriteLine($"no *_Sim.xss in {dist}"); return 1; }
        var d = File.ReadAllBytes(xss);
        if (d.Length < 0x18 || d[0] != (byte)'C' || d[1] != (byte)'S' || d[2] != (byte)'P' || d[3] != (byte)'A')
        { Console.Error.WriteLine($"{xss} is not a CSPA file"); return 1; }

        int count = (int)U32(d, 0x10);
        var byCell = new Dictionary<(int, int), int>();
        for (int i = 0; i < count; i++)
        {
            int b = 0x18 + i * 80 + 16;
            double cx = (F32(d, b) + F32(d, b + 16)) / 2.0, cz = (F32(d, b + 8) + F32(d, b + 24)) / 2.0;
            byCell[((int)Math.Round(cx), (int)Math.Round(cz))] = i;
        }

        int changed = 0, skippedFirst = 0, noCell = 0;
        foreach (var (cell, path) in SimTiles(dist))
        {
            if (new FileInfo(path).Length <= 512) continue;
            var meshes = TileMeshBounds(path);
            if (meshes.Count == 0) continue;
            if (!byCell.TryGetValue(cell, out int i)) { noCell++; continue; }
            if (i == 0) { skippedFirst++; continue; }

            var mn = new float[3]; var mx = new float[3];
            for (int k = 0; k < 3; k++) { mn[k] = meshes.Min(m => m.Min[k]); mx[k] = meshes.Max(m => m.Max[k]); }
            mn[1] -= PadYDown; mx[1] += PadYUp;

            int b = 0x18 + i * 80 + 16;
            foreach (int box in new[] { 0, 32 })
                for (int k = 0; k < 3; k++)
                {
                    BinaryPrimitives.WriteSingleBigEndian(d.AsSpan(b + box + 4 * k, 4), mn[k]);
                    BinaryPrimitives.WriteSingleBigEndian(d.AsSpan(b + box + 16 + 4 * k, 4), mx[k]);
                }
            changed++;
        }

        // No backup is left beside it: everything in the world folder is packed into the DLC.
        if (changed > 0) File.WriteAllBytes(xss, d);
        Console.WriteLine($"collision boxes: {changed} of {count} cells rewritten to their collision bounds"
                          + (skippedFirst > 0 ? $", first record left as the grid cell" : "")
                          + (noCell > 0 ? $", {noCell} tile(s) have no plain grid cell (already rewritten?)" : "") + $" -> {Path.GetFileName(xss)}");
        return 0;
    }

    // ── complete-sim-table ───────────────────────────────────────────────────

    private static (int, int) Pair(string s)
    {
        var m = Regex.Matches(s, @"-?\d+(?:\.\d+)?");
        return ((int)double.Parse(m[0].Value, CultureInfo.InvariantCulture), (int)double.Parse(m[1].Value, CultureInfo.InvariantCulture));
    }

    /// <summary>
    /// Completes a Sim stream table so every centre tile lists each tile whose collision reaches
    /// it (plus a lead distance), within a memory budget. Worlds file collision in blocks larger
    /// than a tile under one corner tile; an authored table that misses such a tile leaves a
    /// direction from which the ground is not requested until the skater is already over it.
    /// </summary>
    public static int CompleteSimTable(string dist, string authoredXml, string outXml, double lead, double budgetMb)
    {
        double budget = budgetMb * 1e6;
        var tiles = SimTiles(dist);
        var size = tiles.ToDictionary(t => t.Key, t => new FileInfo(t.Value).Length);
        var boxes = new SortedDictionary<(int X, int Z), List<(float[] Min, float[] Max)>>();
        foreach (var (t, p) in tiles)
        {
            if (size[t] <= 512) continue;
            var ms = TileMeshBounds(p);
            if (ms.Count > 0) boxes[t] = ms;
        }

        var table = new Dictionary<(int, int), List<(int, int)>>();
        string text = File.ReadAllText(authoredXml);
        foreach (Match blk in Regex.Matches(text, @"<StreamTile>(.*?)</StreamTile>", RegexOptions.Singleline))
        {
            var c = Pair(Regex.Match(blk.Groups[1].Value, @"<Center>(.*?)</Center>", RegexOptions.Singleline).Groups[1].Value);
            table[c] = Regex.Matches(blk.Groups[1].Value, @"<Tile>(.*?)</Tile>", RegexOptions.Singleline)
                            .Select(m => Pair(m.Groups[1].Value)).ToList();
        }

        HashSet<(int, int)> Need((int X, int Z) c, double ld)
        {
            double x0 = c.X - 50 - ld, x1 = c.X + 50 + ld, z0 = c.Z - 50 - ld, z1 = c.Z + 50 + ld;
            var need = new HashSet<(int, int)>();
            foreach (var (t, bs) in boxes)
                if (bs.Any(b => b.Min[0] < x1 && b.Max[0] > x0 && b.Min[2] < z1 && b.Max[2] > z0)) need.Add(t);
            return need;
        }
        long Cost((int, int) c, IEnumerable<(int, int)> list)
        {
            var set = new HashSet<(int, int)>(list) { c };
            return set.Where(size.ContainsKey).Sum(t => size[t]);
        }

        int added = 0, over = 0, shrunk = 0, gapsBefore = 0, gapsAfter = 0, maxList = 0;
        long worst = 0;
        var result = new List<((int X, int Z) Centre, List<(int, int)> List)>();
        foreach (var c in tiles.Keys)
        {
            var lst = (table.TryGetValue(c, out var authored) ? authored : new List<(int, int)>())
                      .Where(t => tiles.ContainsKey(t) && t != c).ToList();
            var baseSet = new HashSet<(int, int)>(lst) { c };
            gapsBefore += Need(c, 0).Count(t => !baseSet.Contains(t));

            var extra = new List<(int, int)>();
            foreach (double ld in new[] { lead, 50.0, 25.0, 0.0 })
            {
                extra = Need(c, ld).Where(t => !baseSet.Contains(t)).OrderBy(t => t).ToList();
                if (Cost(c, lst.Concat(extra)) <= budget || ld == 0.0) break;
                shrunk++;
            }
            if (lst.Count + extra.Count > 62) extra = extra.Take(Math.Max(0, 62 - lst.Count)).ToList();
            lst.AddRange(extra); added += extra.Count;

            long k = Cost(c, lst);
            worst = Math.Max(worst, k); if (k > budget) over++;
            maxList = Math.Max(maxList, lst.Count);
            var finalSet = new HashSet<(int, int)>(lst) { c };
            gapsAfter += Need(c, 0).Count(t => !finalSet.Contains(t));
            result.Add((c, lst));
        }

        var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"us-ascii\"?>\r\n<StreamTiles>\r\n");
        foreach (var (c, lst) in result)
        {
            sb.Append($"  <StreamTile>\r\n    <Center>{c.X}, {c.Z}</Center>\r\n");
            foreach (var t in lst) sb.Append($"    <Tile>{t.Item1}, {t.Item2}</Tile>\r\n");
            sb.Append("  </StreamTile>\r\n");
        }
        sb.Append("</StreamTiles>\r\n");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outXml))!);
        File.WriteAllText(outXml, sb.ToString(), Encoding.ASCII);

        Console.WriteLine(string.Create(CultureInfo.InvariantCulture,
            $"sim table: {result.Count} centres; authored table left {gapsBefore} tile/centre gaps; added {added} tiles; "
            + $"lead reduced at {shrunk} steps; gaps now {gapsAfter}; heaviest centre {worst / 1e6:F2} MB; over budget {over}; max list {maxList} -> {outXml}"));
        return 0;
    }
}
