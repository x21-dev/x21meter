/// An ID for the core sources a binary was built from.
///
/// stim-offline prints it (--version) and the plugin shows it, so two builds
/// with the same ID are known to analyse, score and draw alike. It is a hash
/// of the core files themselves: any edit to them changes it, comments
/// included. Carriage returns are skipped, so a Windows checkout (CRLF) and a
/// macOS or Linux one (LF) give the same ID.
module stimulation.buildid;

version (StimUseOwnFFT) private enum string FFT = "own-fft";
else                    private enum string FFT = "dplug-fft";

/// Eight hex digits. Every core module belongs in this list.
enum string CORE_BUILD_ID = fnv1aHex(import("analyser.d") ~ "\0"
                                     ~ import("fingerprint.d") ~ "\0"
                                     ~ import("engine.d") ~ "\0"
                                     ~ import("timeline.d") ~ "\0"
                                     ~ FFT);

/// 32-bit FNV-1a of `s` without its carriage returns, as hex.
string fnv1aHex(string s) pure nothrow
{
    uint h = 2_166_136_261u;
    foreach (char c; s)
    {
        if (c == '\r') continue;
        h ^= cast(ubyte) c;
        h *= 16_777_619u;
    }
    enum string digits = "0123456789abcdef";
    char[8] hex;
    foreach_reverse (i; 0 .. 8)
    {
        hex[i] = digits[h & 15];
        h >>= 4;
    }
    return hex.idup;
}
