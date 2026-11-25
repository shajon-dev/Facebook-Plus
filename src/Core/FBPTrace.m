#import "FBPTrace.h"

#import <fcntl.h>
#import <os/lock.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

#pragma mark - Line format

//     [HH:mm | dd/MM/yy] [+] [tag] message
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

// The one place the line format lives. Extension lines carry an extra [NSE]
// marker, because the app and the extension append to one shared file.
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

// READ ONCE, AND NEVER WHILE HOLDING A LOCK.
// Building an NSUserDefaults for a suite runs the tweak's own
// -_initWithSuiteName:container: hook, whose resolver logs — which re-enters
// FBPLogRecord (gFBPLogLock) and FBPLogMirrorToFile (gFBPTraceFileLock), and
// os_unfair_lock is not recursive. So the value is primed once, from the one
// place that runs before any lock is taken, and locked callers read the cache.
static BOOL gFBPLogsKeep = YES;
static BOOL gFBPLogsKeepPrimed = NO;

static void FBPLogsPrimeKeepPreference(void) {
    if (gFBPLogsKeepPrimed) return;

    // Same reentrancy guard as FBPTracePath: the read can log, and that log
    // would prime again.
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

// Every file call is wrapped: a failure stays silent and the record works on.
static int gFBPTraceFD = -1;
static os_unfair_lock gFBPTraceFileLock = OS_UNFAIR_LOCK_INIT;

// YES inside an app extension, whose lines share one file with the app's.
static BOOL FBPTraceIsExtension(void) {
    static BOOL isExtension;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isExtension = [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"];
    });
    return isExtension;
}

// The log lives in the shared App-Group container whenever there is one, so the
// app and the notification extension append to one file.
// -containerURLForSecurityApplicationGroupIdentifier: is still the right way to
// ask on a re-signed build that does not hold the real group: SideloadFix.xm in
// the app and FBPNotifyBridge.mm in the extension both hook it and answer with
// the same signer container. Where the group is genuine the call answers with
// the app's own container, equally shared. Either way both land on one file.
// CACHED ONLY ONCE THE SHARED CONTAINER ANSWERS, NEVER ON THE FALLBACK.
// dispatch_once here would be a bug: the first line a process writes runs early
// enough that LSBundleProxy may not have answered yet, so caching the Caches
// fallback at that moment would send every later line to a private directory
// and the extension's lines would never reach the app's log. A failed resolve
// returns the fallback for that line and is retried on the next one.
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

    // THE REENTRANCY GUARD IS NOT OPTIONAL. Asking NSFileManager for the
    // App-Group container runs the tweak's own redirect hook, whose resolver
    // (Paths.mm) logs — which comes straight back here. Unguarded that is
    // unbounded recursion on the first line a process logs. Guarded, the inner
    // call falls back to Caches for that one line.
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

    // Only once: the descriptor is keyed off this exact string.
    os_unfair_lock_lock(&gFBPTracePathLock);
    if (!gFBPTraceResolvedPath) gFBPTraceResolvedPath = [path copy];
    NSString *result = gFBPTraceResolvedPath;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return result;
}

// Never resolves, so it cannot run the App-Group redirect hook and cannot log.
// EVERYTHING THAT RUNS WHILE HOLDING A LOCK MUST USE THIS ONE: logging takes
// both of this file's locks and os_unfair_lock is not recursive, so resolving
// under either one deadlocks the process.
static NSString *FBPTracePathNoResolve(void) {
    os_unfair_lock_lock(&gFBPTracePathLock);
    NSString *resolved = gFBPTraceResolvedPath;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return resolved ?: FBPTraceFallbackPath();
}

NSString *FBPTraceFilePath(void) {
    return FBPTracePath() ?: @"(none)";
}

BOOL FBPTraceFileIsShared(void) {
    // Read under the lock: the resolver publishes this from whichever thread
    // logs first, so an unsynchronised read would be a data race.
    os_unfair_lock_lock(&gFBPTracePathLock);
    BOOL shared = gFBPTraceResolvedPath != nil;
    os_unfair_lock_unlock(&gFBPTracePathLock);
    return shared;
}

static NSString *gFBPTraceOpenedPath;

// Re-opens once if the path has improved from the private fallback to the
// shared container; without that an early launch line would pin the descriptor
// to the wrong file. Call with gFBPTraceFileLock held: the descriptor, its path
// and the write have to move together, or one thread closes the file another is
// mid-write on.
static void FBPTraceOpenFileLocked(NSString *path) {
    if (!path.length) return;
    if (gFBPTraceFD >= 0 && [gFBPTraceOpenedPath isEqualToString:path]) return;

    // A re-open always appends, so the lines written before the shared path
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

    // MOVE WHAT THE FALLBACK ALREADY HOLDS INTO THE SHARED FILE. The
    // App-Group path resolves lazily, so the first lines a process writes land
    // in the private Caches file, while the export reads the shared one — so
    // without this carry the early lines are lost from the record entirely.
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
        // Truncated, not deleted: the path stays valid for a line still
        // racing in, and nothing is carried twice.
        (void)truncate(previous.fileSystemRepresentation, 0);
    }
}

static void FBPLogMirrorToFile(NSString *line) {
    // Never resolves: this runs under gFBPLogLock, and resolving there would
    // re-enter FBPLogRecord through the redirect hook's own logging and
    // deadlock. FBPLogRecord resolves the path before locking.
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

// A backstop against a flood, low enough to stay bounded in the notification
// extension. Reaching it EMPTIES the record rather than dropping the oldest
// lines: what overruns this ceiling is a flood, and a sliding window would hand
// back the flood with everything that explains it already pushed out.
static const NSUInteger kFBPLogMaxLines = 10000;

/// Measured from the epoch, not from first launch, so every device turns over at
/// 00:00 and 12:00 UTC instead of drifting with each relaunch.
static const time_t kFBPLogWindow = 12 * 60 * 60;

// Decided WITHOUT NSUserDefaults — the stamp is a small file beside the log,
// read with POSIX calls. Defaults would mean the suite hook, and the suite hook
// logs; this runs while the record is being created, the one moment logging
// cannot be allowed to re-enter.
static NSString *FBPLogWindowStampPath(NSString *logPath) {
    return logPath.length ? [logPath stringByAppendingPathExtension:@"window"] : nil;
}

static NSString *FBPLogWindowStamp(void) {
    long long window = (long long)(time(NULL) / kFBPLogWindow);
    return [NSString stringWithFormat:@"%lld", window];
}

// Writes this window's stamp as it goes, so it answers YES once per window.
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
        // Driving it from a constructor is not "at launch": constructor order
        // is not a call site's to choose, so the clear would land mid-startup
        // and wipe what earlier constructors recorded.
        if (FBPLogWindowRolledOver(path)) {
            if (path.length) (void)truncate(path.fileSystemRepresentation, 0);
        } else if (FBPLogsKeepAcrossLaunches()) {
            NSString *existing = path.length ? [NSString stringWithContentsOfFile:path
                                                                         encoding:NSUTF8StringEncoding
                                                                            error:nil]
                                             : nil;
            for (NSString *line in [existing componentsSeparatedByString:@"\n"]) {
                if (line.length) [lines addObject:line];
            }
            // Inline rather than through FBPLogClearLocked(), which would
            // call back into this dispatch_once and deadlock.
            if (lines.count >= kFBPLogMaxLines) {
                [lines removeAllObjects];
                if (path.length) (void)truncate(path.fileSystemRepresentation, 0);
            }
        }
    });
    return lines;
}

static os_unfair_lock gFBPLogLock = OS_UNFAIR_LOCK_INIT;

// Pulls the notification extension's lines in before anyone reads the record:
// the extension appends to the shared file from its own process, so the count
// and the export have to come off the file rather than out of memory. Gated on
// the file having grown, because the Logs page polls the count.
static void FBPLogFlushPendingLocked(void);
static void FBPLogClearLocked(void);

// Call with gFBPLogLock held.
static void FBPLogReloadIfChangedLocked(void) {
    static off_t lastSize = -1;

    // Send the run in progress to the file FIRST: the pending line is the one
    // line this process has written that is not in the file yet, and the record
    // is about to be rebuilt from the file.
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

    // A line this process holds but the file does not is KEPT, not dropped: a
    // replace would delete any line that never reached the file. Anything
    // missing is by construction older than what the file holds, so it goes in
    // front.
    NSMutableArray<NSString *> *lines = FBPLogLines();
    NSSet<NSString *> *known = [NSSet setWithArray:fromFile];
    NSMutableArray<NSString *> *onlyInMemory = [NSMutableArray array];
    for (NSString *line in lines) {
        if (![known containsObject:line]) [onlyInMemory addObject:line];
    }

    [lines setArray:onlyInMemory];
    [lines addObjectsFromArray:fromFile];
    // Two processes writing one file can cross the ceiling here rather than at
    // the call that recorded the last line, so the same rule applies.
    if (lines.count >= kFBPLogMaxLines) FBPLogClearLocked();
}

// A run of consecutive identical lines collapses to one entry with a count.
// The in-memory entry is rewritten in place as the count climbs; os_log and the
// file mirror cannot rewrite what they already emitted, so they lag by one run —
// a line goes out when the next different line arrives.
static BOOL gFBPRunOK = NO;
static NSString *gFBPRunTag = nil;
static NSString *gFBPRunMessage = nil;
static NSString *gFBPPendingLine = nil;   // the run's line, not yet sent downstream
static NSUInteger gFBPRepeatCount = 0;

static NSString *FBPLineWithCount(NSString *base, NSUInteger count) {
    return count > 1 ? [NSString stringWithFormat:@"%@ x%lu", base, (unsigned long)count]
                     : base;
}

// Caller holds gFBPLogLock. Ending the run matters: a repeat arriving after a
// flush must start a fresh line, not keep counting into one already written out.
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

// A process's LAST line would otherwise never be written anywhere: the run in
// progress only goes out when a different line arrives. For the notification
// extension, which lives a few hundred milliseconds, that is most of its log.
static void FBPLogFlushAtExit(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    FBPLogFlushPendingLocked();
    os_unfair_lock_unlock(&gFBPLogLock);
}

void FBPLogRecord(BOOL ok, NSString *_Nullable tag, NSString *message) {
    if (!message.length) return;

    // Before any lock: resolving runs the App-Group redirect hook and the
    // preference read runs the suite hook, and both log, so they have to happen
    // where re-entering this function is harmless. Everything downstream reads
    // the cached values instead of calling out.
    (void)FBPTracePath();
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
        // Keeps the timestamp the run started at.
        lines[lines.count - 1] = FBPLineWithCount(gFBPPendingLine, gFBPRepeatCount);
        os_unfair_lock_unlock(&gFBPLogLock);
        return;
    }

    FBPLogFlushPendingLocked();

    NSString *line = FBPLogFormatLine(ok, tag, message);
    gFBPRunOK = ok;
    gFBPRunTag = [tag copy];
    gFBPRunMessage = [message copy];
    gFBPPendingLine = line;
    gFBPRepeatCount = 1;

    [lines addObject:line];

    // The record starts again and says so in its first line, because a log that
    // silently went short reads like logging broke.
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

// So a kept-across-launches log does not bring the cleared lines back.
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

// Call with gFBPLogLock held. File lock inside record lock is the order the
// rest of this file already uses, so nothing new can deadlock here.
static void FBPLogClearLocked(void) {
    [FBPLogLines() removeAllObjects];
    // End any run in progress so a repeat after the clear starts a fresh line.
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

void FBPLogClearIfDue(void) {
    // The clear itself happens where the record is created (FBPLogLines); this
    // only has to touch the record, which is what runs the window check.
    // Priming first keeps the preference read out of the locked path.
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

// On the Simulator sysctl reports the host architecture, so the identifier
// comes from the environment there.
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

static NSString *gFBPDeviceName = nil;
static os_unfair_lock gFBPDeviceNameLock = OS_UNFAIR_LOCK_INIT;

// A public device list; the entry whose "identifier" matches this hardware
// carries the marketing "name".
static NSString *const kFBPDeviceListURL = @"https://api.ipsw.me/v4/devices";

// On-disk cache, so an offline phone keeps the name it learned earlier.
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

// Looked up by hardware identifier, so a model newer than this build still gets
// its real name and no device table need ship in the binary. ONLY THE HARDWARE
// IDENTIFIER LEAVES THE DEVICE — never UIDevice.name, which usually holds the
// owner's own name. Runs once; the raw identifier stands in until it resolves.
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
        // Which file this came from and whether the extension could reach it.
        // Built outside both locks, so asking is safe here and nowhere inside
        // the funnel.
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

    // '-' where a log line uses ':' and '/': a colon is legal on device but
    // renders badly in the share sheet and in receiving apps.
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
