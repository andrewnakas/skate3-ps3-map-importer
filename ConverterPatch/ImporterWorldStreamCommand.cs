using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Sk3.Stream;

/// <summary>
/// Importer-only CLI helper: finds a world's authored stream tables inside a .big (the mod's
/// miscload.big on PS3, for example), fits them to an already converted X360 DIST and writes
/// <c>&lt;DIST&gt;_Pres.xml</c> / <c>&lt;DIST&gt;_Sim.xml</c> for the importer's -WorldStreamDir.
/// </summary>
/// <remarks>
/// The builder generates a plain 3x3 neighbour ring per tile. Big worlds are authored with
/// wider rings where large collision objects live in a tile two away; with 3x3 those load only
/// if you arrived from their side, so the skater falls through in one direction and not the
/// other. Tables are stored RefPack-compressed; every compressed block that decodes to a
/// multi-tile &lt;StreamTiles&gt; document is a candidate, and the pair whose centres cover the
/// DIST's tiles is taken (in retail pairs the first table is Pres, the second Sim).
/// </remarks>
public static class ImporterWorldStreamCommand
{
    public static int Run(string bigPath, string convertedDist, string outDir)
    {
        var have = new HashSet<(int, int)>();
        foreach (var f in Directory.GetFiles(convertedDist, "cSim_*_high.xsf"))
        {
            var m = Regex.Match(Path.GetFileName(f), @"^cSim_(-?\d+)_(-?\d+)_high\.xsf$");
            if (m.Success) have.Add((int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value)));
        }
        if (have.Count == 0) { Console.Error.WriteLine($"no cSim tiles in {convertedDist}"); return 1; }

        var data = File.ReadAllBytes(bigPath);
        var tables = new List<List<((int, int) Center, List<(int, int)> Tiles)>>();
        for (int i = 0; i + 5 < data.Length; i++)
        {
            if (data[i] != 0x10 || data[i + 1] != 0xFB) continue;
            byte[] x;
            try { x = RefPack.Decompress(data.AsSpan(i)); } catch { continue; }
            string text = Encoding.ASCII.GetString(x);
            int lt = text.IndexOf("<StreamTiles", StringComparison.Ordinal);
            if (lt < 0) continue;
            XDocument doc;
            try { doc = XDocument.Parse(text.Substring(text.IndexOf('<'))); } catch { continue; }
            var entries = doc.Root!.Elements("StreamTile").Select(t => (
                Center: P(t.Element("Center")!.Value),
                Tiles: t.Elements("Tile").Select(e => P(e.Value)).ToList())).ToList();
            if (entries.Count > 1) tables.Add(entries);
        }

        // Candidates must cover (nearly) every tile of the converted world.
        var fits = tables.Where(t => t.Count(e => have.Contains(e.Center)) >= have.Count * 0.95).ToList();
        Console.WriteLine($"{tables.Count} world stream tables in {Path.GetFileName(bigPath)}; {fits.Count} cover {have.Count} tiles of {Path.GetFileName(convertedDist)}");
        if (fits.Count < 2) { Console.Error.WriteLine("need a Pres/Sim pair covering this world"); return 1; }

        string dist = Path.GetFileName(Path.TrimEndingDirectorySeparator(convertedDist));
        Directory.CreateDirectory(outDir);
        // Archives store <World>.xml, <World>_Pres.xml, <World>_Sim.xml in that order; some ship
        // only the last two. Either way the Pres/Sim pair is the final two candidates.
        Write(fits[^2], have, Path.Combine(outDir, $"{dist}_Pres.xml"), "Pres");
        Write(fits[^1], have, Path.Combine(outDir, $"{dist}_Sim.xml"), "Sim");
        return 0;
    }

    private static (int, int) P(string s)
    {
        var v = s.Split(',');
        return (int.Parse(v[0].Trim()), int.Parse(v[1].Trim()));
    }

    // Keep entries for tiles this world has, drop references to tiles it lacks, de-duplicate.
    private static void Write(List<((int, int) Center, List<(int, int)> Tiles)> table,
                              HashSet<(int, int)> have, string path, string kind)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"us-ascii\"?>\r\n<StreamTiles>\r\n");
        int n = 0, refs = 0, wide = 0;
        foreach (var (c, tiles) in table)
        {
            if (!have.Contains(c)) continue;
            var keep = tiles.Where(have.Contains).Distinct().ToList();
            if (keep.Any(t => Math.Max(Math.Abs(t.Item1 - c.Item1), Math.Abs(t.Item2 - c.Item2)) > 100)) wide++;
            sb.Append($"  <StreamTile>\r\n    <Center>{c.Item1}, {c.Item2}</Center>\r\n");
            foreach (var t in keep) sb.Append($"    <Tile>{t.Item1}, {t.Item2}</Tile>\r\n");
            sb.Append("  </StreamTile>\r\n");
            n++; refs += keep.Count;
        }
        sb.Append("</StreamTiles>\r\n");
        File.WriteAllText(path, sb.ToString(), Encoding.ASCII);
        Console.WriteLine($"  {kind}: {n} tiles, avg {refs / (double)Math.Max(1, n):F1} streamed each, {wide} reach past their neighbours -> {path}");
    }
}
