    /// <summary>GCM A8R8G8B8 with the linear (LN, 0x20) flag: uncompressed, row-major.</summary>
    public const byte Ps3Argb8Linear = 0xA5;

    /// <summary>
    /// Re-encodes an uncompressed linear A8R8G8B8 chain as DXT5 so the DXT-only Xenos tiler can
    /// take it. Rows are tight (w*4) or, failing that, padded to the header's pitch on every level.
    /// </summary>
    public static (Ps3TextureInfo Info, byte[] Payload) Argb8LinearToDxt5(Ps3TextureInfo info, byte[] src)
    {
        if (info.IsCubemap)
            throw new TranscodeException("Linear A8R8G8B8 cubemaps are not handled.");
        int mips = Math.Max(1, (int)info.MipCount);
        int tight = 0, pitched = 0;
        for (int l = 0; l < mips; l++)
        {
            int w = Math.Max(1, info.Width >> l), h = Math.Max(1, info.Height >> l);
            tight += w * 4 * h;
            pitched += (int)info.Pitch * h;
        }
        bool usePitch;
        if (src.Length >= tight && src.Length - tight < 128) usePitch = false;
        else if (info.Pitch > 0 && src.Length >= pitched && src.Length - pitched < 128) usePitch = true;
        else throw new TranscodeException(
            $"{info.Width}x{info.Height} A8R8G8B8 with {mips} mips: payload {src.Length} B matches "
            + $"neither tight ({tight}) nor pitched ({pitched}) rows.");

        var outInfo = info with { Format = 0x88 };
        var dst = new byte[LinearPayloadSize(outInfo)];
        int so = 0, dof = 0;
        var px = new byte[16 * 4]; // RGBA per texel
        for (int l = 0; l < mips; l++)
        {
            int w = Math.Max(1, info.Width >> l), h = Math.Max(1, info.Height >> l);
            int rowBytes = usePitch ? (int)info.Pitch : w * 4;
            for (int by = 0; by < h; by += 4)
            for (int bx = 0; bx < w; bx += 4)
            {
                for (int i = 0; i < 16; i++)
                {
                    int x = Math.Min(bx + (i & 3), w - 1), y = Math.Min(by + (i >> 2), h - 1);
                    int at = so + y * rowBytes + x * 4;
                    px[i * 4 + 0] = src[at + 1]; px[i * 4 + 1] = src[at + 2];
                    px[i * 4 + 2] = src[at + 3]; px[i * 4 + 3] = src[at + 0];
                }
                EncodeDxt5Block(px, dst.AsSpan(dof, 16));
                dof += 16;
            }
            so += rowBytes * h;
        }
        return (outInfo, dst);
    }

    private static void EncodeDxt5Block(byte[] px, Span<byte> block)
    {
        // Alpha: 8-value mode between the block's max and min.
        byte aMax = 0, aMin = 255;
        for (int i = 0; i < 16; i++) { byte a = px[i * 4 + 3]; if (a > aMax) aMax = a; if (a < aMin) aMin = a; }
        block[0] = aMax; block[1] = aMin;
        Span<int> ap = stackalloc int[8];
        ap[0] = aMax; ap[1] = aMin;
        for (int k = 1; k < 7; k++) ap[k + 1] = ((7 - k) * aMax + k * aMin) / 7;
        ulong abits = 0;
        for (int i = 0; i < 16; i++)
        {
            int a = px[i * 4 + 3], best = 0, bd = int.MaxValue;
            for (int k = 0; k < 8; k++) { int d = Math.Abs(a - ap[k]); if (d < bd) { bd = d; best = k; } }
            abits |= (ulong)best << (3 * i);
        }
        for (int b = 0; b < 6; b++) block[2 + b] = (byte)(abits >> (8 * b));

        // Colour: bounding-box endpoints, four-colour palette.
        int r0 = 0, g0 = 0, b0 = 0, r1 = 255, g1 = 255, b1 = 255;
        for (int i = 0; i < 16; i++)
        {
            int r = px[i * 4], g = px[i * 4 + 1], bb = px[i * 4 + 2];
            r0 = Math.Max(r0, r); g0 = Math.Max(g0, g); b0 = Math.Max(b0, bb);
            r1 = Math.Min(r1, r); g1 = Math.Min(g1, g); b1 = Math.Min(b1, bb);
        }
        static ushort To565(int r, int g, int b) => (ushort)(((r * 31 + 127) / 255 << 11) | ((g * 63 + 127) / 255 << 5) | ((b * 31 + 127) / 255));
        ushort c0 = To565(r0, g0, b0), c1 = To565(r1, g1, b1);
        if (c0 < c1) (c0, c1) = (c1, c0);
        BinaryPrimitives.WriteUInt16LittleEndian(block.Slice(8, 2), c0);
        BinaryPrimitives.WriteUInt16LittleEndian(block.Slice(10, 2), c1);
        Span<int> pal = stackalloc int[12];
        static void Expand(ushort c, Span<int> o) { o[0] = (c >> 11) * 255 / 31; o[1] = ((c >> 5) & 63) * 255 / 63; o[2] = (c & 31) * 255 / 31; }
        Expand(c0, pal.Slice(0, 3)); Expand(c1, pal.Slice(3, 3));
        for (int ch = 0; ch < 3; ch++)
        {
            pal[6 + ch] = (2 * pal[ch] + pal[3 + ch]) / 3;
            pal[9 + ch] = (pal[ch] + 2 * pal[3 + ch]) / 3;
        }
        uint cbits = 0;
        for (int i = 0; i < 16; i++)
        {
            int best = 0, bd = int.MaxValue;
            for (int k = 0; k < 4; k++)
            {
                int dr = px[i * 4] - pal[k * 3], dg = px[i * 4 + 1] - pal[k * 3 + 1], db = px[i * 4 + 2] - pal[k * 3 + 2];
                int d = dr * dr + dg * dg + db * db;
                if (d < bd) { bd = d; best = k; }
            }
            cbits |= (uint)best << (2 * i);
        }
        BinaryPrimitives.WriteUInt32LittleEndian(block.Slice(12, 4), cbits);
    }

