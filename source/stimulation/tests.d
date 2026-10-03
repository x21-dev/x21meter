/// Unit tests for the core: `dub test --compiler=ldc2`.
///
/// They sit in their own module because the core modules are nothrow @nogc
/// from top to bottom, and tests want the GC. What the tests don't cover,
/// stim-check does: that the outputs stay identical to the goldens.
module stimulation.tests;

version (unittest):

// The druntime runs the unittests before main, so an empty one is all the
// test executable needs.
version (StimUnittestMain) void main() {}

import std.algorithm : max, min;
import std.math : isFinite, sin, PI;
import std.format : format;

import canvasity : Canvasity;
import gamut : Image, PixelType;

import stimulation.analyser;
import stimulation.buildid;
import stimulation.engine;
import stimulation.fingerprint;
import stimulation.timeline;

/// A few seconds of music-like test material: a tone, decaying bursts and
/// some noise, different in the two channels. Deterministic.
float[][2] testSignal(float sr, double seconds)
{
    immutable size_t n = cast(size_t)(sr * seconds);
    float[][2] ch = [new float[n], new float[n]];
    uint lcg = 12_345;
    foreach (i; 0 .. n)
    {
        immutable double t = i / sr;
        lcg = lcg * 1_664_525u + 1_013_904_223u;
        immutable double noise = (lcg >> 8) / cast(double)(1 << 24) - 0.5;
        immutable double burstT = t % 0.37;
        immutable double burst = sin(2 * PI * 1_320 * t) * 0.6 * (1 - burstT / 0.37) ^^ 6;
        immutable double tone = 0.3 * sin(2 * PI * 110 * t) + 0.1 * sin(2 * PI * 2_217 * t);
        ch[0][i] = cast(float)(tone + burst + 0.05 * noise);
        ch[1][i] = cast(float)(tone + 0.8 * burst - 0.05 * noise);
    }
    return ch;
}

/// Runs the whole signal through a fresh engine in blocks of the given
/// sizes, repeated until the signal is used up.
FramePacket[] runInBlocks(ref StimEngine engine, float[][2] sig, const(int)[] pattern)
{
    FramePacket[] all;
    size_t pos = 0, k = 0;
    while (pos < sig[0].length)
    {
        immutable size_t want = pattern[k++ % pattern.length];
        immutable int n = cast(int) min(want, sig[0].length - pos);
        auto buf = new FramePacket[engine.maxFrames(n)];
        immutable int got = engine.process(sig[0].ptr + pos, sig[1].ptr + pos, n, buf);
        all ~= buf[0 .. got];
        pos += n;
    }
    return all;
}

FramePacket[] runFresh(float sr, float[][2] sig, const(int)[] pattern)
{
    StimEngine engine;
    engine.initialize(sr);
    scope (exit) engine.destroy();
    return runInBlocks(engine, sig, pattern);
}

void assertSamePackets(const(FramePacket)[] a, const(FramePacket)[] b, string what)
{
    assert(a.length == b.length, format("%s: %d frames vs %d", what, a.length, b.length));
    foreach (i; 0 .. a.length)
        assert(a[i].f == b[i].f && a[i].print == b[i].print,
               format("%s: frame %d differs", what, i));
}

@("the host's block size does not change any result")
unittest
{
    immutable float sr = 44_100;
    auto sig = testSignal(sr, 3.0);
    auto reference = runFresh(sr, sig, [cast(int) sig[0].length]);
    assert(reference.length > 100);

    static immutable int[][] patterns = [[1], [7], [64], [511], [882], [4096], [3, 1000, 17, 256, 4096, 1]];
    foreach (p; patterns)
        assertSamePackets(runFresh(sr, sig, p), reference, format("blocks %s", p));

    // A pseudo-random pattern, as some hosts produce.
    int[] random;
    uint lcg = 99;
    foreach (i; 0 .. 200) { lcg = lcg * 1_664_525u + 1_013_904_223u; random ~= 1 + (lcg >> 20) % 3000; }
    assertSamePackets(runFresh(sr, sig, random), reference, "random blocks");
}

@("initialize() can be called again, and reset() starts over")
unittest
{
    auto sig44 = testSignal(44_100, 2.0);
    auto sig96 = testSignal(96_000, 2.0);
    auto fresh44 = runFresh(44_100, sig44, [512]);

    StimEngine engine;
    scope (exit) engine.destroy();
    engine.initialize(44_100);
    runInBlocks(engine, sig44, [512]);
    engine.initialize(96_000);
    assert(engine.info.hopLen == 1920);
    runInBlocks(engine, sig96, [512]);
    engine.initialize(44_100);
    assertSamePackets(runInBlocks(engine, sig44, [512]), fresh44, "after re-initialize");

    engine.reset();
    assertSamePackets(runInBlocks(engine, sig44, [512]), fresh44, "after reset");

    engine.destroy();   // twice is fine
}

@("the smoothing defaults to PRINT_SMOOTH_FRAMES and changes the fingerprint only")
unittest
{
    immutable float sr = 44_100;
    auto sig = testSignal(sr, 3.0);
    auto reference = runFresh(sr, sig, [4096]);

    StimEngine engine;
    scope (exit) engine.destroy();
    engine.initialize(sr, PRINT_SMOOTH_FRAMES);
    assertSamePackets(runInBlocks(engine, sig, [4096]), reference, "explicit default");

    // Longer smoothing: the same features, a different fingerprint. The
    // setting survives reset() but not a plain initialize().
    engine.initialize(sr, 120);
    auto longer = runInBlocks(engine, sig, [4096]);
    engine.reset();
    assertSamePackets(runInBlocks(engine, sig, [4096]), longer, "120 after reset");
    assert(longer.length == reference.length);
    bool differs = false;
    foreach (i; 0 .. longer.length)
    {
        assert(longer[i].f == reference[i].f, format("frame %d: features changed", i));
        differs = differs || longer[i].print != reference[i].print;
    }
    assert(differs, "smoothing 120 gave the same fingerprint as the default");
    engine.initialize(sr);
    assertSamePackets(runInBlocks(engine, sig, [4096]), reference, "back to the default");
}

@("every packet field is finite, silence and extremes included")
unittest
{
    immutable float sr = 48_000;
    immutable size_t n = 96_000;
    float[][2] silence = [new float[n], new float[n]];
    silence[0][] = 0; silence[1][] = 0;
    float[][2] dc = [new float[n], new float[n]];
    dc[0][] = 0.5f; dc[1][] = 0.5f;
    float[][2] square = [new float[n], new float[n]];
    foreach (i; 0 .. n) square[0][i] = square[1][i] = (i / 100) % 2 ? 1.0f : -1.0f;

    foreach (name, sig; ["silence": silence, "dc": dc, "full-scale square": square])
    {
        auto packets = runFresh(sr, sig, [1024]);
        assert(packets.length > 50, name);
        foreach (i, ref p; packets)
        {
            bool ok = isFinite(p.f.fullCrestDb) && isFinite(p.f.fLowSemitones)
                   && isFinite(p.f.fHighSemitones) && isFinite(p.f.centroidSemitones)
                   && isFinite(p.f.flux) && isFinite(p.f.stereoWidth)
                   && isFinite(p.print.balance) && isFinite(p.print.weight) && isFinite(p.print.score)
                   && isFinite(p.print.red) && isFinite(p.print.green) && isFinite(p.print.blue);
            foreach (b; 0 .. NBANDS)
                ok = ok && isFinite(p.f.bandLevelDb[b]) && isFinite(p.f.bandCrestDb[b]);
            assert(ok, format("%s: frame %d has a non-finite field", name, i));
        }
    }
    // Silence is silent, and the score holds at the top.
    auto quiet = runFresh(sr, silence, [1024]);
    assert(quiet[$ - 1].print.silent);
    assert(scoreGrade(quiet[$ - 1].print.score) == 'A');
}

@("the unclamped channels give the colour and the balance")
unittest
{
    immutable float sr = 44_100;
    auto packets = runFresh(sr, testSignal(sr, 4.0), [4096]);
    bool outside = false;
    foreach (i, ref p; packets)
    {
        if (p.print.silent) continue;
        immutable PrintColour c = printColour(p.print.red, p.print.green, p.print.blue);
        assert(c.balance == p.print.balance, format("frame %d: %s vs %s", i, c.balance, p.print.balance));
        assert(c.colour == p.print.colour, format("frame %d: %s vs %s", i, c.colour, p.print.colour));
        outside = outside || p.print.red < 0 || p.print.red > 1 || p.print.green < 0
               || p.print.green > 1 || p.print.blue < 0 || p.print.blue > 1;
    }
    assert(outside, "no channel left 0..1, so nothing shows they are unclamped");
}

@("P90Tracker follows the exact nearest-rank p90, gaps included")
unittest
{
    import std.algorithm : sort;
    import std.random : Random, uniform;

    auto rng = Random(42);
    P90Tracker t;
    uint[] all;

    // Gappy distribution (0, 8, 16, 24) so the pointer must skip empty buckets.
    foreach (i; 0 .. 2000)
    {
        immutable k = uniform(0u, 4u, rng) * 8;
        t.add(k);
        all ~= k;

        auto s = all.dup;
        sort(s);
        assert(t.p90 == s[(9 * s.length + 9) / 10 - 1]);
    }
}

@("channel buckets and letters: x 28, whole buckets, 31 and up in 31")
unittest
{
    assert(channelBucket(-0.0f) == 0);
    assert(channelBucket(0.0f) == 0);
    assert(channelBucket(0.99f / 28) == 0);
    assert(channelBucket(1.0f / 28) == 1);
    assert(channelBucket(27.5f / 28) == 27);
    assert(channelBucket(1.0f) == 28);
    // Just either side of a boundary: the float nearest 31/28 itself, times
    // 28, rounds to 30.999998, so exact boundaries aren't tested.
    assert(channelBucket(30.99f / 28) == 30);
    assert(channelBucket(31.01f / 28) == 31);
    assert(channelBucket(1e30f) == 31);
    assert(channelBucket(float.infinity) == 31);

    assert(channelGrade(-1) == '-' && channelGrade(0) == '-' && channelGrade(1) == '-');
    assert(channelGrade(2) == 'z' && channelGrade(26) == 'b' && channelGrade(27) == 'a');
    assert(channelGrade(28) == 'A' && channelGrade(29) == 'B' && channelGrade(31) == 'D');
}

@("the channel scores are the p90 of each channel's buckets so far, below 0 left out")
unittest
{
    import std.algorithm : sort;

    immutable float sr = 44_100;
    auto sig = testSignal(sr, 4.0);
    // A second of silence first: silent frames count nothing, so every
    // channel reads -1 until the music starts. (A gap later on wouldn't do:
    // the smoothed window takes far longer than that to fall silent.)
    sig[0][0 .. 44_100] = 0;
    sig[1][0 .. 44_100] = 0;
    auto packets = runFresh(sr, sig, [4096]);

    uint[][3] seen;
    bool silence = false, negative = false, counted = false;
    foreach (i, ref p; packets)
    {
        silence = silence || p.print.silent;
        if (!p.print.silent)
        {
            immutable float[3] v = [p.print.red, p.print.green, p.print.blue];
            foreach (c; 0 .. 3)
            {
                if (v[c] >= 0) seen[c] ~= channelBucket(v[c]);
                else negative = true;
            }
        }
        immutable byte[3] got = [p.print.redP90, p.print.greenP90, p.print.blueP90];
        foreach (c; 0 .. 3)
        {
            if (seen[c].length == 0)
            {
                assert(got[c] == -1, format("frame %d channel %d: %d before any value", i, c, got[c]));
                continue;
            }
            auto s = seen[c].dup;
            sort(s);
            assert(got[c] == s[(9 * s.length + 9) / 10 - 1],
                   format("frame %d channel %d: %d", i, c, got[c]));
            counted = true;
        }
    }
    assert(silence && negative && counted,
           format("the signal no longer tests: silence %s, negative values %s, counting %s",
                  silence, negative, counted));
}

@("lane geometry stays ordered and inside the picture at every scale")
unittest
{
    auto g1 = TimelineGeometry.atScale(1.0f);
    assert(g1.height == TIMELINE_HEIGHT && g1.spectrum == LANE_SPECTRUM && g1.live == LANE_LIVE);

    StreamInfo info;
    info.sampleRate = 48_000;
    {
        StimEngine e;
        e.initialize(48_000);
        info = e.info;
        e.destroy();
    }

    for (float s = 0.6f; s <= 2.5f; s += 0.05f)
    {
        auto g = TimelineGeometry.atScale(s);
        const Lane[9] lanes = [g.print, g.gradeA, g.balance, g.channels, g.spectrum,
                               g.dynamics, g.flux, g.width, g.live];
        foreach (i, lane; lanes)
        {
            assert(lane.height > 0, format("scale %.2f: lane %d is empty", s, i));
            if (i > 0) assert(lane.top > lanes[i - 1].bottom, format("scale %.2f: lanes %d and %d touch", s, i - 1, i));
        }
        assert(g.live.bottom <= g.height);

        int[NBANDS] top, bottom;
        g.bandRows(info.bandCentres, info.sampleRate, top, bottom);
        foreach (b; 0 .. NBANDS)
        {
            assert(top[b] >= g.spectrum.top && bottom[b] <= g.spectrum.bottom);
            assert(top[b] <= bottom[b]);
            if (b > 0) assert(bottom[b] == top[b - 1], format("scale %.2f: gap above band %d", s, b - 1));
        }
    }
}

@("the renderer draws at any scale without leaving the image")
unittest
{
    immutable float sr = 44_100;
    auto sig = testSignal(sr, 2.0);
    StimEngine engine;
    engine.initialize(sr);
    scope (exit) engine.destroy();
    auto packets = runInBlocks(engine, sig, [4096]);

    foreach (s; [0.66f, 1.0f, 1.5f, 2.0f])
    {
        TimelineRenderer r;
        r.initialize(engine.info, s);
        auto image = Image(cast(int) packets.length, r.geometry.height, PixelType.rgba8);
        foreach (x, ref p; packets)
            r.drawColumn(image, cast(int) x, p, 1.0f, false);
        // The fingerprint strip got the fingerprint's colour.
        const px = cast(const(ubyte)*) image.scanptr(r.geometry.print.top) + 4 * (packets.length - 1);
        immutable Rgba c = packets[$ - 1].print.colour;
        assert(px[0] == c.r && px[1] == c.g && px[2] == c.b, format("scale %.2f", s));
    }
}

@("blendColumn draws exactly what Canvasity's fillRect does")
unittest
{
    // Random one-pixel-wide rectangles over random opaque backgrounds, in
    // both images: fractional ends, whole rows, slivers below Canvasity's
    // cut-offs, negative heights and rectangles running off the image.
    enum int W = 64, H = 200;
    auto a = Image(W, H, PixelType.rgba8), b = Image(W, H, PixelType.rgba8);
    uint lcg = 11;
    uint next() { lcg = lcg * 1_664_525u + 1_013_904_223u; return lcg >> 8; }
    float uniform(float lo, float hi) { return lo + (hi - lo) * (next() / cast(float)(1 << 24)); }

    foreach (y; 0 .. H)
        foreach (x; 0 .. W)
        {
            immutable Rgba bg = Rgba(cast(ubyte) next(), cast(ubyte) next(), cast(ubyte) next());
            putColumn(a, x, y, y + 1, bg);
            putColumn(b, x, y, y + 1, bg);
        }

    auto canvas = Canvasity(b);
    static immutable float[] heights = [1, 2, 0.5f, 1e-5f, 3e-5f, 1e-3f, 0.2f];
    foreach (i; 0 .. 4000)
    {
        immutable int   x = next() % W;
        immutable float y = uniform(-10, H + 10);
        immutable float h = i % 3 == 0 ? heights[next() % heights.length] * (next() % 2 ? 1 : -1)
                                       : uniform(-40, 40);
        immutable Rgba  c = Rgba(cast(ubyte) next(), cast(ubyte) next(), cast(ubyte) next(),
                                 i % 4 == 0 ? 255 : cast(ubyte) next());
        blendColumn(a, x, y, h, c);
        canvas.fillStyle = c;
        canvas.fillRect(x, y, 1, h);
    }

    foreach (y; 0 .. H)
    {
        const pa = cast(const(ubyte)*) a.scanptr(y), pb = cast(const(ubyte)*) b.scanptr(y);
        foreach (i; 0 .. 4 * W)
            assert(pa[i] == pb[i], format("row %d, byte %d: %d, Canvasity %d", y, i, pa[i], pb[i]));
    }
}

@("the window score is the score of the last A_WINDOW_S seconds alone")
unittest
{
    import std.math : isClose;
    auto packets = runFresh(44_100, testSignal(44_100, 5.0), [4096]);
    assert(packets.length > A_WINDOW_FRAMES + 50);
    foreach (n, ref p; packets)
    {
        if (n + 1 < A_WINDOW_FRAMES)
        {
            assert(p.print.windowScore == 0, format("frame %d: a score before the window is full", n));
            continue;
        }
        double sum = 0;
        foreach (ref q; packets[n + 1 - A_WINDOW_FRAMES .. n + 1])
            sum += shaped(q.print.balance);
        immutable double expected = shaped(sum / A_WINDOW_FRAMES) * SCORE_SCALE;
        assert(isClose(p.print.windowScore, expected, 1e-5), format("frame %d", n));
    }
}

@("the A lane underscores exactly the frames of every window that scores an A")
unittest
{
    // Windows scoring an A end at these frames; the rest do not.
    static immutable long[] ends = [149, 150, 400, 460, 470, 900];
    PrintFrame a, notA;
    a.windowScore = 27.5f;
    notA.windowScore = 26.9f;
    assert(a.windowIsA() && !notA.windowIsA());

    bool[1000] marked, expected;
    Underscore u;
    foreach (long n; 0 .. 1000)
    {
        bool isEnd = false;
        foreach (e; ends) isEnd = isEnd || e == n;
        immutable long from = u.push(n, isEnd ? a : notA);
        assert(from >= 0 && from <= n + 1);
        foreach (k; from .. n + 1)
        {
            assert(!marked[k], format("frame %d marked twice", k));
            marked[k] = true;
        }
    }
    foreach (e; ends)
        expected[e + 1 - A_WINDOW_FRAMES .. e + 1] = true;
    assert(marked == expected);
}

@("FPControl flushes denormals, and process() leaves the caller's mode alone")
unittest
{
    import inteli.xmmintrin : _mm_getcsr, _MM_FLUSH_ZERO_MASK;
    import stimulation.fpcontrol : FPControl;

    // What process() switches on. On arm64 intel-intrinsics maps this bit to
    // the FPCR's flush-to-zero flag, so the test means the same there.
    {
        FPControl fpc;
        fpc.initialize();
        assert(_mm_getcsr() & _MM_FLUSH_ZERO_MASK, "flush-to-zero is off inside FPControl");
    }

    // ... and it is undone on return, whatever mode the caller was in.
    immutable uint before = _mm_getcsr();
    auto sig = testSignal(44_100, 0.5);
    runFresh(44_100, sig, [4096]);
    assert(_mm_getcsr() == before, "process() changed the caller's floating-point mode");
}

@("the spectrum matches a DFT in double precision")
unittest
{
    import std.math : cos, sqrt;
    foreach (n; [8, 64, 2048, 8192])
    {
        auto x = new float[n];
        uint lcg = 7;
        foreach (i; 0 .. n)
        {
            lcg = lcg * 1_664_525u + 1_013_904_223u;
            x[i] = cast(float)((lcg >> 8) / cast(double)(1 << 24) - 0.5
                               + 0.3 * sin(2 * PI * 5.3 * i / n));
        }
        SpectrumEngine s;
        s.initialize(n);
        scope (exit) s.destroy();
        s.forward(x);

        // Every bin at the small sizes, a spread of them at the large ones.
        double worst = 0, scale = 0;
        foreach (i; 0 .. n) scale += x[i] * x[i];
        scale = sqrt(scale * n);      // the size of a full-scale bin
        for (int k = 0; k <= n / 2; k += n <= 64 ? 1 : 37)
        {
            double re = 0, im = 0;
            foreach (i; 0 .. n)
            {
                re += x[i] * cos(2 * PI * (cast(long) k * i % n) / n);
                im -= x[i] * sin(2 * PI * (cast(long) k * i % n) / n);
            }
            immutable double dr = s.rePtr()[s.stride * k] - re, di = s.imPtr()[s.stride * k] - im;
            worst = max(worst, sqrt(dr * dr + di * di) / scale);
        }
        assert(worst < 1e-6, format("n %d: error %.3g of full scale", n, worst));
    }
}

@("each band passes the same energy at every sample rate")
unittest
{
    import std.complex : cabs = abs, expi;
    import std.math : abs, log10, PI;

    // Energy through one band (its two sections) for a flat spectrum over
    // the analysed range, 20 Hz to 16 kHz, and the gain at its centre.
    static void measure(float sr, out double[NBANDS] energyDb, out double[NBANDS] peakDb)
    {
        BandBank bank;
        bank.initialize(sr);
        foreach (b; 0 .. NBANDS)
        {
            double gainSq(double hz)
            {
                immutable z1 = expi(-2 * PI * hz / sr), z2 = z1 * z1;
                immutable h = (bank.b0[b] + bank.b1[b] * z1 + bank.b2[b] * z2)
                            / (1.0 + bank.a1[b] * z1 + bank.a2[b] * z2);
                return cabs(h) ^^ 2;
            }
            double sum = 0;
            enum int steps = 20_000;
            foreach (i; 0 .. steps)
                sum += gainSq(20.0 + (16_000.0 - 20.0) * (i + 0.5) / steps) ^^ 2;
            energyDb[b] = 10 * log10(sum / steps);
            peakDb[b]   = 10 * log10(gainSq(bank.centreHz[b]));
        }
    }

    double[NBANDS] ref44, peak44;
    measure(44_100, ref44, peak44);
    foreach (sr; [48_000.0f, 96_000.0f, 192_000.0f])
    {
        double[NBANDS] e, p;
        measure(sr, e, p);
        foreach (b; 0 .. NBANDS)
        {
            assert(abs(e[b] - ref44[b]) < 0.05,
                   format("band %d: %.3f dB at %.0f Hz, %.3f dB at 44.1 kHz", b, e[b], sr, ref44[b]));
            assert(abs(p[b]) < 0.01, format("band %d at %.0f Hz: peak %.3f dB", b, sr, p[b]));
        }
    }
    foreach (b; 0 .. NBANDS)
        assert(abs(peak44[b]) < 0.01, format("band %d at 44.1 kHz: peak %.3f dB", b, peak44[b]));
}

@("atan2Fast is atan2 to within 2.5e-7")
unittest
{
    import std.math : atan2, abs;
    double worst = 0;
    uint lcg = 3;
    foreach (i; 0 .. 200_000)
    {
        lcg = lcg * 1_664_525u + 1_013_904_223u;
        immutable float y = (lcg >> 8) / cast(float)(1 << 23) - 1.0f;
        lcg = lcg * 1_664_525u + 1_013_904_223u;
        immutable float x = (lcg >> 8) / cast(float)(1 << 23) - 1.0f;
        worst = max(worst, abs(atan2Fast(y, x) - atan2(cast(double) y, cast(double) x)));
    }
    // The axes, the diagonals and the reduction's switch point, where the
    // selects change over.
    static immutable float[2][] edges = [[0, 1], [1, 0], [0, -1], [-1, 0], [1, 1], [-1, -1],
                                         [1, -1], [-1, 1], [0.41421356f, 1], [1, 0.41421356f],
                                         [-0.41421356f, -1], [1e-30f, 1], [1, 1e-30f]];
    foreach (e; edges)
        worst = max(worst, abs(atan2Fast(e[0], e[1]) - atan2(cast(double) e[0], cast(double) e[1])));
    assert(worst < 2.5e-7, format("error %.3g", worst));
    assert(atan2Fast(0, 0) == 0);
}

@("the build ID ignores line endings")
unittest
{
    assert(CORE_BUILD_ID.length == 8);
    assert(fnv1aHex("one\r\ntwo\r\n") == fnv1aHex("one\ntwo\n"));
    assert(fnv1aHex("one\ntwo\n") != fnv1aHex("one\ntwo \n"));
}
