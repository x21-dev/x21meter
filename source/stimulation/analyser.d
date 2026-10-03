module stimulation.analyser;

import std.math : PI, PI_2, PI_4, sin, cos, cosh, exp, sqrt, log2, log10, pow, ceil, floor;
import stimulation.nogc : mallocSlice, freeSlice;

// noalias on pointer parameters, which the per-bin loop needs to vectorise.
version (LDC) import ldc.attributes : restrict;
else enum restrict = 0;

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

// Frames are fixed in time, not in samples: Analyser.initialize() derives the
// hop, frame and FFT lengths from the sample rate, so a frame means the same
// stretch of music at every rate.
enum double HOP_MS  = 20.0;   // frame = 2 hops: 40 ms, 50 % overlap

// The sizes at 48 kHz. The analyser no longer uses these directly; they are the
// reference that flux is normalised to, and they keep older code compiling.
enum int FRAME_LEN  = 1920;   // 40 ms @ 48 kHz
enum int HOP_LEN    = 960;    // 20 ms @ 48 kHz
enum int NFFT       = 2048;   // smallest power of two >= FRAME_LEN
enum int NBINS      = NFFT / 2 + 1;
enum int NBANDS     = 24;
enum float FLOOR_DB = -60.0f;

enum float BAND_LO_HZ = 30.0f;
enum float BAND_HI_HZ = 16000.0f;

enum float MIN_LIN = 1.0e-9f;

// FLOOR_DB as a squared linear ratio, folded at compile time.
enum float FLOOR_LIN_SQ = 10.0f ^^ (FLOOR_DB / 10.0f);

// ─────────────────────────────────────────────────────────────────────────────
// Output
// ─────────────────────────────────────────────────────────────────────────────

struct FrameFeatures
{
    long  frameIndex;
    float[NBANDS] bandLevelDb;
    float[NBANDS] bandCrestDb;
    float fullCrestDb;
    float fLowSemitones;
    float fHighSemitones;
    float centroidSemitones;
    float flux;
    float stereoWidth;
    int   liveBins;          // bins above the floor - useful for tuning FLOOR_DB
}

// ─────────────────────────────────────────────────────────────────────────────
// Biquad - transposed direct form II
// ─────────────────────────────────────────────────────────────────────────────
// Double coefficients and state: in float, rounding in the state moved band
// levels and crests by up to 0.05 dB, most at high sample rates, where the
// poles sit closest to the unit circle.
//
// There is no anti-denormal offset. StimEngine.process() runs the analysis
// with denormals flushed to zero (FPControl), and it is the only caller.

/// One sample `x` through a section with coefficients b0 .. a2 and state s1,
/// s2, the one recurrence Biquad and BandBank share: results depend on its
/// exact order of operations. The terms that don't need y are summed first,
/// so the recurrence through s1 is one add, one multiply and one subtract long.
pragma(inline, true)
double biquadStep(double b0, double b1, double b2, double a1, double a2,
                  ref double s1, ref double s2, double x) pure nothrow @nogc
{
    immutable double y = b0 * x + s1;
    s1 = (b1 * x + s2) - a1 * y;
    s2 = b2 * x - a2 * y;
    return y;
}

struct Biquad
{
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double s1 = 0, s2 = 0;

    void setCoeffs(double B0, double B1, double B2,
                   double A0, double A1, double A2) pure nothrow @nogc
    {
        immutable double inv = 1.0 / A0;
        b0 = B0 * inv;
        b1 = B1 * inv;
        b2 = B2 * inv;
        a1 = A1 * inv;
        a2 = A2 * inv;
    }

    void setHighShelf(double fs, double f0, double gainDb, double Q) pure nothrow @nogc
    {
        immutable double A     = pow(10.0, gainDb / 40.0);
        immutable double w0    = 2.0 * PI * f0 / fs;
        immutable double cw    = cos(w0);
        immutable double alpha = sin(w0) / (2.0 * Q);
        immutable double sa    = 2.0 * sqrt(A) * alpha;

        setCoeffs(     A * ((A + 1) + (A - 1) * cw + sa),
                  -2 * A * ((A - 1) + (A + 1) * cw     ),
                       A * ((A + 1) + (A - 1) * cw - sa),
                            (A + 1) - (A - 1) * cw + sa,
                       2 * ((A - 1) - (A + 1) * cw     ),
                            (A + 1) - (A - 1) * cw - sa);
    }

    void setHighpass(double fs, double f0, double Q) pure nothrow @nogc
    {
        immutable double w0    = 2.0 * PI * f0 / fs;
        immutable double cw    = cos(w0);
        immutable double alpha = sin(w0) / (2.0 * Q);
        setCoeffs((1 + cw) / 2, -(1 + cw), (1 + cw) / 2,
                  1 + alpha,    -2 * cw,   1 - alpha);
    }

    /// Bandpass with a 0 dB peak whose magnitude matches the analogue
    /// prototype (s/Q) / (s^2 + s/Q + 1) at any sample rate: M. Vicanek,
    /// "Matched Second Order Digital Filters" (2016). The poles are the
    /// analogue ones mapped by z = e^(sT), and the numerator is solved so the
    /// magnitude agrees at DC, at the centre and at Nyquist.
    ///
    /// The bilinear (cookbook) design it replaces placed the centre exactly
    /// but narrowed the bandwidth towards Nyquist, well below it: at 44.1 kHz
    /// the 12.3 kHz band passed 2.5 dB less than the analogue one, at 96 kHz
    /// 0.5 dB less, so band levels, blue and the score depended on the sample
    /// rate. Matched, the bands' energies agree within 0.04 dB from 44.1 to
    /// 192 kHz.
    void setBandpass(double fs, double f0, double Q) pure nothrow @nogc
    {
        immutable double w0 = 2.0 * PI * f0 / fs;
        immutable double q  = 1.0 / (2.0 * Q);
        immutable double e  = exp(-q * w0);
        immutable double A1 = q <= 1.0 ? -2.0 * e * cos(sqrt(1.0 - q * q) * w0)
                                       : -2.0 * e * cosh(sqrt(q * q - 1.0) * w0);
        immutable double A2 = e * e;

        // Vicanek's terms: the denominator's squared magnitude at DC (d0) and
        // Nyquist (d1) and its cross term (d2); phi0, phi1 of the centre.
        immutable double d0 = (1.0 + A1 + A2) ^^ 2;
        immutable double d1 = (1.0 - A1 + A2) ^^ 2;
        immutable double d2 = -4.0 * A2;
        immutable double p1 = sin(w0 / 2) ^^ 2;
        immutable double p0 = 1.0 - p1;
        immutable double R1 = (d0 * p0 + d1 * p1 + d2 * 4.0 * p0 * p1) * Q * Q;
        immutable double R2 = (-d0 + d1 + 4.0 * (p0 - p1) * d2) * Q * Q;
        immutable double B2 = (R1 - R2 * p1) / (4.0 * p1 * p1);
        immutable double B1 = R2 + 4.0 * (p1 - p0) * B2;
        immutable double n1 = -0.5 * sqrt(B1 > 0.0 ? B1 : 0.0);
        immutable double n0 = 0.5 * (sqrt(B2 + n1 * n1) - n1);
        immutable double n2 = -n0 - n1;

        // Vicanek's section peaks at Q; the bank's peak at 1.
        setCoeffs(n0 / Q, n1 / Q, n2 / Q, 1.0, A1, A2);
    }

    pragma(inline, true)
    double process(double x) pure nothrow @nogc
    {
        return biquadStep(b0, b1, b2, a1, a2, s1, s2, x);
    }

    void reset() pure nothrow @nogc { s1 = 0; s2 = 0; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stage 0 - K-weighting
// ─────────────────────────────────────────────────────────────────────────────
// A cookbook high shelf (about +4 dB from ~1.7 kHz up) into a cookbook
// highpass (38 Hz, Q 0.5), both redesigned at the sample rate from the
// parameters below. Those are libebur128's, fitted for its own shelf
// formula; through the cookbook formulas they give a curve of the same shape
// but not the same values: at 48 kHz it reads -1.18 dB at 100 Hz,
// +0.44 dB at 1 kHz and +4.0 dB at 15 kHz.

struct KWeighting
{
    Biquad shelf, hp;

    void initialize(double fs) pure nothrow @nogc
    {
        shelf.setHighShelf(fs, 1681.974450955533, 3.999843853973347,
                               0.7071752369554196);
        hp   .setHighpass (fs,   38.13547087602444,
                               0.5003270373238773);
    }

    pragma(inline, true)
    double process(double x) pure nothrow @nogc { return hp.process(shelf.process(x)); }
    void   reset() pure nothrow @nogc { shelf.reset(); hp.reset(); }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mel scale
// ─────────────────────────────────────────────────────────────────────────────

double hzToMel(double hz) pure nothrow @nogc { return 2595.0 * log10(1.0 + hz / 700.0); }
double melToHz(double m)  pure nothrow @nogc { return 700.0 * (pow(10.0, m / 2595.0) - 1.0); }

// ─────────────────────────────────────────────────────────────────────────────
// Stage 3a - time-domain band bank
// ─────────────────────────────────────────────────────────────────────────────
// Structure-of-arrays rather than an array of filter structs: the inner loop
// then walks five contiguous coefficient arrays instead of striding over
// the filter objects, which is what keeps it in cache and lets the compiler
// vectorise the band loop.

struct BandBank
{
    // Two cascaded bandpass sections. Coefficients are identical per band,
    // states are not.
    double[NBANDS] b0, b1, b2, a1, a2;
    double[NBANDS] s1a, s2a, s1b, s2b;
    float[NBANDS]  centreHz;

    void initialize(double fs) pure nothrow @nogc
    {
        immutable double hi   = (BAND_HI_HZ < 0.45 * fs) ? BAND_HI_HZ : 0.45 * fs;
        immutable double mLo  = hzToMel(BAND_LO_HZ);
        immutable double mHi  = hzToMel(hi);
        immutable double step = (mHi - mLo) / (NBANDS + 1);

        foreach (b; 0 .. NBANDS)
        {
            immutable double fc  = melToHz(mLo + step * (b + 1));
            immutable double fLo = melToHz(mLo + step * b);
            immutable double fHi = melToHz(mLo + step * (b + 2));
            double Q = fc / (fHi - fLo);
            if (Q < 0.35) Q = 0.35;

            Biquad tmp;
            tmp.setBandpass(fs, fc, Q);
            b0[b] = tmp.b0; b1[b] = tmp.b1; b2[b] = tmp.b2;
            a1[b] = tmp.a1; a2[b] = tmp.a2;
            centreHz[b] = cast(float) fc;
        }
        reset();
    }

    /// One sample in, NBANDS band samples out. Fused two-section cascade,
    /// each section a biquadStep().
    pragma(inline, true)
    void process(double x, ref double[NBANDS] outBands) pure nothrow @nogc
    {
        foreach (b; 0 .. NBANDS)
        {
            immutable double y1 = biquadStep(b0[b], b1[b], b2[b], a1[b], a2[b], s1a[b], s2a[b], x);
            outBands[b]         = biquadStep(b0[b], b1[b], b2[b], a1[b], a2[b], s1b[b], s2b[b], y1);
        }
    }

    void reset() pure nothrow @nogc
    {
        s1a[] = 0; s2a[] = 0; s1b[] = 0; s2b[] = 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stage 1 - spectrum engine
// ─────────────────────────────────────────────────────────────────────────────
// The bare transform: forward() leaves the complex spectrum where rePtr() and
// imPtr() point, bin k at [stride * k], until the next forward(). The Analyser
// extracts only what it needs, so no per-bin transcendentals happen here.

struct SpectrumEngine
{
    // A real n-point transform as an n/2-point complex one, even samples in
    // the real part and odd in the imaginary, then one pass that splits the
    // two spectra apart. The complex transform is iterative radix-2 on
    // separate re/im arrays, and every stage reads its own contiguous
    // twiddles, so the butterflies are unit-stride and vectorise.
    int n, h;                  // h = n / 2, the complex length
    float[] zr, zi;            // h: the complex transform, in place
    float[] twc, tws;          // stages 8 .. h, each len / 2 twiddles
    float[] pc, ps;            // h + 1: e^(-2 pi i k / n) for the split
    float[] xr, xi;            // h + 1: the spectrum
    int[]   rev;               // h: bit reversal

    void initialize(int nfft) nothrow @nogc
    {
        assert(nfft >= 8 && (nfft & (nfft - 1)) == 0);
        n = nfft;
        h = n / 2;
        int bits = 0;
        while ((1 << bits) < h) bits++;

        zr  = mallocSlice!float(h);
        zi  = mallocSlice!float(h);
        rev = mallocSlice!int(h);
        twc = mallocSlice!float(h);   // 4 + 8 + ... + h / 2 < h
        tws = mallocSlice!float(h);
        pc  = mallocSlice!float(h + 1);
        ps  = mallocSlice!float(h + 1);
        xr  = mallocSlice!float(h + 1);
        xi  = mallocSlice!float(h + 1);

        foreach (i; 0 .. h)
        {
            int r = 0;
            foreach (b; 0 .. bits)
                if (i & (1 << b)) r |= 1 << (bits - 1 - b);
            rev[i] = r;
        }
        int off = 0;
        for (int len = 8; len <= h; len <<= 1)
            foreach (j; 0 .. len / 2)
            {
                immutable double w = -2.0 * PI * j / len;
                twc[off] = cast(float) cos(w);
                tws[off] = cast(float) sin(w);
                off++;
            }
        foreach (k; 0 .. h + 1)
        {
            immutable double w = -2.0 * PI * k / n;
            pc[k] = cast(float) cos(w);
            ps[k] = cast(float) sin(w);
        }
    }

    void destroy() nothrow @nogc
    {
        zr.freeSlice();  zi.freeSlice();  rev.freeSlice();
        twc.freeSlice(); tws.freeSlice(); pc.freeSlice(); ps.freeSlice();
        xr.freeSlice();  xi.freeSlice();
        zr = zi = twc = tws = pc = ps = xr = xi = null;
        rev = null;
    }

    void forward(const(float)[] timeIn) pure nothrow @nogc
    {
        foreach (i; 0 .. h)
        {
            zr[rev[i]] = timeIn[2 * i];
            zi[rev[i]] = timeIn[2 * i + 1];
        }

        // Stages of length 2 and 4 together: their twiddles are 1 and
        // -i, so no multiplies.
        for (int i = 0; i < h; i += 4)
        {
            immutable float r0 = zr[i] + zr[i + 1],     i0 = zi[i] + zi[i + 1];
            immutable float r1 = zr[i] - zr[i + 1],     i1 = zi[i] - zi[i + 1];
            immutable float r2 = zr[i + 2] + zr[i + 3], i2 = zi[i + 2] + zi[i + 3];
            immutable float r3 = zr[i + 2] - zr[i + 3], i3 = zi[i + 2] - zi[i + 3];
            zr[i]     = r0 + r2;  zi[i]     = i0 + i2;
            zr[i + 2] = r0 - r2;  zi[i + 2] = i0 - i2;
            // (r3 + i i3) * -i = i3 - i r3
            zr[i + 1] = r1 + i3;  zi[i + 1] = i1 - r3;
            zr[i + 3] = r1 - i3;  zi[i + 3] = i1 + r3;
        }

        int off = 0;
        for (int len = 8; len <= h; len <<= 1)
        {
            immutable int half = len >> 1;
            const(float)* wc = twc.ptr + off, ws = tws.ptr + off;
            for (int i = 0; i < h; i += len)
            {
                float* pr = zr.ptr + i, pi = zi.ptr + i;
                float* qr = pr + half,  qi = pi + half;
                foreach (j; 0 .. half)
                {
                    immutable float tr = qr[j] * wc[j] - qi[j] * ws[j];
                    immutable float ti = qr[j] * ws[j] + qi[j] * wc[j];
                    immutable float ar = pr[j], ai = pi[j];
                    qr[j] = ar - tr;  qi[j] = ai - ti;
                    pr[j] = ar + tr;  pi[j] = ai + ti;
                }
            }
            off += half;
        }

        // X[k] = E[k] + e^(-2 pi i k / n) O[k], where E and O are the
        // spectra of the even and odd samples: E = (Z[k] + conj Z[h-k]) / 2,
        // O = (Z[k] - conj Z[h-k]) / 2i, with Z[h] = Z[0].
        foreach (k; 0 .. h + 1)
        {
            immutable int a = k == h ? 0 : k, b = k == 0 ? 0 : h - k;
            immutable float er = 0.5f * (zr[a] + zr[b]), ei = 0.5f * (zi[a] - zi[b]);
            immutable float or = 0.5f * (zi[a] + zi[b]), oi = 0.5f * (zr[b] - zr[a]);
            xr[k] = er + (pc[k] * or - ps[k] * oi);
            xi[k] = ei + (pc[k] * oi + ps[k] * or);
        }
    }

    enum int stride = 1;
    const(float)* rePtr() const pure nothrow @nogc { return xr.ptr; }
    const(float)* imPtr() const pure nothrow @nogc { return xi.ptr; }
}

// ─────────────────────────────────────────────────────────────────────────────
// Analyser
// ─────────────────────────────────────────────────────────────────────────────

struct Analyser
{
private:
    float sampleRate;
    int   frameLen, hopLen, nfft, nbins;   // from the sample rate, see initialize()
    int   kLo, kHi;                        // bins the spectral statistics use
    float fluxNorm;

    KWeighting kwL, kwR;
    BandBank   bank;
    SpectrumEngine spec;

    float[] ring;
    int     ringWrite;
    int     sinceHop;
    long    frameCounter;

    /// What one hop block accumulates, per band and full band. A frame spans
    /// two blocks, `prv` and `cur`. The mid signal's energy is fullSumSq: the
    /// full-band crest and the stereo width share it.
    struct Block
    {
        double[NBANDS] peak = 0, sumSq = 0;
        double fullPeak = 0, fullSumSq = 0;
        double sideSumSq = 0;
    }
    Block cur, prv;
    bool  havePrevBlock;

    float[] win;              // Hann, with the amplitude normalisation folded in
    float[] windowed;
    float[] magSq;            // energy per bin; after pass 2 the live weight
    float[] prevMag, binFreq;
    float[] prevRe, prevIm;   // last frame's complex bins, for the phase difference
    float[] rise;             // per bin: squared rise in magnitude, for flux
    bool    havePrevFrame;

    // e^(-i x the expected phase advance per bin over one hop), and the
    // instantaneous-frequency scale factor.
    float[] advCos, advSin;
    float   ifScale;
    float   binHz;

public:

    /// May be called again, for a new sample rate for instance: the buffers
    /// of the earlier setup are freed first.
    void initialize(float sr) nothrow @nogc
    {
        destroy();
        sampleRate = sr;

        // 960 / 1920 / 2048 at 48 kHz, 882 / 1764 / 2048 at 44.1 kHz,
        // 1920 / 3840 / 4096 at 96 kHz.
        hopLen   = cast(int)(sr * HOP_MS / 1000.0 + 0.5);
        if (hopLen < 4) hopLen = 4;
        frameLen = 2 * hopLen;
        nfft     = 1;
        while (nfft < frameLen) nfft <<= 1;
        nbins    = nfft / 2 + 1;

        // Flux is a norm over bins, and zero padding the frame up to nfft adds
        // bins: for the same audio it grows with sqrt(nfft / frameLen). The
        // ratio before the square root is 1.07 at 48 and 96 kHz but 1.16 at
        // 44.1 and 88.2 kHz, so flux grows by 1.03 and 1.08. Scale it to the
        // 48 kHz ratio, so 48 kHz results are unchanged.
        fluxNorm = cast(float) sqrt((cast(double) NFFT / FRAME_LEN)
                                    / (cast(double) nfft / frameLen));

        ring     = mallocSlice!float(frameLen);
        win      = mallocSlice!float(frameLen);
        windowed = mallocSlice!float(nfft);
        magSq    = mallocSlice!float(nbins);
        prevMag  = mallocSlice!float(nbins);
        binFreq  = mallocSlice!float(nbins);
        prevRe   = mallocSlice!float(nbins);
        prevIm   = mallocSlice!float(nbins);
        rise     = mallocSlice!float(nbins);
        advCos   = mallocSlice!float(nbins);
        advSin   = mallocSlice!float(nbins);

        // Hann, scaled by 2 / sum so a full-scale sine reads 1.
        double wsum = 0.0;
        foreach (i; 0 .. frameLen)
            wsum += 0.5 * (1.0 - cos(2.0 * PI * i / (frameLen - 1)));
        foreach (i; 0 .. frameLen)
            win[i] = cast(float)(0.5 * (1.0 - cos(2.0 * PI * i / (frameLen - 1))) * (2.0 / wsum));

        binHz   = sr / nfft;
        ifScale = sr / (2.0f * PI * hopLen);

        // Spectral statistics look only at BAND_LO_HZ .. BAND_HI_HZ, the band
        // bank's range (with its 0.45 x sr cap), so every sample rate sees the
        // same spectrum. Above 16 kHz the lossy encoder decides what is there
        // (a 128 kbps MP3 cuts near 16 kHz, 320 kbps near 20 kHz) and most
        // adults hear little of it; below 30 Hz the instantaneous-frequency
        // estimate can run down to 0 Hz.
        immutable double hiHz = BAND_HI_HZ < 0.45 * sr ? BAND_HI_HZ : 0.45 * sr;
        kLo = cast(int) ceil(BAND_LO_HZ / binHz);
        kHi = cast(int) floor(hiHz / binHz);
        if (kHi > nbins - 1) kHi = nbins - 1;
        if (kLo > kHi) kLo = kHi;

        // Bin k's phase advances 2 pi k hop / nfft per hop, thousands of
        // radians at the top bins. k hop mod nfft is exact in integers, so
        // the angle is reduced to [0, 2 pi) before anything is rounded.
        foreach (k; 0 .. nbins)
        {
            immutable double a = 2.0 * PI * ((cast(long) k * hopLen) % nfft) / nfft;
            advCos[k] = cast(float) cos(a);
            advSin[k] = cast(float) sin(a);
        }

        kwL.initialize(sr);
        kwR.initialize(sr);
        bank.initialize(sr);
        spec.initialize(nfft);

        reset();
    }

    /// Frees the buffers. Safe to call twice, or before initialize().
    void destroy() nothrow @nogc
    {
        spec.destroy();
        ring.freeSlice();    win.freeSlice();     windowed.freeSlice();
        magSq.freeSlice();   prevMag.freeSlice(); binFreq.freeSlice();
        prevRe.freeSlice();  prevIm.freeSlice();  rise.freeSlice();
        advCos.freeSlice();  advSin.freeSlice();
        ring = win = windowed = magSq = prevMag = binFreq = null;
        prevRe = prevIm = rise = advCos = advSin = null;
    }

    void reset() pure nothrow @nogc
    {
        ring[]      = 0.0f;
        prevRe[]    = 0.0f;
        prevIm[]    = 0.0f;
        prevMag[]   = 0.0f;
        ringWrite   = 0;
        sinceHop    = 0;
        frameCounter  = 0;
        havePrevFrame = false;
        havePrevBlock = false;
        kwL.reset(); kwR.reset(); bank.reset();
        cur = Block.init;
    }

    bool processSample(float left, float right, ref FrameFeatures outFeat) nothrow @nogc
    {
        immutable double wl = kwL.process(left);
        immutable double wr = kwR.process(right);
        immutable double mid  = 0.5 * (wl + wr);
        immutable double side = 0.5 * (wl - wr);

        cur.sideSumSq += side * side;

        double[NBANDS] bandSample = void;
        bank.process(mid, bandSample);
        foreach (b; 0 .. NBANDS)
        {
            immutable double v = bandSample[b];
            immutable double a = v < 0 ? -v : v;
            cur.peak[b]   = a > cur.peak[b] ? a : cur.peak[b];
            cur.sumSq[b] += v * v;
        }
        immutable double am = mid < 0 ? -mid : mid;
        cur.fullPeak   = am > cur.fullPeak ? am : cur.fullPeak;
        cur.fullSumSq += mid * mid;

        ring[ringWrite] = cast(float) mid;
        if (++ringWrite == frameLen) ringWrite = 0;

        if (++sinceHop < hopLen)
            return false;

        sinceHop = 0;
        immutable bool emitted = completeFrame(outFeat);
        prv = cur;
        cur = Block.init;
        havePrevBlock = true;
        return emitted;
    }

    const(float)[] bandCentres() const pure nothrow @nogc { return bank.centreHz[]; }

    /// Samples between frames at this sample rate (20 ms worth).
    int hopLength() const pure nothrow @nogc { return hopLen; }
    /// Bins inside BAND_LO_HZ .. BAND_HI_HZ, the ones FrameFeatures.liveBins
    /// counts from (681 at 48 kHz).
    int binCount() const pure nothrow @nogc { return kHi - kLo + 1; }

private:

    bool completeFrame(ref FrameFeatures f) nothrow @nogc
    {
        if (!havePrevBlock)
            return false;

        // Windowed copy, oldest -> newest, split at the wrap point so there is
        // no modulo in the inner loop.
        {
            immutable int tail = frameLen - ringWrite;
            foreach (i; 0 .. tail)
                windowed[i] = ring[ringWrite + i] * win[i];
            foreach (i; 0 .. ringWrite)
                windowed[tail + i] = ring[i] * win[tail + i];
            windowed[frameLen .. nfft] = 0.0f;
        }

        spec.forward(windowed);

        if (!spectralStats(f))
            return false;

        // Stage 3c - band levels and crest across both hop blocks.
        immutable double invN = 1.0 / frameLen;
        foreach (b; 0 .. NBANDS)
        {
            immutable double pk  = cur.peak[b] > prv.peak[b] ? cur.peak[b] : prv.peak[b];
            immutable double rms = sqrt((cur.sumSq[b] + prv.sumSq[b]) * invN);
            f.bandLevelDb[b] = linToDb(cast(float) rms);
            f.bandCrestDb[b] = peakRmsDb(pk, rms);
        }
        {
            immutable double pk  = cur.fullPeak > prv.fullPeak ? cur.fullPeak : prv.fullPeak;
            immutable double rms = sqrt((cur.fullSumSq + prv.fullSumSq) * invN);
            f.fullCrestDb = peakRmsDb(pk, rms);
        }

        immutable double midE  = cur.fullSumSq + prv.fullSumSq;
        immutable double sideE = cur.sideSumSq + prv.sideSumSq;

        f.frameIndex  = frameCounter;
        f.stereoWidth = (midE > 0.0) ? cast(float)(sideE / (midE + sideE)) : 0.0f;
        frameCounter++;
        return true;
    }

    /// Stages 2 and 3: instantaneous frequency, spectral edges, centroid,
    /// flux and live bins, over kLo .. kHi. Every pass is dense and
    /// branch-free: being above the floor makes a bin's weight its energy
    /// rather than 0, instead of putting it on a list, so the loops are
    /// unit-stride and vectorise. Live bins are most of the range anyway.
    /// Returns false on the first frame, which only primes the history.
    bool spectralStats(ref FrameFeatures f) pure nothrow @nogc
    {
        enum lanes = 4;
        enum st = SpectrumEngine.stride;

        // Locals, not fields: a store through a float* could otherwise alias
        // the slices in `this`, and every bin would reload them.
        const(float)* sRe = spec.rePtr(), sIm = spec.imPtr();
        float* wgt = magSq.ptr, fq = binFreq.ptr;
        immutable int lo = kLo, hi = kHi;

        // Pass 1: energy per bin, and the loudest, in `lanes` independent
        // maxima combined in a fixed order.
        float[lanes] pk = 0.0f;
        int k = lo;
        for (; k + lanes <= hi + 1; k += lanes)
            static foreach (l; 0 .. lanes)
            {{
                immutable float re = sRe[st * (k + l)], im = sIm[st * (k + l)];
                immutable float m2 = re * re + im * im;
                wgt[k + l] = m2;
                pk[l] = m2 > pk[l] ? m2 : pk[l];
            }}
        float pkTail = 0.0f;
        for (; k <= hi; ++k)
        {
            immutable float re = sRe[st * k], im = sIm[st * k];
            immutable float m2 = re * re + im * im;
            wgt[k] = m2;
            pkTail = m2 > pkTail ? m2 : pkTail;
        }
        immutable float p01 = pk[0] > pk[1] ? pk[0] : pk[1];
        immutable float p23 = pk[2] > pk[3] ? pk[2] : pk[3];
        immutable float p03 = p01 > p23 ? p01 : p23;
        immutable float peakMagSq = p03 > pkTail ? p03 : pkTail;

        if (!havePrevFrame)
        {
            foreach (j; lo .. hi + 1)
            {
                prevRe[j]  = sRe[st * j];
                prevIm[j]  = sIm[st * j];
                prevMag[j] = sqrt(wgt[j]);
            }
            havePrevFrame = true;
            frameCounter++;
            return false;
        }

        // The floor is relative to the loudest bin inside the analysed range.
        immutable float floorSq = peakMagSq * FLOOR_LIN_SQ;

        // Pass 2: per bin, element-wise.
        binPass(lo, hi, floorSq, binHz, ifScale, sRe, sIm, advCos.ptr, advSin.ptr,
                prevRe.ptr, prevIm.ptr, prevMag.ptr, wgt, fq, rise.ptr);

        // Pass 3: the sums, again in `lanes` accumulators and a fixed-order
        // combine, which vectorises under strict IEEE and gives the same
        // result on every platform.
        const(float)* rs = rise.ptr;
        float[lanes] eAcc = 0.0f, cAcc = 0.0f, fAcc = 0.0f;
        int[lanes]   nAcc = 0;
        k = lo;
        for (; k + lanes <= hi + 1; k += lanes)
            static foreach (l; 0 .. lanes)
            {
                eAcc[l] += wgt[k + l];
                cAcc[l] += fq[k + l] * wgt[k + l];
                fAcc[l] += rs[k + l];
                nAcc[l] += wgt[k + l] > 0.0f ? 1 : 0;
            }
        float eTail = 0.0f, cTail = 0.0f, fTail = 0.0f;
        int   nTail = 0;
        for (; k <= hi; ++k)
        {
            eTail += wgt[k];
            cTail += fq[k] * wgt[k];
            fTail += rs[k];
            nTail += wgt[k] > 0.0f ? 1 : 0;
        }
        immutable float totalE      = ((eAcc[0] + eAcc[1]) + (eAcc[2] + eAcc[3])) + eTail;
        immutable float centroidNum = ((cAcc[0] + cAcc[1]) + (cAcc[2] + cAcc[3])) + cTail;
        immutable float fluxSq      = ((fAcc[0] + fAcc[1]) + (fAcc[2] + fAcc[3])) + fTail;
        // A live bin has an energy of at least floorSq, so above a floor of 0
        // the live bins are those with a weight. At 0 (a silent frame) every
        // bin is live.
        immutable int nLive = floorSq > 0.0f
                            ? ((nAcc[0] + nAcc[1]) + (nAcc[2] + nAcc[3])) + nTail
                            : hi - lo + 1;

        // Pass 4: the bins where the cumulative energy crosses 5 % and 95 %.
        // A dead bin weighs 0 and can't be where it crosses, so the edges are
        // live bins, as when only those were summed.
        float fLow = 0.0f, fHigh = 0.0f;
        if (totalE > 0.0f)
        {
            immutable float loTarget = 0.05f * totalE;
            immutable float hiTarget = 0.95f * totalE;
            int   j   = lo;
            float cum = wgt[j];
            while (cum < loTarget && j < hi) cum += wgt[++j];
            fLow = fq[j];
            while (cum < hiTarget && j < hi) cum += wgt[++j];
            fHigh = fq[j];
        }

        f.fLowSemitones     = hzToSemitones(fLow);
        f.fHighSemitones    = hzToSemitones(fHigh);
        f.centroidSemitones = hzToSemitones(totalE > 0 ? centroidNum / totalE : 0.0f);
        // Flux needs the whole analysed range, not just the live bins, since
        // energy can appear in a bin that was dead last frame.
        f.flux              = sqrt(fluxSq) * fluxNorm;
        f.liveBins          = nLive;
        return true;
    }

    /// Pass 2 of spectralStats(), one bin at a time with no sums, so that the
    /// loop vectoriser takes it. The arrays are distinct allocations, which
    /// @restrict tells LLVM; without it the run-time alias checks defeat it.
    /// On return wgt holds each bin's live weight, fq its instantaneous
    /// frequency, rise its contribution to flux, and prev* this frame.
    static void binPass(int lo, int hi, float floorSq, float binHz, float ifScale,
                        @restrict const(float)* sRe, @restrict const(float)* sIm,
                        @restrict const(float)* advCos, @restrict const(float)* advSin,
                        @restrict float* prevRe, @restrict float* prevIm,
                        @restrict float* prevMag, @restrict float* wgt,
                        @restrict float* fq, @restrict float* rise) pure nothrow @nogc
    {
        enum st = SpectrumEngine.stride;
        foreach (j; lo .. hi + 1)
        {
            immutable float re = sRe[st * j], im = sIm[st * j];
            immutable float pr = prevRe[j], pi = prevIm[j];
            immutable float m2 = wgt[j];

            // Stage 2 - instantaneous frequency. The phase difference from
            // last frame less the expected advance, as one angle:
            // arg(z conj(p) e^(-i adv)), already in (-pi, pi], so nothing
            // large is subtracted and nothing needs wrapping. A bin that was
            // exactly zero last frame has no phase: difference against
            // phase 0.
            immutable bool  hasPrev = pr * pr + pi * pi > 0.0f;
            immutable float wr = hasPrev ? re * pr + im * pi : re;
            immutable float wi = hasPrev ? im * pr - re * pi : im;
            immutable float ur = wr * advCos[j] + wi * advSin[j];
            immutable float ui = wi * advCos[j] - wr * advSin[j];
            fq[j] = j * binHz + atan2Fast(ui, ur) * ifScale;

            wgt[j] = m2 >= floorSq ? m2 : 0.0f;

            immutable float m = sqrt(m2);
            immutable float d = m - prevMag[j];
            rise[j]    = d > 0.0f ? d * d : 0.0f;
            prevMag[j] = m;
            prevRe[j]  = re;
            prevIm[j]  = im;
        }
    }

}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// atan2 for float, branch-free so that loops over it vectorise: Cephes
/// atanf's range reduction and polynomial, with selects for the branches.
/// Within 2.5e-7 of the true angle (see tests). atan2(-0, x < 0) gives +pi
/// rather than -pi, the same angle.
pragma(inline, true)
float atan2Fast(float y, float x) pure nothrow @nogc
{
    immutable float ax = x < 0.0f ? -x : x;
    immutable float ay = y < 0.0f ? -y : y;
    immutable bool  swap = ay > ax;
    immutable float mx = swap ? ay : ax;
    immutable float mn = swap ? ax : ay;
    // Past tan(pi/8), atan(t) = pi/4 + atan((t - 1) / (t + 1)).
    immutable bool  big = mn > 0.41421356f * mx;
    immutable float num = big ? mn - mx : mn;
    immutable float den = big ? mn + mx : mx;
    immutable float q = num / den;                 // 0 / 0 when x = y = 0,
    immutable float t = den > 0.0f ? q : 0.0f;     // selected away here
    immutable float z = t * t;
    float r = (((8.05374449538e-2f * z - 1.38776856032e-1f) * z
                + 1.99777106478e-1f) * z - 3.33329491539e-1f) * z * t + t;
    r = big  ? r + cast(float) PI_4 : r;
    r = swap ? cast(float) PI_2 - r : r;
    r = x < 0.0f ? cast(float) PI - r : r;
    return y < 0.0f ? -r : r;
}

float linToDb(float x) pure nothrow @nogc
{
    return 20.0f * cast(float) log10(x > MIN_LIN ? x : MIN_LIN);
}

/// A crest factor in dB: peak over RMS, or 0 where the RMS is at MIN_LIN or
/// below and the ratio means nothing.
float peakRmsDb(double pk, double rms) pure nothrow @nogc
{
    return (rms > MIN_LIN) ? linToDb(cast(float)(pk / rms)) : 0.0f;
}

float hzToSemitones(float hz) pure nothrow @nogc
{
    return (hz > 0.0f) ? 12.0f * cast(float) log2(hz / 440.0f) : -120.0f;
}
