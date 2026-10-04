# stim-offline and stim-batch

Command-line tools for extracting features from music:

- **stim-offline** analyses one audio file. It writes a CSV of features (one row per 40 ms frame, a new frame every 20 ms hop) and a PNG that shows how those features change over time, and gives the track a match score.
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
| `--smooth-frames N` | The fingerprint's smoothing time in frames, one per 20 ms hop. Default 80 (1.6 s), which the plugin always uses. It changes the fingerprint, balance, match score, window score and A lane, not the features |
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

- **Formats:** WAV, FLAC, MP3 and Ogg Vorbis. MOD and XM should also work but haven't been tested. QOA and Opus aren't supported: convert them first, for example with `ffmpeg -i track.opus track.flac`.
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

One row per frame. A frame is a 40 ms window, and a new one starts every hop of 20 ms, at any sample rate, so each frame overlaps the next by half. The first five frames are dropped while the filters settle, so the first row is `frame` 6.

| Column | Meaning |
|---|---|
| `frame` | frame index |
| `time_s` | start of the frame's 40 ms window, in seconds |
| `level_<Hz>_dB` ×24 | RMS level of each mel band, named by its centre frequency (127 Hz to about 14 kHz) |
| `crest_<Hz>_dB` ×24 | peak-to-RMS ratio of each band. Low = sustained or compressed, high = transient |
| `full_crest_dB` | peak-to-RMS ratio of the whole signal |
| `f_low_st`, `f_high_st` | frequencies below which 5% and 95% of the spectral energy between 30 Hz and 16 kHz lies |
| `centroid_st` | energy-weighted mean frequency (how bright or dark the sound is) |
| `flux` | how much the spectrum grew since the previous frame, one hop earlier (only increases are counted). **Not normalised: it scales with loudness** |
| `stereo_width` | side energy / (mid + side energy). 0 = mono, 0.5 = uncorrelated, above 0.5 = mostly out of phase |
| `live_bins` | number of FFT bins between 30 Hz and 16 kHz within 60 dB of the loudest bin in that range. The total depends on the sample rate: 742 at 44.1 kHz, 681 at 48 kHz |
| `red`, `green`, `blue` | the fingerprint's three channels, **unclamped**: 0 and 1 are the ends of each channel's range, as in the fingerprint, but values run below 0 and above 1. `nan` in silent frames. See [Channels](#channels) |
| `balance` | fingerprint balance, 0 (one quality dominates) to 1 (all three equal); `nan` in silent frames. See [Match score](#match-score) |
| `balance_weight` | the frame's weight in the match score (peak amplitude^0.5); 0 in silent frames |
| `match_score` | running match score from the start of the track up to this frame, 0–28 |
| `window_score` | the score of the last 3 s alone (the A lane's test: every frame counts equally, no prior), 0–28; 27 or more underlines those 3 s in the PNG. Empty (`nan`) for the first 3 s |
| `grades` | four letters so far: the running match score's grade, then the green, blue and red [channel scores](#channel-scores), e.g. `Agbr`. `-` for a channel with nothing counted yet |

The last eight columns, from `red` on, are derived from the fingerprint rather than measured by the analyser.

Everything is measured on the K-weighted mid signal, (L+R)/2. K-weighting is a loudness filter: a highpass at 38 Hz and a shelf that rises from about 1 kHz to +4 dB by about 5 kHz (+2 dB at 1.7 kHz). The `_st` columns are **semitones relative to A 440 Hz**: 0 = 440 Hz, +12 = 880 Hz, −12 = 220 Hz. A silent frame reads −120. The spectral features (`f_low_st`, `f_high_st`, `centroid_st`, `flux`, `live_bins`) only use 30 Hz–16 kHz, the same range as the 24 bands. Above 16 kHz, lossy encoders decide what's left (a 128 kbps MP3 cuts off near 16 kHz), and most adults hear little of it. `f_low_st` can still dip slightly below 30 Hz (to about −52 semitones, 22 Hz), because the frequency estimate for the lowest bins can land a little under their nominal frequency.

---

## The PNG

Time runs left to right with **one pixel column per frame**, that is one per 20 ms hop, so a 3-minute track is about 9000 px wide. The image is 928 px tall. A light vertical line marks every second and a darker one every 10 seconds.

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
| 888–920 | **Live bins** | How much of the spectrum is within 60 dB of its loudest bin |

### Fingerprint

Three smoothed features are mixed as red, green and blue:

| Channel | Feature | Typical range (mapped to 0–1) |
|---|---|---|
| red | flux divided by the frame's amplitude (how busy the spectrum is, regardless of loudness) | 0.290–0.724 |
| green | how much the centroid moves (its standard deviation, in semitones), **mapped on a log scale** | 3.79–14.26 |
| blue | how far apart the 24 band crests are: their standard deviation within the frame, each band weighted by its share of the energy | 0.913–1.936 dB |

All three ranges are the 10th–90th percentiles over the *reference tracks*, a set spanning dance, pop, 90s, chill, acoustic, piano and classical, soundtrack and rock. Green's is mapped on a log scale, because centroid spread is skewed, with a long upper tail in dance.

The ranges are then checked on a set of current chart hits: on dense commercial mixes the three channels should average about level, so that none of them is the weakest most of the time.

**Why blue uses the spread across bands:** in a mix with depth and separation, different bands are dominated by different sources (sustained bass and pads beside sharp drums and hi-hats), so their crest factors spread apart. A single instrument keeps them close. Limiting squeezes the full-band crest but not this spread, so polished commercial masters aren't penalised for being mastered.

Each channel is mapped onto its range and 0.1 is added to all three. They're then divided by the largest and raised to the power 0.618, so the strongest is always at full brightness and the weaker ones are lifted toward it (pastel mixes):

- **white or pastel:** all three are about equally active;
- **red:** busy note or onset activity (fast piano passages, for example);
- **green:** the tone colour is shifting (typical in fade-outs and transitions);
- **blue:** separated sources with different transient character (a full band mix, for example);
- **mixes:** pink = red + blue, cyan = green + blue, yellow = red + green;
- **grey:** silence.

The smoothing time is 80 frames, 1.6 s at one frame per hop; stim-offline and stim-batch can change it with `--smooth-frames`. It runs **forwards only**, as a live meter would, so each frame depends only on what came before it. As a result, colour changes trail the lanes below by roughly the smoothing time.

### Match score

The match score rates how balanced the fingerprint is over the whole track:

1. **Balance per frame:** `min(R,G,B) / max(R,G,B)` of the fingerprint channels, raised to the power 0.618. It's rescaled so 0 means one channel is at the top of its range and another at the floor, and 1 means all three are equal. The fingerprint's colours use the same power, so a whiter fingerprint strip means a higher balance.
2. **Weight per frame:** peak amplitude^0.5. Silent frames get weight 0.
3. **Running score:** each frame's balance is shaped by `1 − (1 − b)^1.618` and accumulated as a weighted running mean from the start of the track. The mean is shaped again the same way and scaled to 0–28. The value at the last frame is the track's score.
4. **Balanced prior:** every track is scored as if it began with 15 s of perfectly balanced music, weighted at the track's own average weight so far. The running score starts at the top, and a short quiet or sparse intro only dents it. The prior stays in the final score as 15 s ÷ track length of perfect balance, which adds about 0.3–0.9 points to a typical 3–4 minute song, more to short or unbalanced ones.
5. **Grade:** 27 and above = **A**, 26 = B, … 2 = Z, and below 2 = `-`.

The score is **independent of gain**: every weight is a power of amplitude, so a uniform gain change cancels out of the mean. A test with the same track at 0, −3 and −10 dB gave the same final score to within 0.001. The only thing that isn't independent is the −70 dB silence gate: frames it excludes at a lower gain can shift the early running score slightly, and the final score doesn't change.

Weighting means quiet passages hardly count. Balance measures proportion, not activity, though: a steady sine has all three channels at the floor, so they're equal and it scores A.

The score is printed at the end of stim-offline's output (`match score 25.63, grade C`), included in the `--quiet` summary line, and recorded by stim-batch in the manifest's `score` and `grade` columns.

### Balance lane and A lane

The three top lanes read at three time scales. The fingerprint shows balance moment by moment, the A lane marks short stretches of good balance, and the balance lane's score line integrates over the whole measurement, weighted by level.

- **Filled column:** its **height** is the frame's weight in the match score relative to the heaviest frame in the track, so taller columns count more towards the score. With weights of peak^0.5, a passage 20 dB below the loudest is drawn at about a third of full height. The **fill** is the fingerprint's own colour: the lighter it is, the more balanced the frame, and its hue shows what dominates. The height is a ratio, so it doesn't change with gain. A fully grey column (the lighter silence grey) is silence.
- **Score line:** the running match score, from 0 at the bottom to 28 at the top. It is **gold** while the score is at grade A (27 or more) and dark below that. Released music scores high, so the line usually sits near the top.
- **A lane**, the yellow line between the fingerprint strip and the balance lane: it runs under every 3 seconds of fingerprint whose own score is an A. Each 3-second window gets the match score's own formula on its own: shaped balance, averaged, shaped again and scaled to 0–28. Unlike the running score, every frame counts equally whatever its level, there is no balanced prior, and silent frames count as balance 0. Any window that scores 27 or more is underlined across all its 150 frames, so overlapping windows merge into longer lines. A window is only known to qualify once its last frame arrives, so live in the plugin the line is drawn backwards, up to 3 seconds into the past, as each window completes. At the end of a track the offline PNG and the plugin show the same line.

### Channels

The fingerprint's colour and balance only show how the three channels compare with each other. This lane shows how strong each one is: the same red, green and blue on the same scales, but **not clamped** to 0–1 (and without the 0.1 floor). They are also the CSV's `red`, `green` and `blue` columns.

- **Scale:** fixed, from −0.5 at the bottom to 2 at the top, with marks in the gutter at 0 and 1. The shaded band is 0–1: the 10th–90th percentile of each channel across the reference tracks (see [Fingerprint](#fingerprint)). The colour uses only that band. Above it, a channel's colour saturates; below it, the colour stays at the floor.
- **Lines:** plain, in the fingerprint's colours; green is the centroid's bright green, which stays apart from red for red-green colour blindness. They're the fingerprint's smoothed values, so they trail the music by the smoothing time, as the colour does.
- **Past the scale:** a line is pinned to the lane's edge and drawn twice as thick. Green does this at a track's start, before the centroid has had time to move.
- **Silence:** grey, no lines.

When one hue prevails in the fingerprint, this lane shows whether that channel is above its range or the other two are low. On the reference tracks, the 1st–99th percentile of every channel falls within about −0.5 to 1.4. Every channel ignores gain, so none of them follows the level.

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

A channel with nothing counted yet (silence, or only values below 0 so far) shows `-` in text and no letter in the plugin. So a capital letter means the channel spends more than a tenth of the track above its range. On the reference tracks, busy commercial mixes often reach `D` in one or more channels.

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

- **Red** (31/32 or more): nearly every bin clears the floor: a dense mix, or noise.
- **Orange** (below 1/16): very few bins clear it. This is expected for pure tones, and unusual for full music.
- **Grey:** in between.

Dense, modern pop is often red: within 30 Hz–16 kHz, nearly every bin is within 60 dB of the loudest one. Sparse material such as solo piano sits far lower.

### Silence

The full-band level of each frame is the sum of its band energies.

- **Below −70 dB:** the frame counts as silent. Spectrum, dynamics, flux and live-bin lanes get a grey background and no marks, because crest, centroid and the spectral edges would only be describing the noise floor.
- **Between −70 and −55 dB:** the marks fade in.

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
stim-batch --out D:\stim-out\selection --jobs 6 "D:\Music\Classical" "D:\Music\Pop\track.flac"
stim-batch --skip-existing --no-png "D:\Music"
```

### Which files are processed

- Folders are searched recursively for `.wav .flac .mp3 .ogg`. The extension check ignores case; other files are ignored. Lossy files are analysed like the rest, but their results can differ from lossless copies of the same tracks: see [Input](#input).
- The same file given twice (for example, directly and inside a dropped folder) is only processed once. Paths are compared ignoring case on Windows and macOS, whose file systems ignore case, and exactly on Linux.

### Where outputs go

The input folder structure is mirrored under the output root:

| Input | Output |
|---|---|
| a folder `D:\Music\Bach` | `<out>\Bach\<subfolders>\<name>.csv` and `.png` |
| a single file `D:\Music\Pop\track.flac` | `<out>\Pop\track.csv` and `.png` |

If two inputs would produce the same output name (`song.flac` and `song.mp3` in the same folder, or two dropped folders with the same name), the later one gets a `~2` suffix (`song~2.csv`).

### Re-running

- **By default every file is analysed again** and its outputs are overwritten, so a new stim-offline or a different `--smooth-frames` takes effect everywhere. `--skip-existing` couldn't tell that outputs are out of date: it only compares the output files' timestamps with the audio file's.
- Use `--skip-existing` to add new files to a folder you've already processed.
- To keep results from different settings or versions side by side, give each run its own `--out` folder.

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
- Lossy codecs (MP3, Ogg Vorbis) change what the features measure, so a lossy file's fingerprint and score can differ from the lossless master's. Nothing warns about it at run time. See [Input](#input).
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
