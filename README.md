# stim-offline and stim-batch

Command-line tools for extracting features from music:

- **stim-offline** analyses one audio file. It writes a CSV of features (one row per 20 ms frame) and a PNG that shows how those features change over time, and gives the track a match score.
- **stim-batch** runs stim-offline over many files or whole folders, in parallel, and keeps a manifest of the results. On Windows you can drag files onto it or use it from the Send To menu.

stim-batch contains no analysis code. It only starts stim-offline once per file, so both tools always produce the same results.

This repository holds the complete source the released binaries are built from, so you can read it, build it yourself, and check that a release matches. It is provided as is, without support, and doesn't take contributions.

---

## Download

Every release on the [Releases page](../../releases) has one archive per platform: `stim-<version>-windows-x86_64.zip`, `stim-<version>-macos-arm64.tar.gz` and `stim-<version>-linux-x86_64.tar.gz`. Each holds stim-offline, stim-batch, this file, the licence and `build-id.txt`. GitHub Actions builds them from this repository's source at the release's tag; the workflow is `.github/workflows/release.yml`, and each run's log is public.

The binaries aren't code-signed. macOS quarantines downloaded programs; `xattr -dr com.apple.quarantine <folder>` clears that. On Windows, SmartScreen asks first: *More info*, then *Run anyway*.

Keep stim-offline and stim-batch in the same folder: stim-batch looks for stim-offline next to itself.

## Building

You need [LDC](https://github.com/ldc-developers/ldc/releases) 1.42.0, the D compiler the releases are built with. It comes with dub, D's build tool. From the repository's root:

```
dub build --config=offline --build=release --compiler=ldc2
dub build --config=batch   --build=release --compiler=ldc2
```

The executables end up in the repository's root: `stim-offline.exe` and `stim-batch.exe` on Windows, `stim-offline` and `stim-batch` on macOS and Linux. The first build downloads the libraries the tools use (dplug, audio-formats, gamut, canvasity) from the dub registry, at the versions pinned in `dub.selections.json`.

`dub test --compiler=ldc2` runs the unit tests.

### Checking a release

`stim-offline --version` prints the build ID: a hash of the analysis sources. A release's `build-id.txt` holds the ID its stim-offline prints. When your own build prints the same ID, it was built from the same analysis code as the release. The executables themselves needn't be byte-for-byte identical, and builds for different processors can differ in the last digits of some values.

---

## stim-offline

```
stim-offline [options] <audio file>
stim-offline --test
```

| Option | Meaning |
|---|---|
| `--csv PATH` | CSV output path. Default: `<input name>.csv` in the working directory |
| `--png PATH` | PNG output path. Default: `<input name>.png` in the working directory |
| `--no-png` | Write the CSV only |
| `--smooth-frames N` | The fingerprint's smoothing in 20 ms frames. Default 80 (1.6 s), which the plugin always uses. It changes the fingerprint, balance, match score, window score and A lane, not the features |
| `--quiet` | Print no progress lines, only a one-line summary at the end (see below) |
| `--test` | Run the synthetic-signal sanity checks instead of analysing a file |
| `--seed N` | Seed for the noise signals in `--test`. Default 1, so every run writes the same files |
| `--version` | Print the core build ID: a hash of the analysis sources. The plugin shows the same ID, and equal IDs mean equal analysis, score and picture |
| `-h`, `--help` | Show the options |

Examples:

```
stim-offline "D:\Music\track.flac"
stim-offline --csv out\track.csv --png out\track.png "D:\Music\track.flac"
stim-offline --no-png "D:\Music\track.mp3"
```

### Input

- **Formats:** anything the audio-formats library decodes: WAV, FLAC, MP3, OGG Vorbis and Opus. QOA, MOD and XM should also work but haven't been tested.
- **Lossy files can mislead.** MP3, AAC, Ogg Vorbis and Opus throw away what their model of hearing says you won't miss. They cut the top end (a 128 kbps MP3 near 16 kHz), leave quantisation noise where quiet detail was, and smear sharp attacks. Those are exactly what the features measure: band levels and crests, the spectral edges, flux and live bins. So the fingerprint and the match score of a lossy file can differ from the same track's lossless master, and lossless copies have scored higher in practice. Use lossless files (WAV, FLAC) when the score matters, and compare lossy with lossy, lossless with lossless. Higher bitrates distort less, but no bitrate makes a lossy copy equivalent. The same goes for the plugin, which measures whatever the player sends it, a lossy stream included.
- **Sample rate:** any rate from 44.1 kHz up. Frames are **40 ms at every sample rate** (1764 samples at 44.1 kHz, 1920 at 48 kHz, 3840 at 96 kHz), and the spectral features look only at **30 Hz–16 kHz**, so files at different rates give comparable features. Nothing is resampled. Below 35.6 kHz the analysis has to stop short of 16 kHz, and a warning goes to stderr. One small difference remains: lower rates catch fewer peaks that fall between samples, so crest can read a little lower at 44.1 kHz than at 96 kHz.
- **Channels:** mono is copied to both sides, so `stereo_width` reads 0. Files with more than two channels are analysed using only the first two (front left and right in 5.1/7.1), with a warning.
- **Paths:** file names with non-ASCII characters (Cyrillic, accents and so on) work for both input and output.

### Output and exit codes

- The exit code is `0` on success and `1` on any error. The error is one line on stderr, starting with `error:`.
- Warnings (such as the sample rate) go to stderr; progress lines go to stdout.
- With `--quiet`, stdout has exactly one line, printed on success:

  ```
  sample_rate=44100 channels=2 duration_s=213.193 frames=10652 score=25.626 grade=C green_score=b blue_score=D red_score=g
  ```

  stim-batch reads this line into its manifest.
- Without `--quiet`, the last two lines are the match score and grade, and the [channel scores](#channel-scores) in the order green, blue, red.

### Test mode

`stim-offline --test` generates six synthetic signals and prints what each feature should read for them. It writes `test_<name>.csv` and `test_<name>.png` to the working directory. The noise signals use a fixed seed (`--seed`), so the outputs are the same on every run. The PNGs are a useful visual check:

| Signal | What to look for |
|---|---|
| sweep 20 Hz to 20 kHz | the centroid traces one clean curve through the spectrum |
| white noise | full-band crest about 10–12 dB; live bins at the top |
| 97 Hz square | crest about 10 dB (measured after K-weighting, as explained in the printout) |
| decorrelated noise | stereo width about 0.5; the width strip goes fully aqua |
| steady 997 Hz tone | flux close to zero |
| 1 kHz tone bursts | one flux spike per burst; the count matches the expected number |

---

## CSV columns

One row per analysis frame. A frame is 40 ms long and frames start every 20 ms, at any sample rate. The first five frames are dropped while the filters settle, so the first row is `frame` 6.

| Column | Meaning |
|---|---|
| `frame` | frame index |
| `time_s` | start of the frame's 40 ms window, in seconds |
| `level_<Hz>_dB` ×24 | RMS level of each mel band, named by its centre frequency (127 Hz to about 14 kHz) |
| `crest_<Hz>_dB` ×24 | peak-to-RMS ratio of each band. Low = sustained or compressed, high = transient |
| `full_crest_dB` | peak-to-RMS ratio of the whole signal |
| `f_low_st`, `f_high_st` | frequencies below which 5% and 95% of the spectral energy between 30 Hz and 16 kHz lies |
| `centroid_st` | energy-weighted mean frequency (how bright or dark the sound is) |
| `flux` | how much the spectrum grew since the previous frame (only increases are counted). **Not normalised: it scales with loudness** |
| `stereo_width` | side energy / (mid + side energy). 0 = mono, 0.5 = uncorrelated, above 0.5 = mostly out of phase |
| `live_bins` | number of FFT bins between 30 Hz and 16 kHz within 60 dB of the loudest bin in that range. The total depends on the sample rate: 742 at 44.1 kHz, 681 at 48 kHz |
| `red`, `green`, `blue` | the fingerprint's three channels, **unclamped**: 0 and 1 are the ends of each channel's range, as in the fingerprint, but values run below 0 and above 1. `nan` in silent frames. See [Channels](#channels) |
| `balance` | fingerprint balance, 0 (one quality dominates) to 1 (all three equal); `nan` in silent frames. See [Match score](#match-score) |
| `balance_weight` | the frame's weight in the match score (peak amplitude^0.5); 0 in silent frames |
| `match_score` | running match score from the start of the track up to this frame, 0–28 |
| `window_score` | the score of the last 3 s alone (the A lane's test: every frame counts equally, no prior), 0–28; 27 or more underlines those 3 s in the PNG. Empty (`nan`) for the first 3 s |
| `grades` | four letters so far: the running match score's grade, then the green, blue and red [channel scores](#channel-scores), e.g. `Agbr`. `-` for a channel with nothing counted yet |

The last eight columns, from `red` on, are derived from the fingerprint rather than measured by the analyser. They come after the analyser's columns, so those keep their positions.

Everything is measured on the K-weighted mid signal, (L+R)/2. K-weighting is the loudness filter from the BS.1770 standard. The `_st` columns are **semitones relative to A 440 Hz**: 0 = 440 Hz, +12 = 880 Hz, −12 = 220 Hz. A silent frame reads −120. The spectral features (`f_low_st`, `f_high_st`, `centroid_st`, `flux`, `live_bins`) only use 30 Hz–16 kHz, the same range as the 24 bands. Above 16 kHz, lossy encoders decide what's left (a 128 kbps MP3 cuts off near 16 kHz), and most adults hear little of it. `f_low_st` can still dip slightly below 30 Hz (to about −52 semitones, 22 Hz), because the frequency estimate for the lowest bins can land a little under their nominal frequency.

---

## The PNG

Time runs left to right with **one pixel column per frame** (20 ms), so a 3-minute track is about 9000 px wide. The image is 928 px tall. A light vertical line marks every second and a darker one every 10 seconds.

All scales are fixed rather than fitted to each track, so images of different tracks can be compared directly, just like the CSV rows.

| Rows (px) | Lane | How to read it |
|---|---|---|
| 0–24 | **Fingerprint** | One colour per column, smoothed (see below). White = balanced; the tint shows which quality prevails |
| 26–30 | **A lane** | Yellow under every 3 seconds of fingerprint that on their own score an A |
| 32–96 | **Balance** | Columns whose height is each frame's weight in the score and whose colour is the fingerprint's (lighter = more balanced), with the running match score as a line: dark, gold while it is at grade A |
| 104–184 | **Channels** | The fingerprint's red, green and blue unclamped, as lines over a band marking their 0–1 range |
| 192–512 | **Spectrum** | The 24 bands, low at the bottom and high at the top, plus the centroid line |
| 520–700 | **Dynamics** | Crest factor: dots for the full signal, shading for the spread across bands |
| 708–848 | **Flux** | Onset spikes |
| 856–880 | **Stereo width** | Grey = mono, aqua = wide |
| 888–920 | **Live bins** | Diagnostic for tuning `FLOOR_DB` |

### Fingerprint

Three smoothed features are mixed as red, green and blue:

| Channel | Feature | Typical range (mapped to 0–1) |
|---|---|---|
| red | flux divided by the frame's amplitude (how busy the spectrum is, regardless of loudness) | 0.31–0.78 |
| green | how much the centroid moves (its standard deviation, in semitones), **mapped on a log scale** | 3.0–12 |
| blue | how far apart the 24 band crests are: their standard deviation within the frame, each band weighted by its share of the energy | 0.89–1.95 dB |

The red and blue ranges are the 10th–90th percentiles over 72 tracks from 24 sources across dance, pop, 90s, chill, acoustic, piano and classical, soundtrack and rock.

Green works differently. Its percentile range (3.5–14.8) left it at an average of 0.53 on a set of 24 commercial hits, well below red and blue: piano and classical pin the bottom of those two ranges, so hits sit near their top, but not near green's. Centroid spread is also skewed, with a long upper tail in dance. So green uses a log scale over 3–12 semitones, which brings it to about 0.74 on the hits, level with red and blue. This raises hits and dense mixes, and lowers sparse material, whose channels would otherwise all sit at the floor and read as balanced.

**Why blue uses the spread across bands:** in a mix with depth and separation, different bands are dominated by different sources (sustained bass and pads beside sharp drums and hi-hats), so their crest factors spread apart. A single instrument keeps them close. Limiting squeezes the full-band crest but not this spread, so polished commercial masters aren't penalised for being mastered. On the 72 tracks, this cut the yellow cast (blue as the weakest channel) in dance and pop from 36–46% of frames to 10–17%.

Each channel is mapped onto its range and 0.1 is added to all three. They're then divided by the largest and raised to the power 0.618, so the strongest is always at full brightness and the weaker ones are lifted toward it (pastel mixes):

- **white or pastel:** all three are about equally active;
- **red:** busy note or onset activity (fast piano passages, for example);
- **green:** the tone colour is shifting (typical in fade-outs and transitions);
- **blue:** separated sources with different transient character (a full band mix, for example);
- **mixes:** pink = red + blue, cyan = green + blue, yellow = red + green;
- **grey:** silence.

What to change when one hue prevails is in [Using the hues](#using-the-hues).

Smoothing uses `PRINT_SMOOTH_FRAMES` frames, currently 80 (1.6 s; it was 50 until 2026-09-25); stim-offline and stim-batch can override it with `--smooth-frames`. It runs **forwards only**, as a live meter would, so each frame depends only on what came before it. As a result, colour changes trail the lanes below by roughly the smoothing time.

### Match score

This works like OfflineMeter's `allMatch`, applied to the fingerprint:

1. **Balance per frame:** `min(R,G,B) / max(R,G,B)` of the fingerprint channels, raised to `SCORE_GAMMA`. It's rescaled so 0 means one channel is at the top of its range and another at the floor, and 1 means all three are equal. `SCORE_GAMMA` is set to the same value as `PRINT_GAMMA` (0.618), so a whiter fingerprint strip means a higher balance. It's a separate constant, so the picture and the score can be tuned independently.
2. **Weight per frame:** peak amplitude^0.5, the equivalent of OfflineMeter's `sqrt(max peak/slew)`. Silent frames get weight 0.
3. **Running score:** each frame's balance is shaped by `1 − (1 − b)^1.618` and accumulated as a weighted running mean from the start of the track. The mean is shaped again the same way and scaled to 0–28. The value at the last frame is the track's score.
4. **Balanced prior:** every track is scored as if it began with `SCORE_PRIOR_S` (15 s) of perfectly balanced music, weighted at the track's own average weight so far. The running score starts at the top, and a short quiet or sparse intro only dents it, as in OfflineMeter, whose accumulators started out balanced. The prior stays in the final score as 15 s ÷ track length of perfect balance, which adds about 0.3–0.9 points to a typical 3–4 minute song, more to short or unbalanced ones.
5. **Grade:** 27 and above = **A**, 26 = B, … 2 = Z, and below 2 = `-` (OfflineMeter's `packageGrade`).

The score is **independent of gain**: every weight is a power of amplitude, so a uniform gain change cancels out of the mean. A test with the same track at 0, −3 and −10 dB gave the same final score to within 0.001. The only thing that isn't independent is the −70 dB silence gate: frames it excludes at a lower gain can shift the early running score slightly, and the final score doesn't change.

Weighting means quiet passages hardly count. Balance measures proportion, not activity, though: a steady sine has all three channels at the floor, so they're equal and it scores A.

The score is printed at the end of stim-offline's output (`match score 25.63, grade C`), included in the `--quiet` summary line, and recorded by stim-batch in the manifest's `score` and `grade` columns.

### Balance lane and A lane

The three top lanes read at three time scales. The fingerprint shows balance moment by moment, the A lane marks short stretches of good balance, and the balance lane's score line integrates over the whole measurement, weighted by level.

- **Filled column:** its **height** is the frame's weight in the match score relative to the heaviest frame in the track, so taller columns count more towards the score. With weights of peak^0.5, a passage 20 dB below the loudest is drawn at about a third of full height. The **fill** is the fingerprint's own colour: the lighter it is, the more balanced the frame, and its hue shows what dominates. The height is a ratio, so it doesn't change with gain. A fully grey column (the lighter silence grey) is silence.
- **Score line:** the running match score, from 0 at the bottom to 28 at the top. It is **gold** while the score is at grade A (27 or more) and dark below that. Released music scores high, so the line usually sits near the top.
- **A lane**, the yellow line between the fingerprint strip and the balance lane: it runs under every 3 seconds (`A_WINDOW_S`) of fingerprint whose own score is an A. Each 3-second window gets the match score's own formula on its own: shaped balance, averaged, shaped again and scaled to 0–28. Unlike the running score, every frame counts equally whatever its level, there is no balanced prior, and silent frames count as balance 0. Any window that scores 27 or more is underlined across all its 150 frames, so overlapping windows merge into longer lines. A window is only known to qualify once its last frame arrives, so live in the plugin the line is drawn backwards, up to 3 seconds into the past, as each window completes. At the end of a track the offline PNG and the plugin show the same line.

### Channels

The fingerprint's colour and balance only show how the three channels compare with each other. This lane shows how strong each one is: the same red, green and blue on the same scales, but **not clamped** to 0–1 (and without the 0.1 floor). They are also the CSV's `red`, `green` and `blue` columns.

- **Scale:** fixed, from −0.5 at the bottom to 2 at the top, with marks in the gutter at 0 and 1. The shaded band is 0–1: the 10th–90th percentile of each channel across the reference tracks (for green, the range set by hand, see [Fingerprint](#fingerprint)). The colour uses only that band. Above it, a channel's colour saturates; below it, the colour stays at the floor.
- **Lines:** plain, in the fingerprint's colours; green is the centroid's bright green, which stays apart from red for red-green colour blindness. They're the fingerprint's smoothed values, so they trail the music by the smoothing time, as the colour does.
- **Past the scale:** a line is pinned to the lane's edge and drawn twice as thick. Green does this at a track's start, before the centroid has had time to move.
- **Silence:** grey, no lines.

When one hue prevails in the fingerprint, this lane shows whether that channel is above its range or the other two are low. On the reference tracks, the 1st–99th percentile of every channel falls within about −0.25 to 1.5. Every channel ignores gain, so none of them follows the level.

In the plugin, the panel shows the three values now as bars beside this lane, green, blue and red from the top, the order of the spectrum, dynamics and flux lanes below, on the same scale with the same band, each followed by its number. Left of each bar is the channel's score so far, as its letter in the channel's colour. Letters and bars stay in the compact view.

### Channel scores

Each channel gets a letter for how high it runs, on the match score's scale:

1. Every frame that isn't silent puts each channel's unclamped value into one of 32 buckets: the value times 28, rounded down. Values below 0 aren't counted. The channels aren't clamped, so buckets 28–31 happen too, and everything from 31/28 ≈ 1.11 up lands in 31.
2. A channel's score is the 90th percentile of its buckets so far (the nearest-rank one), from the start of the track or the plugin's last reset.
3. The bucket becomes a letter:

| Bucket | Letter | Meaning |
|---|---|---|
| 31, 30, 29, 28 | `D`, `C`, `B`, `A` | above the channel's range, where its colour saturates: from 1.0, `D` from 1.11 |
| 27, 26, … 2 | `a`, `b`, … `z` | within the range, 27 just under its top |
| 1, 0 | `-` | at the very bottom, as the match score shows `-` below 2 |

A channel with nothing counted yet (silence, or only values below 0 so far) shows `-` in text and no letter in the plugin. So a capital letter means the channel spends more than a tenth of the track above its range. On the reference tracks, busy commercial mixes often reach `D` in one or more channels. The scaling is tentative.

stim-offline prints the final letters, the CSV's `grades` column has them frame by frame, and stim-batch's manifest keeps them per track. Spreadsheets that ignore case (Excel's sort and filter) treat `a` and `A` alike.

### Spectrum

- **Vertical axis:** pitch, from 27.5 Hz at the bottom to 22.4 kHz at the top. Each band is a row placed at its own pitch, so low bands are tall and high bands thin. The bottom row reaches down to 30 Hz and the top row up to 16 kHz.
- **Colour strength = band level**, from invisible at −80 dB to full colour at 0 dB.
- **Colour hue = band crest factor:** **red** at 5 dB or less (sustained or compressed), **grey** around 10 dB (similar to noise), **blue** at 15 dB or more (transient).
- **Bright green line with a dark edge** = centroid. Green because the fingerprint's green is how much this line moves.
- **Small dark marks** = `f_low` and `f_high`. They can fall outside the band rows.
- **Faint horizontal lines** at 100 Hz, 1 kHz and 10 kHz.

### Dynamics

- **Vertical axis:** 0 to 24 dB, with hairlines at 5, 10 and 15 dB (the ends and middle of the crest colour scale).
- **Dots:** full-band crest, in the same red, grey and blue as the spectrum.
- **Blue shading behind the dots:** the spread of the 24 band crests. The faint band spans min to max; the stronger band is the middle half. Blue because this spread is what the fingerprint's blue measures.

### Flux

Red spikes rise from the baseline, from 0 to 0.6 (anything higher is clipped at the top). Taller spikes are also more opaque. Because raw flux scales with loudness, loud passages have taller spikes overall. The fingerprint's red is this flux divided by the frame's level, so the red there does not simply follow these spike heights.

### Stereo width

A strip from light grey (0, mono) to aqua (0.5 or more, uncorrelated).

### Live bins

Dots from none (bottom) to all of the bins counted (top), with hairlines at 1/16 and 31/32 of them.

- **Red** (31/32 or more): nearly every bin clears the floor, so `FLOOR_DB` is letting noise in.
- **Orange** (below 1/16): very few bins clear it. This is expected for pure tones; on full music it means `FLOOR_DB` is too strict.
- **Grey:** in between.

Dense, modern pop is often red. Within 30 Hz–16 kHz, nearly every bin is within 60 dB of the loudest one (Ace of Base and *Barbie Girl* in 83–86% of frames). Sparse material such as solo piano sits far lower.

### Silence

The full-band level of each frame is the sum of its band energies.

- **Below −70 dB:** the frame counts as silent. Spectrum, dynamics, flux and live-bin lanes get a grey background and no marks, because crest, centroid and the spectral edges would only be describing the noise floor.
- **Between −70 and −55 dB:** the marks fade in.

---

## Using the hues

The prevailing hue of the fingerprint suggests arrangement, mixing and mastering moves that would even out the balance. They are options to weigh, not instructions. The meter sees only the last few seconds and knows nothing of the arc of stimulation the track is meant to have: a breakdown may be meant to be sparse, a build to lean one way. Whether to tame what prevails or bring up what is missing, and in which part, is the producer's or engineer's call.

### What each colour responds to

- **Red** is how much new energy appears from one 20 ms frame to the next, relative to the level. Only rises count: onsets, re-attacks, noise. Sustained sounds add nothing to it and raise the level it is divided by.
- **Green** is how far the spectral centroid (the average pitch of the energy) jumps within about a second. It grows when bright hits come and go against the body of the mix. Brightness that never goes away holds it down.
- **Blue** is how different the bands' crest factors (peak to average) are in the same moment: sustained parts in some bands, transient or impulsive ones in others.

All three are weighted by energy. The loud parts (kick, bass, snare, lead) decide the colour, and a quiet shaker or hi-hat barely registers. The score is weighted by level too, so fix the loud sections first. The A lane shows which 3-second stretches already pass.

### Reading the prevailing hue

| Hue | What is missing | First thing to try |
|---|---|---|
| Red | green and blue | lower red |
| Green | red and blue | lower green; in a sparse section, raise red and blue instead (see [Sparse and downtempo sections](#sparse-and-downtempo-sections)) |
| Blue | red and green | lower blue |
| Yellow (red + green) | blue | raise blue. The most common cast in dance and pop |
| Pink (red + blue) | green | raise green |
| Cyan (green + blue) | red | raise red |

That is the smallest change, but balance is a ratio, so either route whitens the fingerprint. A steady sine wave scores A, so taming a dominant colour can make a part balanced and dull at once. When a part feels thin, raising the two weaker colours usually serves the music better. The fingerprint can't tell "all three high" from "all three low"; your ears can.

### Hints

**Red**

| | Raise red | Lower red |
|---|---|---|
| Arrangement | busier rhythm in the loud parts (quiet hi-hats and background plucks don't count); a moving melodic line instead of a static one; more prominent percussion | legato writing and sustained layers in the prominent parts; thicker pads |
| Mixing | transient shaper on the drums; slower compressor attack; sustained parts lower against the drums; drum-bus compression with make-up gain | faster compressor attack; softened transients; louder pads |
| Mastering | slower attack on the bus compressor | fast-attack bus compression; heavy limiting |

**Green**

| | Raise green | Lower green |
|---|---|---|
| Arrangement | drum hits whose highs stand out from the body of the mix (in mixes that aren't already drum-heavy); low and high registers answering each other (a small effect) | constant bright layers: noise beds, continuous 16th hi-hats, shakers |
| Mixing | more attack on the drums; sustained parts lower | softened drum transients; noise and crackle; reverb (a little) |
| Mastering | slow attack on the high bands of a multiband compressor | heavy, fast multiband compression, the strongest green reducer found; heavy limiting |

**Blue**

| | Raise blue | Lower blue |
|---|---|---|
| Arrangement | crackle or another impulsive texture over tonal parts; a pulsating bass instead of a held one | thicker sustained layers (pads, drones) |
| Mixing | transient shaping on the drums alone; sidechain ducking of bass and pads; drum-bus compression with make-up gain; sustained parts lower | the same transient shaping on the whole bus; softened transients; louder pads |
| Mastering | slow attack on the high bands of a multiband compressor | heavy, fast multiband compression |

### Moves that touch several colours

Most moves shift more than one colour. Pick one that raises what is missing without feeding what already prevails.

| Move | Red | Green | Blue |
|---|---|---|---|
| Louder snare (+6 dB) | ↑↑ | ± | ± |
| Transient shaper on the drums | ↑↑ | · to ↑ | ↑ |
| Softer drum transients | ↓↓ | ↓↓ | ↓ |
| All sustained parts 6 dB lower | ↑↑ | · to ↑ | ↑ |
| Pad 6 dB louder | ↓ | · to ↓ | ↓ |
| Faster hi-hats and plucks (quiet parts) | · to ↑ | ↓ | ± |
| A moving melodic line instead of a static one* | ↑↑ | ↓ (slightly) | · |
| Pulsating bass instead of a held one | · | · to ↑ | ↑ |
| Sidechain ducking of bass and pad from the kick | · to ↑ | · | ↑ |
| Vinyl-style crackle | · to ↑ | ↓↓ | ↑↑ |
| Steady bright noise, quiet | · | ↓↓ | · to ↑ |
| Steady bright noise, loud | ↑ | ↓↓ | · to ↑ |
| Drum-bus compression with make-up gain | ↑ | · | ↑↑ |
| Reverb on the whole mix | ± | · to ↓ | · to ↓ |
| Fast-attack bus compression | ↓ | · to ↓ | · to ↓ |
| Heavy limiting | ↓↓ | · to ↓ | · to ↓ |
| Clipping | ↓ (slightly) | · | · (↑ on finished masters) |
| Heavy, fast multiband compression | ↓↓ | ↓↓ | ↓ |
| Slow attack on the multiband high bands, instead of fast | ↑↑ | ↑↑ | ↑↑ |

↑↑ or ↓↓: a large shift, typically a fifth of the channel's range or more. ↑ or ↓: a clear shift. ·: no real change. ± or "· to ↑": the direction or size depends on the rest of the mix. \*Tested in the vocal-forward mix only.

### Things that don't work the way you might expect

- **Reverb and delay don't calm red.** A tail is noise-like, so it adds as many small rises as it smooths over. What reverb does lower, a little, is green, and blue in beat-driven music.
- **Limiting and clipping don't lower blue.** Limiting mainly lowers red. Moderate clipping barely registers, and hard clipping of a finished master raises blue, by adding distortion. That is not a fix.
- **Pads lower blue.** Sustained energy weighs down the contrast between sustained and transient bands, so a thicker pad lowers blue as well as red.
- **Drum-bus compression raises red and blue.** With make-up gain it pumps: the hats, snare and room come up between kicks. It does so more with a fast attack.
- **More notes only count in the loud parts.** Faster hi-hats and background plucks barely move red, and they lower green, because a constant high layer steadies the brightness.
- **The biggest lever is often a fader.** Turning the sustained parts down against the drums moved red further than any processing tested, and lifted blue and green with it.
- **On a finished master, most mastering moves change little.** Heavy multiband compression is the exception, for green. Arrangement and the balance between parts come first, then group processing, then mastering.

### The rest of the mix changes the answer

The same move can push a colour different ways in different mixes. A louder snare lowered green in a drum-heavy mix but raised it clearly where pads or a voice carried the body. A transient shaper on the drums raised green in a vocal-led mix and not at all in a drum-led one. Legato writing lowered red only when that part was prominent. As a rule, a move changes a colour most when it changes the loudest element carrying that quality. Adding more of what is already plentiful does little, or even reverses the effect.

### Sparse and downtempo sections

Verses with few parts often show a strong green tint, especially at 60–72 bpm. The hue tests include such a verse (kick on 1 and 3, snare on 2 and 4, quiet hi-hats, a held bass, ringing piano-like keys and an exposed voice), run at 66 and 120 bpm. It comes out green at both tempos, and what it shows changes the advice above:

- **The tint comes from the sparseness, not from too much green.** Green read the same as in a full, vocal-led mix (0.80). What was low was red (0.16 at 66 bpm, 0.25 at 120), because there are few onsets, and blue (0.41), because few parts sound at once. So here, taming the prevailing primary is the wrong move: raise red and blue instead.
- **Slow tempos lower red in any arrangement.** Fewer onsets per second: at 66 bpm, red read 0.04–0.10 lower than at 120 in every mix tested.
- **At slow tempos the colour pulses with the beat.** A beat is about as long as the fingerprint's one-second window, so each channel swings about 1.7 times as much as at 120 bpm. Judge the prevailing hue over several bars. The A lane's 3 seconds cover only about three beats.

What moved the sparse verse at 66 bpm, as the change in its average frame balance (0–1, what the score is built from):

| Helped | | Hurt, or did nothing | |
|---|---|---|---|
| Transient shaper on the drums | +0.37 | A static melodic line instead of a moving one | −0.24 |
| All sustained parts 6 dB lower | +0.28 | Fast-attack bus compression | −0.14 |
| A steady noise bed, tape-hiss style | +0.26 | Heavy limiting | −0.13 |
| Reverb on the whole mix | +0.20 | Softer drum transients | 0 |
| Louder snare (+6 dB) | +0.19 | Sidechain ducking | 0 |
| Busier hi-hats and arpeggiated keys | +0.17 | | |

Where sparse sections differ from the general hints:

- **Reverb and delay help.** In a sparse verse their noise-like tails raise red (+0.15 at 66 bpm) and leave green alone, so balance rises (+0.20). A legitimate tool for a green verse.
- **A sustained part raises blue when few parts play.** Replacing the ringing keys with a held line raised blue by 0.21–0.24, although in full mixes pads lower it. Blue comes from a part whose envelope differs from what is already there. Shorter decays on the keys raised it too (+0.10 to +0.15), and so did a plucked line moving between registers.
- **More kicks don't add red.** Four on the floor instead of 1 and 3 left red unchanged and lowered green. A louder snare (+0.24) or more drum attack does add red.
- **Compression and limiting look like a fix but aren't.** They lower green more in sparse material (up to −0.31), but they take red down with it (about −0.18), and red is already the lowest channel, so balance falls.
- **Sidechain ducking does nothing** with only two kicks a bar. Shaping only the drums, rather than the whole bus, also matters less at slow tempos.
- **Drum-bus compression still raises blue at 66 bpm**, but which release time works best changes with tempo.

### Where these come from

A synthetic 16-bar song was built in four mixes (drum-forward, pad-forward, vocal-forward and a sparse verse) at 120 and 66 bpm, with one move made at a time and each colour measured with stim-offline. The mastering moves were also run on excerpts of four real tracks: drum and bass, acoustic vocal, orchestral and pop.

Every direction in the general tables held in the three full mixes at 120 bpm, or is marked as depending on the mix. The melodic line, which only the vocal-forward mix and the sparse verse have, is the exception. At 66 bpm the directions held too, except that some gains in blue shrank or vanished: from drums-only transient shaping and lower sustained parts in the drum-forward mix, and from sidechain ducking and shaping the drums rather than the whole bus.

The parts are synthetic and the processors simple, so trust the directions more than the sizes.

---

## stim-batch

```
stim-batch [options] <file or folder>...
```

| Option | Default | Meaning |
|---|---|---|
| `--out DIR` | `stim-out` next to stim-batch.exe | Output root |
| `--jobs N` | half the logical cores | How many files are analysed at the same time |
| `--skip-existing` | off | Skip files whose CSV (and PNG, unless `--no-png`) is newer than the audio |
| `--no-png` | off | Write CSVs only |
| `--timeout SEC` | 600 | Stop a file that takes longer than this; 0 = never |
| `--smooth-frames N` | 0 = stim-offline's default (80) | Passed on to stim-offline as its `--smooth-frames`. Use a separate `--out` for each setting: the manifest has one row per audio file, and `--skip-existing` doesn't look at the setting |
| `--exe PATH` | stim-offline.exe next to stim-batch.exe | Which stim-offline to run |
| `--no-pause` | off | Never wait for Enter at the end (for scheduled or scripted runs) |
| `-h`, `--help` | | Show the options |

Examples:

```
stim-batch "D:\Music\Classical"
stim-batch --out D:\stim-out\floor-55 --jobs 6 "D:\Music\Classical" "D:\Music\Pop\track.flac"
stim-batch --skip-existing --no-png "D:\Music"
```

### Which files are processed

- Folders are searched recursively for `.wav .flac .mp3 .ogg .opus`. The extension check ignores case; other files are ignored. Lossy files are analysed like the rest, but their results can differ from lossless copies of the same tracks: see [Input](#input).
- The same file given twice (for example, directly and inside a dropped folder) is only processed once. Paths are compared ignoring case on Windows and macOS, whose file systems ignore case, and exactly on Linux.

### Where outputs go

The input folder structure is mirrored under the output root:

| Input | Output |
|---|---|
| a folder `D:\Music\Bach` | `<out>\Bach\<subfolders>\<name>.csv` and `.png` |
| a single file `D:\Music\Pop\track.flac` | `<out>\Pop\track.csv` and `.png` |

If two inputs would produce the same output name (`song.flac` and `song.mp3` in the same folder, or two dropped folders with the same name), the later one gets a `~2` suffix (`song~2.csv`).

### Re-running

- **By default every file is analysed again** and its outputs are overwritten. That's what you want while tuning stim-offline: changing its parameters or rebuilding it doesn't make old outputs look out of date, because `--skip-existing` only compares the output files' timestamps with the audio file's.
- Use `--skip-existing` to add new files to a folder you've already processed.
- To keep results from different parameter sets side by side, give each run its own `--out` folder.

### manifest.csv

`<out>\manifest.csv` has one row per audio file. Each run updates the rows for the files it processed; rows for other files are kept. The file is saved every 20 finished files and at the end of the run.

| Column | Meaning |
|---|---|
| `audio_path` | full path of the audio file; each row is identified by it (case ignored) |
| `csv_path`, `png_path` | output paths, relative to the output root |
| `status` | `ok`, `failed`, `timeout` or `skipped` |
| `exit_code` | stim-offline's exit code |
| `duration_s`, `sample_rate`, `channels`, `frames` | from stim-offline's summary line, only when `ok` |
| `score`, `grade` | the track's match score and letter grade, only when `ok` |
| `green_score`, `blue_score`, `red_score` | each [channel score](#channel-scores) at the end of the track, only when `ok` |
| `smooth_frames` | the `--smooth-frames` passed on; empty for the default |
| `run_s` | how long the file took to process |
| `processed_at` | local date and time of the run |
| `message` | stim-offline's stderr, with lines joined by ` \| `. For `ok` files this is usually the sample-rate warning |

A skipped file keeps the row from its last real run. For model training, filter to `status == ok`. If the manifest can't be read, it's copied to `manifest.csv.bak` and a new one is started.

### Progress and exit codes

Each finished file prints one line, followed by the error for failures:

```
4 files, 4 to analyse, 0 skipped | 8 at once | out: D:\stim-out
[1/4] failed     0.0 s  Album\Disc 2\broken
    error: could not open '...broken.mp3': Cannot decode stream: unrecognized encoding.
[2/4] ok        11.2 s  Album\song
```

The exit code is `0` when nothing failed or timed out; skipped files count as fine. It is `1` if any file failed or timed out, and also for a usage error, a missing stim-offline, or a locked output folder.

### Drag and drop, and the Send To menu (Windows)

- **Drag and drop:** drop files or folders onto `stim-batch.exe`, or onto a shortcut to it. A console window opens, shows progress, and **waits for Enter** at the end so you can read the summary.
- **Send To menu:**
  1. Press Win+R, type `shell:sendto`, press Enter.
  2. Right-click in the folder that opens, choose New → Shortcut, browse to `stim-batch.exe`, and name it, for example, *Stim analyse*.
  3. Optionally, edit the shortcut's Target to add fixed options before the paths, for example:
     `"C:\...\stim-batch.exe" --out "D:\stim-out" --jobs 6`

  Now right-click any files or folders and choose Send to → Stim analyse.

Run from a terminal, stim-batch never waits for Enter. If you start it some other way that gives it its own console (Task Scheduler, `Start-Process`), add `--no-pause`, or it will wait for Enter in a window nobody sees.

### Safety

- **One run per output folder:** while a run is active, `<out>\stim-batch.lock` is locked and a second stim-batch pointed at the same folder is refused. The OS releases the lock when the run ends, even after a crash or forced kill. Windows also deletes the file; on macOS and Linux it stays behind, which is harmless.
- **Separate processes:** each file runs in its own stim-offline process. A crash, a corrupt file or a hang fails only that file.
- **Ctrl+C** stops stim-batch and the files that are running. Finished outputs stay, but the last 19 or so rows may be missing from the manifest. Re-running fills them in (with `--skip-existing`, those rows show `skipped` without the metadata).
- **Memory:** each running file holds its decoded audio in memory, about 115 MB for 5 minutes of 48 kHz stereo plus the analysis data. Multiply by `--jobs`.

---

## Limitations

- No resampling. Every rate gets 40 ms frames and the 30 Hz–16 kHz range, but crest is measured on sample peaks, so it can read a little lower at 44.1 kHz than at 96 kHz. `stim-offline --test` ends with a table comparing the synthetic signals at 44.1, 48 and 96 kHz.
- Lossy codecs (MP3, Ogg Vorbis, Opus) change what the features measure, so a lossy file's fingerprint and score can differ from the lossless master's. Nothing warns about it at run time. See [Input](#input).
- The whole file is decoded into memory before analysis.
- Output paths longer than 260 characters (deeply nested folders under a long `--out`) haven't been tested.
- The PNG has no text labels or legend; this file is the legend. The CSV holds the exact values.

---

## Licence

Copyright © 2026 x21.

This work is licensed under the [Creative Commons Attribution-NoDerivatives 4.0 International licence](https://creativecommons.org/licenses/by-nd/4.0/) (CC BY-ND 4.0); the full text is in [LICENSE](LICENSE). In short: you may use, copy and share the source and the binaries, commercially too, if you credit the author, link the licence and share them unchanged. You may not share modified versions. Building the unmodified source yourself is fine.

To credit the tools, for example in a copy you share: *stim-offline and stim-batch by x21, https://github.com/x21-dev/x21meter, licensed CC BY-ND 4.0*. If you publish results made with them, a credit like that is appreciated too.

The libraries the build downloads are not part of this work. Each has its own licence.

The software is provided as is, without warranty of any kind, and the author accepts no liability for its use, as the licence's sections 5 and 6 set out.
