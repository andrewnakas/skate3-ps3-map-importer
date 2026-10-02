    /// <summary>
    /// Stores a texture with a side of 16 px or less the way retail does: top level only, in the
    /// standard Xenos tiling, with no mip chain.
    /// </summary>
    /// <remarks>
    /// The tiler's packed-mip form for these reads back black in game. They are colour tints,
    /// default-grey swatches and 16x16 lightmap pages, multiplied over walls and props as macro
    /// overlay, specular or lightmap, so whole buildings drew pure black over a good diffuse.
    /// Retail keeps a 16x16 DXT1 as its top level alone (blocks at bytes 0..56 and 512..568) with
    /// fetch-constant dword 4 = 0 and dword 5 = 0x200.
    /// </remarks>
    private static (byte[] TextureObject, byte[] TiledPayload) SmallTextureLayout(
        Ps3TextureInfo info, byte[] linearPayload, byte[] fetchConstant, byte[] tiledPayload)
    {
        if (Math.Min(info.Width, info.Height) > 16 || info.IsCubemap)
            return (XboxTextureInfoBuilder.Build(fetchConstant), tiledPayload);

        int bs = BytesPerBlock(info.Format);
        int bw = Math.Max(1, (info.Width + 3) / 4), bh = Math.Max(1, (info.Height + 3) / 4);
        if (linearPayload.Length < bw * bh * bs)
            return (XboxTextureInfoBuilder.Build(fetchConstant), tiledPayload);

        int need = 0;
        for (int y = 0; y < bh; y++)
            for (int x = 0; x < bw; x++)
                need = Math.Max(need, XenosTiledOffset(x, y, bw, bs) * bs + bs);

        var payload = new byte[Math.Max(tiledPayload.Length, (need + 15) & ~15)];
        for (int y = 0; y < bh; y++)
            for (int x = 0; x < bw; x++)
            {
                int from = (y * bw + x) * bs, to = XenosTiledOffset(x, y, bw, bs) * bs;
                // Xenos reads DXT words byte-swapped in pairs ("8-in-16").
                for (int i = 0; i < bs; i += 2)
                {
                    payload[to + i] = linearPayload[from + i + 1];
                    payload[to + i + 1] = linearPayload[from + i];
                }
            }

        var fetch = (byte[])fetchConstant.Clone();
        BinaryPrimitives.WriteUInt32BigEndian(fetch.AsSpan(16, 4), 0u);
        BinaryPrimitives.WriteUInt32BigEndian(fetch.AsSpan(20, 4), 0x200u);
        return (XboxTextureInfoBuilder.Build(fetch), payload);
    }

    /// <summary>Block index of (x, y) in the Xenos tiled layout of a surface <paramref name="width"/> blocks wide.</summary>
    private static int XenosTiledOffset(int x, int y, int width, int pitch)
    {
        int aligned = (width + 31) & ~31;
        int logBpp = (pitch >> 2) + ((pitch >> 1) >> (pitch >> 2));
        int macro = ((x >> 5) + (y >> 5) * (aligned >> 5)) << (logBpp + 7);
        int micro = ((x & 7) + ((y & 6) << 2)) << logBpp;
        int off = macro + ((micro & ~15) << 1) + (micro & 15) + ((y & 8) << (3 + logBpp)) + ((y & 1) << 4);
        return (((off & ~511) << 3) + ((off & 448) << 2) + (off & 63) + ((y & 16) << 7)
                + (((((y & 8) >> 2) + (x >> 3)) & 3) << 6)) >> logBpp;
    }

