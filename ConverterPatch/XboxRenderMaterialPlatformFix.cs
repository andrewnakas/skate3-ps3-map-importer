using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Sk3.Stream;

namespace Sk3.Transcode;

/// <summary>
/// Platform-specific RenderMaterialData compatibility fixes plus a safe scanner
/// for importer-only lightmap repair.
///
/// The normal conversion path still remaps the known PS3-only environment.default
/// macro-overlay GUID to its X360 equivalent. Optional repairs are deliberately
/// conservative: they do not rewrite texture bindings or grow material objects.
/// </summary>
public static class XboxRenderMaterialPlatformFix
{
    public const uint RenderMaterialDataType = 0x00EB0005u;

    private static readonly byte[] Ps3Guid =
        { 0x70, 0xDE, 0x2D, 0xE0, 0xFF, 0xA4, 0xF6, 0x28 };
    private static readonly byte[] XboxGuid =
        { 0x70, 0xD7, 0x2A, 0xE0, 0xFF, 0x9E, 0xD2, 0xBA };

    private const ulong DefaultWhiteGuid = 0x2C70170A000B0040UL;

    private static readonly object LightmapGate = new();
    private static readonly HashSet<ulong> ReferencedLightmapGuids = new();
    private static bool SelectiveRepairActive;

    /// <summary>
    /// Scans every PS3 RenderMaterialData object before conversion and records
    /// only the texture GUIDs actually referenced by a non-scalar "lightmap"
    /// channel. The importer uses those GUIDs to neutralize the matching texture
    /// assets while keeping the material dependency graph completely unchanged.
    /// </summary>
    public static void PrepareSelectiveLightmapRepair(string ps3Dist)
    {
        bool enabled = string.Equals(
            Environment.GetEnvironmentVariable("SK3_IMPORTER_SELECTIVE_LIGHTMAP_REPAIR"),
            "1", StringComparison.Ordinal);

        lock (LightmapGate)
        {
            ReferencedLightmapGuids.Clear();
            SelectiveRepairActive = enabled;
        }
        if (!enabled) return;

        int materialObjects = 0;
        var found = new HashSet<ulong>();

        foreach (string path in Directory.EnumerateFiles(ps3Dist, "*.psf")
                                             .OrderBy(p => p, StringComparer.Ordinal))
        {
            IReadOnlyList<StreamAsset> assets;
            try { (_, assets) = SfilFile.Read(path); }
            catch { continue; }

            foreach (var asset in assets)
            {
                ArenaImage image;
                try { image = ArenaImage.Parse(asset.Arena); }
                catch { continue; }

                foreach (var o in image.Objects)
                {
                    if (o.TypeId != RenderMaterialDataType) continue;
                    materialObjects++;
                    foreach (ulong guid in TextureChannelGuids(o.Data, "lightmap"))
                    {
                        if (guid == 0 || guid == DefaultWhiteGuid) continue;
                        found.Add(guid);
                    }
                }
            }
        }

        lock (LightmapGate)
        {
            foreach (ulong guid in found) ReferencedLightmapGuids.Add(guid);
        }

        Console.WriteLine($"  selective lightmap scan: {found.Count} referenced texture GUID(s) from {materialObjects} RenderMaterialData object(s)");
    }

    public static bool ShouldNeutralizeLightmapAsset(ulong assetId)
    {
        lock (LightmapGate)
            return SelectiveRepairActive && ReferencedLightmapGuids.Contains(assetId);
    }

    public static byte[] Apply(byte[] source)
    {
        if (source.Length == 0) return source;

        byte[]? copy = null;
        bool changed = false;

        // RenderMaterialData channel GUIDs are big-endian u64 values.
        for (int i = 0; i <= source.Length - Ps3Guid.Length; i++)
        {
            if (!source.AsSpan(i, Ps3Guid.Length).SequenceEqual(Ps3Guid)) continue;
            copy ??= (byte[])source.Clone();
            XboxGuid.CopyTo(copy, i);
            changed = true;
            i += Ps3Guid.Length - 1;
        }

        // Stream/path strings are the same length, so an in-place text rewrite
        // preserves every relative pointer in RenderMaterialData.
        changed |= ReplaceAscii(ref copy, source,
            "70de2de0ffa4f628", "70d72ae0ff9ed2ba");
        changed |= ReplaceAscii(ref copy, source,
            "70DE2DE0FFA4F628", "70D72AE0FF9ED2BA");

        // Optional diagnostic/material workaround retained from v1.14. It only
        // zeros the scalar contribution and never changes resource references.
        if (string.Equals(Environment.GetEnvironmentVariable("SK3_IMPORTER_SUPPRESS_MACRO_OVERLAY"), "1", StringComparison.Ordinal))
            changed |= ZeroScalarChannel(ref copy, source, "macroOverlayOpacity");

        return changed ? copy! : source;
    }

    private static IEnumerable<ulong> TextureChannelGuids(byte[] source, string shaderInputName)
    {
        if (source.Length < 0x14) yield break;
        uint count = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(0x04, 4));
        uint channels = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(0x0C, 4));
        if (channels > source.Length || count > 65535) yield break;

        for (uint i = 0; i < count; i++)
        {
            long off64 = (long)channels + (long)i * 0x20;
            if (off64 < 0 || off64 + 0x20 > source.Length) yield break;
            int off = (int)off64;

            ushort flags = BinaryPrimitives.ReadUInt16BigEndian(source.AsSpan(off + 4, 2));
            if ((flags & 0x0002) != 0) continue; // scalar constant, not a texture binding

            uint shaderOff = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(off, 4));
            string name = ReadAsciiZ(source, shaderOff);
            if (!string.Equals(name, shaderInputName, StringComparison.OrdinalIgnoreCase) &&
                !name.StartsWith(shaderInputName, StringComparison.OrdinalIgnoreCase))
                continue;

            yield return BinaryPrimitives.ReadUInt64BigEndian(source.AsSpan(off + 0x10, 8));
        }
    }

    private static bool ZeroScalarChannel(ref byte[]? target, byte[] source, string shaderInputName)
    {
        if (source.Length < 0x14) return false;
        uint count = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(0x04, 4));
        uint channels = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(0x0C, 4));
        if (channels > source.Length || count > 65535) return false;

        bool changed = false;
        for (uint i = 0; i < count; i++)
        {
            long off64 = (long)channels + (long)i * 0x20;
            if (off64 < 0 || off64 + 0x20 > source.Length) break;
            int off = (int)off64;

            uint shaderOff = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(off, 4));
            ushort flags = BinaryPrimitives.ReadUInt16BigEndian(source.AsSpan(off + 4, 2));
            if ((flags & 0x0002) == 0) continue;

            string name = ReadAsciiZ(source, shaderOff);
            if (!string.Equals(name, shaderInputName, StringComparison.OrdinalIgnoreCase)) continue;

            target ??= (byte[])source.Clone();
            BinaryPrimitives.WriteUInt32BigEndian(target.AsSpan(off + 0x10, 4), 0u);
            changed = true;
        }
        return changed;
    }

    private static string ReadAsciiZ(byte[] source, uint offset)
    {
        if (offset >= source.Length) return string.Empty;
        int start = (int)offset, end = start;
        int max = Math.Min(source.Length, start + 256);
        while (end < max && source[end] != 0) end++;
        if (end <= start) return string.Empty;
        return Encoding.ASCII.GetString(source, start, end - start);
    }

    private static bool ReplaceAscii(ref byte[]? target, byte[] source,
                                     string from, string to)
    {
        byte[] a = Encoding.ASCII.GetBytes(from);
        byte[] b = Encoding.ASCII.GetBytes(to);
        if (a.Length != b.Length)
            throw new InvalidOperationException("material GUID replacement length mismatch");

        bool changed = false;
        byte[] scan = target ?? source;
        for (int i = 0; i <= scan.Length - a.Length; i++)
        {
            if (!scan.AsSpan(i, a.Length).SequenceEqual(a)) continue;
            target ??= (byte[])source.Clone();
            b.CopyTo(target, i);
            scan = target;
            changed = true;
            i += a.Length - 1;
        }
        return changed;
    }
}
