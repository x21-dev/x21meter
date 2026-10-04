/// The fingerprint and the match score built on it, one frame at a time.
///
/// Part of the core shared by stim-offline and the plugin: any change here
/// changes both, which is the point. Everything is nothrow @nogc, since the
/// plugin runs without a garbage collector, and pure: the structs' own fields
/// are the only state.
module stimulation.fingerprint;

import std.algorithm : max, min;
import std.math : exp, log, log10, sqrt;

import stimulation.analyser;

pure nothrow @nogc:

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

enum float SILENT_DB     = -70.0f;  // full-band level: silence below this
// Fingerprint smoothing: the one-pole time constant in frames, so the 20 ms
// hop sets the duration (80 x 20 ms = 1.6 s; it was 50, 1 s, until
// 2026-09-25). Changing it shifts the channel
// ranges below, centroid SD most, so re-derive them with it. It is the
// default for LiveFingerprint.smoothFrames, which stim-offline's
// --smooth-frames overrides; the plugin always uses it.
enum int   PRINT_SMOOTH_FRAMES = 80;
// Fingerprint channel ranges: the pooled p10..p90 of the smoothed values over
// audible frames of 72 tracks, 3 from each of 24 sources across dance, pop,
// 90s, chill, acoustic, piano, classical, soundtrack and rock, so each channel
// spends about the same span of 0..1 on typical music. Measured 2026-10-04
// with the matched band filters and 80-frame smoothing (they were 0.31..0.78,
// 3..12 and 0.89..1.95, from the bilinear filters and 50 frames), and checked
// on 24 current chart hits, where the three channels now average about level.
// See HELP.md, Tuning, for the procedure.
enum float PRINT_FLUX_LO   =  0.290f; // red: flux / frame amplitude
enum float PRINT_FLUX_HI   =  0.724f;
// Green is mapped on a log scale between these (centroid SD, semitones): its
// distribution is skewed, with a long tail in dance music.
enum float PRINT_SD_LO     =  3.790f;
enum float PRINT_SD_HI     = 14.263f;
enum float PRINT_SPREAD_LO =  0.913f; // blue: spread of the 24 band crests, dB
enum float PRINT_SPREAD_HI =  1.936f;
enum float PRINT_FLOOR    =  0.1f;   // added to each channel so three near-zero
                                     // values read as balanced, not as noise
// Power on each channel's ratio to the strongest. Below 1 lifts the weaker
// channels towards full, so a mix with all three active reads pastel;
// OfflineMeter's 1.618 pushed them down for stronger tints.
enum float PRINT_GAMMA    =  0.618034f;
// Match score, OfflineMeter's allMatch on the fingerprint: per-frame balance
// shaped by 1 - (1 - b)^SCORE_SHAPE, accumulated as a running mean weighted by
// frame peak amplitude ^ SCORE_WEIGHT_POWER, the mean shaped again and scaled
// to 0..SCORE_SCALE. Grades run Z (2) to A (27); below 2 is '-'. The weights
// are a power of amplitude, so a uniform gain cancels out of the mean.
// SCORE_SCALE 28 (was 27.618) gives A, 27 and above, a whole point: the
// shaped mean needs 27/28 = 96.4% for an A instead of 97.8%. Scores scale by
// 28/27.618, so the ranking of tracks doesn't change.
enum double SCORE_SHAPE        = 1.61803399;
enum double SCORE_SCALE        = 28.0;
enum double SCORE_WEIGHT_POWER = 0.5;
// Power on min/max before it becomes balance. Equal to PRINT_GAMMA, balance
// follows the lightness of the fingerprint strip; kept a separate constant
// so the look and the score can be tuned apart later.
enum double SCORE_GAMMA        = 0.618034;
// Every track is scored as if it began with this much perfectly balanced
// music, weighted at the track's own mean weight so far (so gain still cancels).
// The running score starts at the top and a short quiet or sparse intro only
// dents it, as with OfflineMeter's balanced starting accumulators. It stays in
// the final score as SCORE_PRIOR_S / track length of perfect balance.
enum double SCORE_PRIOR_S      = 15.0;
// The short-term test behind the A lane: the match score's own formula over
// the last A_WINDOW_S seconds alone, with every frame counting equally (level
// doesn't weigh in, silent frames count as balance 0) and no prior. A window
// scoring an A underscores all of its frames.
enum int    A_WINDOW_S         = 3;
enum int    A_WINDOW_FRAMES    = cast(int)(A_WINDOW_S * 1000 / HOP_MS);   // 150

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Canvasity takes any 4-byte r/g/b/a struct, which saves building a CSS
/// colour string for every rectangle.
struct Rgba { ubyte r, g, b, a = 255; }

float clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }

/// x^y for x >= 0, as exp(y log x) in the precision of its arguments.
/// std.math.pow computes in real: the x87 unit's 80 bits on x86-64, where
/// it is slow, but only 64 on arm64, so results differed between the two.
double powPos(double x, double y) { return exp(y * log(x)); }
/// ditto
float powPos(float x, float y) { return exp(y * log(x)); }

// 10^(dB / 10) is exp(dB * DB_POWER), 10^(dB / 20) exp(dB * DB_AMPLITUDE).
// The nearest doubles to ln(10) / 10 and / 20, written out: `LN10 / 10` would
// be rounded in the compiler's real, which differs between hosts.
enum double DB_POWER     = 0x1.d791c5f888822p-3;
enum double DB_AMPLITUDE = 0x1.d791c5f888822p-4;

/// Each band's energy, back from its level in dB.
void bandPowers(ref const FrameFeatures f, out double[NBANDS] p)
{
    foreach (b; 0 .. NBANDS) p[b] = exp(f.bandLevelDb[b] * DB_POWER);
}

/// Sum of the band energies. The bands overlap, so this reads a little high,
/// which is fine for gating silence. FrameFeatures has no full-band level.
double bandEnergy(ref const double[NBANDS] p)
{
    double e = 0;
    foreach (b; 0 .. NBANDS) e += p[b];
    return e;
}

/// ditto
double bandEnergy(ref const FrameFeatures f)
{
    double[NBANDS] p;
    bandPowers(f, p);
    return bandEnergy(p);
}

/// Standard deviation of the 24 band crests in dB, each band weighted by its
/// share `p[b] / e` of the frame's energy (bandPowers(f), bandEnergy(p)).
double bandCrestSpread(ref const FrameFeatures f, ref const double[NBANDS] p, double e)
{
    if (!(e > 0)) return 0;
    double m = 0;
    foreach (b; 0 .. NBANDS) m += p[b] / e * f.bandCrestDb[b];
    double v = 0;
    foreach (b; 0 .. NBANDS)
        v += p[b] / e * (f.bandCrestDb[b] - m) ^^ 2;
    return sqrt(v);
}

/// OfflineMeter's packageGrade: 27 -> 'A' ... 2 -> 'Z', below 2 -> '-'.
char scoreGrade(double score)
{
    immutable int n = score < 0 ? 0 : score > 27 ? 27 : cast(int) score;
    return n < 2 ? '-' : cast(char)('Z' - n + 2);
}

/// The match score's shaping, 1 - (1 - x)^SCORE_SHAPE: applied to each
/// frame's balance and again to the mean of them.
double shaped(double x)
{
    return 1.0 - powPos(1.0 - x, SCORE_SHAPE);
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel scores
// ─────────────────────────────────────────────────────────────────────────────
// Each unclamped channel (PrintFrame.red, green, blue) on the match score's
// scale: times CHANNEL_SCALE, cut to a whole bucket. The channels aren't
// clamped, so buckets run past 27 into 28..31, and everything from 31 up
// shares bucket 31. A channel's score is the running 90th percentile of its
// buckets, as a letter: 27 'a' ... 2 'z' within the channel's range, 28 'A'
// ... 31 'D' above it, where its colour saturates. The scaling is tentative.

enum int   CHANNEL_BUCKETS = 32;
// SCORE_SCALE's 28, but a constant of its own: the letters are tied to it
// (28 'A', 27 'a'), so a change to the match score mustn't move them.
enum float CHANNEL_SCALE   = 28.0f;

/// The bucket of unclamped channel value `v`, which must be 0 or more.
uint channelBucket(float v)
in (v >= 0)
{
    immutable float x = v * CHANNEL_SCALE;
    return x >= CHANNEL_BUCKETS - 1 ? CHANNEL_BUCKETS - 1 : cast(uint) x;
}

/// The letter for a channel's p90 bucket: 31 'D' ... 28 'A', 27 'a' ... 2 'z',
/// below 2 '-'; -1 (nothing counted yet) '-' too.
char channelGrade(int bucket)
{
    return bucket >= 28 ? cast(char)('A' + bucket - 28)
         : bucket >= 2  ? cast(char)('a' + 27 - bucket)
         :                '-';
}

/// Exact running p90 (nearest-rank) over 32 discrete values.
/// p90 = smallest bucket v with count(x <= v) >= ceil(0.9 * n).
///
/// A bucket's uint count overflows after 2^32 - 1 values: 994 days without a
/// reset at one value per 20 ms frame, if every frame lands in it. Accepted.
struct P90Tracker
{
pure nothrow @nogc:

    enum B = CHANNEL_BUCKETS;

    uint[B] counts;
    ulong n;
    ulong below;  // number of samples in buckets < p
    uint p;       // bucket holding the current p90

    void add(uint k)
    in (k < B)
    {
        counts[k]++;
        n++;
        if (k < p)
            below++;

        immutable target = (9 * n + 9) / 10;  // ceil(0.9 * n), integer-exact

        // Too low: the count up to and including p is short of the target.
        while (below + counts[p] < target)
            below += counts[p++];

        // Too high: the buckets under p already reach the target.
        while (below >= target)
            below -= counts[--p];
    }

    /// Bucket index of the current p90. Map it to your value if needed.
    uint p90() const
    in (n > 0)
    {
        return p;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LiveFingerprint
// ─────────────────────────────────────────────────────────────────────────────

/// The fingerprint's colour and balance, from printColour().
struct PrintColour
{
    Rgba  colour;
    float balance = 0;  // 0 = one quality dominates .. 1 = all equal
}

/// The colour and balance for the unclamped channels (PrintFrame.red, green,
/// blue): each clamped to 0..1 and raised by PRINT_FLOOR, then taken relative
/// to the strongest.
PrintColour printColour(float red, float green, float blue)
{
    // The lowest min/max possible: one channel at the top of its range, another
    // at the floor. Balance maps that to 0.
    immutable double lo = powPos(PRINT_FLOOR / (1.0 + PRINT_FLOOR), SCORE_GAMMA);

    immutable float r = clamp01(red)   + PRINT_FLOOR;
    immutable float g = clamp01(green) + PRINT_FLOOR;
    immutable float b = clamp01(blue)  + PRINT_FLOOR;
    immutable float m = max(r, g, b);
    PrintColour c;
    c.colour  = Rgba(cast(ubyte)(255.0f * powPos(r / m, PRINT_GAMMA) + 0.5f),
                     cast(ubyte)(255.0f * powPos(g / m, PRINT_GAMMA) + 0.5f),
                     cast(ubyte)(255.0f * powPos(b / m, PRINT_GAMMA) + 0.5f));
    c.balance = clamp01(cast(float)((powPos(cast(double)(min(r, g, b) / m), SCORE_GAMMA) - lo) / (1.0 - lo)));
    return c;
}

/// The quantities LiveFingerprint smooths, as energy-weighted sums: energy,
/// centroid and centroid squared, flux and band-crest spread. Kept together,
/// so LLVM can update them as one vector.
struct Sums { double e = 0, ce = 0, cce = 0, fe = 0, se = 0; }

/// The fingerprint and score for one frame, from LiveFingerprint.push().
struct PrintFrame
{
    Rgba  colour;     // the fingerprint's colour; not meaningful when silent
    bool  silent;     // the smoothed window is below SILENT_DB
    float balance = 0; // 0 = one quality dominates .. 1 = all equal; 0 when silent
    /// The three channels unclamped and without PRINT_FLOOR, on the same
    /// scales: 0 and 1 are the ends of each channel's range (PRINT_FLUX_*,
    /// PRINT_SD_*, PRINT_SPREAD_*), so they run below 0 and above 1 where
    /// the colour saturates. 0 when silent.
    float red = 0, green = 0, blue = 0;
    /// Each channel's score so far: the p90 bucket (channelBucket) of its
    /// values of 0 or more in the frames since reset() that weren't silent,
    /// this one included; channelGrade() gives the letter. -1 until a value
    /// has been counted. Silent frames hold the last value.
    byte redP90 = -1, greenP90 = -1, blueP90 = -1;
    float weight = 0;  // frame peak amplitude ^ SCORE_WEIGHT_POWER; 0 when silent
    float score = 0;   // running match score up to this frame, 0 .. SCORE_SCALE
    /// The last A_WINDOW_FRAMES frames' own score, this one included, 0 ..
    /// SCORE_SCALE; 0 until there have been that many.
    float windowScore = 0;

    /// Whether the window ending here scores an A.
    bool windowIsA() const pure nothrow @nogc { return scoreGrade(windowScore) == 'A'; }
}

/// Every fingerprint channel is an energy-weighted average over the window,
/// so a quiet frame barely moves any of them:
///
///   red    flux / frame amplitude. Raw flux is computed on unnormalised
///          magnitudes and tracks loudness (r ~0.9 on music), so without the
///          division red would mostly be a level meter.
///   green  centroid SD, the square root of E[c^2] - E[c]^2 from the window's
///          weighted sums of c and c squared, mapped on a log scale.
///   blue   spread of the 24 band crests within each frame: their standard
///          deviation in dB, each band weighted by its share of the frame's
///          energy so near-silent bands add no noise. A mix of separated
///          sources (sustained bass and pads beside sharp drums) spreads the
///          bands apart; a single instrument keeps them close. Limiting
///          narrows the full-band crest but not this spread.
///
/// The window is a one-pole lowpass of smoothFrames, forwards only, so
/// each frame depends on the past alone. Balance is min/max of the three
/// raised to SCORE_GAMMA, rescaled so the PRINT_FLOOR baseline maps to 0.
///
/// Call reset() before the first push() and to start a new measurement.
struct LiveFingerprint
{
pure nothrow @nogc:

    /// The smoothing's time constant in frames, at least 1. Set it before the
    /// first push(); reset() leaves it alone.
    int smoothFrames = PRINT_SMOOTH_FRAMES;

    void reset()
    {
        started = false;
        s = Sums.init;
        num = den = 0;
        counted = 0;
        recent[] = 0;
        pushed = 0;
        foreach (ref t; channelP90) t = P90Tracker.init;
    }

    PrintFrame push(ref const FrameFeatures f)
    {
        // This frame's contributions to the smoothed sums. The band powers
        // once: they are most of the cost of a push.
        double[NBANDS] p0;
        bandPowers(f, p0);
        Sums x;
        x.e   = bandEnergy(p0);
        x.ce  = x.e * f.centroidSemitones;
        x.cce = x.ce * f.centroidSemitones;
        x.fe  = sqrt(x.e) * f.flux;                         // e * (flux / sqrt(e))
        x.se  = x.e * bandCrestSpread(f, p0, x.e);
        immutable double pk = sqrt(x.e) * exp(f.fullCrestDb * DB_AMPLITUDE);   // RMS x crest

        // The smoothers start from the first frame's value.
        if (!started)
        {
            s = x;
            started = true;
        }
        immutable double a = 1.0 - exp(-1.0 / smoothFrames);
        foreach (i, ref v; s.tupleof)
            v += a * (x.tupleof[i] - v);

        immutable double priorFrames = SCORE_PRIOR_S * 1000.0 / HOP_MS;

        PrintFrame p;
        immutable double en = s.e > 1e-30 ? s.e : 1e-30;
        if (10.0 * log10(en) < SILENT_DB)
        {
            // A silent window has no meaningful balance to colour or score.
            p.silent  = true;
            p.balance = 0;
            p.weight  = 0;
        }
        else
        {
            immutable double mean = s.ce / en;
            immutable float  sd   = cast(float) sqrt(max(0.0, s.cce / en - mean * mean));
            immutable float  nfl  = cast(float)(s.fe / en);
            immutable float  spr  = cast(float)(s.se / en);

            p.red   = (nfl - PRINT_FLUX_LO)   / (PRINT_FLUX_HI   - PRINT_FLUX_LO);
            p.green = cast(float)(log(max(sd, 1e-6f) / PRINT_SD_LO) / log(PRINT_SD_HI / PRINT_SD_LO));
            p.blue  = (spr - PRINT_SPREAD_LO) / (PRINT_SPREAD_HI - PRINT_SPREAD_LO);

            immutable PrintColour pc = printColour(p.red, p.green, p.blue);
            p.colour  = pc.colour;
            p.balance = pc.balance;

            // The channel scores: values below 0 aren't counted.
            immutable float[3] unclamped = [p.red, p.green, p.blue];
            foreach (c; 0 .. 3)
                if (unclamped[c] >= 0)
                    channelP90[c].add(channelBucket(unclamped[c]));
            p.weight  = cast(float) powPos(pk, SCORE_WEIGHT_POWER);

            num += shaped(p.balance) * p.weight;
            den += p.weight;
            ++counted;
        }
        p.redP90   = channelP90[0].n ? cast(byte) channelP90[0].p90 : -1;
        p.greenP90 = channelP90[1].n ? cast(byte) channelP90[1].p90 : -1;
        p.blueP90  = channelP90[2].n ? cast(byte) channelP90[2].p90 : -1;

        // The prior: priorFrames frames of balance 1 at the mean weight so far.
        // Before any audible frame it is all there is, so the score starts at
        // the top.
        immutable double wPrior = counted > 0 ? priorFrames * den / counted : 1.0;
        immutable double mm = (num + wPrior) / (den + wPrior);
        p.score = cast(float)(shaped(mm) * SCORE_SCALE);

        // The window score: the plain mean of the shaped balances, summed
        // afresh every frame so no rounding builds up.
        recent[pushed % A_WINDOW_FRAMES] = shaped(p.balance);
        ++pushed;
        if (pushed >= A_WINDOW_FRAMES)
        {
            double sum = 0;
            foreach (q; recent) sum += q;
            immutable double wm = sum / A_WINDOW_FRAMES;
            p.windowScore = cast(float)(shaped(wm) * SCORE_SCALE);
        }
        return p;
    }

private:
    bool   started;
    Sums   s;                                        // smoothed sums
    double num = 0, den = 0;                         // weighted balance sums
    size_t counted;                                  // audible frames so far
    double[A_WINDOW_FRAMES] recent = 0;              // shaped balances, circular
    size_t pushed;                                   // frames so far, silent too
    P90Tracker[3] channelP90;                        // red, green, blue buckets
}
