module stimulation.offline;

import std.stdio;
import std.math : PI, sin, sqrt, log, log10, exp, cos, fabs;
import std.random : Random, uniform01;
import std.array : appender, Appender, array;
import std.format : format;
import std.algorithm : map, max, min, sort, startsWith;
import std.exception : enforce;
import std.file : read, writeFile = write;
import std.getopt : getopt, defaultGetoptPrinter;
import std.path : absolutePath, baseName, buildNormalizedPath, stripExtension;
import std.range : iota, isForwardRange, hasLength, walkLength;

import audioformats : AudioStream, audiostreamUnknownLength;
import gamut : Image, ImageFormat, PixelType, LAYOUT_GAPLESS, LAYOUT_VERT_STRAIGHT,
               freeEncodedImage;

import stimulation.analyser;
import stimulation.buildid;
import stimulation.engine;
import stimulation.fingerprint;
import stimulation.timeline;

// ─────────────────────────────────────────────────────────────────────────────
// Runner
// ─────────────────────────────────────────────────────────────────────────────
// The analysis itself, fingerprint and score included, is StimEngine's, the
// same code the plugin runs. This file only feeds it a decoded file and
// writes out what comes back.

/// What analyse() returns: the packets and the stream they came from. The
/// rest is derived from the packets on request, so it can't disagree with them.
struct AnalysisResult
{
    FramePacket[] packets;  // one per frame kept: features, fingerprint, score
    StreamInfo    info;     // sample rate, hop, bin count, band centres

    /// The frames' features, packets[i].f, for the summaries.
    auto frames() const pure nothrow @nogc
    {
        return packets.map!((ref const FramePacket p) => p.f);
    }

    /// The heaviest frame weight, which the balance lane is scaled to: the
    /// engine's running maximum at the last packet, as the plugin uses it.
    /// 0 without frames.
    float maxWeight() const pure nothrow @nogc
    {
        return packets.length > 0 ? packets[$ - 1].maxWeight : 0;
    }

    /// The match score at the end, 0 without frames.
    float finalScore() const pure nothrow @nogc
    {
        return packets.length > 0 ? packets[$ - 1].print.score : 0;
    }

    /// The match score's letter at the end.
    char grade() const pure nothrow @nogc { return scoreGrade(finalScore); }

    /// The channel scores at the end, green, blue, red: see channelGrade.
    /// '-' without frames.
    char[3] channelGrades() const pure nothrow @nogc
    {
        char[3] g = '-';
        if (packets.length > 0)
            g = runningGrades(packets[$ - 1].print)[1 .. 4];
        return g;
    }
}

/// The running grades after frame `p`: the match score's letter, then the
/// green, blue and red channel scores, e.g. "Agbr".
char[4] runningGrades(ref const PrintFrame p) pure nothrow @nogc
{
    return [scoreGrade(p.score), channelGrade(p.greenP90),
            channelGrade(p.blueP90), channelGrade(p.redP90)];
}

/// Feed decoded stereo audio through the engine. `left` and `right` must be
/// the same length. Frames are 40 ms at any sample rate. `smoothFrames` is
/// the fingerprint's smoothing, see LiveFingerprint.smoothFrames.
AnalysisResult analyse(const(float)[] left, const(float)[] right, float sr,
                       int smoothFrames = PRINT_SMOOTH_FRAMES)
{
    if (left.length != right.length)
        throw new Exception("channel length mismatch");

    // Below this the band bank's 0.45 x sr cap falls under BAND_HI_HZ.
    if (sr < BAND_HI_HZ / 0.45f)
        stderr.writefln("WARNING: sample rate is %.0f Hz, so the analysis stops at "
                        ~ "%.0f Hz instead of %.0f Hz; features are not comparable "
                        ~ "with 44.1 kHz and higher material.",
                        sr, 0.45f * sr, BAND_HI_HZ);

    StimEngine engine;
    engine.initialize(sr, smoothFrames);
    scope(exit) engine.destroy();

    // In chunks, so that a very long file cannot overflow the engine's int
    // sample counts.
    enum int CHUNK = 1 << 20;
    auto acc = appender!(FramePacket[]);
    acc.reserve(left.length / engine.info.hopLen + 4);
    auto buf = new FramePacket[engine.maxFrames(CHUNK)];
    for (size_t pos = 0; pos < left.length; pos += CHUNK)
    {
        immutable int n = cast(int) min(CHUNK, left.length - pos);
        immutable int got = engine.process(left.ptr + pos, right.ptr + pos, n, buf);
        acc.put(buf[0 .. got]);
    }

    return AnalysisResult(acc.data, engine.info);
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio file input
// ─────────────────────────────────────────────────────────────────────────────

/// Windows refuses paths of MAX_PATH (260) characters or more unless they
/// carry the \\?\ prefix, which also switches off path parsing, so the path
/// has to be absolute and normalised first. Deep library names under a deep
/// output folder reach that length easily.
string longPath(string p)
{
    version (Windows)
    {
        if (p.length >= 240 && !p.startsWith(`\\?\`))
            return `\\?\` ~ p.absolutePath.buildNormalizedPath;
    }
    return p;
}

struct DecodedAudio
{
    float[] left, right;
    float   sampleRate;
    int     channels;     // as stored in the file, before the L/R split
}

/// Decode a whole file (WAV, FLAC, MP3, OGG, ...) to two float channels.
/// Mono is copied to both sides, so stereo_width reads 0. Beyond two channels
/// only the first pair is kept, which is front L/R in the usual 5.1/7.1 layouts.
///
/// No resampling: the file's own rate is passed on, and analyse() warns when
/// it is not 48 kHz.
DecodedAudio loadAudio(string path)
{
    // Read the file ourselves and decode from memory. openFromFile() goes
    // through the C runtime's narrow fopen, which on Windows cannot open a
    // path with non-ASCII characters; std.file.read uses the wide API. The
    // stream decodes in place, so `bytes` must outlive it, which it does here.
    const(ubyte)[] bytes = cast(const(ubyte)[]) read(longPath(path));
    AudioStream stream;
    stream.openFromMemory(bytes);
    enforce(stream.isValid(),
            format("could not open '%s': %s", path, stream.errorMessage()));
    enforce(stream.isOpenForReading(), "stream is not open for reading");

    immutable int   ch = stream.getNumChannels();
    immutable float sr = stream.getSamplerate();
    enforce(ch > 0,  "decoder returned an invalid channel count");
    enforce(sr > 0,  "decoder returned an invalid sample rate");
    if (ch > 2)
        stderr.writefln("WARNING: %d channels, analysing only the first two", ch);

    auto accL = appender!(float[]);
    auto accR = appender!(float[]);
    immutable long known = stream.getLengthInFrames();
    if (known != audiostreamUnknownLength)
    {
        accL.reserve(cast(size_t) known);
        accR.reserve(cast(size_t) known);
    }

    // Deinterleave chunk by chunk rather than holding the whole interleaved
    // file as well. Reading until the decoder runs dry also covers streams
    // whose length is unknown up front.
    enum int CHUNK = 8192;
    auto buf = new float[CHUNK * ch];
    for (;;)
    {
        immutable int got = stream.readSamplesFloat(buf.ptr, CHUNK);
        enforce(!stream.isError(), "decoding failed: " ~ stream.errorMessage());
        if (got <= 0) break;
        foreach (i; 0 .. got)
        {
            immutable float l = buf[i * ch];
            accL.put(l);
            accR.put(ch == 1 ? l : buf[i * ch + 1]);
        }
    }

    return DecodedAudio(accL.data, accR.data, sr, ch);
}

// ─────────────────────────────────────────────────────────────────────────────
// CSV output
// ─────────────────────────────────────────────────────────────────────────────

/// Writes `r` as CSV to `path` and returns the line to report it with.
string writeCsv(ref const AnalysisResult r, string path)
{
    auto fh = File(longPath(path), "w");

    // Header. Band columns carry their centre frequency so the plot can be
    // labelled without re-deriving the mel layout.
    fh.write("frame,time_s");
    foreach (b; 0 .. NBANDS)
        fh.writef(",level_%.0fHz_dB", r.info.bandCentres[b]);
    foreach (b; 0 .. NBANDS)
        fh.writef(",crest_%.0fHz_dB", r.info.bandCentres[b]);
    fh.writeln(",full_crest_dB,f_low_st,f_high_st,centroid_st,flux,stereo_width,live_bins",
               ",red,green,blue,balance,balance_weight,match_score,window_score,grades");

    immutable double hopSec = cast(double) r.info.hopLen / r.info.sampleRate;

    foreach (n, ref p; r.packets)
    {
        const f = &p.f;
        fh.writef("%d,%.4f", f.frameIndex, f.frameIndex * hopSec);
        foreach (b; 0 .. NBANDS) fh.writef(",%.3f", f.bandLevelDb[b]);
        foreach (b; 0 .. NBANDS) fh.writef(",%.3f", f.bandCrestDb[b]);
        fh.writef(",%.3f,%.3f,%.3f,%.3f,%.6f,%.4f,%d",
                  f.fullCrestDb, f.fLowSemitones, f.fHighSemitones,
                  f.centroidSemitones, f.flux, f.stereoWidth, f.liveBins);
        // Derived, not raw: appended after the analyser's columns so those
        // keep their positions. The channels and balance are nan in silent
        // frames, window_score until its first window is full. grades are
        // the running match score's letter and channel scores.
        immutable bool s = p.print.silent;
        fh.writef(",%.4f,%.4f,%.4f", s ? float.nan : p.print.red,
                  s ? float.nan : p.print.green, s ? float.nan : p.print.blue);
        immutable char[4] grades = runningGrades(p.print);
        fh.writefln(",%.4f,%.6g,%.3f,%.3f,%s", s ? float.nan : p.print.balance,
                    p.print.weight, p.print.score,
                    n + 1 < A_WINDOW_FRAMES ? float.nan : p.print.windowScore, grades[]);
    }

    return format("wrote %s (%d frames)", path, r.packets.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// PNG output
// ─────────────────────────────────────────────────────────────────────────────
// One column per analysis frame (20 ms at any sample rate), time running left
// to right, drawn by the core's TimelineRenderer at scale 1: the plugin's
// window shows the same picture. The lanes are described in
// stimulation.timeline and in HELP.md.

/// Draws `r`'s timeline to `path` as PNG and returns the line to report it with.
string renderPng(ref const AnalysisResult r, string path)
{
    immutable int width = max(1, cast(int) r.packets.length);

    auto image = Image(width, TIMELINE_HEIGHT, PixelType.rgba8);
    image.setLayout(LAYOUT_GAPLESS | LAYOUT_VERT_STRAIGHT);

    TimelineRenderer timeline;
    timeline.initialize(r.info, 1.0f);

    // Balance-lane columns are drawn relative to the heaviest frame, so their
    // heights are in proportion to each frame's share of the score.
    immutable float wMax = r.maxWeight;

    // The A lane as it stands at the end: the plugin marks the same frames,
    // back in time, as the windows complete.
    auto underscored = new bool[r.packets.length];
    Underscore underscore;
    foreach (n, ref p; r.packets)
        underscored[underscore.push(n, p.print) .. n + 1] = true;

    if (r.packets.length == 0)
        putColumn(image, 0, 0, TIMELINE_HEIGHT, SURFACE);
    foreach (x, ref p; r.packets)
        timeline.drawColumn(image, cast(int) x, p, wMax, underscored[x]);

    // Encode in memory and write with std.file: saveToFile() goes through the
    // C runtime's narrow fopen, which garbles non-ASCII names on Windows.
    ubyte[] png = image.saveToMemory(ImageFormat.PNG);
    enforce(png !is null, "could not encode " ~ path);
    scope (exit) freeEncodedImage(png);
    writeFile(longPath(path), png);
    return format("wrote %s (%d x %d)", path, width, TIMELINE_HEIGHT);
}

/// CSV and PNG under one stem. `quiet` leaves out the "wrote ..." lines.
void writeOutputs(ref const AnalysisResult r, string stem, bool quiet)
{
    immutable string csv = writeCsv(r, stem ~ ".csv");
    if (!quiet) writeln(csv);
    immutable string png = renderPng(r, stem ~ ".png");
    if (!quiet) writeln(png);
    writefln("  match score %.2f, grade %c", r.finalScore, r.grade);
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic test signals
// ─────────────────────────────────────────────────────────────────────────────

struct TestSignal
{
    float[] left, right;
    string  name;
}

/// Linear sweep. fLow/fHigh/centroid should trace a clean diagonal.
TestSignal makeSweep(float sr, double seconds, double f0 = 20.0, double f1 = 20000.0) pure nothrow
{
    immutable size_t n = cast(size_t)(sr * seconds);
    auto buf = new float[n];
    double phase = 0.0;
    foreach (i; 0 .. n)
    {
        immutable double t = cast(double) i / n;
        immutable double f = f0 + (f1 - f0) * t;
        buf[i] = cast(float)(0.5 * sin(phase));
        phase += 2.0 * PI * f / sr;
        if (phase > 2.0 * PI) phase -= 2.0 * PI;
    }
    return TestSignal(buf, buf, "sweep");
}

/// Seed for the noise test signals unless --seed says otherwise. Fixed, so
/// that --test writes the same files on every run, which stim-check relies on.
enum uint DEFAULT_TEST_SEED = 1;

/// Gaussian white noise from `seed`. Full-band crest should sit steady around
/// 10-12 dB. `stream` selects an independent sequence under the same seed, so
/// the two channels of makeWideNoise stay uncorrelated.
TestSignal makeNoise(float sr, double seconds, uint seed, double sigma = 0.1,
                     uint stream = 0) pure nothrow
{
    immutable size_t n = cast(size_t)(sr * seconds);
    auto buf = new float[n];
    auto rng = Random(seed + stream);

    // Box-Muller, two samples at a time.
    for (size_t i = 0; i < n; i += 2)
    {
        double u1 = uniform01(rng);
        double u2 = uniform01(rng);
        if (u1 < 1e-12) u1 = 1e-12;
        immutable double mag = sigma * sqrt(-2.0 * log(u1));
        buf[i] = cast(float)(mag * cos(2.0 * PI * u2));
        if (i + 1 < n)
            buf[i + 1] = cast(float)(mag * sin(2.0 * PI * u2));
    }
    return TestSignal(buf, buf, "noise");
}

/// Square wave. Full-band crest should be near 0 dB.
TestSignal makeSquare(float sr, double seconds, double freq = 100.0, double amp = 0.5) pure nothrow
{
    immutable size_t n = cast(size_t)(sr * seconds);
    auto buf = new float[n];
    immutable double period = sr / freq;
    foreach (i; 0 .. n)
    {
        immutable double ph = (i % cast(size_t) period) / period;
        buf[i] = cast(float)(ph < 0.5 ? amp : -amp);
    }
    return TestSignal(buf, buf, "square");
}

/// Decorrelated noise in L/R from `seed`. stereo_width should approach 0.5.
TestSignal makeWideNoise(float sr, double seconds, uint seed, double sigma = 0.1) pure nothrow
{
    auto a = makeNoise(sr, seconds, seed, sigma, 0);
    auto b = makeNoise(sr, seconds, seed, sigma, 1);
    return TestSignal(a.left, b.left, "wide_noise");
}

/// Steady sine. The spectrum is stationary, so flux should sit near zero.
/// 997 Hz rather than 1000: at 1 kHz one hop is exactly 20 periods, so every
/// frame is bit-identical and flux is trivially 0.0 without exercising anything.
TestSignal makeSteadyTone(float sr, double seconds, double freq = 997.0,
                          double amp = 0.5) pure nothrow
{
    immutable size_t n = cast(size_t)(sr * seconds);
    auto buf = new float[n];
    foreach (i; 0 .. n)
        buf[i] = cast(float)(amp * sin(2.0 * PI * freq * i / sr));
    return TestSignal(buf, buf, "steady_tone");
}

/// Samples between makeOnsets' bursts.
size_t burstStride(float sr, double burstHz) pure nothrow @nogc
{
    return cast(size_t)(sr / burstHz);
}

/// Where makeOnsets' bursts start: every burstStride samples, from one
/// stride in, while inside the signal. expectedOnsets counts the same.
auto burstStarts(float sr, double seconds, double burstHz) pure nothrow @nogc
{
    immutable size_t n = cast(size_t)(sr * seconds);
    immutable size_t stride = burstStride(sr, burstHz);
    return iota(stride, n, stride);
}

/// Exponentially decaying tone bursts at a fixed rate, the first at t = 1/burstHz.
/// Flux should spike once per burst and fall back to near zero between them. The
/// decay itself contributes nothing: flux is half-wave rectified, so only rising
/// bin magnitudes count.
TestSignal makeOnsets(float sr, double seconds, double burstHz = 2.0,
                      double freq = 1000.0, double tau = 0.08, double amp = 0.5) pure nothrow
{
    immutable size_t n = cast(size_t)(sr * seconds);
    auto buf = new float[n];
    // new float[] is NaN-initialised in D, and this generator leaves the lead-in
    // gap unwritten. Without this the gap is NaN, not silence, and one NaN is
    // enough to poison the K-weighting biquad states for the whole run.
    buf[] = 0.0f;
    immutable size_t stride = burstStride(sr, burstHz);

    foreach (start; burstStarts(sr, seconds, burstHz))
        foreach (i; 0 .. stride)
        {
            immutable size_t j = start + i;
            if (j >= n) break;
            immutable double t = cast(double) i / sr;
            buf[j] = cast(float)(amp * exp(-t / tau) * sin(2.0 * PI * freq * t));
        }
    return TestSignal(buf, buf, "onsets");
}

/// How many bursts makeOnsets() lays down for these arguments.
int expectedOnsets(float sr, double seconds, double burstHz = 2.0) pure nothrow @nogc
{
    return cast(int) burstStarts(sr, seconds, burstHz).walkLength;
}

// ─────────────────────────────────────────────────────────────────────────────
// Summaries
// ─────────────────────────────────────────────────────────────────────────────

struct Stats { double mean, sd, lo, hi; }

/// `pick` is an alias so the lambda inlines and there is no delegate-parameter
/// type inference to get wrong: summarise!(f => f.fullCrestDb)(r.frames).
/// Two passes over `fr`, in order.
Stats summarise(alias pick, R)(R fr) pure nothrow @nogc
if (isForwardRange!R && hasLength!R)
{
    if (fr.length == 0) return Stats(0, 0, 0, 0);
    double s = 0, lo = double.max, hi = -double.max;
    foreach (f; fr.save)
    {
        immutable double v = cast(double) pick(f);
        s += v; lo = min(lo, v); hi = max(hi, v);
    }
    immutable double m = s / fr.length;
    double var = 0;
    foreach (f; fr)
    {
        immutable double d = cast(double) pick(f) - m;
        var += d * d;
    }
    return Stats(m, sqrt(var / fr.length), lo, hi);
}

/// Peak-to-RMS in dB over a whole buffer. The analyser measures crest AFTER
/// K-weighting, which is what BS.1770 asks for; this is the pre-filter value,
/// and it is the one that is 0 dB for a square wave.
double crestDb(const(float)[] x) pure nothrow @nogc
{
    if (x.length == 0) return 0;
    double pk = 0, ss = 0;
    foreach (v; x) { immutable double a = fabs(v); if (a > pk) pk = a; ss += v * v; }
    immutable double rms = sqrt(ss / x.length);
    return (rms > 1e-12) ? 20 * log10(pk / rms) : 0;
}

struct FluxPeaks
{
    int    count;
    double median;    // typical flux between onsets
    double peak;      // largest flux in the track
    double peakMean;  // mean height of the detected peaks
}

/// Count local maxima in the flux track that clear a quarter of the largest.
/// The threshold is relative to the peak rather than the median because the
/// median is legitimately zero when the material is mostly silence. A
/// three-frame refractory stops one onset being counted twice.
FluxPeaks findFluxPeaks(R)(R fr) pure nothrow
if (isForwardRange!R)
{
    FluxPeaks r;
    double[] v = fr.map!(f => cast(double) f.flux).array;
    if (v.length < 3) return r;

    auto s = v.dup;
    sort(s);
    r.median = s[$ / 2];
    r.peak   = s[$ - 1];

    // A flat track has no peaks. Without this a silent input trips the local-max
    // test on every frame and reports a spurious count.
    if (!(r.peak > 0)) return r;

    immutable double thresh = 0.25 * r.peak;
    double acc = 0;
    ptrdiff_t last = -100;
    for (size_t i = 1; i + 1 < v.length; ++i)
    {
        if (v[i] < thresh || v[i] < v[i - 1] || v[i] < v[i + 1]) continue;
        if (cast(ptrdiff_t) i - last < 3) continue;
        last = cast(ptrdiff_t) i;
        acc += v[i];
        r.count++;
    }
    if (r.count > 0) r.peakMean = acc / r.count;
    return r;
}

void report(string label, Stats st, string expectation)
{
    writefln("  %-16s mean %8.2f  sd %6.2f  range [%8.2f, %8.2f]   expect: %s",
             label, st.mean, st.sd, st.lo, st.hi, expectation);
}

// ─────────────────────────────────────────────────────────────────────────────
// Test mode
// ─────────────────────────────────────────────────────────────────────────────

/// The --test signals, by the names their outputs are written under
/// (test_<name>.csv). The plugin's dev host makes them with the same code to
/// check that the plugin produces the same CSVs.
immutable string[] TEST_SIGNALS = ["sweep", "noise", "square", "wide_noise", "steady_tone", "onsets"];

/// The --test signal `name` at `sr`; the noise ones from `seed`.
TestSignal testSignalNamed(string name, float sr, uint seed = DEFAULT_TEST_SEED) pure
{
    switch (name)
    {
        case "sweep":       return makeSweep(sr, 10.0);
        case "noise":       return makeNoise(sr, 10.0, seed);
        // 97 Hz rather than a round 100: at 100 Hz one hop is exactly two
        // periods, so every frame is bit-identical and the sd below is a
        // meaningless 0.00. 97 Hz is incommensurate with the 20 ms hop.
        case "square":      return makeSquare(sr, 5.0, 97.0);
        case "wide_noise":  return makeWideNoise(sr, 5.0, seed);
        case "steady_tone": return makeSteadyTone(sr, 5.0);
        case "onsets":      return makeOnsets(sr, 6.0, 2.0);
        default: throw new Exception("no test signal called " ~ name);
    }
}

/// The synthetic signals at three sample rates. Frames are 40 ms and the
/// spectrum is limited to BAND_LO_HZ .. BAND_HI_HZ at every rate, so the rows
/// for one signal should agree closely. Crest may still read a little lower at
/// lower rates, which catch fewer peaks between samples.
void runRateChecks(uint seed)
{
    writeln("=== sample-rate comparison (means over each signal) ===");
    writefln("  %-12s %6s %9s %9s %8s %7s %6s %6s",
             "signal", "kHz", "crest dB", "centroid", "flux", "live %", "width", "score");
    foreach (name; TEST_SIGNALS)
    {
        foreach (sr; [44_100.0f, 48_000.0f, 96_000.0f])
        {
            auto sig = testSignalNamed(name, sr, seed);
            auto r = analyse(sig.left, sig.right, sr);
            writefln("  %-12s %6.1f %9.2f %9.2f %8.4f %7.1f %6.3f %6.2f", name, sr / 1000,
                     summarise!(f => f.fullCrestDb)(r.frames).mean,
                     summarise!(f => f.centroidSemitones)(r.frames).mean,
                     summarise!(f => f.flux)(r.frames).mean,
                     100.0 * summarise!(f => f.liveBins)(r.frames).mean / r.info.binCount,
                     summarise!(f => f.stereoWidth)(r.frames).mean,
                     r.finalScore);
        }
    }
    writeln();
}

/// The --test run: the six signals from `seed`, their outputs and reports.
/// `quiet` leaves out the "wrote ..." lines.
void runSanityChecks(uint seed, bool quiet, float sr = 48000.0f)
{
    writeln("=== sanity checks ===\n");

    {
        auto sig = testSignalNamed("sweep", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_sweep", quiet);
        writeln("sweep 20 Hz -> 20 kHz, 10 s");
        report("f_low (st)",   summarise!(f => f.fLowSemitones)(r.frames),
               "monotonic rise, no plateaus or spikes");
        report("f_high (st)",  summarise!(f => f.fHighSemitones)(r.frames),
               "tracks f_low closely");
        report("centroid (st)",summarise!(f => f.centroidSemitones)(r.frames),
               "between the two");
        writeln("  -> plot f_low/f_high/centroid vs time: should be one clean diagonal\n");
    }

    {
        auto sig = testSignalNamed("noise", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_noise", quiet);
        writeln("gaussian white noise, 10 s");
        report("full crest (dB)", summarise!(f => f.fullCrestDb)(r.frames),
               "~10-12 dB, sd under 1");
        report("live bins",       summarise!(f => f.liveBins)(r.frames),
               "high - noise fills the spectrum");
        report("stereo width",    summarise!(f => f.stereoWidth)(r.frames),
               "~0 (identical channels)");
        writeln();
    }

    {
        auto sig = testSignalNamed("square", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_square", quiet);
        writefln("97 Hz square, 5 s - raw crest is %.2f dB before filtering",
                 crestDb(sig.left));
        report("full crest (dB)", summarise!(f => f.fullCrestDb)(r.frames),
               "~10 dB, NOT 0 - see below");
        writeln("  -> crest is measured after K-weighting, by design. At this");
        writeln("     frequency the 38 Hz highpass droops the flat tops (~4 ms");
        writeln("     time constant against a ~5 ms half-period) and the +4 dB");
        writeln("     shelf overshoots the edges. Both effects shrink with");
        writeln("     frequency: a 1 kHz square lands near 5.5 dB, 4 kHz near 1.8.\n");
    }

    {
        auto sig = testSignalNamed("wide_noise", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_wide_noise", quiet);
        writeln("decorrelated L/R noise, 5 s");
        report("stereo width", summarise!(f => f.stereoWidth)(r.frames),
               "~0.5 (uncorrelated channels)");
        writeln();
    }

    {
        auto sig = testSignalNamed("steady_tone", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_steady_tone", quiet);
        auto fp = findFluxPeaks(r.frames);
        writeln("steady 997 Hz tone, 5 s");
        report("flux", summarise!(f => f.flux)(r.frames),
               "near zero - a stationary spectrum has nothing to flux");
        writefln("  %-16s %.6f  (vs ~0.44 at an onset, below)", "flux max", fp.peak);
        writeln();
    }

    {
        immutable double seconds = 6.0, burstHz = 2.0;
        immutable int expect = expectedOnsets(sr, seconds, burstHz);
        auto sig = testSignalNamed("onsets", sr, seed);
        auto r = analyse(sig.left, sig.right, sr);
        writeOutputs(r, "test_onsets", quiet);
        auto fp = findFluxPeaks(r.frames);
        writefln("1 kHz tone bursts every %.0f ms, %.0f s", 1000.0 / burstHz, seconds);
        writefln("  %-16s %d detected, %d expected%s", "flux peaks",
                 fp.count, expect, fp.count == expect ? "" : "   <-- MISMATCH");
        writefln("  %-16s peak %.4f   median %.6f", "flux contrast",
                 fp.peakMean, fp.median);
        writeln("  -> counts should match: one flux spike per onset, and the");
        writeln("     between-onset median should be far below the peak.\n");
    }

    runRateChecks(seed);

    Analyser an;
    an.initialize(sr);
    scope (exit) an.destroy();
    immutable int bins = an.binCount();

    writeln("=== floor tuning ===");
    writefln("Plot the live_bins column from a real track. At %.0f Hz it is "
             ~ "counted out of %d bins.", sr, bins);
    writeln("  pinned near ", bins, "  -> FLOOR_DB too permissive, you are keeping noise");
    writeln("  down in the dozens -> FLOOR_DB too strict, you are discarding content");
}

// ─────────────────────────────────────────────────────────────────────────────

version (StimOfflineMain)
int main(string[] args)
{
    bool   test, noPng, showVersion, quiet;
    string csvPath, pngPath;
    int    smoothFrames = PRINT_SMOOTH_FRAMES;
    uint   seed = DEFAULT_TEST_SEED;

    try
    {
        auto opt = getopt(args,
            "test",   "run the synthetic-signal sanity checks", &test,
            "seed",   format("seed for --test's noise signals (default %d)", DEFAULT_TEST_SEED), &seed,
            "csv",    "CSV path (default: <input name>.csv)",  &csvPath,
            "png",    "PNG path (default: <input name>.png)",  &pngPath,
            "no-png", "write the CSV only",                     &noPng,
            "smooth-frames", format("fingerprint smoothing in 20 ms frames (default %d)",
                                    PRINT_SMOOTH_FRAMES), &smoothFrames,
            "quiet",  "print only a key=value summary line",   &quiet,
            "version", "print the core build ID and exit",     &showVersion);

        if (showVersion)
        {
            // Same ID as the plugin shows: built from the same analysis code.
            writeln("stim-offline core ", CORE_BUILD_ID);
            return 0;
        }

        if (test)
        {
            runSanityChecks(seed, quiet);
            return 0;
        }

        if (opt.helpWanted || args.length != 2)
        {
            defaultGetoptPrinter("usage: stim-offline [options] <audio file>\n"
                                 ~ "       stim-offline --test\n", opt.options);
            return opt.helpWanted ? 0 : 1;
        }

        enforce(smoothFrames >= 1, "--smooth-frames must be 1 or more");

        // Outputs land in the working directory, named after the input.
        immutable string input = args[1];
        immutable string stem  = input.baseName.stripExtension;
        if (csvPath.length == 0) csvPath = stem ~ ".csv";
        if (pngPath.length == 0) pngPath = stem ~ ".png";

        auto audio = loadAudio(input);
        immutable double seconds = audio.left.length / audio.sampleRate;
        if (!quiet)
            writefln("%s: %.0f Hz, %d ch, %.2f s", input, audio.sampleRate,
                     audio.channels, seconds);
        if (!quiet && smoothFrames != PRINT_SMOOTH_FRAMES)
            writefln("fingerprint smoothing %d frames (%.2f s), default %d",
                     smoothFrames, smoothFrames * HOP_MS / 1000.0, PRINT_SMOOTH_FRAMES);

        auto r = analyse(audio.left, audio.right, audio.sampleRate, smoothFrames);
        immutable string wroteCsv = writeCsv(r, csvPath);
        if (!quiet) writeln(wroteCsv);
        if (!noPng)
        {
            immutable string wrotePng = renderPng(r, pngPath);
            if (!quiet) writeln(wrotePng);
        }

        // The one line --quiet leaves on stdout: a stable interface for
        // stim-batch, which copies these into its manifest.
        if (quiet)
            writefln("sample_rate=%.0f channels=%d duration_s=%.3f frames=%d score=%.3f grade=%c"
                     ~ " green_score=%c blue_score=%c red_score=%c",
                     audio.sampleRate, audio.channels, seconds, r.frames.length,
                     r.finalScore, r.grade, r.channelGrades[0], r.channelGrades[1], r.channelGrades[2]);
        else
        {
            writefln("match score %.2f, grade %c", r.finalScore, r.grade);
            writefln("channel scores: green %c, blue %c, red %c",
                     r.channelGrades[0], r.channelGrades[1], r.channelGrades[2]);
        }
        return 0;
    }
    catch (Exception e)
    {
        stderr.writeln("error: ", e.msg);
        return 1;
    }
}
