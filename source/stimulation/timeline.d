/// The timeline picture: lanes, scales, colours and a renderer that draws one
/// frame's column at a time.
///
/// stim-offline's PNG is this renderer run over every frame at scale 1; the
/// plugin runs it on each new frame into its rolling window, at the scale the
/// window size asks for. Every mark depends only on its own frame, which is
/// what makes that possible, with two exceptions that are passed in: the
/// heaviest weight, which sets the balance-lane heights, and whether the A
/// lane underscores the frame, which a later frame can decide (Underscore).
///
/// Lanes, top to bottom:
///
///   fingerprint  one colour per column, mixed as in OfflineMeter's backdrop:
///                red = flux relative to level, green = how much the centroid
///                moves, blue = how far apart the 24 band crests are. White
///                means balanced and the tint names what prevails (see
///                stimulation.fingerprint).
///   A lane       yellow in the gap below, under every A_WINDOW_S seconds of
///                fingerprint whose own score is an A: short stretches of
///                good balance, level not counted.
///   balance      each frame's weight in the match score as a column, relative
///                to the heaviest frame (taller = more impact on the score),
///                filled in the fingerprint's own colour (lighter = more
///                balanced). The running match score is the line (top =
///                SCORE_SCALE): dark, and gold while it is at grade A.
///   channels     the fingerprint's three channels unclamped (PrintFrame.red,
///                green, blue) as lines on one fixed scale, CHANNEL_LO ..
///                CHANNEL_HI, over a band from 0 to 1: the range the colour
///                spans. Above the band a channel saturates the colour; how
///                far it is from the others says whether to calm it or raise
///                them. Values past the scale are pinned to its edge, thicker.
///   spectrum     the 24 mel bands, each drawn at its own pitch, so low bands are
///                tall and high bands thin. Strength = band level, hue = band
///                crest (red sustained or compressed, grey typical, blue
///                transient). f_low and f_high are small dark marks; the
///                centroid is the bright green line with a dark edge.
///   dynamics     full-band crest as dots in the same crest colours, over the
///                spread of the 24 band crests in blue (faint: min-max,
///                stronger: middle half). Hairlines at the two poles and at
///                10 dB (white noise).
///   flux         red spikes up from the baseline.
///
/// The centroid, the crest spread and flux are what the fingerprint's green,
/// blue and red are made from, so they are drawn in those colours.
///   width        stereo width, grey (mono) to aqua (uncorrelated, 0.5 and up).
///   live bins    fraction of the bins counted. Red when pinned near the top
///                (FLOOR_DB is letting noise in), orange when down in the
///                dozens (too strict).
///
/// Every scale is fixed rather than fitted to the track, so pictures of
/// different material compare the way the CSV rows do. Frames near silence
/// fade out and fully silent ones get a grey background: there, crest, edges
/// and centroid describe the noise floor rather than the music.
module stimulation.timeline;

import std.algorithm : max, min, sort;
import std.math : floor, log10, round, sqrt;

import gamut : Image;

import stimulation.analyser;
import stimulation.engine;
import stimulation.fingerprint;

pure nothrow @nogc:

// ─────────────────────────────────────────────────────────────────────────────
// Layout and scales (at scale 1, which is the PNG)
// ─────────────────────────────────────────────────────────────────────────────

enum int TIMELINE_HEIGHT = 928;

struct Lane
{
pure nothrow @nogc:
    int top, height;
    int bottom() const { return top + height; }
}

enum Lane LANE_PRINT    = Lane(  0,  24);
enum Lane LANE_GRADE_A  = Lane( 26,   4);
enum Lane LANE_BALANCE  = Lane( 32,  64);
enum Lane LANE_CHANNELS = Lane(104,  80);
enum Lane LANE_SPECTRUM = Lane(192, 320);
enum Lane LANE_DYNAMICS = Lane(520, 180);
enum Lane LANE_FLUX     = Lane(708, 140);
enum Lane LANE_WIDTH    = Lane(856,  24);
enum Lane LANE_LIVE     = Lane(888,  32);

enum float LEVEL_LO_DB   = -80.0f;  // band level at which a cell fades to the surface
enum float LEVEL_HI_DB   =   0.0f;
enum float CREST_MID_DB  =  10.0f;  // white noise: the neutral midpoint
enum float CREST_SPAN_DB =   5.0f;  // poles at 5 and 15 dB, roughly p5/p95 on music
enum float CREST_MAX_DB  =  24.0f;  // top of the dynamics lane
enum float PITCH_LO_ST   = -48.0f;  // 27.5 Hz
enum float PITCH_HI_ST   =  68.0f;  // 22.4 kHz
enum float FLUX_MAX      =   0.6f;
// The channels lane's scale, in the units of PrintFrame.red/green/blue. On
// music p1..p99 runs about -0.25..1.5; green dips far below at a start, where
// the centroid hasn't moved yet. At scale 1 each unit is 32 px.
enum float CHANNEL_LO    =  -0.5f;
enum float CHANNEL_HI    =   2.0f;
enum float WIDTH_MAX     =   0.5f;  // uncorrelated L/R
enum float AUDIBLE_DB    = -55.0f;  // marks at full strength above this (SILENT_DB: none)
// Live-bin thresholds as fractions of the bins counted, which vary with the
// sample rate: about 43 and 660 of 681 at 48 kHz.
enum float LIVE_LOW      = 1.0f / 16;   // "down in the dozens"
enum float LIVE_PINNED   = 31.0f / 32;

enum Rgba SURFACE    = Rgba(0xfc, 0xfc, 0xfb);
enum Rgba SILENCE    = Rgba(0xf0, 0xef, 0xec);
enum Rgba GRID       = Rgba(0xe1, 0xe0, 0xd9);
enum Rgba BASELINE   = Rgba(0xc3, 0xc2, 0xb7);
enum Rgba INK        = Rgba(0x0b, 0x0b, 0x0b);
enum Rgba MUTED      = Rgba(0x89, 0x87, 0x81);
enum Rgba CREST_LOW  = Rgba(0xc0, 0x39, 0x39);
enum Rgba CREST_MID  = Rgba(0x52, 0x51, 0x4e);
enum Rgba CREST_HIGH = Rgba(0x1c, 0x5c, 0xab);
// The lanes behind the fingerprint's three channels are drawn in its colours,
// so a tint in the fingerprint strip points at the lane that explains it.
enum Rgba FLUX_INK      = Rgba(0xc4, 0x48, 0x3c);  // red: flux
enum Rgba CENTROID_INK  = Rgba(0x5c, 0xe0, 0x6e);  // green: centroid; bright, so it
enum Rgba CENTROID_EDGE = Rgba(0x0c, 0x4a, 0x1c);  // reads on any cell with its dark edge
enum Rgba SPREAD_INK    = Rgba(0x2a, 0x6c, 0xc8);  // blue: spread of the band crests
enum Rgba CHANNEL_BAND  = Rgba(0xea, 0xe9, 0xe3);  // the channels' 0..1, darker than SILENCE
enum Rgba WIDTH_INK  = Rgba(0x13, 0x8a, 0x60);
enum Rgba CRITICAL   = Rgba(0xd0, 0x3b, 0x3b);
enum Rgba SERIOUS    = Rgba(0xec, 0x83, 0x5a);
enum Rgba BALANCE_BG = Rgba(0xd6, 0xd5, 0xce);  // darker than any pastel, so white fills show
enum Rgba GRADE_A    = Rgba(0xf5, 0xc0, 0x00);
enum Rgba GRADE_A_INK = Rgba(0xd9, 0x9a, 0x00); // the score line at A: darker, to hold on white

Rgba mix(Rgba a, Rgba b, float t)
{
    t = clamp01(t);
    return Rgba(cast(ubyte)(a.r + (b.r - a.r) * t + 0.5f),
                cast(ubyte)(a.g + (b.g - a.g) * t + 0.5f),
                cast(ubyte)(a.b + (b.b - a.b) * t + 0.5f), 255);
}

Rgba alpha(Rgba c, float a) { c.a = cast(ubyte)(255.0f * clamp01(a) + 0.5f); return c; }

/// Diverging crest scale shared by the spectrum and dynamics lanes.
Rgba crestColour(float crestDb)
{
    immutable float d = (crestDb - CREST_MID_DB) / CREST_SPAN_DB;
    return d < 0 ? mix(CREST_MID, CREST_LOW, -d) : mix(CREST_MID, CREST_HIGH, d);
}

// ─────────────────────────────────────────────────────────────────────────────
// Geometry at any scale
// ─────────────────────────────────────────────────────────────────────────────

/// The lanes at a vertical scale. Each lane edge is rounded on its own, so
/// lanes never overlap or leave uneven gaps. At scale 1 everything equals the
/// constants above.
struct TimelineGeometry
{
pure nothrow @nogc:

    float scale = 1;
    int   height = TIMELINE_HEIGHT;
    Lane  print    = LANE_PRINT,    gradeA   = LANE_GRADE_A,
          balance  = LANE_BALANCE,  channels = LANE_CHANNELS,
          spectrum = LANE_SPECTRUM,
          dynamics = LANE_DYNAMICS, flux     = LANE_FLUX,
          width    = LANE_WIDTH,    live     = LANE_LIVE;

    static TimelineGeometry atScale(float s)
    {
        static Lane scaled(Lane l, float s)
        {
            immutable int top    = cast(int) round(l.top * s);
            immutable int bottom = cast(int) round(l.bottom * s);
            return Lane(top, bottom - top);
        }
        TimelineGeometry g;     // every lane starts at its scale-1 constant
        g.scale  = s;
        g.height = cast(int) round(TIMELINE_HEIGHT * s);
        foreach (ref field; g.tupleof)
            static if (is(typeof(field) == Lane))
                field = scaled(field, s);
        return g;
    }

    /// Thickness of a mark drawn `px` thick at scale 1, never under 1 pixel.
    float thick(float px) const { return max(1.0f, px * scale); }

    float pitchToY(float st) const
    {
        immutable float t = clamp01((st - PITCH_LO_ST) / (PITCH_HI_ST - PITCH_LO_ST));
        return spectrum.top + spectrum.height * (1.0f - t);
    }

    /// Where a channel value sits in the channels lane, clamped to it.
    float channelY(float v) const
    {
        return channels.bottom - channels.height * clamp01((v - CHANNEL_LO) / (CHANNEL_HI - CHANNEL_LO));
    }

    float crestY(float db) const
    {
        return dynamics.bottom - dynamics.height * clamp01(db / CREST_MAX_DB);
    }

    float liveY(float frac) const
    {
        return live.bottom - live.height * clamp01(frac);
    }

    /// Pixel rows for each band, split halfway (in semitones) between
    /// neighbouring centres. The outer rows run to the bank's own edges, the
    /// same BAND_LO_HZ and capped BAND_HI_HZ that BandBank.initialize() places
    /// its skirts at: the bottom band's wide low-Q response really does reach
    /// down to 30 Hz.
    void bandRows(ref const float[NBANDS] centresHz, float sr,
                  out int[NBANDS] top, out int[NBANDS] bottom) const
    {
        float[NBANDS] st;
        foreach (b; 0 .. NBANDS) st[b] = hzToSemitones(centresHz[b]);
        immutable float edgeHi = BAND_HI_HZ < 0.45f * sr ? BAND_HI_HZ : 0.45f * sr;
        foreach (b; 0 .. NBANDS)
        {
            immutable float lo = b == 0 ? hzToSemitones(BAND_LO_HZ)
                                        : 0.5f * (st[b - 1] + st[b]);
            immutable float hi = b == NBANDS - 1 ? hzToSemitones(edgeHi)
                                                 : 0.5f * (st[b] + st[b + 1]);
            top[b]    = cast(int) round(pitchToY(hi));
            bottom[b] = cast(int) round(pitchToY(lo));
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawing
// ─────────────────────────────────────────────────────────────────────────────

/// Opaque vertical run from y0 up to but excluding y1, written straight into
/// the bitmap.
void putColumn(ref Image img, int x, int y0, int y1, Rgba c)
{
    foreach (y; max(0, y0) .. min(img.height, y1))
    {
        auto p = cast(ubyte*) img.scanptr(y) + 4 * x;
        p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = c.a;
    }
}

/// Blends colour `c`, with its alpha, over the one-pixel-wide rectangle from
/// y to y + h in column `x`, antialiased at its fractional ends.
///
/// This is what Canvasity's fillRect(x, y, 1, h) gives, pixel for pixel, at a
/// small part of the cost: Canvasity walks its clip mask, two runs for every
/// row of the image, on each fill, and a column takes about 23 of them. So
/// the steps are Canvasity 1.0.7's, in its order and precision: the coverage
/// of each row by the rectangle's edges, then its blend in its default pow2
/// gamma (colours squared in, square-rooted out), premultiplied source-over,
/// with 8-bit conversion as in gamut and colors. The tests check the two
/// agree exactly.
void blendColumn(ref Image img, int x, float y, float h, Rgba c)
{
    enum float threshold = 1.0f / 8160.0f;   // Canvasity's least coverage and alpha

    if (h == 0) return;
    immutable float fh = img.height;
    float ya = y, yb = y + h;
    if (yb < ya) { immutable float t = ya; ya = yb; yb = t; }
    ya = ya < 0.0f ? 0.0f : (ya > fh ? fh : ya);
    yb = yb < 0.0f ? 0.0f : (yb > fh ? fh : yb);
    if (yb - ya < 2.0e-5f) return;          // Canvasity drops shorter edges

    // The brush: linearised, premultiplied.
    float fr = c.r / 255.0f, fg = c.g / 255.0f, fb = c.b / 255.0f;
    immutable float fa = c.a / 255.0f;
    fr = fr * fr; fg = fg * fg; fb = fb * fb;
    fr = fr * fa; fg = fg * fa; fb = fb * fa;

    immutable int r0 = cast(int) floor(ya), r1 = cast(int) floor(yb);
    foreach (row; r0 .. min(r1 + 1, img.height))
    {
        // Partial first and last rows, whole rows between: exact in float.
        immutable float cover = r0 == r1   ? yb - ya
                              : row == r0  ? (r0 + 1.0f) - ya
                              : row == r1  ? yb - r1
                              :              1.0f;
        if (!(cover >= threshold)) continue;

        auto p = cast(ubyte*) img.scanptr(row) + 4 * x;
        float br = p[0] / 255.0f, bg = p[1] / 255.0f, bb = p[2] / 255.0f;
        immutable float ba = p[3] / 255.0f;
        br = br * br; bg = bg * bg; bb = bb * bb;
        br = br * ba; bg = bg * ba; bb = bb * ba;

        immutable float sa = cover * fa, keep = 1.0f - sa;
        float r = cover * fr + keep * br;
        float g = cover * fg + keep * bg;
        float b = cover * fb + keep * bb;
        float a = sa + keep * ba;
        a = a < 1.0f ? a : 1.0f;
        if (a < threshold)
            r = g = b = a = 0.0f;
        else
        {
            immutable float inv = 1.0f / a;
            r = sqrt(inv * r); g = sqrt(inv * g); b = sqrt(inv * b);
        }
        p[0] = cast(ubyte)(0.5f + r * 255.0f);
        p[1] = cast(ubyte)(0.5f + g * 255.0f);
        p[2] = cast(ubyte)(0.5f + b * 255.0f);
        p[3] = cast(ubyte)(0.5f + a * 255.0f);
    }
}

/// A mark `t` thick centred on `y` in column `x`.
void stroke(ref Image img, int x, float y, float t, Rgba c)
{
    blendColumn(img, x, y - t * 0.5f, t, c);
}

/// A mark from `yTop` down to `yBottom` in column `x`.
void span(ref Image img, int x, float yTop, float yBottom, Rgba c)
{
    blendColumn(img, x, yTop, yBottom - yTop, c);
}

/// Which frames the A lane underscores: all of every A_WINDOW_FRAMES run of
/// frames whose window score is an A (PrintFrame.windowIsA). The frame that
/// ends such a run is the first to know, so it marks the run back to its
/// start, up to A_WINDOW_S seconds into the past. Marks are only ever added.
struct Underscore
{
pure nothrow @nogc:

    void reset() { markedTo = -1; }

    /// Frame `n` of the stream (0, 1, 2, ... in turn) came with print `fp`.
    /// Returns the first frame this newly underscores: frames from there to
    /// `n` are to be marked. Returns n + 1 when it marks none.
    long push(long n, ref const PrintFrame fp)
    {
        if (!fp.windowIsA())
            return n + 1;
        long from = n - A_WINDOW_FRAMES + 1;
        if (from <= markedTo)
            from = markedTo + 1;
        markedTo = n;
        return from;
    }

private:
    long markedTo = -1;     // frames up to here are marked already
}

/// How audible a frame is, 0 (silent: nothing drawn) to 1 (full strength).
float audibility(ref const FrameFeatures f)
{
    return clamp01((cast(float)(10.0 * log10(bandEnergy(f))) - SILENT_DB)
                   / (AUDIBLE_DB - SILENT_DB));
}

struct TimelineRenderer
{
pure nothrow @nogc:

    /// For the frames described by `info`, at vertical `scale`.
    void initialize(ref const StreamInfo info, float scale)
    {
        geo      = TimelineGeometry.atScale(scale);
        hopSec   = cast(double) info.hopLen / info.sampleRate;
        binCount = info.binCount;
        geo.bandRows(info.bandCentres, info.sampleRate, rowTop, rowBottom);
    }

    ref const(TimelineGeometry) geometry() const return { return geo; }

    /// Draws frame `p` as pixel column `x` of `image`, which must be
    /// geometry.height rows tall. `wMax` is the heaviest weight the
    /// balance-lane heights are relative to; `underscored` whether the A lane
    /// is marked under this frame.
    void drawColumn(ref Image image, int x,
                    ref const FramePacket p, float wMax, bool underscored)
    {
        const f  = &p.f;
        const fp = &p.print;
        immutable float conf   = audibility(*f);
        immutable bool  silent = conf == 0.0f;

        // Pass 1, straight into the bitmap: backgrounds, time grid, and the
        // lanes that are one flat colour per pixel.

        // A faint line at every second, a darker one every ten. It shows in
        // the gaps between lanes and behind the plotted ones.
        immutable long sec  = cast(long)(f.frameIndex * hopSec);
        immutable long prev = cast(long)((f.frameIndex - 1) * hopSec);
        immutable Rgba bg = sec == prev ? SURFACE : (sec % 10 == 0 ? BASELINE : GRID);
        putColumn(image, x, 0, geo.height, bg);

        if (silent)
        {
            const Lane[4] greyed = [geo.spectrum, geo.dynamics, geo.flux, geo.live];
            foreach (lane; greyed)
                putColumn(image, x, lane.top, lane.bottom, SILENCE);
        }

        putColumn(image, x, geo.print.top, geo.print.bottom, fp.silent ? SILENCE : fp.colour);
        if (underscored)
            markUnderscore(image, x);

        fillBalance(image, x, *fp, wMax);
        fillChannels(image, x, *fp);

        if (!silent)
        {
            putColumn(image, x, geo.spectrum.top, geo.spectrum.bottom, SURFACE);
            foreach (b; 0 .. NBANDS)
            {
                immutable float t = (f.bandLevelDb[b] - LEVEL_LO_DB) / (LEVEL_HI_DB - LEVEL_LO_DB);
                putColumn(image, x, rowTop[b], rowBottom[b],
                          mix(SURFACE, crestColour(f.bandCrestDb[b]), t));
            }
        }

        putColumn(image, x, geo.width.top, geo.width.bottom,
                  mix(SILENCE, WIDTH_INK, f.stereoWidth / WIDTH_MAX));

        // Pass 2, blended over pass 1 with antialiased ends: reference
        // lines, then the marks.

        static immutable float[3] pitchLinesHz = [100.0f, 1_000.0f, 10_000.0f];
        static immutable float[3] crestLinesDb = [CREST_MID_DB - CREST_SPAN_DB, CREST_MID_DB,
                                                  CREST_MID_DB + CREST_SPAN_DB];
        static immutable float[2] liveLines    = [LIVE_LOW, LIVE_PINNED];
        foreach (hz; pitchLinesHz)
            stroke(image, x, geo.pitchToY(hzToSemitones(hz)), 1, alpha(INK, 0.15f));
        foreach (db; crestLinesDb)
            stroke(image, x, geo.crestY(db), 1, GRID);
        foreach (frac; liveLines)
            stroke(image, x, geo.liveY(frac), 1, GRID);
        {
            const Lane[3] based = [geo.dynamics, geo.flux, geo.live];
            foreach (lane; based)
                blendColumn(image, x, lane.bottom - 1, 1, BASELINE);
        }

        strokeBalance(image, x, *fp);
        strokeChannels(image, x, *fp);

        if (silent) return;
        immutable float c = conf;

        // Spectrum overlay: the occupied span's edges, then the centroid in
        // the fingerprint's green, bright with a dark edge so it reads over
        // any cell colour. The span is deliberately not shaded: f_high jumps
        // from frame to frame, and a narrow span (a tone) would cover the
        // very cell that holds the energy.
        {
            immutable float yHigh = geo.pitchToY(f.fHighSemitones);
            immutable float yLow  = geo.pitchToY(f.fLowSemitones);
            immutable float yCen  = geo.pitchToY(f.centroidSemitones);
            immutable float edge = geo.thick(1.5f), outline = geo.thick(4.0f), core = geo.thick(2.0f);
            stroke(image, x, yHigh, edge,    alpha(INK, 0.5f * c));
            stroke(image, x, yLow,  edge,    alpha(INK, 0.5f * c));
            stroke(image, x, yCen,  outline, alpha(CENTROID_EDGE, c));
            stroke(image, x, yCen,  core,    alpha(CENTROID_INK, c));
        }

        // Dynamics: band-crest spread, in the fingerprint's blue, behind the
        // full-band dot.
        {
            float[NBANDS] cr = f.bandCrestDb;
            sort(cr[]);
            span(image, x, geo.crestY(cr[$ - 1]), geo.crestY(cr[0]),
                 alpha(SPREAD_INK, 0.12f * c));
            span(image, x, geo.crestY(cr[3 * NBANDS / 4]), geo.crestY(cr[NBANDS / 4]),
                 alpha(SPREAD_INK, 0.28f * c));
            stroke(image, x, geo.crestY(f.fullCrestDb), geo.thick(2.0f),
                   alpha(crestColour(f.fullCrestDb), c));
        }

        // Flux: taller spikes are also more opaque, so onsets stand out.
        {
            immutable float tf = clamp01(f.flux / FLUX_MAX);
            span(image, x, geo.flux.bottom - geo.flux.height * tf, geo.flux.bottom,
                 alpha(FLUX_INK, (0.3f + 0.7f * tf) * c));
        }

        // Live bins.
        {
            immutable float lf = cast(float) f.liveBins / binCount;
            immutable Rgba lc = lf >= LIVE_PINNED ? CRITICAL
                              : lf <  LIVE_LOW    ? SERIOUS : MUTED;
            stroke(image, x, geo.liveY(lf), geo.thick(2.0f), alpha(lc, c));
        }
    }

    /// Marks the A lane under column `x`, which is drawn already. Nothing
    /// else draws into the A lane's rows, so this gives the same pixels as
    /// drawing the column with `underscored` set.
    void markUnderscore(ref Image image, int x)
    {
        putColumn(image, x, geo.gradeA.top, geo.gradeA.bottom, GRADE_A);
    }

private:
    /// The balance lane's rows: the frame's weight as a column in the
    /// fingerprint's colour, over a darker background.
    void fillBalance(ref Image image, int x, ref const PrintFrame fp, float wMax)
    {
        if (fp.silent || wMax <= 0)
            putColumn(image, x, geo.balance.top, geo.balance.bottom, SILENCE);
        else
        {
            immutable int h = cast(int) round(fp.weight / wMax * geo.balance.height);
            putColumn(image, x, geo.balance.top, geo.balance.bottom - h, BALANCE_BG);
            putColumn(image, x, geo.balance.bottom - h, geo.balance.bottom, fp.colour);
        }
    }

    /// The balance lane's lines: its frame and the running match score.
    void strokeBalance(ref Image image, int x, ref const PrintFrame fp)
    {
        // Frame the balance lane just outside its rows: a fully balanced stretch
        // fills with white and would otherwise vanish into the page.
        blendColumn(image, x, geo.balance.top - 1, 1, BASELINE);
        blendColumn(image, x, geo.balance.bottom, 1, BASELINE);

        // Running match score, drawn through silence too: it holds its value.
        immutable float yScore = geo.balance.bottom
                               - geo.balance.height * cast(float)(fp.score / SCORE_SCALE);
        stroke(image, x, yScore, geo.thick(2.0f), scoreGrade(fp.score) == 'A' ? GRADE_A_INK : INK);
    }

    /// The channels lane's rows: the 0..1 band over the surface, or the
    /// silence grey when the fingerprint is silent.
    void fillChannels(ref Image image, int x, ref const PrintFrame fp)
    {
        if (fp.silent)
        {
            putColumn(image, x, geo.channels.top, geo.channels.bottom, SILENCE);
            return;
        }
        immutable int y1 = cast(int) round(geo.channelY(1)), y0 = cast(int) round(geo.channelY(0));
        putColumn(image, x, geo.channels.top, y1, SURFACE);
        putColumn(image, x, y1, y0, CHANNEL_BAND);
        putColumn(image, x, y0, geo.channels.bottom, SURFACE);
    }

    /// The channels lane's lines: its baseline and the three channels as
    /// plain lines, green last. The centroid's bright green without its dark
    /// edge, which cluttered the lane: bright, it still stays apart from red
    /// for red-green colour blindness.
    void strokeChannels(ref Image image, int x, ref const PrintFrame fp)
    {
        blendColumn(image, x, geo.channels.bottom - 1, 1, BASELINE);
        if (fp.silent) return;

        void line(float v, float thickness, Rgba c)
        {
            // Past the scale: pinned inside the edge, twice as thick.
            immutable bool off = v < CHANNEL_LO || v > CHANNEL_HI;
            immutable float t = off ? 2 * thickness : thickness;
            float y = geo.channelY(v) - t * 0.5f;
            if (y < geo.channels.top) y = geo.channels.top;
            if (y + t > geo.channels.bottom) y = geo.channels.bottom - t;
            blendColumn(image, x, y, t, c);
        }
        immutable float core = geo.thick(2.0f);
        line(fp.blue,  core, SPREAD_INK);
        line(fp.red,   core, FLUX_INK);
        line(fp.green, core, CENTROID_INK);
    }

    TimelineGeometry geo;
    int[NBANDS]      rowTop, rowBottom;
    double           hopSec = 0;
    int              binCount = 1;
}
