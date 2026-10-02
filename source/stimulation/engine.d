/// StimEngine: audio in, frames with their fingerprint and score out.
///
/// The one path from samples to results for both front-ends: stim-offline
/// feeds it a decoded file, the plugin feeds it host blocks of any size.
/// Neither does any analysis of its own, so they cannot drift apart.
module stimulation.engine;

import dplug.core.fpcontrol : FPControl;

import stimulation.analyser;
import stimulation.fingerprint;

nothrow @nogc:

enum int WARMUP_FRAMES = 5;   // ~100 ms: filter settling, discarded

/// One analysis frame (20 ms apart, 40 ms long) and what the fingerprint
/// made of it.
struct FramePacket
{
    FrameFeatures f;
    PrintFrame    print;
    /// The heaviest print.weight since the last reset, this frame included:
    /// what the balance lane's column heights are relative to. At the end of
    /// a track it is the value stim-offline scales the whole PNG by.
    float         maxWeight = 0;
}

/// What a consumer needs to know about the frames of one stream. Fixed from
/// initialize() to the next initialize().
struct StreamInfo
{
    float sampleRate = 0;
    int   hopLen;                  // samples per frame step (20 ms)
    int   binCount;                // what FrameFeatures.liveBins is counted out of
    float[NBANDS] bandCentres = 0; // Hz
}

struct StimEngine
{
nothrow @nogc:

    /// Allocates, so not on the audio thread. May be called again, for a new
    /// sample rate: the earlier setup is freed first. `smoothFrames` is the
    /// fingerprint's smoothing (LiveFingerprint.smoothFrames); the plugin
    /// leaves it at the default.
    void initialize(float sampleRate, int smoothFrames = PRINT_SMOOTH_FRAMES)
    {
        assert(smoothFrames >= 1);
        analyser.initialize(sampleRate);
        print.smoothFrames   = smoothFrames;
        _info.sampleRate     = sampleRate;
        _info.hopLen         = analyser.hopLength();
        _info.binCount       = analyser.binCount();
        _info.bandCentres[]  = analyser.bandCentres()[];
        reset();
    }

    void destroy() { analyser.destroy(); }

    /// Starts a new measurement: filters, fingerprint and score from scratch,
    /// the first WARMUP_FRAMES frames dropped again.
    void reset() pure
    {
        analyser.reset();
        print.reset();
        emitted = 0;
        maxWeight = 0;
    }

    ref const(StreamInfo) info() const pure return { return _info; }

    /// The most frames that `n` samples can complete: one per hop, plus one
    /// for a hop already under way.
    int maxFrames(int n) const pure { return n / _info.hopLen + 1; }

    /// Runs `n` samples through the analysis. The frames they complete are
    /// written to `output`, which needs room for maxFrames(n); returns how many.
    /// Mono: pass the same pointer for both channels.
    int process(const(float)* left, const(float)* right, int n, FramePacket[] output)
    {
        // Denormals flush to zero (and read as zero) for the whole analysis,
        // whoever calls. The plugin's format wrappers set this around the audio
        // callback anyway, but stim-offline and the test tools have no wrapper,
        // and both front-ends must compute alike. FPControl restores the
        // caller's mode on return; it works on x86 and, through
        // intel-intrinsics, on arm64.
        FPControl fpControl;
        fpControl.initialize();

        assert(output.length >= maxFrames(n));
        int count = 0;
        FrameFeatures f;
        foreach (i; 0 .. n)
        {
            if (!analyser.processSample(left[i], right[i], f))
                continue;
            if (emitted++ < WARMUP_FRAMES)
                continue;
            output[count].f     = f;
            output[count].print = print.push(f);
            if (output[count].print.weight > maxWeight)
                maxWeight = output[count].print.weight;
            output[count].maxWeight = maxWeight;
            ++count;
        }
        return count;
    }

private:
    Analyser        analyser;
    LiveFingerprint print;
    StreamInfo      _info;
    long            emitted;   // frames since reset, warm-up included
    float           maxWeight = 0;
}
