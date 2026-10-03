/// stim-batch: run stim-offline over many audio files.
///
///     stim-batch [options] <file or folder>...
///
/// Folders are searched recursively. Outputs mirror the input layout under an
/// output root (default: stim-out next to this exe), and manifest.csv there
/// keeps one row per audio file, updated across runs. Each file is its own
/// stim-offline process, so a crash or a stuck decode fails only that entry.
///
/// Dropping files or folders onto the exe, or using it from the Send To menu,
/// passes their paths as arguments; the window then waits for Enter at the end
/// (--no-pause turns that off for scheduled or scripted runs).
module stimbatch;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : canFind, endsWith, filter, fold, map, max, sort, startsWith;
import std.array : array, join, split;
import std.conv : octal, to;
import std.csv : csvReader;
import std.datetime : Clock, DateTime;
import std.file;
import std.format : format;
import std.getopt : getopt, defaultGetoptPrinter;
import std.parallelism : totalCPUs;
import std.path;
import std.process : Pid, kill, spawnProcess, thisProcessID, tryWait, wait;
import std.stdio;
import std.string : indexOf, lineSplitter, strip;
import std.uni : toLower;

// No .opus: audio-formats decodes Opus only in its LGPL configuration, which
// the proprietary and CC BY-ND builds can't link.
immutable string[] AUDIO_EXTS = [".wav", ".flac", ".mp3", ".ogg"];

version (Windows) enum string OFFLINE_EXE = "stim-offline.exe";
else              enum string OFFLINE_EXE = "stim-offline";

/// Key for telling paths apart. Windows and macOS file systems ignore case by
/// default; Linux ones don't, and there Song.flac and song.flac are two files.
string pathKey(string p) pure
{
    version (linux) return p;
    else            return p.toLower;
}

immutable string[] MANIFEST_COLS = [
    "audio_path", "csv_path", "png_path", "status", "exit_code",
    "duration_s", "sample_rate", "channels", "frames", "score", "grade",
    "green_score", "blue_score", "red_score", "smooth_frames", "run_s",
    "processed_at", "message",
];

struct Job
{
    string audio;          // absolute
    string csv, png;       // absolute
    string label;          // output stem relative to the root, for the log
    string status;         // ok, failed, timeout, skipped
    int    exitCode;
    string summary;        // stim-offline --quiet's key=value line
    string message;        // its stderr, one line
    double runSeconds = 0;
}

struct Running
{
    size_t   job;
    Pid      pid;
    MonoTime started;
    string   outLog, errLog;
}

bool isAudio(string path) pure
{
    return AUDIO_EXTS.canFind(path.extension.toLower);
}

/// An audio file to analyse, and the folder its outputs are laid out from:
/// the folder it was found in by a search, or its own folder if given directly.
struct Found
{
    string file;    // absolute
    string base;
}

/// Expand the arguments into audio files, in order and each once. Folders are
/// searched recursively; a file given directly is taken whatever its extension.
Found[] findAudio(string[] inputs)
{
    Found[] found;
    bool[string] seen;
    foreach (arg; inputs)
    {
        immutable string p = arg.absolutePath.buildNormalizedPath;
        if (!p.exists)
        {
            stderr.writeln("not found, skipped: ", arg);
            continue;
        }

        string base;
        string[] files;
        if (p.isDir)
        {
            base = p;
            foreach (DirEntry e; dirEntries(p, SpanMode.depth, false))
                if (e.isFile && isAudio(e.name))
                    files ~= e.name;
            files.sort();
        }
        else
        {
            base  = p.dirName;
            files = [p];
        }

        foreach (f; files)
        {
            immutable string key = pathKey(f);
            if (key in seen) continue;
            seen[key] = true;
            found ~= Found(f, base);
        }
    }
    return found;
}

/// The jobs for `found`, their outputs under `root`: a searched folder maps
/// to <root>/<folder name>/..., a file given directly to <root>/<its parent
/// folder's name>/<stem>. Outputs that would coincide (song.mp3 next to
/// song.flac, or two dropped folders with the same name) get a ~N suffix,
/// in order: the first keeps the plain name.
Job[] assignOutputs(const(Found)[] found, string root) pure
{
    Job[] jobs;
    size_t[string] uses;
    foreach (fd; found)
    {
        string top = fd.base.baseName;
        if (top.length == 0 || top == "." || top.endsWith(":\\"))
            top = "root";
        string rel  = buildPath(top, relativePath(fd.file, fd.base).stripExtension);
        string stem = buildPath(root, rel);

        immutable string key = pathKey(stem ~ ".csv");
        immutable size_t n = uses.get(key, 0) + 1;
        uses[key] = n;
        if (n > 1)
        {
            immutable string suffix = format("~%d", n);
            rel  ~= suffix;
            stem ~= suffix;
        }

        Job j;
        j.audio = fd.file;
        j.label = rel;
        j.csv   = stem ~ ".csv";
        j.png   = stem ~ ".png";
        jobs ~= j;
    }
    return jobs;
}

/// Windows refuses paths of MAX_PATH (260) characters or more without the
/// \\?\ prefix. The paths here are already absolute and normalised.
string longPath(string p) pure
{
    version (Windows)
    {
        if (p.length >= 240 && !p.startsWith(`\\?\`))
            return `\\?\` ~ p;
    }
    return p;
}

bool upToDate(ref const Job j, bool withPng)
{
    immutable csv = longPath(j.csv), png = longPath(j.png);
    if (!csv.exists) return false;
    immutable src = longPath(j.audio).timeLastModified;
    if (csv.timeLastModified < src) return false;
    return !withPng || (png.exists && png.timeLastModified >= src);
}

/// Starts stim-offline on `j`. `smoothFrames` 0 passes nothing, so
/// stim-offline uses its own default.
Running launch(size_t idx, ref Job j, string exe, bool noPng, int smoothFrames, string logDir)
{
    mkdirRecurse(j.csv.dirName);

    string[] cmd = [exe, "--quiet", "--csv", j.csv];
    cmd ~= noPng ? ["--no-png"] : ["--png", j.png];
    if (smoothFrames > 0)
        cmd ~= ["--smooth-frames", smoothFrames.to!string];
    cmd ~= ["--", j.audio];   // "--" in case a file name starts with '-'

    // Child output goes to files rather than pipes: nothing is read until
    // the child exits, and a long stack trace would fill a pipe and block it.
    // The child shares this console, so Ctrl+C stops it along with us.
    Running r;
    r.job    = idx;
    r.outLog = buildPath(logDir, format("%d.out", idx));
    r.errLog = buildPath(logDir, format("%d.err", idx));
    auto o = File(r.outLog, "w");
    auto e = File(r.errLog, "w");
    r.pid     = spawnProcess(cmd, stdin, o, e);
    r.started = MonoTime.currTime;
    return r;
}

/// Read and delete a child's log. The delete can fail right after the child
/// exits (a virus scanner inspecting the fresh file holds it briefly); that
/// is harmless, the run's log folder is removed at the end anyway.
string slurp(string path)
{
    if (!path.exists) return "";
    scope (exit) tryRemove(path);
    return readText(path);
}

void tryRemove(string path) nothrow
{
    try remove(path); catch (Exception) {}
}

void tryRemoveDir(string path) nothrow
{
    try rmdirRecurse(path); catch (Exception) {}
}

/// The non-empty lines of `text`, stripped.
auto contentLines(string text) pure
{
    return text.lineSplitter.map!strip.filter!(line => line.length > 0);
}

void finish(ref Job j, ref Running r, int exitCode, bool timedOut)
{
    j.runSeconds = (MonoTime.currTime - r.started).total!"msecs" / 1000.0;
    j.exitCode   = exitCode;
    j.status     = timedOut ? "timeout" : exitCode == 0 ? "ok" : "failed";

    // The summary is stim-offline's last line; stderr becomes one line. The
    // fold keeps each line over the one before, so it ends with the last.
    j.summary = contentLines(slurp(r.outLog)).fold!((last, line) => line)("");
    j.message = contentLines(slurp(r.errLog)).join(" | ");
    if (timedOut)
        j.message = "killed after timeout" ~ (j.message.length ? " | " ~ j.message : "");
}

// ─────────────────────────────────────────────────────────────────────────────
// Manifest
// ─────────────────────────────────────────────────────────────────────────────

alias Row = string[string];

Row[string] loadManifest(string path)
{
    Row[string] rows;
    if (!path.exists) return rows;
    try
    {
        // Excel saves CSV with a UTF-8 byte order mark, which csvReader would
        // take as part of the first column name.
        string text = readText(path);
        if (text.startsWith("﻿")) text = text[3 .. $];
        foreach (rec; csvReader!(string[string])(text, null))
        {
            Row row;
            foreach (k, v; rec) row[k] = v;
            if (auto a = "audio_path" in row)
                rows[pathKey(*a)] = row;
        }
    }
    catch (Exception e)
    {
        immutable string bak = path ~ ".bak";
        copy(path, bak);
        stderr.writefln("could not read %s (%s); saved it as %s and started a new one",
                        path, e.msg, bak);
        rows = null;
    }
    return rows;
}

string csvField(string s) pure
{
    if (s.indexOf(',') < 0 && s.indexOf('"') < 0 && s.indexOf('\n') < 0)
        return s;
    return '"' ~ s.split('"').join(`""`) ~ '"';
}

void saveManifest(Row[string] rows, string path)
{
    immutable string tmp = path ~ ".tmp";
    {
        auto f = File(tmp, "w");
        f.writeln(MANIFEST_COLS.join(","));
        foreach (key; rows.keys.sort)
            f.writeln(MANIFEST_COLS.map!(c => csvField(rows[key].get(c, ""))).join(","));
    }
    rename(tmp, path);
}

/// stim-offline --quiet's summary line, space-separated key=value pairs, as a map.
string[string] parseSummary(string summary) pure
{
    string[string] fields;
    foreach (kv; summary.split)
    {
        immutable ptrdiff_t eq = kv.indexOf('=');
        if (eq > 0) fields[kv[0 .. eq]] = kv[eq + 1 .. $];
    }
    return fields;
}

/// The time as processed_at records it: local, to the second.
string timestamp()
{
    return (cast(DateTime) Clock.currTime).toISOExtString;
}

/// Puts `j`'s row into `rows`. `smoothFrames` 0 is recorded as empty, and
/// `processedAt` is the row's time (timestamp()).
void record(ref Row[string] rows, ref const Job j, string root, bool noPng,
            int smoothFrames, string processedAt) pure
{
    immutable string key = pathKey(j.audio);
    // A skipped file keeps whatever an earlier run recorded for it.
    if (j.status == "skipped" && key in rows) return;

    Row row;
    row["audio_path"]   = j.audio;
    row["csv_path"]     = relativePath(j.csv, root);
    row["png_path"]     = noPng ? "" : relativePath(j.png, root);
    row["status"]       = j.status;
    row["exit_code"]    = j.status == "skipped" ? "" : j.exitCode.to!string;
    row["run_s"]        = j.status == "skipped" ? "" : format("%.1f", j.runSeconds);
    row["smooth_frames"] = smoothFrames > 0 ? smoothFrames.to!string : "";
    row["processed_at"] = processedAt;
    row["message"]      = j.message;
    foreach (k, v; parseSummary(j.summary))
        row[k] = v;
    rows[key] = row;
}

// ─────────────────────────────────────────────────────────────────────────────

version (Windows)
{
    import core.sys.windows.windows : CloseHandle, CreateFileW, HANDLE, INVALID_HANDLE_VALUE,
        GENERIC_WRITE, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, FILE_FLAG_DELETE_ON_CLOSE,
        CP_UTF8, GetConsoleOutputCP, SetConsoleOutputCP;
    import std.utf : toUTF16z;

    /// Held for the whole run. A second stim-batch on the same output root
    /// would interleave outputs and overwrite the manifest, so it is refused.
    /// The OS deletes the file when the handle closes, crash included, so a
    /// lock never goes stale.
    HANDLE lockRoot(string root)
    {
        return CreateFileW(buildPath(root, "stim-batch.lock").toUTF16z, GENERIC_WRITE,
                           0, null, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, null);
    }

    extern (Windows) uint GetConsoleProcessList(uint* list, uint count) nothrow @nogc;

    /// True when this process is alone on its console, i.e. Explorer opened
    /// the window for it (drag and drop, Send To) and it closes when we exit.
    bool ownConsole()
    {
        uint[2] ids;
        return GetConsoleProcessList(ids.ptr, 2) == 1;
    }
}
else version (Posix)
{
    import core.stdc.stdio : SEEK_SET;
    import core.sys.posix.fcntl : F_SETLK, F_WRLCK, O_CREAT, O_WRONLY, fcntl, flock, open;
    import core.sys.posix.unistd : close;
    import std.string : toStringz;

    /// The same guard with a POSIX record lock, which the OS also drops when
    /// the process ends, crash included. The file itself stays behind; the
    /// next run simply locks it again.
    int lockRoot(string root)
    {
        immutable int fd = open(buildPath(root, "stim-batch.lock").toStringz,
                                O_WRONLY | O_CREAT, octal!644);
        if (fd < 0) return -1;
        flock fl;               // start 0, length 0: the whole file
        fl.l_type   = F_WRLCK;
        fl.l_whence = SEEK_SET;
        if (fcntl(fd, F_SETLK, &fl) == -1)
        {
            close(fd);
            return -1;
        }
        return fd;
    }

    bool ownConsole() { return false; }
}
else
    bool ownConsole() { return false; }

int main(string[] args)
{
    version (Windows)
    {
        // File names can be Cyrillic and so on, and the console shows UTF-8
        // only when told to. The setting outlives the process, so restore it.
        immutable uint oldCodePage = GetConsoleOutputCP();
        SetConsoleOutputCP(CP_UTF8);
        scope (exit) SetConsoleOutputCP(oldCodePage);
    }
    immutable bool pause = ownConsole();
    bool noPause;
    scope (exit)
        if (pause && !noPause)
        {
            write("\npress Enter to close");
            stdout.flush();
            readln();
        }

    string root = buildPath(thisExePath.dirName, "stim-out");
    string exe  = buildPath(thisExePath.dirName, OFFLINE_EXE);
    int    jobsN   = max(1, totalCPUs / 2);
    int    timeout = 600;
    int    smoothFrames;   // 0: stim-offline's own default, smooth_frames left empty
    bool   skip, noPng;

    try
    {
        auto opt = getopt(args,
            "out",           "output root (default: stim-out next to this exe)", &root,
            "jobs",          format("files processed at once (default: %d)", jobsN), &jobsN,
            "skip-existing", "skip files whose outputs are newer than the audio", &skip,
            "no-png",        "write CSVs only", &noPng,
            "timeout",       "seconds before a file is killed, 0 = never (default: 600)", &timeout,
            "smooth-frames", "fingerprint smoothing in 20 ms frames, passed to stim-offline (default: 0 = its own, 80)", &smoothFrames,
            "exe",           "stim-offline to run (default: the one next to this exe)", &exe,
            "no-pause",      "never wait for Enter at the end (for scheduled or scripted runs)", &noPause);

        if (opt.helpWanted || args.length < 2)
        {
            defaultGetoptPrinter("usage: stim-batch [options] <file or folder>...\n"
                ~ "Analyses every audio file (" ~ AUDIO_EXTS.join(" ") ~ ") with stim-offline.\n",
                opt.options);
            return opt.helpWanted ? 0 : 1;
        }
        if (smoothFrames < 0)
        {
            stderr.writeln("--smooth-frames can't be negative");
            return 1;
        }
        if (!exe.exists)
        {
            stderr.writeln("stim-offline not found: ", exe);
            return 1;
        }
        jobsN = max(1, jobsN);
        root  = root.absolutePath.buildNormalizedPath;
        mkdirRecurse(root);
        version (Windows)
        {
            HANDLE lock = lockRoot(root);
            if (lock == INVALID_HANDLE_VALUE)
            {
                stderr.writeln("another stim-batch is already writing to ", root);
                return 1;
            }
            scope (exit) CloseHandle(lock);
        }
        else version (Posix)
        {
            immutable int lock = lockRoot(root);
            if (lock < 0)
            {
                stderr.writeln("another stim-batch is already writing to ", root);
                return 1;
            }
            scope (exit) close(lock);
        }

        immutable string logDir = buildPath(tempDir, format("stim-batch-%d", thisProcessID));
        mkdirRecurse(logDir);
        scope (exit) tryRemoveDir(logDir);

        auto jobs = assignOutputs(findAudio(args[1 .. $]), root);
        size_t[] todo;
        foreach (i, ref j; jobs)
        {
            if (skip && upToDate(j, !noPng))
                j.status = "skipped";
            else
                todo ~= i;
        }
        writefln("%d files, %d to analyse, %d skipped | %d at once | out: %s",
                 jobs.length, todo.length, jobs.length - todo.length, jobsN, root);

        immutable string manifestPath = buildPath(root, "manifest.csv");
        auto rows = loadManifest(manifestPath);
        foreach (ref j; jobs)
            if (j.status == "skipped") record(rows, j, root, noPng, smoothFrames, timestamp());

        immutable int width = cast(int) todo.length.to!string.length;
        immutable startAll = MonoTime.currTime;
        size_t next, done, sinceSave;
        int[string] tally;
        Running[] running;

        while (next < todo.length || running.length)
        {
            while (running.length < jobsN && next < todo.length)
            {
                immutable size_t idx = todo[next++];
                try
                    running ~= launch(idx, jobs[idx], exe, noPng, smoothFrames, logDir);
                catch (Exception e)
                {
                    jobs[idx].status  = "failed";
                    jobs[idx].message = "could not start: " ~ e.msg;
                    ++done; ++tally["failed"];
                    writefln("[%*d/%d] failed           %s\n    %s", width, done,
                             todo.length, jobs[idx].label, jobs[idx].message);
                    record(rows, jobs[idx], root, noPng, smoothFrames, timestamp());
                }
            }

            bool progressed = false;
            for (size_t k = 0; k < running.length; )
            {
                auto w = tryWait(running[k].pid);
                bool timedOut = false;
                int  code = w.status;
                if (!w.terminated)
                {
                    if (timeout <= 0 || MonoTime.currTime - running[k].started < timeout.seconds)
                    {
                        ++k;
                        continue;
                    }
                    kill(running[k].pid);
                    code = wait(running[k].pid);
                    timedOut = true;
                }

                auto j = &jobs[running[k].job];
                finish(*j, running[k], code, timedOut);
                ++done; ++tally[j.status];
                writefln("[%*d/%d] %-7s %6.1f s  %s", width, done, todo.length,
                         j.status, j.runSeconds, j.label);
                if (j.status != "ok" && j.message.length)
                    writeln("    ", j.message);
                record(rows, *j, root, noPng, smoothFrames, timestamp());
                if (++sinceSave >= 20)
                {
                    saveManifest(rows, manifestPath);
                    sinceSave = 0;
                }

                running[k] = running[$ - 1];
                running.length--;
                progressed = true;
            }
            if (!progressed)
                Thread.sleep(50.msecs);
        }

        saveManifest(rows, manifestPath);
        immutable double total = (MonoTime.currTime - startAll).total!"msecs" / 1000.0;
        writefln("\ndone in %.1f s: %d ok, %d failed, %d timed out, %d skipped",
                 total, tally.get("ok", 0), tally.get("failed", 0),
                 tally.get("timeout", 0), jobs.length - todo.length);
        writeln("manifest: ", manifestPath);
        return tally.get("failed", 0) + tally.get("timeout", 0) == 0 ? 0 : 1;
    }
    catch (Exception e)
    {
        stderr.writeln("error: ", e.msg);
        return 1;
    }
}
