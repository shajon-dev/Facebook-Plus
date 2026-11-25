#import "FBPTrace.h"

#import <fcntl.h>
#import <os/lock.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

// The tweak version is injected at build time (-DFBP_VERSION in the Makefile),
// so it is never hardcoded here.
#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

#pragma mark - Line format

//     [HH:mm | dd/MM/yy] [+] [tag] message
//
// localtime_r and snprintf rather than NSDateFormatter: this runs on layout and
// download paths where a formatter's locale work would show up.
static NSString *FBPLogStamp(void) {
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);

    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d:%02d | %02d/%02d/%02d",
             parts.tm_hour, parts.tm_min,
             parts.tm_mday, parts.tm_mon + 1, (parts.tm_year + 1900) % 100);
    return @(stamp);
}

static BOOL FBPTraceIsExtension(void);

// The one place the line format lives. The tag bracket is dropped when tag is
// nil, so a raw line reads as plain text.
//
// Lines written from the notification extension carry an extra [NSE] marker.
// The app and the extension append to one shared file, and when the question is
// "did the extension run at all" a line that cannot say which process wrote it
// is worthless. The app's own lines are left exactly as they were.
static NSString *FBPLogFormatLine(BOOL ok, NSString *_Nullable tag, NSString *message) {
    NSString *process = FBPTraceIsExtension() ? @"[NSE] " : @"";
    if (tag.length) {
        return [NSString stringWithFormat:@"[%@] [%@] %@[%@] %@",
                                          FBPLogStamp(), ok ? @"+" : @"-", process, tag, message];
    }
    return [NSString stringWithFormat:@"[%@] [%@] %@%@",
                                      FBPLogStamp(), ok ? @"+" : @"-", process, message];
}

#pragma mark - The log handle

os_log_t FBPTraceLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.shajon.fbplus", "tweak");
    });
    return log;
}

#pragma mark - Settings read directly from the preferences suite

// Read straight from the defaults suite (never through FBPPrefs/UIKit) so this
// file stays Foundation-only. Mirrors kSuiteName and the FBPKeyLogs* constants.
static NSString *const kFBPTraceSuite     = @"com.shajon.fbplus";
static NSString *const kFBPTraceKeepKey   = @"logsKeep";
// The last-clear date used to live in this suite under "logsLastClear". It is a
// file beside the log now (FBPLogWindowStampPath): it has to be read at the
// moment the record is created, and reading a defaults suite there would run the
// tweak's own suite hook, which logs. A stale "logsLastClear" left in anyone's
// defaults is harmless and nothing reads it.

// On by default: the log is kept across launches unless the user turns it off.
//
// READ ONCE, AND NEVER WHILE HOLDING A LOCK.
//
// Building an NSUserDefaults for a suite runs the tweak's own
// -_initWithSuiteName:container: hook, whose resolver emits a diagnostic line
// when it settles on a container — and emitting a line comes back into
// FBPLogRecord, which takes gFBPLogLock, and into FBPLogMirrorToFile, which
// takes gFBPTraceFileLock. This used to be read from inside
// FBPTraceOpenFileLocked, i.e. with **both** of those held, and os_unfair_lock
// is not recursive: the only reason it never deadlocked is that FBPTracePath()
// happens to resolve the container earlier in the same call, which leaves the
// resolver cached and quiet. That ordering is incidental, not guaranteed:
// anything that logged before the path resolved would have deadlocked.
//
// So the value is primed once, from the one place that runs before any lock is
// taken, and every locked caller reads the cached copy.
static BOOL gFBPLogsKeep = YES;
static BOOL gFBPLogsKeepPrimed = NO;

static void FBPLogsPrimeKeepPreference(void) {
    if (gFBPLogsKeepPrimed) return;

    // Same reentrancy guard as FBPTracePath, for the same reason: the read can
    // log, and that log would prime again. One line keeping the default is a
    // acceptable cost of not recursing.
    static _Thread_local BOOL priming = NO;
    if (priming) return;

    priming = YES;
    id value = [[[NSUserDefaults alloc] initWithSuiteName:kFBPTraceSuite]
                   objectForKey:kFBPTraceKeepKey];
    priming = NO;

    // Two threads racing here compute the same answer, so no lock is needed.
    gFBPLogsKeep = value ? [value boolValue] : YES;
    gFBPLogsKeepPrimed = YES;
}

static BOOL FBPLogsKeepAcrossLaunches(void) {
    return gFBPLogsKeep;
}

#pragma mark - The file mirror

// Reading os_log back off an iPhone needs usbmux, which a network-only setup
// does not have; a root shell can `cat` this file instead. Under the app's
// Caches directory, truncated once at first use this launch, so it never needs
// rotation. All file I/O is wrapped so a failure stays silent and the
// in-memory record keeps working.
static int gFBPTraceFD = -1;
static os_unfair_lock gFBPTraceFileLock = OS_UNFAIR_LOCK_INIT;

// YES inside an app extension. The notification extension is a separate process
// with its own containers and its own copy of this file, so its lines have to be
// distinguishable from the app's in a log both of them write.
static BOOL FBPTraceIsExtension(void) {
    static BOOL isExtension;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isExtension = [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"];
    });
    return isExtension;
}

// The log lives in the **shared App-Group container** whenever there is one, so
// the app and the notification extension append to the same file and the Logs
// page shows both. That matters because the extension is the half nobody can
// see: it is not attached to a debugger, it runs for a few hundred milliseconds,
// and on a re-signed build reading os_log off the device needs usbmux.
//
// -containerURLForSecurityApplicationGroupIdentifier: is the right way to ask
// even though a re-signed build does not hold the Meta group: SideloadFix.xm in
// the app and FBPNotifyBridge.mm in the extension both hook that selector and
// answer with the signer's container, and both resolve the *same* one. On
// TrollStore and jailbroken installs the group is real and the call answers with
// Meta's own container, which is equally shared. Either way both processes land
// on one file.
//
// Falls back to the process's own Caches directory, which is what an install
// with no usable App Group gets — then the app still logs, the extension still
// logs, and the two simply do not meet.
// Resolved on first use and **cached only once the shared container answers**,
// never on the fallback.
//
// dispatch_once here would be a bug, and the same bug this project has already
// had to fix twice: getAppGroupPathIfExists() used to cache a failed lookup
// forever, and so did the keychain access-group probe. The first line written in
// a process is the launch trace, which runs very early — early enough that
// LSBundleProxy may not have answered yet. Caching the Caches fallback at that
// moment would send the rest of the process's lines to a private directory, and
// the extension's lines would then never reach the app's log at all, which is
// the one thing this move was for.
//
// So: a failed resolve returns the fallback for that line and is retried on the
// next one. The log file mirror is opened once (FBPTraceOpenFile), so in the
// worst case a handful of launch lines land in Caches before the shared path
// takes over — acceptable, where a permanently wrong path is not.
static NSString *gFBPTraceResolvedPath;
static os_unfair_lock gFBPTracePathLock = OS_UNFAIR_LOCK_INIT;

// The process's own Caches directory. Always available, never shared.
static NSString *FBPTraceFallbackPath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return caches.length ? [caches stringByAppendingPathComponent:@"facebook-plus-trace.log"]
                         : nil;
}

static NSString *FBPTracePath(void) {
    os_unfair_lock_lock(&gFBPTracePathLock);
    NSString *resolved = gFBPTraceResolvedPath;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    if (resolved) return resolved;

    // THE REENTRANCY GUARD IS NOT OPTIONAL.
    //
    // Asking NSFileManager for the App-Group container runs the tweak's own
    // redirect hook, whose resolver (Paths.mm) emits a diagnostic line when it
    // settles on a container — and emitting a line comes straight back here.
    // That is unbounded recursion and a stack overflow on the first line a
    // process logs, which is exactly how this crashed the app on device.
    //
    // Guarded, the inner call falls back to Caches for that one line while the
    // outer call completes and caches the shared path, so every line after it
    // lands in the shared file. One stray line in a private directory is a fair
    // price; a recursive crash is not.
    static _Thread_local BOOL resolving = NO;
    if (resolving) return FBPTraceFallbackPath();

    resolving = YES;
    NSURL *shared = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:@"group.com.facebook.Facebook"];
    resolving = NO;

    if (!shared.path.length) return FBPTraceFallbackPath();

    [NSFileManager.defaultManager createDirectoryAtURL:shared
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    NSString *path = [shared.path stringByAppendingPathComponent:@"facebook-plus-trace.log"];

    // Cached only on success, and only once: two threads racing here must not
    // both publish, because the descriptor is keyed off this exact string.
    os_unfair_lock_lock(&gFBPTracePathLock);
    if (!gFBPTraceResolvedPath) gFBPTraceResolvedPath = [path copy];
    NSString *result = gFBPTraceResolvedPath;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return result;
}

// The resolved path if one is already cached, otherwise the private fallback —
// and never a resolve, so this cannot run the App-Group redirect hook and
// cannot log. **Everything that runs while holding a lock must use this one.**
// FBPTracePath() may call into tweak code that logs, and logging takes both of
// this file's locks; os_unfair_lock is not recursive, so resolving under either
// one deadlocks the process.
static NSString *FBPTracePathNoResolve(void) {
    os_unfair_lock_lock(&gFBPTracePathLock);
    NSString *resolved = gFBPTraceResolvedPath;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return resolved ?: FBPTraceFallbackPath();
}

// Which file this process is actually writing to, and whether it is the shared
// one. Reported into the log itself at launch, so a capture never leaves anyone
// guessing whether the extension's lines could have arrived — the question that
// cost an hour of pulling containers off a device with devicectl.
NSString *FBPTraceFilePath(void) {
    return FBPTracePath() ?: @"(none)";
}

BOOL FBPTraceFileIsShared(void) {
    // Read under the lock like every other access to it: the resolver publishes
    // this from whichever thread logs first, and an unsynchronised read of a
    // variable another thread is publishing is a data race whatever the
    // architecture makes of it in practice.
    os_unfair_lock_lock(&gFBPTracePathLock);
    BOOL shared = gFBPTraceResolvedPath != nil;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return shared;
}

// Opens the mirror, and re-opens it once if the path has since improved from the
// private fallback to the shared container (see FBPTracePath). Without that
// re-open an early launch line would pin the descriptor to the wrong file for
// the rest of the process.
static NSString *gFBPTraceOpenedPath;

// Opens the mirror, re-opening it once if the path has improved from the private
// fallback to the shared container. Call with gFBPTraceFileLock held: the
// descriptor, the path it belongs to and the write all have to move together,
// or one thread closes the file another is mid-write on.
static void FBPTraceOpenFileLocked(NSString *path) {
    if (!path.length) return;
    if (gFBPTraceFD >= 0 && [gFBPTraceOpenedPath isEqualToString:path]) return;

    // Append when the log is kept across launches; otherwise start fresh each
    // launch. The daily auto-clear and the Clear action truncate it. A re-open
    // always appends, so the handful of lines written before the shared path
    // resolved are not what truncates it.
    BOOL reopening = gFBPTraceFD >= 0;
    int flags = O_WRONLY | O_CREAT |
                ((FBPLogsKeepAcrossLaunches() || reopening) ? O_APPEND : O_TRUNC);
    int fd = open(path.fileSystemRepresentation, flags, 0644);
    if (fd < 0) return;

    NSString *previous = gFBPTraceOpenedPath;
    if (reopening) close(gFBPTraceFD);
    gFBPTraceFD = fd;
    gFBPTraceOpenedPath = [path copy];

    // MOVE WHAT THE FALLBACK ALREADY HOLDS INTO THE SHARED FILE.
    //
    // This is what made every constructor line invisible. The App-Group path
    // resolves lazily — it has to, LSBundleProxy is not always ready that early
    // — so the first lines a process writes land in the private Caches file,
    // and the descriptor only moves to the shared file once the path improves.
    // The export, meanwhile, reads the *shared* file and replaces the in-memory
    // record with it (FBPLogReloadIfChangedLocked), so those early lines were
    // not merely in the wrong file: they were deleted from the record that had
    // them. Three device exports in a row began mid-startup for this reason,
    // with no "launch ·" line in any of them.
    //
    // Carrying the fallback's contents across on the one re-open fixes it at
    // the source, and makes the replace-on-reload correct rather than lossy. It
    // is a few launch lines, read and appended once per process.
    if (reopening && previous.length && [previous isEqualToString:FBPTraceFallbackPath()]) {
        NSData *carried = [NSData dataWithContentsOfFile:previous];
        if (carried.length) {
            const char *bytes = carried.bytes;
            size_t remaining = carried.length;
            while (remaining > 0) {
                ssize_t written = write(fd, bytes, remaining);
                if (written <= 0) break;
                bytes += written;
                remaining -= (size_t)written;
            }
        }
        // Truncated, not deleted: the path stays valid for any line that still
        // races in before the resolve completes, and nothing is carried twice.
        (void)truncate(previous.fileSystemRepresentation, 0);
    }
}

// Writes one already-formatted line to the file mirror.
static void FBPLogMirrorToFile(NSString *line) {
    // Never resolves: this runs under gFBPLogLock (FBPLogRecord flushes the
    // pending line while holding it), and resolving there would re-enter
    // FBPLogRecord through the redirect hook's own logging and deadlock.
    // FBPLogRecord has already resolved the path before locking.
    NSString *path = FBPTracePathNoResolve();
    if (!path.length) return;

    NSString *withNewline = [line stringByAppendingString:@"\n"];
    const char *bytes = withNewline.UTF8String;
    if (!bytes) return;
    size_t remaining = strlen(bytes);

    os_unfair_lock_lock(&gFBPTraceFileLock);
    FBPTraceOpenFileLocked(path);
    while (gFBPTraceFD >= 0 && remaining > 0) {
        ssize_t written = write(gFBPTraceFD, bytes, remaining);
        if (written <= 0) break;   // A failed mirror must not stall a hook.
        bytes += written;
        remaining -= (size_t)written;
    }
    os_unfair_lock_unlock(&gFBPTraceFileLock);
}

#pragma mark - The record

// Held in memory rather than read back from the mirror, which depends on a
// writable path not every install has.
//
// The record is bounded, oldest out first. It used to be uncapped, on the
// grounds that consecutive repeats collapse into one "… xN" entry (see
// FBPLogRecord) so no single chatty call site can grow it. True, and not
// enough: the collapse only folds **consecutive** repeats, so call sites that
// alternate defeat it completely. A device export from 2026-11-21 filled 4,000
// lines in one minute with five "gate installed" lines cycling, and everything
// worth reading had already been pushed out of it.
//
// That spam is fixed where it belonged — those reports were sitting next to
// their FBP_ONCE install instead of inside it, and now use FBPLogOnce — so this
// ceiling is a backstop rather than the answer. It is set high enough to hold a
// long session's real lines and low enough to stay bounded in the notification
// extension, which has about 24 MB to live in.
//
// Reaching it EMPTIES the record rather than dropping the oldest lines.
//
// A sliding window sounds kinder and reads worse. What overruns this ceiling is
// never steady traffic, it is a flood — and a window hands back ten thousand
// lines of the flood with everything that explains it already pushed out of the
// front. A device export from 2026-11-21 is exactly that: 9,171 of its 10,000
// lines are five install reports cycling, and not one line survives from the
// session the person actually wanted to ask about. Starting again keeps the
// lines written after the flood, which are the ones nobody has read yet.
static const NSUInteger kFBPLogMaxLines = 10000;

/// How long a log is kept before it starts again: twelve hours.
///
/// Measured from the epoch rather than from the first launch, so the boundaries
/// are 00:00 and 12:00 UTC and every device turns over at the same two moments.
/// A window that started when the app did would drift with every relaunch, and
/// two exports taken an hour apart could cover wildly different spans.
static const time_t kFBPLogWindow = 12 * 60 * 60;

// Whether the window rolled over since the last clear, decided WITHOUT
// NSUserDefaults — the stamp is kept in a small file beside the log, read and
// written with POSIX calls. Defaults would mean the suite hook, and the suite
// hook logs; this runs while the record is being created, which is the one
// moment logging cannot be allowed to re-enter.
static NSString *FBPLogWindowStampPath(NSString *logPath) {
    return logPath.length ? [logPath stringByAppendingPathExtension:@"window"] : nil;
}

/// Which twelve-hour window we are in, as a decimal string.
static NSString *FBPLogWindowStamp(void) {
    long long window = (long long)(time(NULL) / kFBPLogWindow);
    return [NSString stringWithFormat:@"%lld", window];
}

// YES when the kept log belongs to an earlier window. Writes this window's
// stamp as it goes, so it answers YES exactly once per window per device.
static BOOL FBPLogWindowRolledOver(NSString *logPath) {
    NSString *stampPath = FBPLogWindowStampPath(logPath);
    if (!stampPath.length) return NO;

    NSString *current = FBPLogWindowStamp();

    char buffer[32] = {0};
    int fd = open(stampPath.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        ssize_t read_bytes = read(fd, buffer, sizeof(buffer) - 1);
        close(fd);
        if (read_bytes > 0 && strcmp(buffer, current.UTF8String) == 0) return NO;
    }

    fd = open(stampPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *bytes = current.UTF8String;
        if (bytes) (void)!write(fd, bytes, strlen(bytes));
        close(fd);
    }

    // The calendar-day stamp this replaced, removed so it does not sit in the
    // container forever. Harmless if it was never there.
    NSString *retired = logPath.length ? [logPath stringByAppendingPathExtension:@"day"] : nil;
    if (retired.length) (void)unlink(retired.fileSystemRepresentation);

    return YES;
}

static NSMutableArray<NSString *> *FBPLogLines(void) {
    static NSMutableArray<NSString *> *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = [NSMutableArray array];

        NSString *path = FBPTracePathNoResolve();

        // THE TWELVE-HOURLY CLEAR HAPPENS HERE, BEFORE THE FIRST LINE EXISTS.
        //
        // It used to be driven by FBPLogClearIfDue() from FBPEntry's
        // constructor, which looked like "at launch" and is not: constructors do
        // not all run before that one, so the clear landed in the middle of
        // startup and wiped everything already recorded. A device export from
        // 2026-11-21 contains not one line written by any constructor in the
        // tweak — not the keychain access group, not the notification hooks'
        // install summaries, not even FBPEntry's own "launch ·" line. Every
        // debugging session that asked "did this hook install?" was reading a
        // log the answer had been deleted from.
        //
        // Doing it as the record is created makes "once a window, before
        // anything is logged" literally true, and leaves nothing to wipe
        // afterwards.
        if (FBPLogWindowRolledOver(path)) {
            if (path.length) (void)truncate(path.fileSystemRepresentation, 0);
        } else if (FBPLogsKeepAcrossLaunches()) {
            // Kept across launches: seed the record from last launch's file so
            // the count and the export carry the history forward.
            NSString *existing = path.length ? [NSString stringWithContentsOfFile:path
                                                                         encoding:NSUTF8StringEncoding
                                                                            error:nil]
                                             : nil;
            for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
                if (line.length) [lines addObject:line];
            }
            // At the ceiling the kept log starts again, here as everywhere
            // else. Done inline rather than through FBPLogClearLocked(),
            // which would call back into this dispatch_once and deadlock.
            if (lines.count >= kFBPLogMaxLines) {
                [lines removeAllObjects];
                if (path.length) (void)truncate(path.fileSystemRepresentation, 0);
            }
        }
    });
    return lines;
}

static os_unfair_lock gFBPLogLock = OS_UNFAIR_LOCK_INIT;

// Pull the notification extension's lines in before anyone reads the record.
//
// The in-memory record only ever holds what *this* process wrote plus whatever
// was seeded at launch. Once the mirror lives in the shared App-Group container
// the extension is appending to it too, from its own short-lived process, and
// those lines are exactly the ones worth reading — so the count and the export
// have to come off the file rather than out of memory.
//
// Gated on the file having grown since the last read, because the Logs page
// polls the count: an unchanged log costs one stat() and nothing else. The
// record is replaced rather than appended to, which is correct because every
// line this process wrote was mirrored to that same file.
//
// Defined below, with the run-collapsing state it belongs to.
static void FBPLogFlushPendingLocked(void);
static void FBPLogClearLocked(void);

// Call with gFBPLogLock held.
static void FBPLogReloadIfChangedLocked(void) {
    static off_t lastSize = -1;

    // Send the run in progress to the file FIRST. The record is about to be
    // replaced by the file's contents, and the pending line is the one line this
    // process has written that is NOT in the file yet — so without this the
    // newest line disappeared from the count and from the export every time a
    // reload ran. The comment below about "every line this process wrote was
    // mirrored to that same file" was true of every line except the newest one.
    FBPLogFlushPendingLocked();

    NSString *path = FBPTracePathNoResolve();
    if (!path.length) return;

    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0) return;
    if (info.st_size == lastSize) return;
    lastSize = info.st_size;

    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (!contents) return;   // A torn read mid-append: keep what we have.

    NSMutableArray<NSString *> *fromFile = [NSMutableArray array];
    for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
        if (line.length) [fromFile addObject:line];
    }

    // A line this process holds but the file does not is KEPT, not dropped.
    //
    // The record used to be replaced outright, on the stated grounds that every
    // line this process wrote was already in this file. That was not true, and
    // a replace therefore deleted evidence: a line written before the shared
    // path resolved went to the private fallback file (now carried across in
    // FBPTraceOpenFileLocked), and the run in progress is not in any file until
    // it is flushed (now flushed above). Both are fixed at the source; this
    // keeps the record honest even if a third way to miss the file turns up,
    // because losing a line someone is trying to read is the worst outcome
    // available here.
    //
    // Anything missing is by construction older than what the file holds — it
    // was written before the file could take it — so it goes in front.
    NSMutableArray<NSString *> *lines = FBPLogLines();
    NSSet<NSString *> *known = [NSSet setWithArray:fromFile];
    NSMutableArray<NSString *> *onlyInMemory = [NSMutableArray array];
    for (NSString *line in lines) {
        if (![known containsObject:line]) [onlyInMemory addObject:line];
    }

    [lines setArray:onlyInMemory];
    [lines addObjectsFromArray:fromFile];
    // Two processes writing one file can cross the ceiling here rather than at
    // the call that recorded the last line, so the same rule applies: start
    // again. The extension's lines count towards it exactly like the app's.
    if (lines.count >= kFBPLogMaxLines) FBPLogClearLocked();
}

// A run of consecutive identical lines (same ok / tag / message) collapses to one
// entry with a count — "… x12" — instead of flooding the record. The in-memory
// entry is rewritten in place as the count climbs; os_log and the file mirror
// cannot rewrite what they have already emitted, so they lag by one run — a line
// goes out when the next different line arrives (FBPLogFlushPendingLocked). This
// is what keeps a chatty call site (an appearance snapshot that repeats on every
// layout, say) from evicting every other line out of the capped record.
static BOOL gFBPRunOK = NO;
static NSString *gFBPRunTag = nil;
static NSString *gFBPRunMessage = nil;
static NSString *gFBPPendingLine = nil;   // the run's line, not yet sent downstream
static NSUInteger gFBPRepeatCount = 0;

static NSString *FBPLineWithCount(NSString *base, NSUInteger count) {
    return count > 1 ? [NSString stringWithFormat:@"%@ x%lu", base, (unsigned long)count]
                     : base;
}

// Emits the finished run to os_log and the file, then ends it. Caller holds
// gFBPLogLock. Ending the run matters: a repeat arriving after a flush must start
// a fresh line rather than keep counting into one already written out.
static void FBPLogFlushPendingLocked(void) {
    if (!gFBPPendingLine) return;
    NSString *out = FBPLineWithCount(gFBPPendingLine, gFBPRepeatCount);
    gFBPPendingLine = nil;
    gFBPRunTag = nil;
    gFBPRunMessage = nil;
    gFBPRepeatCount = 0;

    os_log(FBPTraceLog(), "%{public}s", out.UTF8String);
    FBPLogMirrorToFile(out);
}

// A process's LAST line would otherwise never be written anywhere. The run
// in progress is only sent to os_log and the file when a *different* line
// arrives, so whatever a process logs last stays pending until it exits —
// and for the notification extension, which lives a few hundred milliseconds
// and writes a handful of lines, "the last line" is most of the evidence. An
// exit handler flushes it, which costs nothing in the app and is the whole
// difference in the extension.
static void FBPLogFlushAtExit(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    FBPLogFlushPendingLocked();
    os_unfair_lock_unlock(&gFBPLogLock);
}

void FBPLogRecord(BOOL ok, NSString *_Nullable tag, NSString *message) {
    if (!message.length) return;

    // Resolve the log's path here, in the one funnel every line passes through,
    // and before any lock is taken. Resolving runs the App-Group redirect hook,
    // which is tweak code that logs — so it has to happen where re-entering
    // this function is harmless. Everything downstream then reads the cached
    // value through FBPTracePathNoResolve() and never touches the hook again.
    (void)FBPTracePath();

    // Both of these also have to happen before the lock: the preference read can
    // log (see FBPLogsPrimeKeepPreference), and every locked path below reads the
    // cached copy instead of calling out.
    FBPLogsPrimeKeepPreference();

    static dispatch_once_t exitOnce;
    dispatch_once(&exitOnce, ^{
        atexit(FBPLogFlushAtExit);
    });

    os_unfair_lock_lock(&gFBPLogLock);
    NSMutableArray<NSString *> *lines = FBPLogLines();

    BOOL sameAsRun = gFBPPendingLine != nil &&
                     ok == gFBPRunOK &&
                     ((tag == nil && gFBPRunTag == nil) ||
                      [tag isEqualToString:gFBPRunTag]) &&
                     [message isEqualToString:gFBPRunMessage];

    if (sameAsRun && lines.count > 0) {
        gFBPRepeatCount++;
        // Rewritten with the new count, keeping the timestamp the run started at.
        lines[lines.count - 1] = FBPLineWithCount(gFBPPendingLine, gFBPRepeatCount);
        os_unfair_lock_unlock(&gFBPLogLock);
        return;
    }

    // A different line: close out the previous run (to os_log + file), then begin a
    // new one. The new line is itself only sent downstream once it, too, ends.
    FBPLogFlushPendingLocked();

    NSString *line = FBPLogFormatLine(ok, tag, message);
    gFBPRunOK = ok;
    gFBPRunTag = [tag copy];
    gFBPRunMessage = [message copy];
    gFBPPendingLine = line;
    gFBPRepeatCount = 1;

    [lines addObject:line];

    // The ceiling — see kFBPLogMaxLines. The record starts again rather than
    // sliding, and says so in its first line, because a log that silently went
    // short reads like logging broke.
    if (lines.count >= kFBPLogMaxLines) {
        FBPLogClearLocked();
        NSString *reason =
            [NSString stringWithFormat:@"log cleared: reached %lu lines",
                                       (unsigned long)kFBPLogMaxLines];
        gFBPRunOK = YES;
        gFBPRunTag = nil;
        gFBPRunMessage = [reason copy];
        gFBPPendingLine = FBPLogFormatLine(YES, nil, reason);
        gFBPRepeatCount = 1;
        [lines addObject:gFBPPendingLine];
    }
    os_unfair_lock_unlock(&gFBPLogLock);
}

void FBPTraceEmit(NSString *line) {
    if (!line.length) return;
    FBPLogRecord(YES, nil, line);
}

NSUInteger FBPLogLineCount(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    FBPLogReloadIfChangedLocked();
    NSUInteger count = FBPLogLines().count;
    os_unfair_lock_unlock(&gFBPLogLock);
    return count;
}

// Empties the file mirror, so a kept-across-launches log does not bring the
// cleared lines back and an export right after a clear is empty.
static void FBPLogEmptyFileMirror(void) {
    os_unfair_lock_lock(&gFBPTraceFileLock);
    if (gFBPTraceFD >= 0) {
        if (ftruncate(gFBPTraceFD, 0) == 0) lseek(gFBPTraceFD, 0, SEEK_SET);
    } else {
        NSString *path = FBPTracePathNoResolve();
        if (path.length) [[NSData data] writeToFile:path atomically:YES];
    }
    os_unfair_lock_unlock(&gFBPTraceFileLock);
}

// The clear itself. Call with gFBPLogLock held.
//
// Taking the file lock inside the record lock is the order the rest of this
// file already uses — FBPLogFlushPendingLocked writes the mirror while holding
// the record lock — so nothing new can deadlock here.
static void FBPLogClearLocked(void) {
    [FBPLogLines() removeAllObjects];
    // End any run in progress so a repeat after the clear starts a fresh line
    // rather than counting into one that no longer exists.
    gFBPPendingLine = nil;
    gFBPRunTag = nil;
    gFBPRunMessage = nil;
    gFBPRepeatCount = 0;
    FBPLogEmptyFileMirror();
}

void FBPLogClear(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    FBPLogClearLocked();
    os_unfair_lock_unlock(&gFBPLogLock);
}

// Clears the log once every twelve hours, on the first call after the window
// turns over. Call at launch; a call inside the same window returns at once.
void FBPLogClearIfDue(void) {
    // The clear itself now happens where the record is created, which is the
    // only place that is genuinely "before anything is logged" — see the long
    // note in FBPLogLines(). Calling this from a constructor, as FBPEntry does,
    // used to wipe whatever earlier constructors had already recorded, because
    // constructor order is not something a call site can choose.
    //
    // The call is kept and still does the right thing: touching the record is
    // what runs the window check, so a launch that reaches here has had its
    // clear decided exactly once. Priming first keeps the preference read out
    // of the locked path.
    FBPLogsPrimeKeepPreference();

    os_unfair_lock_lock(&gFBPLogLock);
    (void)FBPLogLines();
    os_unfair_lock_unlock(&gFBPLogLock);
}

#pragma mark - Feature diagnostics

void FBPDiag(NSString *feature, NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FBPLogRecord(YES, feature, msg);
}

void FBPDiagFail(NSString *feature, NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FBPLogRecord(NO, feature, msg);
}

#pragma mark - Fire accounting

void FBPTraceDidFire(const char *name) {
    if (!name) return;
    FBPLogRecord(YES, @"fire", @(name));
}

#pragma mark - Device information

// The hardware identifier, e.g. "iPhone17,2". On the Simulator sysctl reports
// the host architecture, so the identifier comes from the environment there.
static NSString *FBPDeviceIdentifier(void) {
    NSString *simulated =
        NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
    if (simulated.length) return simulated;

    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *value = (char *)malloc(size);
    if (!value) return nil;
    NSString *result = nil;
    if (sysctlbyname("hw.machine", value, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:value];
    }
    free(value);
    return result;
}

static NSString *gFBPDeviceName = nil;   // resolved from ipsw.me, or the disk cache
static os_unfair_lock gFBPDeviceNameLock = OS_UNFAIR_LOCK_INIT;

// The public ipsw.me device list; the entry whose "identifier" matches this
// hardware carries the marketing "name".
static NSString *const kFBPDeviceListURL = @"https://api.ipsw.me/v4/devices";

// On-disk cache, so the request happens once per device and an offline phone
// keeps the name it learned earlier.
static NSString *_Nullable FBPDeviceNameCachePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    NSString *dir = [support stringByAppendingPathComponent:@"FacebookPlus"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"device-name.txt"];
}

static void FBPSetResolvedDeviceName(NSString *name) {
    if (!name.length) return;
    os_unfair_lock_lock(&gFBPDeviceNameLock);
    gFBPDeviceName = [name copy];
    os_unfair_lock_unlock(&gFBPDeviceNameLock);
    NSString *path = FBPDeviceNameCachePath();
    if (path) [name writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Resolves the marketing device name from the ipsw.me list by hardware
// identifier, so a model newer than this build still gets its real name and no
// device table need ship in the binary. Runs once; the disk cache short-circuits
// the request, and until it resolves (or if it fails, or offline) the built-in
// map and then the raw identifier stand in. Only the hardware identifier
// (e.g. iPhone15,3) leaves the device — never UIDevice.name, which usually holds
// the owner's own name.
void FBPResolveDeviceName(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *identifier = FBPDeviceIdentifier();
        if (!identifier.length) return;

        NSString *path = FBPDeviceNameCachePath();
        NSString *cached = path ? [[NSString stringWithContentsOfFile:path
                                                             encoding:NSUTF8StringEncoding
                                                                error:nil]
                                      stringByTrimmingCharactersInSet:
                                          NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                : nil;
        if (cached.length) {
            os_unfair_lock_lock(&gFBPDeviceNameLock);
            gFBPDeviceName = cached;
            os_unfair_lock_unlock(&gFBPDeviceNameLock);
            return;
        }

        NSURLSessionConfiguration *cfg =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.timeoutIntervalForRequest = 20;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        [[session dataTaskWithURL:[NSURL URLWithString:kFBPDeviceListURL]
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            if (error || !data.length) {
                FBPDiagFail(@"trace", @"device list unreachable (%@) — naming the device by "
                                      @"its identifier",
                            error.localizedDescription ?: @"empty response");
                return;
            }
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![parsed isKindOfClass:NSArray.class]) {
                FBPDiagFail(@"trace", @"device list was not the expected array");
                return;
            }
            for (id entry in (NSArray *)parsed) {
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                id entryId = entry[@"identifier"];
                if (![entryId isKindOfClass:NSString.class] ||
                    ![entryId isEqualToString:identifier]) continue;
                id name = entry[@"name"];
                if ([name isKindOfClass:NSString.class] && [name length]) {
                    FBPSetResolvedDeviceName(name);
                    FBPDiag(@"trace", @"device resolved %@ -> %@", identifier, name);
                }
                return;
            }
            FBPDiagFail(@"trace", @"device list has no entry for %@", identifier);
        }] resume];
    });
}

// The resolved ipsw.me name once known; until then (or offline) the raw
// hardware identifier, so it is never empty.
NSString *FBPDeviceDisplayName(void) {
    FBPResolveDeviceName();
    os_unfair_lock_lock(&gFBPDeviceNameLock);
    NSString *resolved = gFBPDeviceName;
    os_unfair_lock_unlock(&gFBPDeviceNameLock);
    if (resolved.length) return resolved;
    return FBPDeviceIdentifier() ?: @"Unknown device";
}

#pragma mark - Export

static NSString *FBPLogHeader(NSUInteger lineCount) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;

    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"exported",      FBPLogStamp() ],
        @[ @"tweak_version", FBP_VERSION ],
        @[ @"device_name",   FBPDeviceDisplayName() ],
        @[ @"ios_version",   [NSString stringWithFormat:@"%ld.%ld.%ld",
                              (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion] ],
        @[ @"log_lines",     [NSString stringWithFormat:@"%lu", (unsigned long)lineCount] ],
        // Where this export came from, and whether the notification extension
        // could have reached it. Three device captures were read without this,
        // and every question they raised — are the extension's lines here, did
        // the early lines land somewhere else — needed exactly these two facts
        // and could not be answered from the file. The header is built outside
        // both locks, so asking is safe here and nowhere inside the funnel.
        @[ @"trace_file",    FBPTraceFilePath() ],
        @[ @"trace_shared",  FBPTraceFileIsShared() ? @"yes (app and extension share it)"
                                                    : @"NO (private Caches — extension lines cannot arrive)" ],
    ];

    NSMutableString *text = [NSMutableString stringWithString:@"Facebook Plus log\n\n"];
    for (NSArray<NSString *> *row in rows) {
        [text appendFormat:@"%-14s ---->  %@\n", row[0].UTF8String, row[1]];
    }
    [text appendString:@"\n"];
    return text;
}

NSString *FBPLogExportText(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    FBPLogReloadIfChangedLocked();
    NSArray<NSString *> *snapshot = [FBPLogLines() copy];
    os_unfair_lock_unlock(&gFBPLogLock);

    NSMutableString *text = [NSMutableString stringWithString:FBPLogHeader(snapshot.count)];
    for (NSString *line in snapshot) {
        [text appendString:line];
        [text appendString:@"\n"];
    }
    return text;
}

NSURL *_Nullable FBPLogWriteExportFile(void) {
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);

    // Same stamp as a log line, with '-' where a line uses ':' and '/': a colon
    // is legal on device but renders badly in the share sheet and in receiving
    // apps.
    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d-%02d_%02d-%02d-%02d",
             parts.tm_hour, parts.tm_min,
             parts.tm_mday, parts.tm_mon + 1, (parts.tm_year + 1900) % 100);

    NSString *name = [NSString stringWithFormat:@"Facebook-Plus-%s.txt", stamp];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];

    NSError *error = nil;
    BOOL ok = [FBPLogExportText() writeToFile:path atomically:YES
                                     encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        os_log(FBPTraceLog(), "log export failed %{public}s",
               error.localizedDescription.UTF8String ?: "(unknown)");
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}
