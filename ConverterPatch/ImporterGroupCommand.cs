using System.Numerics;
using System.Text.Json;
using DlcBuilder;
using DlcBuilder.Inputs;
using DlcBuilder.Modules.DlcManifest;
using DlcBuilder.Modules.Orchestrator;
using DlcBuilder.Outputs;

/// <summary>
/// Importer-only CLI helper. Builds ONE Xbox DLC staging tree from multiple
/// already-converted X360 DIST folders. With every MapInput.Section left null,
/// all freeskate rows resolve to the same package map-category. This intentionally
/// mirrors stock district navigation: the top-level Locations menu shows one
/// parent such as `Community Maps (4)`, and selecting it opens a second-level
/// list containing the four independent DIST_* map locations.
/// </summary>
public static class ImporterGroupCommand
{
    private sealed class GroupConfig
    {
        public string PackageName { get; set; } = "Custom Maps";
        public string? OutputDirectory { get; set; }
        public List<GroupMap> Maps { get; set; } = new();
    }

    private sealed class GroupMap
    {
        public string DistFolderPath { get; set; } = "";
        public string DisplayName { get; set; } = "";
        public string? SlugSuffix { get; set; }
        public float SpawnX { get; set; }
        public float SpawnY { get; set; }
        public float SpawnZ { get; set; }
        public float SpawnYaw { get; set; }
    }

    public static int Run(string configPath)
    {
        try
        {
            if (!File.Exists(configPath))
                return Fail($"group config not found: {configPath}");

            var cfg = JsonSerializer.Deserialize<GroupConfig>(File.ReadAllText(configPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidOperationException("group config parsed as null");

            if (string.IsNullOrWhiteSpace(cfg.PackageName))
                return Fail("group PackageName is empty");
            if (cfg.Maps.Count == 0)
                return Fail("group contains no maps");

            var maps = new List<MapInput>(cfg.Maps.Count);
            var seenDist = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var seenSuffix = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var m in cfg.Maps)
            {
                string dist = Path.GetFullPath(m.DistFolderPath.Trim().Trim('"'));
                if (!Directory.Exists(dist))
                    return Fail($"group DIST folder is missing: {dist}");
                if (!Path.GetFileName(dist).StartsWith("DIST_", StringComparison.OrdinalIgnoreCase))
                    return Fail($"group DIST folder must begin with DIST_: {dist}");
                if (!seenDist.Add(dist))
                    return Fail($"group contains the same DIST twice: {dist}");

                string display = string.IsNullOrWhiteSpace(m.DisplayName)
                    ? Path.GetFileName(dist)["DIST_".Length..]
                    : m.DisplayName.Trim();
                string suffix = string.IsNullOrWhiteSpace(m.SlugSuffix)
                    ? DlcSpec.ToSlug(display)
                    : DlcSpec.ToSlug(m.SlugSuffix!);
                if (string.IsNullOrWhiteSpace(suffix)) suffix = "map";
                if (!seenSuffix.Add(suffix))
                    return Fail($"two group maps resolve to the same menu suffix '{suffix}'");

                maps.Add(new MapInput
                {
                    DistFolderPath = dist,
                    DisplayName = display,
                    SlugSuffix = suffix,
                    // Null is intentional: all maps go directly under the ONE
                    // package category, instead of creating another subsection.
                    Section = null,
                    SpawnX = m.SpawnX,
                    SpawnY = m.SpawnY,
                    SpawnZ = m.SpawnZ,
                    SpawnYaw = m.SpawnYaw,
                    Locators = new[]
                    {
                        new LocatorInput
                        {
                            Id = Guid.NewGuid(),
                            Name = display,
                            Position = new Vector3(m.SpawnX, m.SpawnY, m.SpawnZ),
                            RotationDegrees = new Vector3(0f, m.SpawnYaw, 0f),
                            Kind = LocatorKind.Spawn,
                            IsFreeskateMenuSlot = true,
                        }
                    }
                });
            }

            var package = new PackageInput
            {
                PackageName = cfg.PackageName.Trim(),
                Maps = maps,
            };

            string output = string.IsNullOrWhiteSpace(cfg.OutputDirectory)
                ? Path.Combine(Path.GetTempPath(), "Skate3PS3ToX360MapImporter", "group-build")
                : Path.GetFullPath(cfg.OutputDirectory!);
            Directory.CreateDirectory(output);

            Console.WriteLine($"building grouped Locations package '{package.PackageName}' with {maps.Count} map(s)");
            foreach (var m in maps)
                Console.WriteLine($"  + {m.DisplayName} -> {Path.GetFileName(m.DistFolderPath)}");

            var result = new DlcBuildOrchestrator().Build(package, output,
                new BuildOptions
                {
                    Platform = DlcPlatform.Xbox360,
                    PackBig = false,
                    PackOtsPsf = false,
                    CleanStagingAfterPack = false,
                });

            foreach (var d in result.Diagnostics)
                Console.WriteLine($"[{d.Level}] {d.Source}: {d.Message}");

            if (result.Status == BuildStatus.Failed || result.HasErrors)
                return Fail("grouped DLC staging build failed");

            Console.WriteLine($"group staging complete: {maps.Count} freeskate locations under one package category");
            Console.WriteLine($"expected Locations parent: {package.PackageName} ({maps.Count})");
            Console.WriteLine("selecting the parent opens the child-map list");
            return 0;
        }
        catch (Exception ex)
        {
            return Fail(ex.Message);
        }
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message);
        return 2;
    }
}
