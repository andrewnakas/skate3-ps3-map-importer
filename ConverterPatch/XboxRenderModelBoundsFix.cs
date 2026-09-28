using System.Buffers.Binary;

namespace Sk3.Transcode;

/// <summary>
/// Converts PS3-style zero-radius RenderModelData island AABBs into the
/// Xbox 360 form expected by the X360 render culler.
///
/// PS3 custom maps commonly store island bounds as:
///   Vector4(minX,minY,minZ,0), Vector4(maxX,maxY,maxZ,0)
/// Xbox 360 expects the W component of both vectors to contain the island
/// bounding-sphere radius. The radius is half the AABB diagonal.
///
/// Existing non-zero radii are preserved.
/// </summary>
public static class XboxRenderModelBoundsFix
{
    public const uint RenderModelDataType = 0x00EB0001u;

    public static byte[] Apply(byte[] source)
    {
        if (source.Length < 0x40)
            return source;

        ushort numIslands = BinaryPrimitives.ReadUInt16BigEndian(source.AsSpan(0x36, 2));
        uint aabbsOffsetU32 = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(0x38, 4));

        if (numIslands == 0 || aabbsOffsetU32 > int.MaxValue)
            return source;

        ulong end = (ulong)aabbsOffsetU32 + (ulong)numIslands * 32UL;
        if (end > (ulong)source.Length)
            return source;

        byte[] fixedData = (byte[])source.Clone();
        bool changed = false;

        for (int i = 0; i < numIslands; i++)
        {
            int b = checked((int)aabbsOffsetU32 + i * 32);

            uint minWBits = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(b + 12, 4));
            uint maxWBits = BinaryPrimitives.ReadUInt32BigEndian(source.AsSpan(b + 28, 4));

            // Preserve already-valid Xbox-style radii. Treat +0 and -0 as zero.
            if ((minWBits & 0x7FFFFFFFu) != 0 || (maxWBits & 0x7FFFFFFFu) != 0)
                continue;

            float minX = ReadF32(source, b + 0);
            float minY = ReadF32(source, b + 4);
            float minZ = ReadF32(source, b + 8);
            float maxX = ReadF32(source, b + 16);
            float maxY = ReadF32(source, b + 20);
            float maxZ = ReadF32(source, b + 24);

            double dx = (double)maxX - minX;
            double dy = (double)maxY - minY;
            double dz = (double)maxZ - minZ;
            float radius = (float)(Math.Sqrt(dx * dx + dy * dy + dz * dz) * 0.5);

            if (!float.IsFinite(radius) || radius <= 0.0f)
                radius = 0.001f;

            WriteF32(fixedData, b + 12, radius);
            WriteF32(fixedData, b + 28, radius);
            changed = true;
        }

        return changed ? fixedData : source;
    }

    private static float ReadF32(byte[] data, int offset)
    {
        uint bits = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset, 4));
        return BitConverter.UInt32BitsToSingle(bits);
    }

    private static void WriteF32(byte[] data, int offset, float value)
    {
        uint bits = BitConverter.SingleToUInt32Bits(value);
        BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(offset, 4), bits);
    }
}
